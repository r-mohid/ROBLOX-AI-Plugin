--[[
	AI Assistant - a Roblox Studio plugin

	A small panel with a prompt box, a model picker and a token counter.
	You type what you want, and the AI (via Coarena, Claude, Gemini or
	GitHub Copilot) makes the change in your place straight away.

	Coarena works out of the box: your key is built in below (search for
	COARENA_BUILT_IN_KEY). Don't share this file, since it contains that key.
	Coarena stores every prompt and reply, including your scripts, and may
	license them to others - pick another service for anything private.

	INSTALL
	  Put this file in  %LOCALAPPDATA%\Roblox\Plugins  and restart Studio.
	  Then: Plugins tab -> AI Assistant -> click "Keys" and paste a key.

	HOW IT WORKS
	  1. You type what you want and press Enter (or Send).
	  2. The plugin sends your text plus an outline of your place (and the
	     script you have selected, if any) to the model you picked.
	  3. The AI replies with code, and the plugin runs it in Studio right
	     away as ONE undo step - Ctrl+Z reverts the whole change.
	     If the code fails, the change is rolled back and the AI is
	     automatically asked to fix it (up to 2 more tries).
	  4. A one-line summary of what was done appears under the box.

	NOTES
	  - Keys are stored in Studio's plugin settings on this computer, in plain
	    text. They are only ever sent to the provider they belong to.
	  - GitHub Copilot needs no key. Run copilot-bridge\start-bridge.bat and
	    keep its window open; it uses your Copilot sign-in (`copilot login`)
	    through GitHub's official Copilot SDK.
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")

-- Only run in the editor, not inside a play test.
if not RunService:IsEdit() then
	return
end

local COARENA_BUILT_IN_KEY = ""

----------------------------------------------------------------------
-- Settings you may want to tweak
----------------------------------------------------------------------

local MAX_REPLY_TOKENS = 16000 -- upper limit on the length of one reply
local MAX_HISTORY_MESSAGES = 12 -- how much of the chat is re-sent each time
local MAX_OUTLINE_PER_SERVICE = 60 -- Explorer lines sent per service
local MAX_SCRIPT_CHARS = 60000 -- selected script source sent (per message)
local MAX_FIX_ATTEMPTS = 2 -- automatic retries when the AI's code fails

local SYSTEM_PROMPT = [[You are built into a Roblox Studio plugin that edits the user's place for them. The user types what they want; the plugin runs your code immediately, without showing it to them, and shows them only your one-line summary. The user may be new to coding.

Every user message starts with a snapshot of the place: an outline of the Explorer and the current selection (including the source of a selected script).

Always reply with exactly one Luau code block and nothing else, in this form:

```lua
-- STUDIO_ACTION
-- SUMMARY: <one short, plain sentence: what you did, plus anything the user must do next, such as pressing Play to test>
<code>
```

Rules for the code:
- It runs in Studio's edit mode with plugin permissions, not in a running game. Use game:GetService, Instance.new, set properties and parent instances. To create or change a script, create or find the Script, LocalScript or ModuleScript and assign its .Source, using a long string such as [==[ ... ]==] for the source.
- It must not yield: no task.wait, WaitForChild or web requests, and no loops that keep running. The whole block is recorded as a single undo step.
- Only change what the user asked for. Never delete, replace or move things they didn't mention.
- Where it helps, finish by selecting what you made with game:GetService("Selection"):Set({ ... }).
- If the message is a question, or the request can't be done safely or isn't clear, write a block with only the two comment lines and put your short answer or question in the SUMMARY.

If a message says your previous code failed, the place was rolled back to how it was before that code ran. Fix the problem and reply with a complete corrected block.]]

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function trim(text)
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function formatNumber(value)
	local digits = tostring(math.floor((tonumber(value) or 0) + 0.5))
	local reversed = string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")
	local result = string.reverse(reversed)
	if string.sub(result, 1, 1) == "," then
		result = string.sub(result, 2)
	end
	return result
end

local function getSetting(name)
	local ok, value = pcall(function()
		return plugin:GetSetting(name)
	end)
	if ok and type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function setSetting(name, value)
	pcall(function()
		plugin:SetSetting(name, value)
	end)
end

----------------------------------------------------------------------
-- HTTP
----------------------------------------------------------------------

-- Returns the response table, or nil plus a readable error.
local function httpRequest(options)
	local ok, response = pcall(function()
		return HttpService:RequestAsync(options)
	end)
	if not ok then
		local message = tostring(response)
		if string.find(string.lower(message), "not enabled", 1, true) then
			message = message
				.. " (Turn on File > Game Settings > Security > Allow HTTP Requests, then try again.)"
		end
		return nil, "Couldn't reach the service: " .. message
	end
	return response
end

local function decodeJson(body)
	local ok, data = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	if ok and type(data) == "table" then
		return data
	end
	return nil
end

-- Header names can arrive in any letter case.
local function getHeader(response, name)
	if type(response.Headers) ~= "table" then
		return nil
	end
	for key, value in pairs(response.Headers) do
		if string.lower(tostring(key)) == name then
			return value
		end
	end
	return nil
end

local function describeFailure(serviceName, response, data)
	local detail = nil
	if data then
		if type(data.error) == "table" and type(data.error.message) == "string" then
			detail = data.error.message
		elseif type(data.error) == "string" then
			detail = data.error
		elseif type(data.message) == "string" then
			detail = data.message
		end
	end
	if not detail then
		detail = string.sub(tostring(response.Body or ""), 1, 300)
	end

	local code = response.StatusCode
	local hint = ""
	if code == 401 or code == 403 then
		hint = "\nThe key looks wrong or doesn't have access. Check it under Keys."
	elseif code == 404 then
		hint = "\nThis model may not be available to your account. Pick another model."
	elseif code == 429 then
		hint = "\nRate limit or quota reached. Wait a little, or check your plan and credits."
	elseif code >= 500 then
		hint = "\nThe service is having trouble. Try again shortly."
	end
	return serviceName .. " error " .. tostring(code) .. ": " .. detail .. hint
end

----------------------------------------------------------------------
-- Streaming
-- A normal request waits silently for the whole reply, and Roblox gives up
-- (HttpError: Timedout) when a big reply takes too long. Streaming receives
-- the reply bit by bit, so the connection never sits idle.
----------------------------------------------------------------------

local STREAM_LIMIT_SECONDS = 15 * 60
local PROGRESS_EVERY_SECONDS = 0.5

-- Turns incoming text into the "data:" payloads of a server-sent-event
-- stream. Works whether Roblox delivers raw chunks (which can split a line
-- in two) or one line at a time without the line break.
local function makeSSEParser(onData)
	local buffer = ""
	local stopped = false

	local function deliver(payload)
		if not stopped and payload ~= "" and onData(payload) == true then
			stopped = true
		end
	end

	local function handleLine(line)
		line = string.gsub(line, "\r$", "")
		if string.sub(line, 1, 5) == "data:" then
			deliver(trim(string.sub(line, 6)))
		end
	end

	local function looksComplete(payload)
		if payload == "[DONE]" then
			return true
		end
		return payload ~= "" and pcall(function()
			return HttpService:JSONDecode(payload)
		end)
	end

	local function feed(chunk)
		buffer = buffer .. chunk
		while true do
			local newline = string.find(buffer, "\n", 1, true)
			if not newline then
				break
			end
			handleLine(string.sub(buffer, 1, newline - 1))
			buffer = string.sub(buffer, newline + 1)
		end
		-- Text left over without a line break: use it now if it's already whole.
		if string.sub(buffer, 1, 5) == "data:" then
			local payload = trim(string.sub(buffer, 6))
			if looksComplete(payload) then
				buffer = ""
				deliver(payload)
			end
		elseif
			string.sub(buffer, 1, 6) == "event:"
			or string.sub(buffer, 1, 3) == "id:"
			or string.sub(buffer, 1, 6) == "retry:"
			or string.sub(buffer, 1, 1) == ":"
		then
			-- Only "data:" lines matter here.
			buffer = ""
		end
		return stopped
	end

	local function finish()
		if buffer ~= "" then
			handleLine(buffer)
			buffer = ""
		end
	end

	return feed, finish
end

-- Sends a request and reads its reply as a stream.
-- onData(payload) is called for each "data:" payload; returning true ends it.
-- Returns a table: ok, status, errorText, headersText, unsupported.
local function streamRequest(options, onData)
	local created, client = pcall(function()
		return HttpService:CreateWebStreamClient(Enum.WebStreamClientType.RawStream, options)
	end)
	if not created or not client then
		return { ok = false, unsupported = true, errorText = tostring(client) }
	end

	local feed, finish = makeSSEParser(onData)
	local status, headersText, errorText = nil, nil, nil
	local errorChunks = {}
	local rawHead = "" -- start of the reply, kept to explain non-stream errors
	local finished = false

	local connections = {
		client.Opened:Connect(function(statusCode, headers)
			status = tonumber(statusCode)
			headersText = type(headers) == "string" and headers or nil
		end),
		client.MessageReceived:Connect(function(chunk)
			if status and status >= 400 then
				table.insert(errorChunks, chunk)
				return
			end
			if #rawHead < 4000 then
				rawHead = rawHead .. string.sub(tostring(chunk), 1, 4000 - #rawHead)
			end
			local ok, stopped = pcall(feed, tostring(chunk))
			if not ok then
				errorText = "Couldn't read the reply: " .. tostring(stopped)
				finished = true
			elseif stopped then
				finished = true
			end
		end),
		client.Error:Connect(function(statusCode, message)
			local code = tonumber(statusCode)
			if code and code > 0 then
				status = code
			end
			errorText = tostring(message)
			finished = true
		end),
		client.Closed:Connect(function()
			finished = true
		end),
	}

	local deadline = os.time() + STREAM_LIMIT_SECONDS
	while not finished and os.time() < deadline do
		task.wait(0.1)
	end
	if not finished then
		errorText = "The reply took longer than " .. tostring(STREAM_LIMIT_SECONDS / 60) .. " minutes."
	end

	pcall(finish)
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	pcall(function()
		client:Close()
	end)

	if #errorChunks > 0 then
		errorText = table.concat(errorChunks)
	end
	return {
		ok = errorText == nil and (status == nil or status < 400),
		status = status,
		errorText = errorText,
		headersText = headersText,
		rawHead = rawHead,
		unsupported = false,
	}
end

-- Turns a failed stream into a readable message.
local function describeStreamFailure(serviceName, outcome)
	local status = outcome.status
	if status and status >= 400 then
		local body = outcome.errorText or ""
		return describeFailure(serviceName, { StatusCode = status, Body = body }, decodeJson(body))
	end
	local message = tostring(outcome.errorText or "the connection closed early")
	if string.find(string.lower(message), "not enabled", 1, true) then
		message = message .. " (Turn on File > Game Settings > Security > Allow HTTP Requests, then try again.)"
	end
	return "Couldn't reach " .. serviceName .. ": " .. message
end

-- When a stream produced no text, explains why if the server sent a plain
-- JSON error instead of a stream.
local function plainErrorFromStream(serviceName, outcome)
	local data = decodeJson(trim(outcome.rawHead or ""))
	if data and data.error ~= nil then
		return describeFailure(serviceName, { StatusCode = outcome.status or 400, Body = outcome.rawHead }, data)
	end
	return nil
end

-- Reads one header from the headers text a stream reports.
local function headerFromText(headersText, name)
	if type(headersText) ~= "string" then
		return nil
	end
	for line in string.gmatch(headersText, "[^\r\n]+") do
		local key, value = string.match(line, "^%s*([^:]+):%s*(.-)%s*$")
		if key and string.lower(key) == name then
			return value
		end
	end
	return nil
end

-- Calls onProgress(characters) at most twice a second.
local function makeProgress(onProgress)
	local last = 0
	return function(characters)
		if onProgress and os.clock() - last >= PROGRESS_EVERY_SECONDS then
			last = os.clock()
			pcall(onProgress, characters)
		end
	end
end

----------------------------------------------------------------------
-- Claude (Anthropic)
----------------------------------------------------------------------

local CLAUDE_HEADERS_VERSION = "2026-10-21"

-- Models where a declined request can be re-run on another model server-side.
local CLAUDE_FALLBACK_MODELS = {
	["claude-fable-5-2"] = true,
	["claude-fable-5-1"] = true,
	["claude-opus-5-5"] = true,
	["claude-opus-5"] = true,
	["claude-sonnet-5-5"] = true,
}

local function callClaudeBlocking(key, modelId, systemPrompt, messages)
	local outgoing = {}
	for index, message in ipairs(messages) do
		outgoing[index] = { role = message.role, content = message.text }
	end

	local body = {
		model = modelId,
		max_tokens = MAX_REPLY_TOKENS,
		system = systemPrompt,
		messages = outgoing,
	}
	local headers = {
		["Content-Type"] = "application/json",
		["x-api-key"] = key,
		["anthropic-version"] = CLAUDE_HEADERS_VERSION,
	}

	local usingFallback = CLAUDE_FALLBACK_MODELS[modelId] == true
	if usingFallback then
		body.fallbacks = "default"
		headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
	end

	local function post()
		return httpRequest({
			Url = "https://api.anthropic.com/v1/messages",
			Method = "POST",
			Headers = headers,
			Body = HttpService:JSONEncode(body),
		})
	end

	local response, requestError = post()
	if not response then
		return nil, requestError
	end
	local data = decodeJson(response.Body)

	-- The fallback option is optional: if the API rejects it, send the plain request.
	if response.StatusCode == 400 and usingFallback then
		local message = string.lower(describeFailure("Claude", response, data))
		if string.find(message, "fallback", 1, true) or string.find(message, "beta", 1, true) then
			body.fallbacks = nil
			headers["anthropic-beta"] = nil
			response, requestError = post()
			if not response then
				return nil, requestError
			end
			data = decodeJson(response.Body)
		end
	end

	if not response.Success or not data then
		return nil, describeFailure("Claude", response, data)
	end

	local pieces = {}
	if type(data.content) == "table" then
		for _, block in ipairs(data.content) do
			if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
				table.insert(pieces, block.text)
			end
		end
	end
	local text = table.concat(pieces, "")

	local note = nil
	if data.stop_reason == "refusal" then
		if text == "" then
			return nil, "The model declined this request. Try rewording it, or pick another model."
		end
		note = "(The model stopped early and declined to continue.)"
	elseif data.stop_reason == "max_tokens" then
		note = "(The reply was cut off at the length limit. Ask it to continue.)"
	end

	local usage = type(data.usage) == "table" and data.usage or {}
	local inputTokens = (tonumber(usage.input_tokens) or 0)
		+ (tonumber(usage.cache_creation_input_tokens) or 0)
		+ (tonumber(usage.cache_read_input_tokens) or 0)

	local limitText = nil
	local remaining = tonumber(getHeader(response, "anthropic-ratelimit-tokens-remaining"))
	local limit = tonumber(getHeader(response, "anthropic-ratelimit-tokens-limit"))
	if remaining and limit then
		limitText = "Rate limit left: " .. formatNumber(remaining) .. " of " .. formatNumber(limit) .. " tokens/min"
	elseif remaining then
		limitText = "Rate limit left: " .. formatNumber(remaining) .. " tokens/min"
	end

	return {
		text = text,
		inputTokens = inputTokens,
		outputTokens = tonumber(usage.output_tokens) or 0,
		limitText = limitText,
		note = note,
	}
end

local function listClaudeModels(key)
	local response = httpRequest({
		Url = "https://api.anthropic.com/v1/models?limit=100",
		Method = "GET",
		Headers = {
			["x-api-key"] = key,
			["anthropic-version"] = CLAUDE_HEADERS_VERSION,
		},
	})
	if not response or not response.Success then
		return nil
	end
	local data = decodeJson(response.Body)
	if not data or type(data.data) ~= "table" then
		return nil
	end
	local models = {}
	for _, entry in ipairs(data.data) do
		if type(entry) == "table" and type(entry.id) == "string" and string.sub(entry.id, 1, 7) == "claude-" then
			table.insert(models, {
				id = entry.id,
				label = type(entry.display_name) == "string" and entry.display_name or entry.id,
			})
			if #models >= 12 then
				break
			end
		end
	end
	return models
end

----------------------------------------------------------------------
-- Gemini (Google)
----------------------------------------------------------------------

local GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/"

local function callGeminiBlocking(key, modelId, systemPrompt, messages)
	local contents = {}
	for index, message in ipairs(messages) do
		contents[index] = {
			role = (message.role == "assistant") and "model" or "user",
			parts = { { text = message.text } },
		}
	end

	local response, requestError = httpRequest({
		Url = GEMINI_BASE .. "models/" .. modelId .. ":generateContent",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["x-goog-api-key"] = key,
		},
		Body = HttpService:JSONEncode({
			systemInstruction = { parts = { { text = systemPrompt } } },
			contents = contents,
			generationConfig = { maxOutputTokens = MAX_REPLY_TOKENS },
		}),
	})
	if not response then
		return nil, requestError
	end
	local data = decodeJson(response.Body)
	if not response.Success or not data then
		return nil, describeFailure("Gemini", response, data)
	end

	if type(data.promptFeedback) == "table" and data.promptFeedback.blockReason then
		return nil, "Gemini blocked this request (" .. tostring(data.promptFeedback.blockReason) .. "). Try rewording it."
	end

	local candidate = type(data.candidates) == "table" and data.candidates[1] or nil
	local pieces = {}
	if type(candidate) == "table" and type(candidate.content) == "table" and type(candidate.content.parts) == "table" then
		for _, part in ipairs(candidate.content.parts) do
			-- Skip the model's private "thought" parts; keep the answer.
			if type(part) == "table" and type(part.text) == "string" and part.thought ~= true then
				table.insert(pieces, part.text)
			end
		end
	end
	local text = table.concat(pieces, "")
	local finishReason = type(candidate) == "table" and candidate.finishReason or nil

	local note = nil
	if text == "" then
		return nil, "Gemini returned no text (reason: " .. tostring(finishReason or "unknown") .. "). Try again or reword it."
	elseif finishReason == "MAX_TOKENS" then
		note = "(The reply was cut off at the length limit. Ask it to continue.)"
	end

	local usage = type(data.usageMetadata) == "table" and data.usageMetadata or {}
	return {
		text = text,
		inputTokens = tonumber(usage.promptTokenCount) or 0,
		outputTokens = (tonumber(usage.candidatesTokenCount) or 0) + (tonumber(usage.thoughtsTokenCount) or 0),
		limitText = nil,
		note = note,
	}
end

local GEMINI_SKIP_WORDS = { "embedding", "image", "tts", "audio", "live", "robotics", "computer" }

local function listGeminiModels(key)
	local response = httpRequest({
		Url = GEMINI_BASE .. "models?pageSize=200",
		Method = "GET",
		Headers = { ["x-goog-api-key"] = key },
	})
	if not response or not response.Success then
		return nil
	end
	local data = decodeJson(response.Body)
	if not data or type(data.models) ~= "table" then
		return nil
	end

	local models = {}
	for _, entry in ipairs(data.models) do
		if type(entry) == "table" and type(entry.name) == "string" then
			local id = string.gsub(entry.name, "^models/", "")
			local usable = string.sub(id, 1, 7) == "gemini-"
			if usable and type(entry.supportedGenerationMethods) == "table" then
				usable = false
				for _, method in ipairs(entry.supportedGenerationMethods) do
					if method == "generateContent" then
						usable = true
					end
				end
			end
			if usable then
				for _, word in ipairs(GEMINI_SKIP_WORDS) do
					if string.find(id, word, 1, true) then
						usable = false
					end
				end
			end
			if usable then
				table.insert(models, {
					id = id,
					label = type(entry.displayName) == "string" and entry.displayName or id,
				})
			end
		end
	end
	-- Newest version numbers first.
	table.sort(models, function(a, b)
		return a.id > b.id
	end)
	while #models > 14 do
		table.remove(models)
	end
	return models
end

----------------------------------------------------------------------
-- GitHub Copilot
----------------------------------------------------------------------

-- Copilot has no API keys, so the plugin talks to the small "Copilot bridge"
-- program (copilot-bridge\start-bridge.bat) running on this PC. The bridge
-- uses your normal Copilot sign-in through GitHub's official Copilot SDK.

local BRIDGE_BASE = "http://127.0.0.1:34877"
local BRIDGE_REPLY_LIMIT_SECONDS = 11 * 60

local BRIDGE_DOWN = "Can't reach the Copilot bridge. Double-click start-bridge.bat in the "
	.. "copilot-bridge folder, leave that window open, then try again."

local function bridgeRequest(method, route, body)
	local options = {
		Url = BRIDGE_BASE .. route,
		Method = method,
		Headers = { ["X-Roblox-Bridge"] = "1" },
	}
	if body then
		options.Headers["Content-Type"] = "application/json"
		options.Body = HttpService:JSONEncode(body)
	end
	local response = httpRequest(options)
	if not response then
		return nil, BRIDGE_DOWN
	end
	local data = decodeJson(response.Body)
	if not response.Success or not data then
		local message = data and type(data.error) == "string" and data.error
			or ("Copilot bridge error " .. tostring(response.StatusCode))
		return nil, message
	end
	return data
end

local function callCopilot(_, modelId, systemPrompt, messages)
	local outgoing = {}
	for index, message in ipairs(messages) do
		outgoing[index] = { role = message.role, text = message.text }
	end

	local started, startError = bridgeRequest("POST", "/chat", {
		model = modelId,
		system = systemPrompt,
		messages = outgoing,
	})
	if not started then
		return nil, startError
	end
	if type(started.jobId) ~= "string" then
		return nil, "The Copilot bridge gave an unexpected answer. Restart it and try again."
	end

	-- Check back every second until the reply is ready.
	local deadline = os.clock() + BRIDGE_REPLY_LIMIT_SECONDS
	while os.clock() < deadline do
		task.wait(1)
		local job, jobError = bridgeRequest("GET", "/job?id=" .. HttpService:UrlEncode(started.jobId))
		if not job then
			return nil, jobError
		end
		if job.state == "error" then
			return nil, "Copilot: " .. tostring(job.error)
		end
		if job.state == "done" then
			return {
				text = type(job.text) == "string" and job.text or "",
				inputTokens = tonumber(job.inputTokens) or 0,
				outputTokens = tonumber(job.outputTokens) or 0,
				limitText = type(job.quotaText) == "string" and job.quotaText or nil,
				note = type(job.note) == "string" and job.note or nil,
			}
		end
	end
	return nil, "Copilot took too long to answer. Try again, or pick a faster model."
end

local copilotQuotaText = nil

local function listCopilotModels()
	local status = bridgeRequest("GET", "/status")
	if not status then
		return nil
	end
	if type(status.quotaText) == "string" then
		copilotQuotaText = status.quotaText
	end
	if not status.signedIn then
		return nil
	end
	local data = bridgeRequest("GET", "/models")
	if not data or type(data.models) ~= "table" then
		return nil
	end
	local models = {}
	for _, entry in ipairs(data.models) do
		if type(entry) == "table" and type(entry.id) == "string" then
			table.insert(models, {
				id = entry.id,
				label = type(entry.label) == "string" and entry.label or entry.id,
			})
		end
	end
	return models
end

----------------------------------------------------------------------
-- Coarena (free Model API: $5 of usage per day, many models)
----------------------------------------------------------------------

local COARENA_BASE = "https://coarena.ai/api/v1"
-- Your Coarena key, built in. Paste a different one under Keys to override it.
local COARENA_MAX_TOKENS = 16000 -- Coarena allows up to 16,384 per reply

local coarenaBalanceText = nil

local function formatDollars(value)
	return string.format("$%.2f", math.max(0, tonumber(value) or 0))
end

-- Reads how much of today's free allowance is left.
local function refreshCoarenaBalance(key)
	local response = httpRequest({
		Url = COARENA_BASE .. "/usage",
		Method = "GET",
		Headers = { ["Authorization"] = "Bearer " .. key },
	})
	if not response or not response.Success then
		return
	end
	local data = decodeJson(response.Body)
	data = data and data.data
	if type(data) ~= "table" or type(data.today) ~= "table" or type(data.limits) ~= "table" then
		return
	end
	local allowance = tonumber(data.limits.usd_per_day)
	if not allowance then
		return
	end
	local used = (tonumber(data.today.spent_usd) or 0) + (tonumber(data.today.held_usd) or 0)
	local text = "Coarena today: " .. formatDollars(allowance - used) .. " of " .. formatDollars(allowance) .. " left"

	local resetsAt = tonumber(data.today.resets_at)
	if resetsAt then
		local hours = math.floor((resetsAt / 1000 - os.time()) / 3600 + 0.5)
		if hours >= 1 then
			text = text .. " (resets in " .. tostring(hours) .. "h)"
		end
	end
	coarenaBalanceText = text
end

local function callCoarenaBlocking(key, modelId, systemPrompt, messages)
	local outgoing = { { role = "system", content = systemPrompt } }
	for _, message in ipairs(messages) do
		table.insert(outgoing, { role = message.role, content = message.text })
	end

	local response, requestError = httpRequest({
		Url = COARENA_BASE .. "/chat/completions",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer " .. key,
		},
		Body = HttpService:JSONEncode({
			model = modelId,
			max_tokens = COARENA_MAX_TOKENS,
			messages = outgoing,
		}),
	})
	if not response then
		return nil, requestError
	end
	local data = decodeJson(response.Body)
	if not response.Success or not data then
		return nil, describeFailure("Coarena", response, data)
	end

	local choice = type(data.choices) == "table" and data.choices[1] or nil
	local message = type(choice) == "table" and type(choice.message) == "table" and choice.message or {}
	local text = type(message.content) == "string" and message.content or ""

	local note = nil
	if type(message.refusal) == "string" and message.refusal ~= "" and text == "" then
		return nil, "The model declined this request. Try rewording it, or pick another model."
	end
	if text == "" then
		return nil, "Coarena returned no text. Try again, or pick another model."
	end
	if type(choice) == "table" and choice.finish_reason == "length" then
		note = "(The reply was cut off at the length limit.)"
	end
	local substitutedTo = getHeader(response, "x-coarena-substituted-to")
	if substitutedTo and substitutedTo ~= "" then
		note = (note and (note .. " ") or "") .. "(Coarena answered with " .. tostring(substitutedTo) .. " instead.)"
	end

	refreshCoarenaBalance(key)

	local usage = type(data.usage) == "table" and data.usage or {}
	return {
		text = text,
		inputTokens = tonumber(usage.prompt_tokens) or 0,
		outputTokens = tonumber(usage.completion_tokens) or 0,
		limitText = coarenaBalanceText,
		note = note,
	}
end

local function listCoarenaModels(key)
	refreshCoarenaBalance(key)
	local response = httpRequest({
		Url = COARENA_BASE .. "/models",
		Method = "GET",
		Headers = { ["Authorization"] = "Bearer " .. key },
	})
	if not response or not response.Success then
		return nil
	end
	local data = decodeJson(response.Body)
	if not data or type(data.data) ~= "table" then
		return nil
	end
	local models = {}
	for _, entry in ipairs(data.data) do
		if type(entry) == "table" and type(entry.id) == "string" and entry.lifecycle ~= "retired" then
			table.insert(models, {
				id = entry.id,
				label = type(entry.display_name) == "string" and entry.display_name or entry.id,
			})
		end
	end
	return models
end

----------------------------------------------------------------------
-- Streaming versions of the Claude, Gemini and Coarena calls.
-- Each falls back to a normal request if this Studio can't stream.
----------------------------------------------------------------------

local function streamClaude(key, modelId, systemPrompt, messages, onProgress)
	local outgoing = {}
	for index, message in ipairs(messages) do
		outgoing[index] = { role = message.role, content = message.text }
	end

	local body = {
		model = modelId,
		max_tokens = MAX_REPLY_TOKENS,
		system = systemPrompt,
		messages = outgoing,
		stream = true,
	}
	local headers = {
		["Content-Type"] = "application/json",
		["x-api-key"] = key,
		["anthropic-version"] = CLAUDE_HEADERS_VERSION,
	}
	local usingFallback = CLAUDE_FALLBACK_MODELS[modelId] == true
	if usingFallback then
		body.fallbacks = "default"
		headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
	end

	local parts, inputTokens, outputTokens, stopReason, apiError
	local progress = makeProgress(onProgress)

	local function run()
		parts, inputTokens, outputTokens, stopReason, apiError = {}, 0, 0, nil, nil
		local written = 0
		return streamRequest({
			Url = "https://api.anthropic.com/v1/messages",
			Method = "POST",
			Headers = headers,
			Body = HttpService:JSONEncode(body),
		}, function(payload)
			local event = decodeJson(payload)
			if not event then
				return
			end
			if event.type == "message_start" and type(event.message) == "table" then
				local usage = type(event.message.usage) == "table" and event.message.usage or {}
				inputTokens = (tonumber(usage.input_tokens) or 0)
					+ (tonumber(usage.cache_creation_input_tokens) or 0)
					+ (tonumber(usage.cache_read_input_tokens) or 0)
			elseif event.type == "content_block_start" and type(event.content_block) == "table" then
				if event.content_block.type == "fallback" then
					-- Another model took over: drop the text the first one started.
					parts, written = {}, 0
				end
			elseif event.type == "content_block_delta" and type(event.delta) == "table" then
				if event.delta.type == "text_delta" and type(event.delta.text) == "string" then
					table.insert(parts, event.delta.text)
					written = written + #event.delta.text
					progress(written)
				end
			elseif event.type == "message_delta" then
				if type(event.delta) == "table" and event.delta.stop_reason then
					stopReason = event.delta.stop_reason
				end
				if type(event.usage) == "table" and tonumber(event.usage.output_tokens) then
					outputTokens = tonumber(event.usage.output_tokens)
				end
			elseif event.type == "message_stop" then
				return true
			elseif event.type == "error" then
				apiError = type(event.error) == "table" and event.error.message or "unknown error"
				return true
			end
		end)
	end

	local outcome = run()
	if outcome.unsupported then
		return nil, nil, true
	end
	-- The fallback option is optional: if the API rejects it, send the plain request.
	if not outcome.ok and outcome.status == 400 and usingFallback then
		local message = string.lower(tostring(outcome.errorText))
		if string.find(message, "fallback", 1, true) or string.find(message, "beta", 1, true) then
			body.fallbacks = nil
			headers["anthropic-beta"] = nil
			outcome = run()
		end
	end
	if not outcome.ok then
		return nil, describeStreamFailure("Claude", outcome)
	end
	if apiError then
		return nil, "Claude error: " .. tostring(apiError)
	end

	local text = table.concat(parts, "")
	local note = nil
	if stopReason == "refusal" then
		if text == "" then
			return nil, "The model declined this request. Try rewording it, or pick another model."
		end
		note = "(The model stopped early and declined to continue.)"
	elseif stopReason == "max_tokens" then
		note = "(The reply was cut off at the length limit.)"
	end
	if text == "" and not note then
		return nil, plainErrorFromStream("Claude", outcome) or "Claude returned no text. Try again."
	end

	local limitText = nil
	local remaining = tonumber(headerFromText(outcome.headersText, "anthropic-ratelimit-tokens-remaining"))
	local limit = tonumber(headerFromText(outcome.headersText, "anthropic-ratelimit-tokens-limit"))
	if remaining and limit then
		limitText = "Rate limit left: " .. formatNumber(remaining) .. " of " .. formatNumber(limit) .. " tokens/min"
	end

	return {
		text = text,
		inputTokens = inputTokens,
		outputTokens = outputTokens,
		limitText = limitText,
		note = note,
	}
end

local function streamGemini(key, modelId, systemPrompt, messages, onProgress)
	local contents = {}
	for index, message in ipairs(messages) do
		contents[index] = {
			role = (message.role == "assistant") and "model" or "user",
			parts = { { text = message.text } },
		}
	end

	local parts, usage, finishReason, blockReason, apiError = {}, {}, nil, nil, nil
	local written = 0
	local progress = makeProgress(onProgress)

	local outcome = streamRequest({
		Url = GEMINI_BASE .. "models/" .. modelId .. ":streamGenerateContent?alt=sse",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["x-goog-api-key"] = key,
		},
		Body = HttpService:JSONEncode({
			systemInstruction = { parts = { { text = systemPrompt } } },
			contents = contents,
			generationConfig = { maxOutputTokens = MAX_REPLY_TOKENS },
		}),
	}, function(payload)
		local data = decodeJson(payload)
		if not data then
			return
		end
		if type(data.error) == "table" then
			apiError = data.error.message or "unknown error"
			return true
		end
		if type(data.promptFeedback) == "table" and data.promptFeedback.blockReason then
			blockReason = tostring(data.promptFeedback.blockReason)
		end
		if type(data.usageMetadata) == "table" then
			usage = data.usageMetadata
		end
		local candidate = type(data.candidates) == "table" and data.candidates[1] or nil
		if type(candidate) == "table" then
			if candidate.finishReason then
				finishReason = candidate.finishReason
			end
			if type(candidate.content) == "table" and type(candidate.content.parts) == "table" then
				for _, part in ipairs(candidate.content.parts) do
					-- Skip the model's private "thought" parts; keep the answer.
					if type(part) == "table" and type(part.text) == "string" and part.thought ~= true then
						table.insert(parts, part.text)
						written = written + #part.text
						progress(written)
					end
				end
			end
		end
	end)

	if outcome.unsupported then
		return nil, nil, true
	end
	if not outcome.ok then
		return nil, describeStreamFailure("Gemini", outcome)
	end
	if apiError then
		return nil, "Gemini error: " .. tostring(apiError)
	end
	if blockReason then
		return nil, "Gemini blocked this request (" .. blockReason .. "). Try rewording it."
	end

	local text = table.concat(parts, "")
	local note = nil
	if text == "" then
		return nil,
			plainErrorFromStream("Gemini", outcome)
				or ("Gemini returned no text (reason: " .. tostring(finishReason or "unknown") .. "). Try again.")
	elseif finishReason == "MAX_TOKENS" then
		note = "(The reply was cut off at the length limit.)"
	end

	return {
		text = text,
		inputTokens = tonumber(usage.promptTokenCount) or 0,
		outputTokens = (tonumber(usage.candidatesTokenCount) or 0) + (tonumber(usage.thoughtsTokenCount) or 0),
		limitText = nil,
		note = note,
	}
