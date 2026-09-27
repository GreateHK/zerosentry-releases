# ZeroMaster Releases

Compiled patch releases and admin tools for ZeroMaster field upgrades.

## Admin Tools

Install on any ZeroMaster deployment (auto-detects install dir):

```powershell
iwr -UseBasicParsing "https://raw.githubusercontent.com/GreateHK/zerosentry-releases/main/tools/install_tools.ps1?v=2026.09.27.2" | iex
```

### `tools/forensics_snapshot.bat`
Captures full diagnostic snapshot (Task Scheduler state, port listeners,
python.exe memory/handles, app.log tail, event logs) when the web UI
is unresponsive. Run as Administrator **before** rebooting so the
forensic evidence is preserved.
