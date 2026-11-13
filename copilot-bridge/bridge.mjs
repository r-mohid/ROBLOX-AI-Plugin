// Copilot bridge for the Roblox Studio "AI Assistant" plugin.
//
// Roblox Studio can't sign in to GitHub Copilot by itself, so this small
// program runs on your PC, uses your normal Copilot sign-in (from
// `copilot login`) through GitHub's official Copilot SDK, and lets the plugin
// talk to it over http://127.0.0.1:34877. Nothing is reachable from other
// computers.
//
// Start it with start-bridge.bat (or `node bridge.mjs`) and leave the window
// open while you use the plugin.

import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { CopilotClient } from "@github/copilot-sdk";

const PORT = 34877;
const ALLOWED_HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`]);
const REPLY_TIMEOUT_MS = 10 * 60 * 1000;
const JOB_KEEP_MS = 15 * 60 * 1000;
const MAX_BODY_BYTES = 4 * 1024 * 1024;

// An empty folder for Copilot sessions, so they never look at your files.
const WORK_DIR = path.join(os.tmpdir(), "roblox-copilot-bridge");
fs.mkdirSync(WORK_DIR, { recursive: true });

const NOT_SIGNED_IN =
  "Copilot isn't signed in on this PC. In a terminal run:  copilot login  " +
  "then restart the bridge.";

// ---------------------------------------------------------------------------
// Copilot client (one for the whole bridge, restarted if it dies)
// ---------------------------------------------------------------------------

let clientPromise = null;

function getClient() {
  if (!clientPromise) {
    clientPromise = (async () => {
      const client = new CopilotClient({ workingDirectory: WORK_DIR });
      await client.start();
      return client;
    })().catch((error) => {
      clientPromise = null;
      throw error;
    });
  }
  return clientPromise;
}

async function resetClient() {
  const old = clientPromise;
  clientPromise = null;
  if (old) {
    try {
      await (await old).stop();
    } catch {
      // already gone
    }
  }
}

async function getAuth() {
  const client = await getClient();
  const auth = await client.getAuthStatus();
  return { client, auth };
}

function formatNumber(n) {
  return Math.round(Number(n) || 0).toLocaleString("en-US");
}

async function quotaText(client) {
  try {
    const result = await client.rpc.account.getQuota({});
    const snap = result?.quotaSnapshots?.premium_interactions;
    if (!snap) return null;
    if (snap.isUnlimitedEntitlement) return "Premium requests: unlimited";
    const left = Math.max(0, (snap.entitlementRequests ?? 0) - (snap.usedRequests ?? 0));
    let text =
      `Premium requests left: ${formatNumber(left)} of ${formatNumber(snap.entitlementRequests)}` +
      ` (${Math.round(snap.remainingPercentage ?? 0)}%)`;
    // Some accounts report "now" as the reset date; only show a real future date.
    const reset = Date.parse(snap.resetDate ?? "");
    if (reset > Date.now() + 60 * 60 * 1000) text += `, resets ${new Date(reset).toISOString().slice(0, 10)}`;
    return text;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Chat jobs. The plugin starts a job, then checks back every second, so a
// long reply never runs into Roblox's HTTP time limit.
// ---------------------------------------------------------------------------

const jobs = new Map();

function buildPrompt(messages) {
  const earlier = messages.slice(0, -1);
  const latest = messages[messages.length - 1];
  if (earlier.length === 0) return latest.text;

  const lines = ["Earlier in this conversation:"];
  for (const message of earlier) {
    lines.push("");
    lines.push(message.role === "assistant" ? "[Assistant]" : "[User]");
    lines.push(message.text);
  }
  lines.push("", "---", "", "The user's new message:", "", latest.text);
  return lines.join("\n");
}

async function runJob(job, { model, system, messages }) {
  let session = null;
  let client = null;
  try {
    const signIn = await getAuth();
    client = signIn.client;
    if (!signIn.auth.isAuthenticated) throw new Error(NOT_SIGNED_IN);

    session = await client.createSession({
      model,
      systemMessage: { mode: "replace", content: system },
      // A plain chat: no file, shell, web or MCP tools at all.
      availableTools: [],
      excludedTools: ["builtin:*", "mcp:*", "custom:*"],
      onPermissionRequest: () => ({ kind: "reject", feedback: "Tools are disabled in this bridge." }),
      workingDirectory: WORK_DIR,
    });

    let inputTokens = 0;
    let outputTokens = 0;
    let filtered = false;
    let finishReason = null;
    session.on("assistant.usage", (event) => {
      inputTokens += (event.data.inputTokens ?? 0) + (event.data.cacheReadTokens ?? 0) + (event.data.cacheWriteTokens ?? 0);
      outputTokens += event.data.outputTokens ?? 0;
      if (event.data.contentFilterTriggered) filtered = true;
      if (event.data.finishReason) finishReason = event.data.finishReason;
    });

    const response = await session.sendAndWait({ prompt: buildPrompt(messages) }, REPLY_TIMEOUT_MS);
    const text = response?.data?.content ?? "";

    let note = null;
    if (filtered) note = "(The model declined or was filtered. Try rewording it, or pick another model.)";
    else if (finishReason === "length") note = "(The reply was cut off at the length limit. Ask it to continue.)";
    if (!text && !note) throw new Error("Copilot returned no text. Try again, or pick another model.");

    Object.assign(job, {
      state: "done",
      text,
      note,
      inputTokens,
      outputTokens,
      quotaText: await quotaText(client),
    });
  } catch (error) {
    let message = error?.message ?? String(error);
    if (/not authenticated|unauthori[sz]ed|401/i.test(message)) message = NOT_SIGNED_IN;
    Object.assign(job, { state: "error", error: message });
    if (/connection|closed|ECONNRESET|EPIPE|disposed/i.test(message)) await resetClient();
  } finally {
    job.finishedAt = Date.now();
    if (session) {
      const id = session.sessionId;
      await session.disconnect().catch(() => {});
      // Don't leave one saved Copilot session per question lying around.
      if (client && id) await client.deleteSession(id).catch(() => {});
    }
  }
}

setInterval(() => {
  const cutoff = Date.now() - JOB_KEEP_MS;
  for (const [id, job] of jobs) {
    if (job.finishedAt && job.finishedAt < cutoff) jobs.delete(id);
  }
}, 60 * 1000).unref();

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------

function send(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("Request too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function validChatRequest(body) {
  if (!body || typeof body !== "object") return "Missing request body.";
  if (typeof body.model !== "string" || !body.model) return "Missing model.";
  if (typeof body.system !== "string") return "Missing system prompt.";
  if (!Array.isArray(body.messages) || body.messages.length === 0) return "Missing messages.";
  for (const message of body.messages) {
    if (!message || typeof message.text !== "string" || !["user", "assistant"].includes(message.role)) {
      return "Each message needs a role (user or assistant) and text.";
    }
  }
  if (body.messages[body.messages.length - 1].role !== "user") return "The last message must be from the user.";
  return null;
}

const server = http.createServer(async (req, res) => {
  // Only the Studio plugin on this PC: the right Host (blocks DNS-rebinding
  // tricks) and a custom header that web pages can't send without permission.
  if (!ALLOWED_HOSTS.has(String(req.headers.host ?? "").toLowerCase()) || req.headers["x-roblox-bridge"] !== "1") {
    return send(res, 403, { error: "Forbidden" });
  }

  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  try {
    if (req.method === "GET" && url.pathname === "/status") {
      const { client, auth } = await getAuth();
      return send(res, 200, {
        signedIn: !!auth.isAuthenticated,
        login: auth.login ?? null,
        message: auth.isAuthenticated ? null : NOT_SIGNED_IN,
        quotaText: auth.isAuthenticated ? await quotaText(client) : null,
      });
    }

    if (req.method === "GET" && url.pathname === "/models") {
      const { client, auth } = await getAuth();
      if (!auth.isAuthenticated) return send(res, 401, { error: NOT_SIGNED_IN });
      const models = (await client.listModels())
        .filter((m) => m.policy?.state !== "disabled")
        .map((m) => {
          const multiplier = m.billing?.multiplier;
          let cost = "";
          if (multiplier === 0) cost = " (free)";
          else if (typeof multiplier === "number") cost = ` (${multiplier}x)`;
          return { id: m.id, label: `${m.name || m.id}${cost}` };
        });
      return send(res, 200, { models });
    }

    if (req.method === "POST" && url.pathname === "/chat") {
      let body;
      try {
        body = JSON.parse(await readBody(req));
      } catch {
        return send(res, 400, { error: "The request wasn't valid JSON." });
      }
      const problem = validChatRequest(body);
      if (problem) return send(res, 400, { error: problem });

      const id = randomUUID();
      const job = { state: "running", startedAt: Date.now() };
      jobs.set(id, job);
      runJob(job, body);
      console.log(`[${new Date().toLocaleTimeString()}] Prompt sent to ${body.model}`);
      return send(res, 200, { jobId: id });
    }

    if (req.method === "GET" && url.pathname === "/job") {
      const job = jobs.get(url.searchParams.get("id") ?? "");
      if (!job) return send(res, 404, { error: "That request has expired. Send it again." });
      const { startedAt, finishedAt, ...visible } = job;
      return send(res, 200, visible);
    }

    return send(res, 404, { error: "Not found" });
  } catch (error) {
    await resetClient();
    return send(res, 500, { error: `Bridge error: ${error?.message ?? error}` });
  }
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    console.error(`Port ${PORT} is already in use. Is the bridge already running in another window?`);
  } else {
    console.error(error);
  }
  process.exit(1);
});

server.listen(PORT, "127.0.0.1", async () => {
  console.log(`Copilot bridge running on http://127.0.0.1:${PORT}`);
  try {
    const { auth } = await getAuth();
    if (auth.isAuthenticated) {
      console.log(`Signed in to Copilot as ${auth.login ?? "(unknown user)"}. Leave this window open while you use Studio.`);
    } else {
      console.log(NOT_SIGNED_IN);
    }
  } catch (error) {
    console.error(`Couldn't start Copilot: ${error?.message ?? error}`);
  }
});

async function shutdown() {
  server.close();
  await resetClient();
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