end

local function streamCoarena(key, modelId, systemPrompt, messages, onProgress)
	local outgoing = { { role = "system", content = systemPrompt } }
	for _, message in ipairs(messages) do
		table.insert(outgoing, { role = message.role, content = message.text })
	end

	local parts, usage, finishReason, refusal, apiError = {}, {}, nil, nil, nil
	local written = 0
	local progress = makeProgress(onProgress)

	local outcome = streamRequest({
		Url = COARENA_BASE .. "/chat/completions",
		Method = "POST",
		Headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer " .. key,
		},
		Body = HttpService:JSONEncode({
			model = modelId,
			max_tokens = COARENA_MAX_TOKENS,
			messages = outgoing,
			stream = true,
			stream_options = { include_usage = true },
		}),
	}, function(payload)
		if payload == "[DONE]" then
			return true
		end
		local data = decodeJson(payload)
		if not data then
			return
		end
		if data.error ~= nil then
			apiError = type(data.error) == "table" and data.error.message or tostring(data.error)
			return true
		end
		if type(data.usage) == "table" then
			usage = data.usage
		end
		local choice = type(data.choices) == "table" and data.choices[1] or nil
		if type(choice) == "table" then
			if choice.finish_reason then
				finishReason = choice.finish_reason
			end
			local delta = choice.delta
			if type(delta) == "table" then
				if type(delta.content) == "string" then
					table.insert(parts, delta.content)
					written = written + #delta.content
					progress(written)
				end
				if type(delta.refusal) == "string" then
					refusal = (refusal or "") .. delta.refusal
				end
			end
		end
	end)

	if outcome.unsupported then
		return nil, nil, true
	end
	if not outcome.ok then
		return nil, describeStreamFailure("Coarena", outcome)
	end
	if apiError then
		return nil, "Coarena error: " .. tostring(apiError)
	end

	local text = table.concat(parts, "")
	if text == "" then
		if refusal then
			return nil, "The model declined this request. Try rewording it, or pick another model."
		end
		return nil, plainErrorFromStream("Coarena", outcome) or "Coarena returned no text. Try again, or pick another model."
	end

	local note = nil
	if finishReason == "length" then
		note = "(The reply was cut off at the length limit.)"
	end
	local substitutedTo = headerFromText(outcome.headersText, "x-coarena-substituted-to")
	if substitutedTo and substitutedTo ~= "" then
		note = (note and (note .. " ") or "") .. "(Coarena answered with " .. substitutedTo .. " instead.)"
	end

	refreshCoarenaBalance(key)

	return {
		text = text,
		inputTokens = tonumber(usage.prompt_tokens) or 0,
		outputTokens = tonumber(usage.completion_tokens) or 0,
		limitText = coarenaBalanceText,
		note = note,
	}
