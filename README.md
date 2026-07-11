# Cisco Macro Tool for PowerShell

> **Note**: This is a community tool and is not officially supported by Pexip or Cisco.

Bulk macro, CA certificate, and UI panel management for Cisco RoomOS devices
(Room Kit, Board, Desk series) over the HTTPS xAPI — in pure PowerShell.

Designed for airgapped and locked-down environments: it needs **only the
PowerShell that ships with Windows** (Windows PowerShell 5.1) or PowerShell 7+.
No Python, no external modules, no installers.

## What it does

- **Deploy macros** — a single `.js` file, a whole directory, or `.zip`
  packages, to one device or thousands. Automatically enables macro mode,
  activates each macro, and restarts the macro runtime.
- **Deploy CA certificates** — install trust-store CA certificates in bulk
  (e.g. the Pexip CA so meeting-control macros can talk to Pexip over TLS).
  Handles PEM (including multi-cert bundles) and binary DER files, and treats
  already-installed certificates as success.
- **Pexip One-Touch-Join / meeting-control deployments** — the combined flow:
  per-device ZIP packages matched by room name (or shared macro files), plus
  the Pexip CA certificate, in a single run.
- **Remove in bulk** — specific macros or all macros, plus the companion UI
  panels many macros create (specific panel IDs or all UI extensions), with a
  macro-runtime restart afterwards.
- **Audit the fleet** — inventory report (CSV) of every device: product,
  software version, macro mode, macros (with active state), and panel IDs.
- **Test connectivity** — dry run that checks reachability and credentials
  without changing anything.

## Built for scale (2,000+ rooms)

- **Parallel execution** with a configurable throttle (default 20 concurrent
  devices) using runspace pools — works on PowerShell 5.1 and 7.
- **Automatic retries** — transient failures (timeouts, connection resets,
  HTTP 5xx/429) are retried up to 3 times with exponential backoff and jitter.
  Permanent failures (wrong password, rejected commands) fail fast with the
  device's actual reason.
- **One failure never stops the run** — each device is independent; the run
  continues and every outcome is recorded.
- **Retry file** — every run writes a `*_failed.csv` containing just the
  devices that failed, partially failed, or were unreachable. Feed that file
  back in as the device CSV to retry only the failures.
- **Real error detection** — RoomOS returns HTTP 200 even when a command is
  rejected; the tool parses the XML response and surfaces the device's
  `<Reason>` instead of reporting false success.
- **Logging** — every run writes a timestamped log and a per-device results
  CSV under `.\logs\`, and prints a color-coded summary
  (succeeded / partial / failed / unreachable).

## Requirements

- Windows PowerShell 5.1 (preinstalled on Windows 10/11 and Server 2016+) or
  PowerShell 7+ (Windows/macOS/Linux)
- Network access to the devices on TCP 443
- A device user with **Admin** role (macro and certificate commands require it)
- Macros/HttpMode enabled on the devices (they are by default)

## Quick start

```powershell
git clone https://github.com/acloudcenter/cisco-macro-tool-for-powershell.git
cd cisco-macro-tool-for-powershell

# 1. Copy the template and fill in your rooms
Copy-Item .\devices.template.csv .\devices.csv
notepad .\devices.csv

# 2. Run the interactive menu
.\Start-CiscoMacroTool.ps1
```

Menu options:

```
1. Deploy macros (file / folder / ZIP, + optional CA certs)
2. Deploy Pexip OTJ packages (per-device ZIPs)
3. Upload CA certificates only
4. Remove macros and/or UI panels
5. Fleet inventory report (macros, panels, software)
6. Test connectivity (dry run)
7. Exit
```

## Device CSV

```csv
name,host,username,password
Conference Room 101,10.0.10.11,admin,SecretPassword1
Conference Room 102,roomkit-102.example.com,admin,SecretPassword2
Boardroom,10.0.10.13,,
```

- `host` can be an IP address or DNS name (with or without `https://`).
- Leave `username`/`password` blank to be prompted **once** for shared
  credentials — recommended so passwords never sit in a file.
- The legacy headers from earlier versions of this tool
  (`system name`, `ip address`) still work.
- Blank hosts and duplicate hosts are skipped with a warning.

## Scripting it directly (no menu)

Everything the menu does is a module function you can call from your own
scripts or a scheduled task:

```powershell
Import-Module .\CiscoRoomKit.psm1

# Pexip meeting-control example: two macro files + the Pexip CA, to 2000 rooms
$cred = Get-Credential
Invoke-MacroDeployment -DeviceCsv .\devices.csv `
    -MacroPath .\pexip\pexip-otj.js, .\pexip\pexip-scheduler.js `
    -CertificatePath .\pexip\pexip-ca.pem `
    -Credential $cred -ThrottleLimit 30

