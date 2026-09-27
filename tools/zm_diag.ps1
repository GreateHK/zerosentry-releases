# zm_diag.ps1  -  ZeroMaster one-shot diagnostic summary (READ-ONLY)
# ------------------------------------------------------------------
# Prints a ~30-line health summary that can be copied straight out of the
# RustDesk window, so nobody has to transfer problem-report zips around.
# Changes nothing on the machine. Device passwords are masked in everything
# it prints or saves.
#
# Usage (Admin PowerShell on the ZeroMaster VM):
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\ZeroSentry\ZeroMaster\admin_tools\zm_diag.ps1
#   ... -Hours 72          look further back (default 24)
#   ... -Zip               also save a masked copy of the logs to the Desktop
#   ... -Telegram          also send the summary to Telegram (the daily
#                          ZeroMaster-Daily-Diag task runs it this way at 09:00)
#
# Must stay Windows PowerShell 5.1 compatible (no ??, no ternary).

param(
    [string]$ZmDir = "C:\ZeroSentry\ZeroMaster",
    [int]   $Hours = 24,
    [switch]$Zip,
    [switch]$Telegram
)

$ErrorActionPreference = "Continue"

$LogPath      = Join-Path $ZmDir "app.log"
$WatchdogLog  = Join-Path $ZmDir "admin_tools\watchdog.log"
$Python       = Join-Path $ZmDir "venv\Scripts\python.exe"
$cutoff       = (Get-Date).AddHours(-$Hours)
$out          = New-Object System.Collections.Generic.List[string]
$issues       = New-Object System.Collections.Generic.List[string]   # need a human
$notes        = New-Object System.Collections.Generic.List[string]   # known / informational

function Hide-Secrets([string]$Text) {
    # Same masking as journal_digest.ps1: query string, JSON/repr, URL userinfo.
    $t = $Text
    $t = $t -replace '(?i)\b(pass|password)=[^&\s''"),]*', '$1=***'
    $t = $t -replace '(?i)(["''](?:pass|password)["'']\s*:\s*)(["''])(?:\\.|(?!\2).)*\2', '$1$2***$2'
    $t = $t -replace '(?i)([a-z][a-z0-9+.\-]*://[^/\s:@]+:)[^@\s/]+@', '$1***@'
    return $t
}

function Add([string]$Line) { $out.Add((Hide-Secrets $Line)) }

function Get-TaskLine([string]$Name) {
    try {
        $raw = schtasks /Query /TN $Name /FO LIST /V 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $raw) {
            # SYSTEM tasks are invisible to a non-elevated shell - say so instead of "not found"
            return "$Name : query failed ($(($raw | Out-String).Trim())) - run PowerShell as Administrator?"
        }
        $status = ($raw | Select-String '^Status:').ToString() -replace '^Status:\s*', ''
        $last   = ($raw | Select-String '^Last Run Time:').ToString() -replace '^Last Run Time:\s*', ''
        $result = ($raw | Select-String '^Last Result:').ToString() -replace '^Last Result:\s*', ''
        $state  = ($raw | Select-String '^Scheduled Task State:').ToString() -replace '^Scheduled Task State:\s*', ''
        return "$Name : $status / $state, last run $last (result $result)"
    } catch { return "$Name : n/a" }
}