end

-- Stream when possible; otherwise send a normal request.
local function withFallback(streamFn, blockingFn)
	return function(key, modelId, systemPrompt, messages, onProgress)
		local result, problem, unsupported = streamFn(key, modelId, systemPrompt, messages, onProgress)
		if unsupported then
			return blockingFn(key, modelId, systemPrompt, messages)
		end
		return result, problem
	end
end

local callClaude = withFallback(streamClaude, callClaudeBlocking)
local callGemini = withFallback(streamGemini, callGeminiBlocking)
local callCoarena = withFallback(streamCoarena, callCoarenaBlocking)

----------------------------------------------------------------------
-- Providers and their starting model lists
-- (each list is replaced by the live list from your account once a key is saved)
----------------------------------------------------------------------

local PROVIDERS = {
	{
		id = "coarena",
		label = "Coarena (free, $5/day)",
		keyName = "AIA_CoarenaKey",
		defaultKey = COARENA_BUILT_IN_KEY,
		keyLabel = "Coarena key - built in already; paste only to use a different one",
		keyHint = "coa_...",
		balanceHint = "Coarena: $5 of free usage per day",
		call = callCoarena,
		listModels = listCoarenaModels,
		models = {
			{ id = "claude-opus-5-5", label = "Claude Opus 5.5" },
			{ id = "claude-sonnet-5-5", label = "Claude Sonnet 5.5" },
			{ id = "gemini-4-carbon", label = "Gemini 4 Carbon" },
			{ id = "grok-4-7", label = "Grok 4.7" },
		},
	},
	{
		id = "claude",
		label = "Claude",
		keyName = "AIA_ClaudeKey",
		keyLabel = "Claude API key - from platform.claude.com (API keys)",
		keyHint = "sk-ant-...",
		balanceHint = "Credit balance: see platform.claude.com (not shared with plugins)",
		call = callClaude,
		listModels = listClaudeModels,
		models = {
			{ id = "claude-opus-5-5", label = "Claude Opus 5.5" },
			{ id = "claude-fable-5-2", label = "Claude Fable 5.2 (most capable, priciest)" },
			{ id = "claude-sonnet-5-5", label = "Claude Sonnet 5.5" },
			{ id = "claude-haiku-5-5", label = "Claude Haiku 5.5 (cheapest)" },
		},
	},
	{
		id = "gemini",
		label = "Gemini",
		keyName = "AIA_GeminiKey",
		keyLabel = "Gemini API key - from aistudio.google.com (Get API key)",
		keyHint = "AIza...",
		balanceHint = "Quota left: see aistudio.google.com (not shared with plugins)",
		call = callGemini,
		listModels = listGeminiModels,
		models = {
			{ id = "gemini-4-carbon", label = "Gemini 4 Carbon (most capable)" },
			{ id = "gemini-4-argon", label = "Gemini 4 Argon" },
			{ id = "gemini-3.8-flash", label = "Gemini 3.8 Flash" },
			{ id = "gemini-3.5-flash-lite", label = "Gemini 3.5 Flash-Lite (cheapest)" },
		},
	},
	{
		id = "copilot",
		label = "GitHub Copilot",
		keyName = nil, -- no key: uses the Copilot bridge and your Copilot sign-in
		balanceHint = "Start the Copilot bridge to see your premium requests left",
		call = callCopilot,
		listModels = listCopilotModels,
		models = {
			{ id = "auto", label = "Copilot: Auto (picks a model for you)" },
		},
	},
}

