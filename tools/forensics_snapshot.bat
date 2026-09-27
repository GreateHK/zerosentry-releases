@echo off
REM ============================================================
REM  ZeroMaster Forensics Snapshot v2
REM  Run AS ADMINISTRATOR when web UI is stuck on 404 (before reboot).
REM  Auto-detects install path from script location.
REM ============================================================

setlocal enabledelayedexpansion

REM --- Self-elevate to admin if not already ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting admin privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM --- Resolve paths ---
set "ZM_DIR=%~dp0.."
pushd "%ZM_DIR%"
set "ZM_DIR=%CD%"
popd
set "OUT_DIR=%ZM_DIR%\forensics"
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

REM --- Timestamp ---
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set TS=%%i
set "OUT=%OUT_DIR%\snap_%TS%.txt"

echo Writing snapshot to: %OUT%
echo.

echo ============================================================ > "%OUT%"
echo  ZeroMaster Forensics Snapshot v2 >> "%OUT%"
echo  Time: %date% %time% >> "%OUT%"
echo  Install dir: %ZM_DIR% >> "%OUT%"
echo ============================================================ >> "%OUT%"

echo. >> "%OUT%"
echo === [1] Task Scheduler: ZeroMaster (summary) === >> "%OUT%"
schtasks /Query /TN "ZeroMaster" /V /FO LIST >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [1b] Task Scheduler XML (full config + all triggers) === >> "%OUT%"
schtasks /Query /TN "ZeroMaster" /XML >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [2] All python.exe processes (with parent, start time) === >> "%OUT%"
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Select-Object ProcessId,ParentProcessId,CreationDate,HandleCount,ThreadCount,WorkingSetSize,CommandLine | Format-List | Out-String -Width 4000" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [2b] Parent process names === >> "%OUT%"
powershell -NoProfile -Command "$ps = Get-CimInstance Win32_Process -Filter \"Name='python.exe'\"; foreach ($p in $ps) { $parent = Get-CimInstance Win32_Process -Filter \"ProcessId=$($p.ParentProcessId)\" -ErrorAction SilentlyContinue; '{0,-8} parent={1,-8} parent_name={2}' -f $p.ProcessId, $p.ParentProcessId, $(if ($parent) { $parent.Name } else { '(gone)' }) }" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [3a] Port 5001 listener (ACTUAL web UI port) === >> "%OUT%"
netstat -ano -p TCP >> "%OUT%.netstat.tmp" 2>&1
findstr ":5001 " "%OUT%.netstat.tmp" >> "%OUT%"

echo. >> "%OUT%"
echo === [3b] Who owns :5001 (PID + image) === >> "%OUT%"
powershell -NoProfile -Command "$conn = Get-NetTCPConnection -LocalPort 5001 -State Listen -ErrorAction SilentlyContinue; if ($conn) { foreach ($c in $conn) { $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue; '{0} PID={1} ({2})' -f $c.LocalAddress, $c.OwningProcess, $(if ($proc) { $proc.ProcessName } else { 'unknown' }) } } else { Write-Output 'NOTHING LISTENING ON :5001' }" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [3c] Port 5000 listener (legacy / just in case) === >> "%OUT%"
findstr ":5000 " "%OUT%.netstat.tmp" >> "%OUT%"

echo. >> "%OUT%"
echo === [3d] Port 8090 (device API) === >> "%OUT%"
findstr ":8090" "%OUT%.netstat.tmp" >> "%OUT%"

echo. >> "%OUT%"
echo === [3e] Port 10005 (device FTP) === >> "%OUT%"
findstr ":10005" "%OUT%.netstat.tmp" >> "%OUT%"
del "%OUT%.netstat.tmp" 2>nul

