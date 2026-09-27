# install_journal_digest.ps1  —  one-click installer for the 4-hourly journal digest
# --------------------------------------------------------------------------------
# Downloads journal_digest.ps1, verifies Telegram creds, registers the scheduled
# task (every 4h, SYSTEM), and runs one digest immediately as a smoke test.
#
# Prereq: journal_digest.ps1 must be published in zerosentry-releases/tools/.
# Prereq: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID set as machine env vars.
#
# Run (Admin PowerShell):
#   iwr -UseBasicParsing "https://raw.githubusercontent.com/GreateHK/zerosentry-releases/main/tools/install_journal_digest.ps1?v=1" | iex

$ErrorActionPreference = "Stop"

$InstallDir = "C:\ZeroSentry\ZeroMaster\admin_tools"
$ScriptUrl  = "https://raw.githubusercontent.com/GreateHK/zerosentry-releases/main/tools/journal_digest.ps1?v=1"
$ScriptPath = Join-Path $InstallDir "journal_digest.ps1"
$TaskName   = "ZeroMaster-Journal-Digest"

Write-Host "=============================================="
Write-Host "  ZeroMaster Journal Digest — installer"
Write-Host "=============================================="

# 1. Verify Telegram env vars (machine scope)
$token = [Environment]::GetEnvironmentVariable("TELEGRAM_BOT_TOKEN", "Machine")
$chat  = [Environment]::GetEnvironmentVariable("TELEGRAM_CHAT_ID", "Machine")
if (-not $token -or -not $chat) {
    Write-Host "ERROR: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set (machine scope)."
    Write-Host 'Set them in an Admin CMD, then reopen PowerShell:'
    Write-Host '  setx TELEGRAM_BOT_TOKEN "<bot_token>" /M'
    Write-Host '  setx TELEGRAM_CHAT_ID  "<chat_id>"  /M'
    exit 1
}

# 2. Download the digest script
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
Write-Host "> Downloading journal_digest.ps1 ..."
# .NET WebClient (PS 5.x handles GitHub redirects better than Invoke-WebRequest)
(New-Object System.Net.WebClient).DownloadFile($ScriptUrl, $ScriptPath)
if (-not (Test-Path $ScriptPath)) { Write-Host "ERROR: download failed."; exit 1 }
Write-Host "  saved -> $ScriptPath"

# 3. Telegram reachability test
$uri  = "https://api.telegram.org/bot$token/sendMessage"
$body = @{ chat_id = $chat; text = ("[OK] Journal-digest installer: Telegram reachable on " + $env:COMPUTERNAME) } | ConvertTo-Json -Compress
$bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
try {
    Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes | Out-Null
    Write-Host "> Test Telegram sent (check your chat)."
} catch {
    Write-Host "WARNING: Telegram test failed: $_"
}

# 4. Register scheduled task — every 4 hours, SYSTEM
Write-Host "> Registering scheduled task '$TaskName' (every 4h)..."
$tr = "powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath"
schtasks /Create /TN $TaskName /TR $tr /SC HOURLY /MO 4 /RU SYSTEM /RL HIGHEST /F | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: task registration failed (exit $LASTEXITCODE)."; exit 1 }

# 5. Run one digest now as a smoke test
Write-Host "> Running one digest now..."
schtasks /Run /TN $TaskName | Out-Null

Write-Host "=============================================="
Write-Host "  Done. A digest should arrive on Telegram shortly."
Write-Host "  Task: $TaskName  (every 4h, SYSTEM)"
Write-Host "=============================================="