-- The key to use: one pasted under Keys, otherwise a built-in one (Coarena).
local function providerKey(provider)
	if not provider.keyName then
		return nil
	end
	return getSetting(provider.keyName) or provider.defaultKey
end

-- The providers that need a pasted key (shown on the Keys screen).
local KEY_PROVIDERS = {}
for _, provider in ipairs(PROVIDERS) do
	if provider.keyName then
		table.insert(KEY_PROVIDERS, provider)
	end
end

----------------------------------------------------------------------
-- What the model gets to see of your place
----------------------------------------------------------------------

local OUTLINE_SERVICES = {
	"Workspace",
	"Lighting",
	"ReplicatedFirst",
	"ReplicatedStorage",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"SoundService",
	"Teams",
}

local function readScriptSource(instance)
	-- Prefer what is in the script editor (it may have unsaved edits).
	local ok, source = pcall(function()
		return game:GetService("ScriptEditorService"):GetEditorSource(instance)
	end)
	if ok and type(source) == "string" then
		return source
	end
	ok, source = pcall(function()
		return instance.Source
	end)
	if ok and type(source) == "string" then
		return source
	end
	return nil
end

-- Returns the snapshot text, plus a warning for the user when something was left out.
local function buildSnapshot()
	local lines = { "Explorer outline (name, class):" }

	for _, serviceName in ipairs(OUTLINE_SERVICES) do
		local ok, service = pcall(function()
			return game:GetService(serviceName)
		end)
		if ok and service then
			table.insert(lines, serviceName)
			local count = 0
			local cutShort = false
			local function walk(parent, depth, indent)
				local okChildren, children = pcall(function()
					return parent:GetChildren()
				end)
				if not okChildren then
					return
				end
				for _, child in ipairs(children) do
					if count >= MAX_OUTLINE_PER_SERVICE then
						cutShort = true
						return
					end
					count = count + 1
					table.insert(lines, indent .. child.Name .. " (" .. child.ClassName .. ")")
					if depth < 3 then
						walk(child, depth + 1, indent .. "  ")
					end
				end
			end
			walk(service, 1, "  ")
			if cutShort then
				table.insert(lines, "  ... (more items not listed)")
			end
		end
	end

	local warning = nil
	local selected = Selection:Get()
	table.insert(lines, "")
	if #selected == 0 then
		table.insert(lines, "Current selection: nothing selected")
	else
		table.insert(lines, "Current selection:")
		local budget = MAX_SCRIPT_CHARS
		for index, instance in ipairs(selected) do
			if index > 5 then
				table.insert(lines, "  ... and " .. tostring(#selected - 5) .. " more")
				break
			end
			table.insert(lines, "  " .. instance:GetFullName() .. " (" .. instance.ClassName .. ")")
			if instance:IsA("LuaSourceContainer") then
				local source = readScriptSource(instance)
				if source then
					if #source > budget then
						warning = "Note: the selected script is long, so only the first "
							.. formatNumber(budget)
							.. " characters were sent."
						source = string.sub(source, 1, budget)
						table.insert(lines, "  Source of " .. instance.Name .. " (TRUNCATED - the rest was not sent):")
					else
						table.insert(lines, "  Source of " .. instance.Name .. ":")
					end
					budget = budget - #source
					table.insert(lines, "```lua")
					table.insert(lines, source)
					table.insert(lines, "```")
				end
			end
		end
	end

	return table.concat(lines, "\n"), warning
end

-- Finds the code block the model marked as a change for the place.
local function extractAction(text)
	for code in string.gmatch(text, "```[%w_%-]*[ \t]*\r?\n(.-)```") do
		if string.find(code, "STUDIO_ACTION", 1, true) then
			return code
		end
	end
	return nil
end

-- The one-line summary the AI wrote for the user.
local function extractSummary(code, fullText)
	local summary = code and string.match(code, "%-%-%s*SUMMARY:%s*([^\r\n]+)")
	if not summary then
		-- Fall back to the first line of plain text outside any code block.
		local outside = string.gsub(fullText or "", "```.-```", "")
		for line in string.gmatch(outside, "[^\r\n]+") do
			if trim(line) ~= "" then
				summary = trim(line)
				break
			end
		end
	end
	summary = trim(summary or "")
	if #summary > 300 then
		summary = string.sub(summary, 1, 297) .. "..."
	end
	return summary
end

-- True when the block holds real code, not just comment lines.
local function hasCode(code)
	for line in string.gmatch(code, "[^\r\n]+") do
		local text = trim(line)
		if text ~= "" and string.sub(text, 1, 2) ~= "--" then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------
-- Colours that follow Studio's light / dark theme
----------------------------------------------------------------------

local FALLBACK_COLORS = {
	MainBackground = Color3.fromRGB(46, 46, 46),
	MainText = Color3.fromRGB(204, 204, 204),
	DimmedText = Color3.fromRGB(140, 140, 140),
	InputFieldBackground = Color3.fromRGB(37, 37, 37),
	Border = Color3.fromRGB(34, 34, 34),
	Button = Color3.fromRGB(60, 60, 60),
	ButtonText = Color3.fromRGB(204, 204, 204),
	MainButton = Color3.fromRGB(0, 162, 255),
	ErrorText = Color3.fromRGB(255, 68, 68),
}

local function themeColor(name)
	local ok, color = pcall(function()
		return settings().Studio.Theme:GetColor(Enum.StudioStyleGuideColor[name])
	end)
	if ok and typeof(color) == "Color3" then
		return color
	end
	return FALLBACK_COLORS[name] or Color3.fromRGB(128, 128, 128)
end

local themed = {} -- { instance, property, colour name }

local function paint(instance, property, colorName)
	instance[property] = themeColor(colorName)
	table.insert(themed, { instance, property, colorName })
end

local function make(className, properties, parent)
	local instance = Instance.new(className)
	for name, value in pairs(properties) do
		instance[name] = value
	end
	instance.Parent = parent
	return instance
end

local FONT = Enum.Font.SourceSans
local WHITE = Color3.fromRGB(255, 255, 255)

local function makeButton(text, properties, parent, primary)
	local button = make("TextButton", {
		Text = text,
		Font = FONT,
		TextSize = 15,
		AutoButtonColor = true,
		BorderSizePixel = 1,
	}, nil)
	for name, value in pairs(properties) do
		button[name] = value
	end
	if primary then
		paint(button, "BackgroundColor3", "MainButton")
		button.TextColor3 = WHITE
	else
		paint(button, "BackgroundColor3", "Button")
		paint(button, "TextColor3", "ButtonText")
	end
	paint(button, "BorderColor3", "Border")
	button.Parent = parent
	return button
end

local function makeLabel(text, properties, parent, dimmed)
	local label = make("TextLabel", {
		Text = text,
		Font = FONT,
		TextSize = 14,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, nil)
	for name, value in pairs(properties) do
		label[name] = value
	end
	paint(label, "TextColor3", dimmed and "DimmedText" or "MainText")
	label.Parent = parent
	return label
end

local function makeTextBox(properties, parent)
	local box = make("TextBox", {
		Text = "",
		Font = FONT,
		TextSize = 15,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		BorderSizePixel = 1,
	}, nil)
	for name, value in pairs(properties) do
		box[name] = value
	end
	paint(box, "BackgroundColor3", "InputFieldBackground")
	paint(box, "TextColor3", "MainText")
	paint(box, "PlaceholderColor3", "DimmedText")
	paint(box, "BorderColor3", "Border")
	make("UIPadding", {
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 6),
		PaddingTop = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 4),
	}, box)
	box.Parent = parent
	return box
end

----------------------------------------------------------------------
-- The panel
----------------------------------------------------------------------

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 360, 320, 260, 240)