# ---- header -------------------------------------------------------------
$version = "?"
try {
    $m = Select-String -Path (Join-Path $ZmDir "app.py") -Pattern 'APP_VERSION = f"Version ([0-9.]+)' | Select-Object -First 1
    if ($m) { $version = $m.Matches[0].Groups[1].Value }
} catch { }
Add ("=== ZeroMaster diag {0}  host {1}  v{2}  window {3}h ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $env:COMPUTERNAME, $version, $Hours)

# ---- service ------------------------------------------------------------
Add "-- service"
Add (Get-TaskLine "ZeroMaster")
Add (Get-TaskLine "ZeroMaster-Watchdog")
Add (Get-TaskLine "ZeroMaster-Journal-Digest")
# Watchdog liveness: it runs every 5 min. On 2026-09-24 one run hung for 72h
# (IgnoreNew then skipped every later run) and nothing noticed for 3 days.
try {
    $wdTask = Get-ScheduledTask -TaskName "ZeroMaster-Watchdog" -ErrorAction Stop
    $wdInfo = $wdTask | Get-ScheduledTaskInfo
    $ageMin = [int]((Get-Date) - $wdInfo.LastRunTime).TotalMinutes
    $limit  = $wdTask.Settings.ExecutionTimeLimit
    $verdict = "ok"
    if ($wdTask.State -eq 'Running' -and $ageMin -gt 10) { $verdict = "!! HUNG - running for $ageMin min" }
    elseif ($ageMin -gt 10) { $verdict = "!! STALE - last run $ageMin min ago" }
    $wdState = Join-Path $ZmDir "admin_tools\watchdog_state.json"
    $fail = "?"
    if (Test-Path $wdState) { $fail = (Get-Content $wdState -Raw | ConvertFrom-Json).failCount }
    Add ("watchdog liveness: {0} (last run {1} min ago, failCount {2}, run limit {3})" -f $verdict, $ageMin, $fail, $limit)
    if ($verdict -ne 'ok') { $issues.Add("watchdog $verdict") }
} catch { Add ("watchdog liveness: n/a ({0})" -f $_.Exception.Message); $issues.Add('watchdog status unreadable') }
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:5001/login" -UseBasicParsing -TimeoutSec 10
    Add ("http :5001/login -> {0} in {1} ms" -f $r.StatusCode, $sw.ElapsedMilliseconds)
} catch { Add ("http :5001/login -> FAILED: {0}" -f $_.Exception.Message); $issues.Add('web UI not answering') }
try {
    $py = @(Get-Process -Name python -ErrorAction SilentlyContinue)
    $exe = Get-Item $Python -ErrorAction SilentlyContinue
    $size = "missing"
    if ($exe) { $size = "$($exe.Length) bytes" }
    $disk = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    $free = "?"
    if ($disk) { $free = "{0:N1} GB" -f ($disk.Free / 1GB) }
    Add ("python.exe running: {0}   venv python.exe: {1}   C: free {2}" -f $py.Count, $size, $free)
    # A 0-byte venv python.exe killed the service on 2026-09-24
    if (-not $exe -or $exe.Length -lt 100000) { $issues.Add("venv python.exe is $size") }
    if ($disk -and $disk.Free -lt 5GB) { $issues.Add("C: only $free free") }
} catch { }

# ---- database: devices, queue, alembic ---------------------------------
Add "-- database"
if (Test-Path $Python) {
    # Written to a temp file: PS 5.1 does not escape embedded quotes when passing
    # arguments to native programs, so `python -c "<code>"` would break.
    $code = @'
import os, sqlalchemy as s
e = s.create_engine(os.environ['DATABASE_URL'])
with e.connect() as c:
    for n, ip, on, hb in c.execute(s.text('select name, ip_address, is_online, last_heartbeat from devices order by id')):
        print('device %s %s %s last_heartbeat(UTC) %s' % (n, ip, 'ONLINE' if on else 'OFFLINE', hb))
    cnt, oldest, alerted = c.execute(s.text('select count(*), min(created_at), sum(alerted_at is not null) from pending_device_deletions')).fetchone()
    print('pending queue: %s row(s), oldest %s, alerted %s' % (cnt, oldest, alerted or 0))
    print('alembic: %s' % c.execute(s.text('select version_num from alembic_version')).scalar())
'@
    $pyFile = Join-Path $env:TEMP "zm_diag_query.py"
    try {
        Set-Content -Path $pyFile -Value $code -Encoding ASCII
        $res = & $Python $pyFile 2>&1
        $dbOk = $false
        foreach ($l in $res) {
            $s = "$l"
            Add ("  " + $s)
            if ($s -match '^alembic: ') { $dbOk = $true }
            if ($s -match '^device (.+) (\S+) OFFLINE last_heartbeat\(UTC\) (.+)$') { $notes.Add(("{0} ({1}) offline, last seen {2} UTC" -f $matches[1], $matches[2], $matches[3])) }
            if ($s -match 'alerted ([1-9]\d*)') { $notes.Add("$($matches[1]) queue row(s) already alerted as stuck") }
        }
        if (-not $dbOk) { $issues.Add('database query failed') }
    } catch { Add ("  db query failed: {0}" -f $_.Exception.Message) }
    finally { Remove-Item -Path $pyFile -ErrorAction SilentlyContinue }
} else { Add "  venv python not found" }