echo. >> "%OUT%"
echo === [4] Curl localhost 127.0.0.1:5001 === >> "%OUT%"
echo --- GET / --- >> "%OUT%"
curl -v -m 10 http://127.0.0.1:5001/ >> "%OUT%" 2>&1
echo. >> "%OUT%"
echo --- GET /login --- >> "%OUT%"
curl -v -m 10 http://127.0.0.1:5001/login >> "%OUT%" 2>&1
echo. >> "%OUT%"
echo --- GET /dashboard --- >> "%OUT%"
curl -v -m 10 http://127.0.0.1:5001/dashboard >> "%OUT%" 2>&1
echo. >> "%OUT%"
echo --- GET /api/staff/list (API probe) --- >> "%OUT%"
curl -v -m 10 http://127.0.0.1:5001/api/staff/list >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [5] MySQL service === >> "%OUT%"
sc query MySQL80 >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [6] Disk free (C:) === >> "%OUT%"
powershell -NoProfile -Command "Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='C:'\" | Select-Object @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,2)}},@{n='SizeGB';e={[math]::Round($_.Size/1GB,2)}} | Format-List | Out-String" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [7] app.log size + tail 300 === >> "%OUT%"
if exist "%ZM_DIR%\app.log" (
    dir "%ZM_DIR%\app.log" >> "%OUT%"
    echo. >> "%OUT%"
    echo --- Last 300 lines of app.log --- >> "%OUT%"
    powershell -NoProfile -Command "Get-Content -Path '%ZM_DIR%\app.log' -Tail 300" >> "%OUT%" 2>&1
) else (
    echo app.log NOT FOUND at %ZM_DIR%\app.log >> "%OUT%"
)

echo. >> "%OUT%"
echo === [8] flask.log tail (if exists) === >> "%OUT%"
if exist "%ZM_DIR%\flask.log" (
    dir "%ZM_DIR%\flask.log" >> "%OUT%"
    powershell -NoProfile -Command "Get-Content -Path '%ZM_DIR%\flask.log' -Tail 200" >> "%OUT%" 2>&1
) else (
    echo flask.log not present >> "%OUT%"
)

echo. >> "%OUT%"
echo === [9] TCP summary === >> "%OUT%"
powershell -NoProfile -Command "netstat -an | Select-String -Pattern 'CLOSE_WAIT|TIME_WAIT|LISTENING|ESTABLISHED' | Group-Object { ($_ -split '\s+')[-1] } | Select-Object Name,Count | Format-Table -AutoSize | Out-String" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [10] OS boot time (LastBootUpTime) === >> "%OUT%"
powershell -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime" >> "%OUT%" 2>&1

echo. >> "%OUT%"
echo === [11] ZeroMaster version === >> "%OUT%"
if exist "%ZM_DIR%\app.py" (
    findstr /C:"APP_VERSION" "%ZM_DIR%\app.py" >> "%OUT%" 2>&1
) else (
    dir "%ZM_DIR%\app.*" >> "%OUT%" 2>&1
)

echo. >> "%OUT%"
echo === [12] Exporting Event Logs (past 48h) === >> "%OUT%"
wevtutil epl Application "%OUT_DIR%\app_events_%TS%.evtx" /q:"*[System[TimeCreated[timediff(@SystemTime) <= 172800000]]]" 2>>"%OUT%"
wevtutil epl System      "%OUT_DIR%\sys_events_%TS%.evtx" /q:"*[System[TimeCreated[timediff(@SystemTime) <= 172800000]]]" 2>>"%OUT%"
wevtutil epl "Microsoft-Windows-TaskScheduler/Operational" "%OUT_DIR%\taskscheduler_%TS%.evtx" 2>>"%OUT%"

echo.
echo ============================================================
echo  Snapshot complete.
echo  Text report: %OUT%
echo  Event logs:  %OUT_DIR%\*_%TS%.evtx
echo ============================================================
echo.
echo Zip the whole '%OUT_DIR%' folder and send to developer.
echo.
REM The watchdog runs this hidden with /nopause - a pause there waits forever
REM (it froze the watchdog for 72h on 2026-09-24).
if /i not "%~1"=="/nopause" pause