local widget
local createdOk = pcall(function()
	widget = plugin:CreateDockWidgetPluginGuiAsync("AIAssistantPanel", widgetInfo)
end)
if not createdOk or not widget then
	widget = plugin:CreateDockWidgetPluginGui("AIAssistantPanel", widgetInfo)
end
widget.Title = "AI Assistant"
widget.Name = "AIAssistantPanel"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local toolbar = plugin:CreateToolbar("AI Assistant")
local toggleButton = toolbar:CreateButton("AIAssistantToggle", "Show or hide the AI Assistant panel", "", "AI Assistant")
toggleButton.ClickableWhenViewportHidden = true
toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
toggleButton:SetActive(widget.Enabled)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

-- Heights of the fixed rows, in pixels.
local TOP_HEIGHT = 28
local SEND_HEIGHT = 28
local STATUS_HEIGHT = 52
local USAGE_HEIGHT = 48
local GAP = 6

local root = make("Frame", { Size = UDim2.new(1, 0, 1, 0), BorderSizePixel = 0 }, widget)
paint(root, "BackgroundColor3", "MainBackground")
make("UIPadding", {
	PaddingLeft = UDim.new(0, 8),
	PaddingRight = UDim.new(0, 8),
	PaddingTop = UDim.new(0, 8),
	PaddingBottom = UDim.new(0, 8),
}, root)