# ---- app.log -------------------------------------------------------------
Add ("-- app.log (last {0}h)" -f $Hours)
$lines = @()
if (Test-Path $LogPath) {
    $files = @(Get-ChildItem -Path "$LogPath*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    foreach ($f in $files) {
        if ($f.LastWriteTime -ge $cutoff) { $lines += Get-Content -Path $f.FullName -ErrorAction SilentlyContinue }
    }
}
$groups = @{}; $errCount = 0; $warnCount = 0; $wdEvents = $false
$starts = New-Object System.Collections.Generic.List[string]
$syncOK = 0; $replayOK = 0; $skipped = 0; $queueWarn = 0
$expOK = 0; $expRecs = 0; $expFail = 0; $replayed = 0; $alerts = 0; $resolved = 0
$lastPending = ""
foreach ($line in $lines) {
    if ($line -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { continue }
    $ts = $null
    try { $ts = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch { continue }
    if ($ts -lt $cutoff) { continue }
    if ($line -match 'Scheduler started') { $starts.Add($ts.ToString('MM-dd HH:mm')) }
    elseif ($line -match 'scheduled_sync .* executed successfully') { $syncOK++ }
    elseif ($line -match 'scheduled_replay .* executed successfully') { $replayOK++ }
    elseif ($line -match 'maximum number of running instances|was missed') { $skipped++ }
    elseif ($line -match 'waitress.queue') { $queueWarn++ }
    elseif ($line -match 'db_export: exported (\d+) records') { $expOK++; $expRecs += [int]$matches[1] }
    elseif ($line -match 'db_export: export failed') { $expFail++ }
    elseif ($line -match 'Pending device ops:') { $lastPending = $line }
    elseif ($line -match 'Replayed \d+') { $replayed++ }
    elseif ($line -match 'not converging') { $alerts++ }
    elseif ($line -match 'resolved - ') { $resolved++ }
    if ($line -match ' - (ERROR|CRITICAL) - ') {
        $errCount++
        $sig = ($line -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d+ - ', '') -replace 'at 0x[0-9a-fA-F]+', 'at 0x?'
        if (-not $groups.ContainsKey($sig)) { $groups[$sig] = @{ Count = 0; First = $ts; Last = $ts } }
        $groups[$sig].Count++; $groups[$sig].Last = $ts
    } elseif ($line -match ' - WARNING - ' -and $line -notmatch 'waitress.queue') { $warnCount++ }
}
$startText = "none"
if ($starts.Count -gt 0) { $startText = ($starts -join ", ") }
Add ("service (re)starts: {0}" -f $startText)
Add ("jobs ok: sync {0}, replay {1}   skipped/missed: {2}   waitress queue warnings: {3}" -f $syncOK, $replayOK, $skipped, $queueWarn)
Add ("db_export: {0} OK ({1} recs), {2} fail" -f $expOK, $expRecs, $expFail)
Add ("replay: {0} replayed batch(es), {1} stuck alert(s), {2} resolved" -f $replayed, $alerts, $resolved)
if ($lastPending) { Add ("last queue summary: " + ($lastPending -replace '^.* - Pending', 'Pending')) }
Add ("errors: {0} line(s) in {1} kind(s); other warnings: {2}" -f $errCount, $groups.Count, $warnCount)
if ($starts.Count -gt 0) { $issues.Add("service restarted $($starts.Count)x") }
if ($skipped -gt 0) { $issues.Add("$skipped scheduler run(s) skipped/missed") }
if ($syncOK -eq 0) { $issues.Add('no successful scheduled_sync in window') }
if ($expFail -gt 0) { $issues.Add("$expFail HRM export failure(s)") }
if ($alerts -gt 0) { $notes.Add("$alerts stuck-queue alert(s), $resolved resolved") }
# Unreachable-terminal timeouts are expected while a terminal is off; anything else needs a look
$otherKinds = @($groups.Keys | Where-Object { -not ($_ -match "HTTPConnectionPool\(host='" -and $_ -match 'timed out|Max retries') })
if ($otherKinds.Count -gt 0) { $issues.Add("$($otherKinds.Count) other error kind(s)") }
$top = $groups.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 5
foreach ($g in $top) {
    $text = $g.Key
    if ($text -match "HTTPConnectionPool\(host='([^']+)'") {
        $h = $matches[1]
        if ($text -match 'timed out|Max retries') { $text = "[terminal $h unreachable] " + $text }
    }
    if ($text.Length -gt 200) { $text = $text.Substring(0, 200) + '...' }
    Add ("  x{0} {1}..{2} {3}" -f $g.Value.Count, $g.Value.First.ToString('MM-dd HH:mm'), $g.Value.Last.ToString('HH:mm'), $text)
}

# ---- watchdog -----------------------------------------------------------
Add "-- watchdog (events in window)"
if (Test-Path $WatchdogLog) {
    $wd = Get-Content -Path $WatchdogLog -Tail 400 -ErrorAction SilentlyContinue
    $shown = 0
    foreach ($l in $wd) {
        if ($l -match '(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})') {
            $t = $null
            try { $t = [datetime]::Parse($matches[1]) } catch { $t = $null }
            if ($t -and $t -ge $cutoff) {
                Add ("  " + $l); $shown++
                if ($l -match 'Unhealthy|Triggering|FAILED|timed out') { $wdEvents = $true }
            }
        }
    }
    if ($shown -eq 0) { Add "  none" }
    if ($wdEvents) { $issues.Add('watchdog saw the web UI fail') }
} else { Add "  watchdog.log not found" }

# ---- verdict first, so one glance is enough ----------------------------
$verdictLine = "VERDICT: OK"
if ($issues.Count -gt 0) { $verdictLine = "VERDICT: ATTENTION - " + ($issues -join '; ') }
if ($notes.Count -gt 0) { $verdictLine += "`nnote: " + ($notes -join '; ') }
$out.Insert(1, (Hide-Secrets $verdictLine))

$out | ForEach-Object { Write-Output $_ }

if ($Telegram) {
    $token  = [Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'Machine')
    $chatId = [Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID', 'Machine')
    if ($token -and $chatId) {
        $text = ($out -join "`n")
        if ($text.Length -gt 3900) { $text = $text.Substring(0, 3900) + "`n...(truncated)" }
        $body = @{ chat_id = $chatId; text = $text; disable_web_page_preview = $true } | ConvertTo-Json -Compress
        try {
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post `
                -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
            Write-Output "telegram: sent"
        } catch { Write-Output ("telegram: send failed - {0}" -f $_.Exception.Message) }
    } else { Write-Output "telegram: TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set (machine scope)" }
}

# ---- optional masked bundle --------------------------------------------
if ($Zip) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmm'
    $tmp = Join-Path $env:TEMP "zm_diag_$stamp"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $out | Set-Content -Path (Join-Path $tmp "summary.txt") -Encoding UTF8
    $lines | ForEach-Object { Hide-Secrets $_ } | Set-Content -Path (Join-Path $tmp "app_log_masked.txt") -Encoding UTF8
    if (Test-Path $WatchdogLog) {
        Get-Content $WatchdogLog -Tail 2000 | ForEach-Object { Hide-Secrets $_ } | Set-Content -Path (Join-Path $tmp "watchdog_log_masked.txt") -Encoding UTF8
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = $env:TEMP }
    $zipPath = Join-Path $desktop "zm_diag_$stamp.zip"
    Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zipPath -Force
    Remove-Item -Recurse -Force $tmp
    Write-Output ("zip saved: " + $zipPath)
}
