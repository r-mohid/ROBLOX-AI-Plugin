@echo off
title Copilot bridge for Roblox Studio
cd /d "%~dp0"
if not exist node_modules\@github\copilot-sdk (
  echo Installing the GitHub Copilot SDK, one moment...
  call npm install
)
node bridge.mjs
pause