-- Top row: model picker, New, Keys
local modelButton = makeButton("", {
	Size = UDim2.new(1, -108, 0, TOP_HEIGHT),
	Position = UDim2.new(0, 0, 0, 0),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, root, false)
make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, modelButton)

local newChatButton = makeButton("New", {
	Size = UDim2.new(0, 48, 0, TOP_HEIGHT),
	Position = UDim2.new(1, -102, 0, 0),
}, root, false)

local keysButton = makeButton("Keys", {
	Size = UDim2.new(0, 48, 0, TOP_HEIGHT),
	Position = UDim2.new(1, -48, 0, 0),
}, root, false)

-- The prompt box fills the space between the top row and the Send button.
local BELOW_PROMPT = GAP + SEND_HEIGHT + GAP + STATUS_HEIGHT + GAP + USAGE_HEIGHT
local promptBox = makeTextBox({
	Position = UDim2.new(0, 0, 0, TOP_HEIGHT + GAP),
	Size = UDim2.new(1, 0, 1, -(TOP_HEIGHT + GAP + BELOW_PROMPT)),
	MultiLine = false, -- Enter sends
	TextWrapped = true,
	TextYAlignment = Enum.TextYAlignment.Top,
	PlaceholderText = 'What should I make or change? e.g. "add a spinning coin that gives 10 points when touched"  (Enter to send)',
}, root)

