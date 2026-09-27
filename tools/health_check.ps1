# ============================================================
#  ZeroMaster Watchdog - Health Check
#  Runs every 5 min via scheduled task "ZeroMaster-Watchdog".
#  Probes web UI; if unhealthy, captures forensics, kills orphan
#  python.exe, restarts ZeroMaster task, and alerts via Telegram.
#
#  Config: reads TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID from
#  machine-scope env vars (set via 'setx /M').
# ============================================================

$ErrorActionPreference = 'Continue'

# --- Auto-detect ZM install dir ---
$candidates = @(
    'C:\ZeroSentry\ZeroMaster',
    'C:\zeromaster\ZeroMaster',
    'C:\ZeroMaster'
)
$zmDir = $null
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c 'app.log')) { $zmDir = $c; break }
    if (Test-Path (Join-Path $c 'app.py'))  { $zmDir = $c; break }
}
if (-not $zmDir) { $zmDir = 'C:\ZeroSentry\ZeroMaster' }

# --- Config ---
$probeUrl           = 'http://127.0.0.1:5001/login'
$stateFile          = Join-Path $zmDir 'admin_tools\watchdog_state.json'
$logFile            = Join-Path $zmDir 'admin_tools\watchdog.log'
$forensicsBat       = Join-Path $zmDir 'admin_tools\forensics_snapshot.bat'
$maxFailCount       = 3       # consecutive failures before recovery
$maxRecoveriesPerDay = 3      # stop auto-recovering beyond this
$probeTimeoutSec    = 10
$postRestartWaitSec = 30      # wait after schtasks /Run before verifying
$forensicsTimeoutSec = 120    # never let forensics block recovery

# --- Load state ---
$state = @{
    failCount       = 0
    lastRecovery    = $null
    recoveriesToday = 0
    recoveriesDate  = (Get-Date).ToString('yyyy-MM-dd')
}
if (Test-Path $stateFile) {
    try {
        $loaded = Get-Content $stateFile -Raw | ConvertFrom-Json
        foreach ($p in 'failCount','lastRecovery','recoveriesToday','recoveriesDate') {
            if ($null -ne $loaded.$p) { $state[$p] = $loaded.$p }
        }
    } catch {}
}

# Reset per-day recovery counter at midnight
$today = (Get-Date).ToString('yyyy-MM-dd')
if ($state.recoveriesDate -ne $today) {
    $state.recoveriesDate  = $today
    $state.recoveriesToday = 0
}

