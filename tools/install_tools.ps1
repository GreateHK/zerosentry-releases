# ============================================================
#  ZeroMaster Admin Tools - one-shot installer / updater
#
#  USAGE (paste ONE line into an *Administrator* PowerShell):
#    iwr -UseBasicParsing "https://raw.githubusercontent.com/GreateHK/zerosentry-releases/main/tools/install_tools.ps1?v=2026.09.27.2" | iex
#
#  What it does (does NOT touch ZeroMaster itself, no service restart):
#    1. downloads the admin tools and checks every file's SHA-256
#       (any mismatch -> installs nothing)
#    2. backs up the current copies to admin_tools\backup_<time>\
#    3. installs the new copies
#    4. caps the Watchdog / Journal-Digest tasks at 10 minutes per run and
#       (re)creates ZeroMaster-Daily-Diag: zm_diag -> Telegram every day 09:00
#    5. runs forensics once (must finish on its own) and sends zm_diag to
#       Telegram once now, so the phone shows the whole path works
#
#  Runs via `iex`, so: ASCII only, no BOM, never call `exit`.
# ============================================================

$toolsVersion = '2026.09.27.2'
$baseUrl      = 'https://raw.githubusercontent.com/GreateHK/zerosentry-releases/main/tools'
$expected = @{
    'health_check.ps1'       = '6e6e12f92d4515fad6461ec3e983a356e244960ae6f8e47632b8ac6a3c98059d'
    'forensics_snapshot.bat' = 'ccba4929ecb5d916ef4b31c42a9a31ccce6d69a40c48d0aaf116c16e90faa485'
    'zm_diag.ps1'            = 'd6f1656b6bb71861517c0fe86e43029f76a50588f8f38c6dbf0add40cdcdc1ad'
    'journal_digest.ps1'     = 'aa6213b88fd52abdf375524ad5a8948d12b382696802359db1409a1d852f68e3'
}

function Write-Step($msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

& {
    $ErrorActionPreference = 'Stop'

    # --- 0. must be Administrator ------------------------------------------
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Please open PowerShell with 'Run as Administrator' and paste the line again." -ForegroundColor Red
        return
    }

    # --- locate ZeroMaster ---------------------------------------------------
    $installDir = $null
    foreach ($c in @('C:\ZeroSentry\ZeroMaster', 'C:\zeromaster\ZeroMaster', 'C:\ZeroMaster')) {
        if (Test-Path (Join-Path $c 'app.py')) { $installDir = $c; break }
    }
    if (-not $installDir) { Write-Host "ZeroMaster install dir not found." -ForegroundColor Red; return }
    $toolsDir = Join-Path $installDir 'admin_tools'
    if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }
    Write-Host "ZeroMaster: $installDir   tools version: $toolsVersion" -ForegroundColor Green

    # --- 1. download + verify everything first -----------------------------
    Write-Step "1/5 download + verify"
    $stage = Join-Path $env:TEMP ("zm_tools_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    $allOk = $true
    foreach ($name in $expected.Keys) {
        $dest = Join-Path $stage $name
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$name`?v=$toolsVersion" -OutFile $dest
            $hash = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToLower()
            if ($hash -eq $expected[$name]) { Write-Host "  OK   $name" -ForegroundColor Green }
            else { Write-Host "  BAD  $name (hash mismatch)" -ForegroundColor Red; $allOk = $false }
        } catch {
            Write-Host "  FAIL $name : $($_.Exception.Message)" -ForegroundColor Red; $allOk = $false
        }
    }
    if (-not $allOk) {
        Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
        Write-Host "Nothing was installed. GitHub may still be serving an old copy - wait 5 minutes and paste the line again." -ForegroundColor Red
        return
    }

    # --- 2. backup ------------------------------------------------------------
    Write-Step "2/5 backup"
    $backup = Join-Path $toolsDir ("backup_" + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($name in $expected.Keys) {
        $cur = Join-Path $toolsDir $name
        if (Test-Path $cur) { Copy-Item $cur $backup }
    }
    Write-Host "  $backup"

    # --- 3. install -------------------------------------------------------------
    Write-Step "3/5 install"
    foreach ($name in $expected.Keys) {
        Copy-Item (Join-Path $stage $name) (Join-Path $toolsDir $name) -Force
        $hash = (Get-FileHash -Path (Join-Path $toolsDir $name) -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $expected[$name]) { Write-Host "  $name did not install cleanly - restore from $backup" -ForegroundColor Red; return }
        Write-Host "  installed $name"
    }
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue

    # --- 4. 10-minute run limit on the helper tasks (NOT on ZeroMaster itself) ---
    Write-Step "4/5 scheduled tasks"
    foreach ($taskName in @('ZeroMaster-Watchdog', 'ZeroMaster-Journal-Digest')) {
        try {
            $t = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $t.Settings.ExecutionTimeLimit = 'PT10M'
            Set-ScheduledTask -InputObject $t | Out-Null
            $now = (Get-ScheduledTask -TaskName $taskName).Settings.ExecutionTimeLimit
            Write-Host "  $taskName -> $now"
        } catch { Write-Host "  $taskName : $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    # Daily health summary to Telegram. Register-ScheduledTask instead of schtasks:
    # PS 5.1 mangles embedded quotes when passing arguments to native programs.
    try {
        $diag = Join-Path $toolsDir 'zm_diag.ps1'
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$diag`" -Hours 24 -Telegram"
        $trigger   = New-ScheduledTaskTrigger -Daily -At '09:00'
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -StartWhenAvailable
        Register-ScheduledTask -TaskName 'ZeroMaster-Daily-Diag' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        $d = Get-ScheduledTask -TaskName 'ZeroMaster-Daily-Diag'
        Write-Host ("  ZeroMaster-Daily-Diag -> daily 09:00, limit {0}" -f $d.Settings.ExecutionTimeLimit)
    } catch { Write-Host "  ZeroMaster-Daily-Diag : $($_.Exception.Message)" -ForegroundColor Yellow }

    # --- 5. prove forensics can no longer hang, then show diag ---------------
    Write-Step "5/5 check"
    $bat = Join-Path $toolsDir 'forensics_snapshot.bat'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $bat -ArgumentList '/nopause' -WindowStyle Hidden -PassThru
    $p | Wait-Process -Timeout 180 -ErrorAction SilentlyContinue
    if ($p.HasExited) { Write-Host ("  forensics finished on its own in {0}s - OK" -f [int]$sw.Elapsed.TotalSeconds) -ForegroundColor Green }
    else { $p | Stop-Process -Force; Write-Host "  forensics did NOT finish in 180s - tell Claude" -ForegroundColor Red }

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir 'zm_diag.ps1') -Hours 24 -Telegram

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  DONE (tools $toolsVersion). Check your phone for the Telegram summary, then copy everything above to Claude." -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
}