local sendButton = makeButton("Send", {
	Size = UDim2.new(1, 0, 0, SEND_HEIGHT),
	Position = UDim2.new(0, 0, 1, -(SEND_HEIGHT + GAP + STATUS_HEIGHT + GAP + USAGE_HEIGHT)),
}, root, true)

-- One line saying what happened.
local statusLabel = makeLabel("", {
	Size = UDim2.new(1, 0, 0, STATUS_HEIGHT),
	Position = UDim2.new(0, 0, 1, -(STATUS_HEIGHT + GAP + USAGE_HEIGHT)),
	TextSize = 14,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, root, false)

-- Token usage
local usageLabel = makeLabel("", {
	Size = UDim2.new(1, 0, 0, USAGE_HEIGHT),
	Position = UDim2.new(0, 0, 1, -USAGE_HEIGHT),
	TextSize = 13,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, root, true)

-- Model dropdown (floats over the prompt box)
local dropdown = make("ScrollingFrame", {
	Position = UDim2.new(0, 0, 0, TOP_HEIGHT + 2),
	Size = UDim2.new(1, 0, 0, 200),
	Visible = false,
	ZIndex = 10,
	BorderSizePixel = 1,
	ScrollBarThickness = 6,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollingDirection = Enum.ScrollingDirection.Y,
}, root)
paint(dropdown, "BackgroundColor3", "MainBackground")
paint(dropdown, "BorderColor3", "Border")
make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, dropdown)

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local selectedProvider = PROVIDERS[1]
local selectedModel = PROVIDERS[1].models[1]

local history = {} -- { role = "user" | "assistant", text = string }, kept so follow-ups work
local totalInput = 0
local totalOutput = 0
local lastResult = nil
local busy = false
local statusKind = "idle"

local READY_TEXT = "Type what you want and press Enter. Changes are made straight away - Ctrl+Z undoes them."

----------------------------------------------------------------------
-- Status and usage lines
----------------------------------------------------------------------

local STATUS_COLORS = {
	idle = "DimmedText",
	working = "DimmedText",
	done = "MainText",
	error = "ErrorText",
}

local function setStatus(text, kind)
	statusKind = kind or "idle"
	statusLabel.Text = text
	statusLabel.TextColor3 = themeColor(STATUS_COLORS[statusKind] or "MainText")
end

local function balanceHint()
	if selectedProvider.id == "copilot" and copilotQuotaText then
		return copilotQuotaText
	end
	if selectedProvider.id == "coarena" and coarenaBalanceText then
		return coarenaBalanceText
	end
	return selectedProvider.balanceHint
end

local function showUsage()
	local lines = {
		"Tokens used: " .. formatNumber(totalInput) .. " in / " .. formatNumber(totalOutput) .. " out",
	}
	if lastResult then
		table.insert(
			lines,
			"Last request: "
				.. formatNumber(lastResult.inputTokens)
				.. " in / "
				.. formatNumber(lastResult.outputTokens)
				.. " out"
		)
		table.insert(lines, lastResult.limitText or balanceHint())
	else
		table.insert(lines, balanceHint())
	end
	usageLabel.Text = table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- Model dropdown
----------------------------------------------------------------------

local function showSelectedModel()
	modelButton.Text = selectedModel.label .. "  ▼"
end

local function selectModel(provider, model)
	selectedProvider = provider
	selectedModel = model
	setSetting("AIA_Model", provider.id .. "|" .. model.id)
	showSelectedModel()
	showUsage(nil)
end

local function rebuildDropdown()
	for _, child in ipairs(dropdown:GetChildren()) do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	local order = 0
	local height = 0
	for _, provider in ipairs(PROVIDERS) do
		order = order + 1
		local hasKey = provider.keyName == nil or providerKey(provider) ~= nil
		local header = make("TextLabel", {
			Size = UDim2.new(1, 0, 0, 22),
			LayoutOrder = order,
			ZIndex = 11,
			BackgroundTransparency = 1,
			Font = Enum.Font.SourceSansBold,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "  " .. string.upper(provider.label) .. (hasKey and "" or "  (no key yet)"),
			TextColor3 = themeColor("DimmedText"),
		}, dropdown)
		height = height + header.Size.Y.Offset

		for _, model in ipairs(provider.models) do
			order = order + 1
			local isCurrent = provider == selectedProvider and model.id == selectedModel.id
			local item = make("TextButton", {
				Size = UDim2.new(1, 0, 0, 26),
				LayoutOrder = order,
				ZIndex = 11,
				BorderSizePixel = 0,
				AutoButtonColor = true,
				Font = FONT,
				TextSize = 15,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Text = "     " .. model.label,
				BackgroundColor3 = isCurrent and themeColor("MainButton") or themeColor("MainBackground"),
				TextColor3 = isCurrent and WHITE or themeColor("MainText"),
			}, dropdown)
			height = height + 26
			item.MouseButton1Click:Connect(function()
				selectModel(provider, model)
				dropdown.Visible = false
				rebuildDropdown()
			end)
		end
	end
	dropdown.Size = UDim2.new(1, 0, 0, math.min(height, 300))
end

-- Replace a provider's starting list with the live list from the account.
local function refreshModels(provider)
	local key = nil
	if provider.keyName then
		key = providerKey(provider)
		if not key then
			return
		end
	end
	task.spawn(function()
		local ok, models = pcall(provider.listModels, key)
		if not busy then
			showUsage(nil)
		end
		if ok and type(models) == "table" and #models > 0 then
			provider.models = models
			-- Keep the current pick, but show its proper name if the live list has one.
			if provider == selectedProvider then
				for _, model in ipairs(models) do
					if model.id == selectedModel.id then
						selectedModel = model
						showSelectedModel()
					end
				end
			end
			rebuildDropdown()
		end
	end)
end

-- Restore the model picked last time.
do
	local saved = getSetting("AIA_Model")
	if saved then
		local providerId, modelId = string.match(saved, "^([^|]+)|(.+)$")
		for _, provider in ipairs(PROVIDERS) do
			if provider.id == providerId then
				selectedProvider = provider
				selectedModel = { id = modelId, label = modelId }
				for _, model in ipairs(provider.models) do
					if model.id == modelId then
						selectedModel = model
					end
				end
			end
		end
	end
end

modelButton.MouseButton1Click:Connect(function()
	dropdown.Visible = not dropdown.Visible
	if dropdown.Visible then
		-- The Copilot bridge may have been started since the last look.
		for _, provider in ipairs(PROVIDERS) do
			if not provider.keyName then
				refreshModels(provider)
			end
		end
	end
end)

----------------------------------------------------------------------
-- Keys screen
----------------------------------------------------------------------

-- Scrolls, so it still fits when the panel is small.
local keysScreen = make("ScrollingFrame", {
	Size = UDim2.new(1, 0, 1, 0),
	Visible = false,
	Active = true,
	ZIndex = 20,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	CanvasSize = UDim2.new(0, 0, 0, 76 + #KEY_PROVIDERS * 68 + 92),
}, root)
paint(keysScreen, "BackgroundColor3", "MainBackground")

makeLabel("API keys", {
	Size = UDim2.new(1, 0, 0, 22),
	Position = UDim2.new(0, 0, 0, 0),
	Font = Enum.Font.SourceSansBold,
	TextSize = 17,
	ZIndex = 21,
}, keysScreen, false)

makeLabel(
	"Paste a key for each service you want to use. Keys are saved on this computer only "
		.. "(in plain text) and are sent only to the service they belong to.",
	{ Size = UDim2.new(1, 0, 0, 48), Position = UDim2.new(0, 0, 0, 24), TextSize = 13, ZIndex = 21 },
	keysScreen,
	true
)

local keyBoxes = {}

local function showKeyPlaceholders()
	for _, provider in ipairs(KEY_PROVIDERS) do
		local box = keyBoxes[provider.id]
		local saved = getSetting(provider.keyName)
		box.Text = ""
		if saved then
			box.PlaceholderText = "Saved (ends in " .. string.sub(saved, -4) .. "). Paste to replace."
		elseif provider.defaultKey then
			box.PlaceholderText = "Using the built-in key (ends in " .. string.sub(provider.defaultKey, -4) .. ")."
		else
			box.PlaceholderText = provider.keyHint
		end
	end
end

for index, provider in ipairs(KEY_PROVIDERS) do
	local top = 76 + (index - 1) * 68
	makeLabel(provider.keyLabel, {
		Size = UDim2.new(1, 0, 0, 32),
		Position = UDim2.new(0, 0, 0, top),
		TextSize = 13,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		ZIndex = 21,
	}, keysScreen, false)

	keyBoxes[provider.id] = makeTextBox({
		Size = UDim2.new(1, -70, 0, 26),
		Position = UDim2.new(0, 0, 0, top + 36),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 21,
	}, keysScreen)

	local removeButton = makeButton("Remove", {
		Size = UDim2.new(0, 64, 0, 26),
		Position = UDim2.new(1, -64, 0, top + 36),
		TextSize = 13,
		ZIndex = 21,
	}, keysScreen, false)
	removeButton.MouseButton1Click:Connect(function()
		setSetting(provider.keyName, "")
		showKeyPlaceholders()
		rebuildDropdown()
	end)
end

local saveKeysButton = makeButton("Save", {
	Size = UDim2.new(0.5, -3, 0, 28),
	Position = UDim2.new(0, 0, 0, 76 + #KEY_PROVIDERS * 68 + 8),
	ZIndex = 21,
}, keysScreen, true)

local closeKeysButton = makeButton("Close", {
	Size = UDim2.new(0.5, -3, 0, 28),
	Position = UDim2.new(0.5, 3, 0, 76 + #KEY_PROVIDERS * 68 + 8),
	ZIndex = 21,
}, keysScreen, false)

makeLabel(
	"GitHub Copilot needs no key: double-click start-bridge.bat in the copilot-bridge folder "
		.. "and keep its window open while you use Studio.",
	{
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.new(0, 0, 0, 76 + #KEY_PROVIDERS * 68 + 44),
		TextSize = 13,
		ZIndex = 21,
	},
	keysScreen,
	true
)

local function openKeys()
	dropdown.Visible = false
	showKeyPlaceholders()
	keysScreen.Visible = true
end

keysButton.MouseButton1Click:Connect(openKeys)

closeKeysButton.MouseButton1Click:Connect(function()
	keysScreen.Visible = false
end)

saveKeysButton.MouseButton1Click:Connect(function()
	for _, provider in ipairs(KEY_PROVIDERS) do
		local typed = trim(keyBoxes[provider.id].Text)
		if typed ~= "" then
			setSetting(provider.keyName, typed)
			refreshModels(provider)
		end
	end
	keysScreen.Visible = false
	rebuildDropdown()
end)

----------------------------------------------------------------------
-- Running the AI's code in Studio
----------------------------------------------------------------------

-- Runs one change as a single undo step. Returns true, or false + error.
-- The third result is true when retrying can't help.
local function runChange(code)
	local compiled, compileError
	local loaded = pcall(function()
		compiled, compileError = loadstring(code, "=AIAssistantChange")
	end)
	if not loaded then
		return false, "Studio won't let this plugin run code (loadstring is unavailable).", true
	end
	if not compiled then
		return false, "Syntax error: " .. tostring(compileError), false
	end

	local recording = nil
	pcall(function()
		recording = ChangeHistoryService:TryBeginRecording("AI Assistant change")
	end)

	local ranOk, runError = pcall(compiled)

	if recording then
		pcall(function()
			-- Commit keeps the change as one undo step; Cancel rolls it all back.
			ChangeHistoryService:FinishRecording(
				recording,
				ranOk and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
			)
		end)
	end

	if ranOk then
		return true
	end
	return false, tostring(runError), false
end

----------------------------------------------------------------------
-- Sending a prompt
----------------------------------------------------------------------

local function remember(userText, replyText)
	table.insert(history, { role = "user", text = userText })
	table.insert(history, { role = "assistant", text = replyText })
	while #history > MAX_HISTORY_MESSAGES do
		table.remove(history, 1)
		table.remove(history, 1)
	end
end

local function send()
	if busy then
		return
	end
	local prompt = trim(promptBox.Text)
	if prompt == "" then
		return
	end

	local provider = selectedProvider
	local model = selectedModel
	local key = nil
	if provider.keyName then
		key = providerKey(provider)
		if not key then
			setStatus("Add your " .. provider.label .. " key first, then press Enter again.", "error")
			openKeys()
			return
		end
	end

	busy = true
	dropdown.Visible = false
	sendButton.Text = "Working..."
	promptBox.TextEditable = false

	task.spawn(function()
		local userText = prompt
		local attempt = 0
		local finalText, finalKind

		while true do
			attempt = attempt + 1
			if attempt == 1 then
				setStatus("Working on it with " .. model.label .. "... (can take a minute)", "working")
			else
				setStatus("That didn't work, so the AI is fixing it (try " .. attempt .. ")...", "working")
			end

			local snapshot, warning = buildSnapshot()
			local outgoing = {}
			for _, message in ipairs(history) do
				table.insert(outgoing, message)
			end
			table.insert(outgoing, {
				role = "user",
				text = "<studio_snapshot>\n" .. snapshot .. "\n</studio_snapshot>\n\n" .. userText,
			})

			local function onProgress(characters)
				setStatus(
					"Writing the change with " .. model.label .. "... " .. formatNumber(characters) .. " characters so far",
					"working"
				)
			end

			local ok, result, callError = pcall(provider.call, key, model.id, SYSTEM_PROMPT, outgoing, onProgress)
			if not ok then
				callError = "Something went wrong inside the plugin: " .. tostring(result)
				result = nil
			end
			if not result then
				finalText, finalKind = tostring(callError), "error"
				break
			end

			remember(userText, result.text)
			totalInput = totalInput + result.inputTokens
			totalOutput = totalOutput + result.outputTokens
			lastResult = result
			showUsage()

			local code = extractAction(result.text)
			local summary = extractSummary(code, result.text)

			if not code then
				-- The AI answered in words instead of making a change.
				finalText = (summary ~= "" and summary or "The AI didn't make a change.")
				finalKind = "done"
				break
			end

			if not hasCode(code) then
				-- A question, or something it chose not to do: just show its answer.
				finalText = (summary ~= "" and summary or "Nothing to change.")
				finalKind = "done"
				break
			end

			local changed, runError, fatal = runChange(code)
			if changed then
				finalText = (summary ~= "" and summary or "Done.") .. "  (Ctrl+Z to undo)"
				if result.note then
					finalText = finalText .. " " .. result.note
				end
				if warning then
					finalText = finalText .. " " .. warning
				end
				finalKind = "done"
				promptBox.Text = ""
				break
			end

			if fatal or attempt > MAX_FIX_ATTEMPTS then
				finalText = "Couldn't make that change, so nothing was changed. Error: " .. runError
				finalKind = "error"
				break
			end

			userText = "Your code failed when it ran in Studio, and every change it made was rolled back. Error:\n"
				.. runError
				.. "\n\nFix it and reply with a complete corrected block. The original request was:\n"
				.. prompt
		end

		busy = false
		sendButton.Text = "Send"
		promptBox.TextEditable = true
		setStatus(finalText, finalKind)
		showUsage()
	end)
end

sendButton.MouseButton1Click:Connect(send)
promptBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		send()
	end
end)

----------------------------------------------------------------------
-- New, theme changes, start-up
----------------------------------------------------------------------

newChatButton.MouseButton1Click:Connect(function()
	if busy then
		return
	end
	history = {}
	totalInput = 0
	totalOutput = 0
	lastResult = nil
	setStatus("Started fresh: the AI has forgotten your earlier requests.", "idle")
	showUsage()
end)

pcall(function()
	settings().Studio.ThemeChanged:Connect(function()
		for _, entry in ipairs(themed) do
			entry[1][entry[2]] = themeColor(entry[3])
		end
		statusLabel.TextColor3 = themeColor(STATUS_COLORS[statusKind] or "MainText")
		rebuildDropdown()
	end)
end)

showSelectedModel()
rebuildDropdown()
setStatus(READY_TEXT, "idle")
showUsage()

for _, provider in ipairs(PROVIDERS) do
	refreshModels(provider)
end
