# journal_digest.ps1  —  ZeroMaster 4-hourly log health digest
# ------------------------------------------------------------
# Scans the last N hours of app.log and Telegrams a short digest so
# silent failures (e.g. db_export crashing without taking the app down)
# are caught proactively — the watchdog only sees the app go *down*.
#
# Runs as a scheduled task every 4h (SYSTEM). Reads Telegram creds from
# machine-scope env vars TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID.
#
# Install (on the customer VM, Admin PowerShell):
#   schtasks /Create /TN "ZeroMaster-Journal-Digest" ^
#     /TR "powershell -NoProfile -ExecutionPolicy Bypass -File C:\ZeroSentry\ZeroMaster\admin_tools\journal_digest.ps1" ^
#     /SC HOURLY /MO 4 /RU SYSTEM /RL HIGHEST /F
# Test once:  powershell -NoProfile -ExecutionPolicy Bypass -File .\journal_digest.ps1
# Preview without sending:  ... -File .\journal_digest.ps1 -DryRun
#
# 2026-09-27: device passwords are masked before anything leaves the machine
# (app.log lines carry `pass=...` in request URLs), and identical errors are
# grouped with a count instead of repeating the same line hundreds of times.
# Must stay Windows PowerShell 5.1 compatible (no ??, no ternary).

param(
    [string]$LogPath   = "C:\ZeroSentry\ZeroMaster\app.log",
    [int]   $WindowHrs = 4,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$Hostname  = $env:COMPUTERNAME
$Token     = [Environment]::GetEnvironmentVariable("TELEGRAM_BOT_TOKEN", "Machine")
$ChatId    = [Environment]::GetEnvironmentVariable("TELEGRAM_CHAT_ID", "Machine")

function Hide-Secrets([string]$Text) {
    # Mask device credentials in every shape they appear in app.log:
    #   query string   ...?pass=<pw>&...
    #   JSON / repr    "pass": "<pw>"  /  'pass': '<pw>'
    #   URL userinfo   ftp://admin:<pw>@host
    $t = $Text
    $t = $t -replace '(?i)\b(pass|password)=[^&\s''"),]*', '$1=***'
    $t = $t -replace '(?i)(["''](?:pass|password)["'']\s*:\s*)(["''])(?:\\.|(?!\2).)*\2', '$1$2***$2'
    $t = $t -replace '(?i)([a-z][a-z0-9+.\-]*://[^/\s:@]+:)[^@\s/]+@', '$1***@'
    return $t
}

function Send-Telegram([string]$Text) {
    $Text = Hide-Secrets $Text
    if ($DryRun) { Write-Output $Text; return }
    if (-not $Token -or -not $ChatId) { return }
    $uri  = "https://api.telegram.org/bot$Token/sendMessage"
    $body = @{ chat_id = $ChatId; text = $Text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
    # UTF-8 bytes — PS5.x mangles emoji if you pass a string body
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    try {
        Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes | Out-Null
    } catch { }
}

if (-not (Test-Path $LogPath)) {
    Send-Telegram "WARNING ZeroMaster $Hostname : app.log not found at $LogPath"
    exit 0
}

$cutoff = (Get-Date).AddHours(-$WindowHrs)

# Bound the work; 4h of logs is well under this
$lines = Get-Content -Path $LogPath -Tail 12000 -ErrorAction SilentlyContinue

$errCount      = 0
$groups        = @{}          # signature -> @{ Count; Last; Sample }
$exportOK      = 0
$exportRecords = 0
$exportFail    = 0
$exportIdle    = 0

foreach ($line in $lines) {
    $ts = $null
    if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
        try { $ts = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch { $ts = $null }
        if ($ts -and $ts -lt $cutoff) { continue }   # outside the window
    }

    if ($line -match 'db_export: exported (\d+) records') {
        $exportOK++; $exportRecords += [int]$matches[1]
    }
    elseif ($line -match 'db_export: export failed') { $exportFail++ }
    elseif ($line -match 'db_export: no new records') { $exportIdle++ }

    if ($line -match ' ERROR ' -or $line -match '\bERROR\b.*(api\.|Traceback)') {
        $errCount++
        # Group identical errors: drop the timestamp and the per-call object address
        $msg = ($line.Trim() -replace '\s+', ' ')
        $sig = $msg -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d+ - ', ''
        $sig = $sig -replace 'at 0x[0-9a-fA-F]+', 'at 0x?'
        if (-not $groups.ContainsKey($sig)) {
            $groups[$sig] = @{ Count = 0; Last = ''; Sample = $sig }
        }
        $groups[$sig].Count++
        if ($ts) { $groups[$sig].Last = $ts.ToString('HH:mm') }
    }
}

$exportLine = "db_export: $exportOK OK ($exportRecords recs), $exportFail fail, $exportIdle idle"

if ($errCount -eq 0 -and $exportFail -eq 0) {
    $msg = "OK ZeroMaster $Hostname - last ${WindowHrs}h healthy.`n$exportLine`nNo errors."
} else {
    $kinds = $groups.Count
    $top = $groups.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 6
    $rows = foreach ($g in $top) {
        $text = $g.Value.Sample
        # Name the unreachable terminal up front - that is what the reader needs
        # Capture the host before the second -match overwrites $matches
        if ($text -match "HTTPConnectionPool\(host='([^']+)'") {
            $deviceHost = $matches[1]
            if ($text -match 'timed out|Max retries') {
                $text = "[terminal $deviceHost unreachable] " + $text
            }
        }
        if ($text.Length -gt 240) { $text = $text.Substring(0, 240) + '...' }
        "x$($g.Value.Count) (last $($g.Value.Last)) $text"
    }
    $msg = "WARNING ZeroMaster $Hostname - last ${WindowHrs}h: $errCount error line(s), $kinds kind(s).`n$exportLine`n--- by kind ---`n" + ($rows -join "`n")
    if ($msg.Length -gt 3500) { $msg = $msg.Substring(0, 3500) + "`n...(truncated)" }
}

Send-Telegram $msg
