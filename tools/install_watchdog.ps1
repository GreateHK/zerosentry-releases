# ============================================================
#  ZeroMaster Watchdog Installer
#  Creates scheduled task "ZeroMaster-Watchdog" that runs
#  health_check.ps1 every 5 min as SYSTEM.
#
#  PREREQUISITE - set Telegram credentials first (admin CMD):
#    setx TELEGRAM_BOT_TOKEN "123456:AAB...xyz"      /M
#    setx TELEGRAM_CHAT_ID   "123456789"             /M
#
#  USAGE - run in PowerShell as Administrator:
#    iwr -UseBasicParsing https://raw.githubusercontent.com/GreateHK/zerosentry-releases/main/tools/install_watchdog.ps1 | iex
# ============================================================

$ErrorActionPreference = 'Stop'

# --- Check admin ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Must run PowerShell as Administrator." -ForegroundColor Red
    exit 1
}

# --- Auto-detect install dir ---
$candidates = @(
    'C:\ZeroSentry\ZeroMaster',
    'C:\zeromaster\ZeroMaster',
    'C:\ZeroMaster'
)
$zmDir = $null
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'admin_tools')) { $zmDir = $c; break }
}
if (-not $zmDir) {
    Write-Host "Could not auto-detect ZeroMaster install dir." -ForegroundColor Yellow
    $zmDir = Read-Host "Enter full path to ZeroMaster directory"
    if (-not (Test-Path $zmDir)) { throw "Path not found: $zmDir" }
}
$toolsDir = Join-Path $zmDir 'admin_tools'
if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }
Write-Host "Install dir: $zmDir" -ForegroundColor Green

# --- Verify env vars ---
$token  = [Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'Machine')
$chatId = [Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID',  'Machine')
if (-not $token -or -not $chatId) {
    Write-Host ""
    Write-Host "ERROR: Telegram env vars missing (machine scope)." -ForegroundColor Red
    Write-Host "Run these in Admin CMD first:"
    Write-Host '  setx TELEGRAM_BOT_TOKEN "<your_token>" /M' -ForegroundColor Cyan
    Write-Host '  setx TELEGRAM_CHAT_ID "<your_chat_id>" /M' -ForegroundColor Cyan
    Write-Host ""
    exit 1
}
Write-Host "Telegram env vars: OK" -ForegroundColor Green

# --- Send test Telegram message ---
Write-Host "Sending test Telegram message..." -ForegroundColor Cyan
try {
    $body      = @{ chat_id = $chatId; text = "[OK] ZeroMaster watchdog installer: Telegram reachable on $env:COMPUTERNAME" } | ConvertTo-Json -Compress
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $null = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -Body $bodyBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 10
    Write-Host "  Test message sent. Check your Telegram." -ForegroundColor Green
} catch {
    Write-Host "  Test message FAILED: $_" -ForegroundColor Red
    $ans = Read-Host "Continue anyway? (y/n)"
    if ($ans -ne 'y') { exit 1 }
}

# --- Download health_check.ps1 ---
$scriptPath = Join-Path $toolsDir 'health_check.ps1'
$url = 'https://raw.githubusercontent.com/GreateHK/zerosentry-releases/main/tools/health_check.ps1'
Write-Host "Downloading health_check.ps1..." -ForegroundColor Cyan
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $scriptPath
Write-Host "  -> $scriptPath" -ForegroundColor Green

# --- Also ensure forensics_snapshot.bat is present ---
$batPath = Join-Path $toolsDir 'forensics_snapshot.bat'
if (-not (Test-Path $batPath)) {
    Write-Host "Downloading forensics_snapshot.bat..." -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/GreateHK/zerosentry-releases/main/tools/forensics_snapshot.bat' -OutFile $batPath
    Write-Host "  -> $batPath" -ForegroundColor Green
}

# --- Create / replace scheduled task ---
$taskName = 'ZeroMaster-Watchdog'
Write-Host "Creating scheduled task '$taskName'..." -ForegroundColor Cyan

# Delete existing if present (use Get-ScheduledTask to avoid schtasks stderr throwing under ErrorActionPreference=Stop)
$taskExists = $false
try {
    $null = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    $taskExists = $true
} catch {
    $taskExists = $false
}
if ($taskExists) {
    $null = & schtasks.exe /Delete /TN $taskName /F 2>&1
    Write-Host "  Removed existing task." -ForegroundColor Yellow
}

$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$null = & schtasks.exe /Create `
    /TN $taskName `
    /TR "$cmd" `
    /SC MINUTE /MO 5 `
    /RU SYSTEM `
    /RL HIGHEST `
    /F 2>&1

if ($LASTEXITCODE -ne 0) { throw "Failed to create scheduled task (exit $LASTEXITCODE)." }

# schtasks /Create leaves the default 72h run limit. With IgnoreNew, one hung run
# then blocks every later run for 3 days (happened 2026-09-24..27). Cap it.
$task = Get-ScheduledTask -TaskName $taskName
$task.Settings.ExecutionTimeLimit = 'PT10M'
$null = Set-ScheduledTask -InputObject $task
Write-Host "  Task created: runs every 5 min as SYSTEM, max 10 min per run" -ForegroundColor Green

# --- Trigger first run immediately ---
Write-Host "Triggering first run..." -ForegroundColor Cyan
$null = & schtasks.exe /Run /TN $taskName 2>&1
Start-Sleep -Seconds 3

# --- Summary ---
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Watchdog installed." -ForegroundColor Green
Write-Host "  Task name:  $taskName" -ForegroundColor Green
Write-Host "  Runs every: 5 minutes (as SYSTEM)" -ForegroundColor Green
Write-Host "  Script:     $scriptPath" -ForegroundColor Green
Write-Host "  Log:        $toolsDir\watchdog.log" -ForegroundColor Green
Write-Host "  State:      $toolsDir\watchdog_state.json" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "To uninstall: schtasks /Delete /TN $taskName /F" -ForegroundColor Gray
Write-Host "To view logs: Get-Content '$toolsDir\watchdog.log' -Tail 50" -ForegroundColor Gray
Write-Host ""