# Retry just the failures from that run
Invoke-MacroDeployment -DeviceCsv .\logs\MacroDeployment_20260711_090000_failed.csv `
    -MacroPath .\pexip\ -CertificatePath .\pexip\pexip-ca.pem -Credential $cred

# Certificates only
Invoke-CertificateDeployment -DeviceCsv .\devices.csv -CertificatePath .\ca-bundle.pem -Credential $cred

# Remove the macros and their companion panel everywhere
Invoke-MacroRemoval -DeviceCsv .\devices.csv `
    -MacroName pexip-otj, pexip-scheduler -PanelId pexip_meetings -Credential $cred

# Nuke everything (asks you to type 'remove' to confirm)
Invoke-MacroRemoval -DeviceCsv .\devices.csv -AllMacros -AllPanels -Credential $cred

# Audit
Get-FleetInventory -DeviceCsv .\devices.csv -Credential $cred -OutputCsv .\inventory.csv

# Dry run
Test-FleetConnectivity -DeviceCsv .\devices.csv -Credential $cred
```

Add `-Force` to any deployment/removal function to skip the confirmation
prompt (for unattended runs).

Lower-level single-device building blocks are also exported if you want to
compose your own workflow: `Test-RoomKitDevice`, `Save-RoomKitMacro`,
`Enable-RoomKitMacro`, `Remove-RoomKitMacro`, `Add-RoomKitCACertificate`,
`Get-RoomKitPanelList`, `Remove-RoomKitPanel`, `Restart-RoomKitMacroRuntime`,
and more.

## What a deployment run does per device

1. **Connectivity/auth check** — `GET /getxml?location=/Status/SystemUnit`;
   unreachable devices are reported and skipped.
2. **Enable macro mode** (`xConfiguration Macros Mode: On`) and autostart.
3. **Install CA certificates** (`xCommand Security Certificates CA Add`) —
   re-adding an existing certificate counts as success.
4. **Save each macro** (`xCommand Macros Macro Save`, overwrite enabled) and
   **activate it** (`xCommand Macros Macro Activate`).
5. **Restart the macro runtime once** (`xCommand Macros Runtime Restart`) so
   the new macros start — this is when macros that ship a companion panel
   (like Pexip's meetings panel) create it.

Removal runs deactivate + remove the macros, remove the requested panels
(or all UI extensions), and restart the runtime.

## Output files

Every run writes to `.\logs\` (ignored by git):

| File | Contents |
| --- | --- |
| `<Operation>_<timestamp>.log` | Full per-device, per-step log with timestamps |
| `<Operation>_<timestamp>_results.csv` | One row per device: status, items succeeded/failed, duration, detail |
| `<Operation>_<timestamp>_failed.csv` | Failed/partial/unreachable devices, formatted as a device CSV for retry |
| `FleetInventory_<timestamp>_inventory.csv` | Audit report (inventory runs only) |

Passwords are written into `*_failed.csv` **only** if they came from your
input CSV; devices using the shared prompted credential get blank
username/password columns.

## Transpile options (older firmware)

Cisco deprecated macro transpilation in newer RoomOS releases. If you still
manage older firmware you can pass:

- `-Transpile` — sets `<Transpile>True</Transpile>` on macro save
- `-EvaluateTranspiled True|False` — sets
  `xConfiguration Macros EvaluateTranspiled`; devices that don't support the
  setting log a note and continue.

## Security notes

- Device certificates are **not validated** (`-SkipCertificateCheck` on PS 7,
  a validation-callback override on PS 5.1) because most RoomOS devices use
  self-signed certificates. Traffic is still TLS-encrypted.
- Prefer blank CSV credential columns + the shared credential prompt over
  storing passwords in the CSV.
- Basic authentication is used per request; credentials are only held in
  process memory during the run.

## Migrating from the previous version

The old per-task scripts (`MainMenu.ps1`, `UploadJsMacros.ps1`,
`UploadPexipOTJMacros.ps1`, `RemoveMacros.ps1`, `RemoveUIExtensions.ps1`,
`CheckMacrosOnSystem.ps1`, `CheckMacrosOnAllSystems.ps1`) were replaced by
`Start-CiscoMacroTool.ps1` + `CiscoRoomKit.psm1`. Your existing CSVs keep
working — the legacy `system name` / `ip address` headers are recognized.

## License

MIT — see [LICENSE](LICENSE).