function Write-WDLog($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $msg"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

function Send-TelegramAlert($msg) {
    $token  = [Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'Machine')
    $chatId = [Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID',  'Machine')
    if (-not $token -or -not $chatId) {
        Write-WDLog "Telegram env vars not set - skipping alert: $msg"
        return
    }
    try {
        $bodyJson  = @{
            chat_id    = $chatId
            text       = $msg
            parse_mode = 'Markdown'
        } | ConvertTo-Json -Compress
        # Force UTF-8 - PowerShell 5.x Invoke-RestMethod defaults to latin-1 for string bodies,
        # which mangles emoji and non-ASCII. Converting to bytes preserves UTF-8.
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($bodyJson)
        Invoke-RestMethod `
            -Uri "https://api.telegram.org/bot$token/sendMessage" `
            -Method Post `
            -Body $bodyBytes `
            -ContentType 'application/json; charset=utf-8' `
            -TimeoutSec 10 | Out-Null
    } catch {
        Write-WDLog "Telegram send failed: $_"
    }
}

# --- Probe ---
$healthy    = $false
$statusText = ''
try {
    $resp = Invoke-WebRequest -Uri $probeUrl `
                              -TimeoutSec $probeTimeoutSec `
                              -UseBasicParsing `
                              -MaximumRedirection 5
    if ($resp.StatusCode -eq 200) {
        $healthy    = $true
        $statusText = 'HTTP 200'
    } else {
        $statusText = "HTTP $($resp.StatusCode)"
    }
} catch [System.Net.WebException] {
    # Capture the HTTP status code if present (e.g., 404)
    if ($_.Exception.Response) {
        $code = [int]$_.Exception.Response.StatusCode
        $statusText = "HTTP $code"
    } else {
        $statusText = "Connection error: $($_.Exception.Message)"
    }
} catch {
    $statusText = "Error: $($_.Exception.Message)"
}

# --- React to result ---
if ($healthy) {
    if ($state.failCount -gt 0) {
        Write-WDLog "Recovered naturally. Previous fail count: $($state.failCount). Status: $statusText"
        Send-TelegramAlert "✅ *ZeroMaster* recovered on its own. Status: $statusText"
    }
    $state.failCount = 0
} else {
    $state.failCount++
    Write-WDLog "Unhealthy $($state.failCount)/$maxFailCount. Status: $statusText"

    if ($state.failCount -ge $maxFailCount) {
        if ($state.recoveriesToday -ge $maxRecoveriesPerDay) {
            Write-WDLog "Max recoveries/day ($maxRecoveriesPerDay) reached. Skipping auto-recovery."
            Send-TelegramAlert "⚠️ *ZeroMaster UNHEALTHY* ($statusText)`nDaily auto-recovery limit ($maxRecoveriesPerDay) reached.`n*Manual intervention needed.*"
        } else {
            Write-WDLog "Triggering auto-recovery (attempt $($state.recoveriesToday + 1)/$maxRecoveriesPerDay today)..."
            Send-TelegramAlert "🚨 *ZeroMaster UNHEALTHY* ($statusText)`nAuto-recovery attempt $($state.recoveriesToday + 1)/$maxRecoveriesPerDay today. Capturing forensics, killing stale processes, restarting..."

            # 1. Capture forensics FIRST (preserve evidence)
            if (Test-Path $forensicsBat) {
                try {
                    # Bounded wait: on 2026-09-24 an unbounded -Wait on this bat hung the
                    # watchdog for 72h (the bat ended in `pause`), so no recovery ran and
                    # every later 5-minute run was skipped by IgnoreNew.
                    $fp = Start-Process -FilePath $forensicsBat -ArgumentList '/nopause' -WindowStyle Hidden -PassThru -ErrorAction Stop
                    $fp | Wait-Process -Timeout $forensicsTimeoutSec -ErrorAction SilentlyContinue
                    if (-not $fp.HasExited) {
                        $fp | Stop-Process -Force -ErrorAction SilentlyContinue
                        Write-WDLog "Forensics snapshot timed out after ${forensicsTimeoutSec}s - killed, continuing recovery."
                    } else {
                        Write-WDLog "Forensics snapshot captured."
                    }
                } catch {
                    Write-WDLog "Forensics capture failed: $_"
                }
            }

            # 2. Kill all python.exe (eliminates dual-process state)
            try {
                $killed = Get-Process python -ErrorAction SilentlyContinue
                if ($killed) {
                    $killed | Stop-Process -Force
                    Write-WDLog "Killed $($killed.Count) python.exe process(es)."
                }
            } catch {
                Write-WDLog "Kill python.exe failed: $_"
            }
            Start-Sleep -Seconds 3

            # 3. Restart task
            try {
                $null = & schtasks.exe /Run /TN 'ZeroMaster' 2>&1
                Write-WDLog "Ran schtasks /Run /TN ZeroMaster"
            } catch {
                Write-WDLog "schtasks /Run failed: $_"
            }

            # 4. Wait for warm-up then verify
            Start-Sleep -Seconds $postRestartWaitSec
            $recovered = $false
            try {
                $verify = Invoke-WebRequest -Uri $probeUrl -TimeoutSec $probeTimeoutSec -UseBasicParsing
                if ($verify.StatusCode -eq 200) { $recovered = $true }
            } catch {}

            if ($recovered) {
                Write-WDLog "Recovery successful."
                Send-TelegramAlert "✅ *ZeroMaster recovered* via auto-restart."
            } else {
                Write-WDLog "Recovery FAILED - still unhealthy after restart."
                Send-TelegramAlert "❌ *ZeroMaster still UNHEALTHY* after auto-restart.`n*Manual intervention needed.*"
            }

            $state.recoveriesToday++
            $state.lastRecovery = (Get-Date).ToString('o')
            $state.failCount    = 0
        }
    }
}

# --- Save state ---
try {
    $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
} catch {
    Write-WDLog "Failed to save state: $_"
}
