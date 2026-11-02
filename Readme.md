\# Get-AutopilotProfile



Check \*\*online\*\* whether a Windows device is registered in \*\*Windows Autopilot\*\* — and in \*\*which tenant\*\* — straight from the device, without Microsoft Graph, app registrations, or credentials.



It does this by asking the Autopilot service (`ztd.dds.microsoft.com`) the same question Windows asks during OOBE, using the device's own cached MSA device ticket and Autopilot marker.



> ⚠️ \*\*Unsupported / undocumented.\*\* This relies on an internal Windows flow that Microsoft does not document and may change at any time. Use it as a diagnostic tool on devices you own. For production, supported checks, use the Microsoft Graph Autopilot APIs.



\---



\## What it does



Run it on a device and it tells you:



```

Status       : Registered

TenantDomain : contoso.com

TenantId     : 00000000-0000-0000-0000-000000000000

ProfileName  : Standard Autopilot

SerialNumber : ABC1234

ExitCode     : 0

```



or, for a device that is not enrolled:



```

Status       : NotRegistered

ExitCode     : 1

```



Results are also written to `%ProgramData%\\AutopilotProbe\\` (a log, a JSON result, and the raw service response).



\### Exit codes



| Code | Meaning |

|------|---------|

| `0`  | Registered in Autopilot |

| `1`  | Not registered (`ZtdDeviceIsNotRegistered` / error 807) |

| `2`  | Unknown (couldn't determine — see the log) |



\---



\## Requirements



\- A \*\*fully running, provisioned Windows\*\* (a normal desktop session). See \[Where it works](#where-it-works).

\- Must run as \*\*`NT AUTHORITY\\SYSTEM`\*\* — the device ticket lives in the SYSTEM account's profile hive.

\- \*\*Network\*\* access to `https://ztd.dds.microsoft.com`.

\- Windows PowerShell 5.1 (it uses `System.Security.Cryptography.ProtectedData`, which is not loaded by default in PowerShell 7).



\## Usage



Run as SYSTEM, e.g. with \[PsExec](https://learn.microsoft.com/sysinternals/downloads/psexec):



```cmd

psexec -s powershell -ExecutionPolicy Bypass -File .\\Get-AutopilotProfile.ps1

```



The script relaunches itself as SYSTEM via a one-shot scheduled task if you start it as a normal admin, so this also works:



```powershell

powershell -ExecutionPolicy Bypass -File .\\Get-AutopilotProfile.ps1

```



Show the result in a window instead of the console:



```powershell

powershell -ExecutionPolicy Bypass -File .\\Get-AutopilotProfile.ps1 -Gui

```



Or use the \*\*runner\*\*, which downloads PsExec (Sysinternals) into its own folder if it isn't there yet and launches the check as SYSTEM for you (GUI by default):



```powershell

powershell -ExecutionPolicy Bypass -File .\\Run-AutopilotCheck.ps1

```



In a deployment task sequence (where the step already runs as SYSTEM) it sets task-sequence variables `AutopilotStatus`, `AutopilotTenant` and `AutopilotProfile` when the 2Pint DeployR `DeployR.Utility` module is present.



\### Files



| File | Purpose |

|------|---------|

| `Get-AutopilotProfile.ps1` | The check. Self-elevates to SYSTEM if started as a normal admin; `-Gui` shows a window. |

| `Run-AutopilotCheck.ps1` | Downloads PsExec if needed and runs the check as SYSTEM (GUI by default). |

| `README.md` | This file. |



\---



\## How it works



Windows, during OOBE, asks the Autopilot service whether the device has a profile. This script replicates that call.



\*\*The request\*\*



```

GET https://ztd.dds.microsoft.com/ztd/device/autopilotdevicebootstrappolicies

&#x20; X-Device-Token:     <MSA device ticket (JWT)>

&#x20; X-Autopilot-Marker: <device Autopilot marker>

&#x20; MS-CV:              <correlation vector>

&#x20; User-Agent:         Dsreg/10.0 (Windows NT 10.0)

```



Both headers are required. With only the token you get `{"ErrorCode":908,"ErrorReason":"HardwareMarkerMismatch"}`; the hardware hash is \*\*not\*\* needed.



\*\*Where the two inputs come from\*\*



\- \*\*Device token\*\* — an MSA device ticket (a JWT) cached by `wlidsvc`. It is stored DPAPI-encrypted inside an NDR structure under:



&#x20; ```

&#x20; HKEY\_USERS\\S-1-5-18\\SOFTWARE\\Microsoft\\IdentityCRL\\Immersive\\production\\Token\\{8A6E5826-EA01-989D-989D-158EE04D1518}\\DeviceTicket

&#x20; ```



&#x20; The `{8A6E5826-…}` key is the hosting app for `dds.microsoft.com`. The script DPAPI-unprotects the blob (skipping its 4-byte header) and extracts the JWT — the UTF‑16LE string starting with `eyJ`.



\- \*\*Autopilot marker\*\* — a device-unique GUID, originally set in UEFI and surfaced to the registry at:



&#x20; ```

&#x20; HKLM\\SOFTWARE\\Microsoft\\Provisioning\\HardwareInfo\\AutopilotMarker

&#x20; ```



\*\*The response\*\* is the full Autopilot profile as JSON (`CloudAssignedTenantDomain`, `CloudAssignedTenantId`, `DeploymentProfileName`, …), or an error indicating the device is not registered.



\---



\## Where it works



| Phase / environment | Works? | Why |

|---|---|---|

| \*\*Running, provisioned Windows\*\* (desktop session) | ✅ | Device ticket present, DPAPI master keys available, marker in registry |

| \*\*Windows OOBE\*\* | ❌ | The ticket exists but DPAPI can't decrypt it in the OOBE state ("Key not valid for use in specified state") |

| \*\*WinPE\*\* | ❌ | No `wlidsvc`, so no device ticket; and the Platform Crypto Provider / TPM crypto stack isn't usable |

| \*\*Audit mode (fresh install)\*\* | ⚠️ | The device ticket is usually not minted yet |



In short: this is a check for \*\*devices that are up and running\*\*. It is not a pre-deployment (bare-metal) check — at that stage the required inputs don't exist yet. For that, use Microsoft Graph with app or device-code authentication.



\### The device ticket is short-lived



Even on a running device, the cached MSA device ticket \*\*expires\*\* (hours, not days). When it is present but expired, the service replies \*\*HTTP 401\*\* and the script reports `Unknown`. You don't control when Windows refreshes it — a \*\*reboot\*\* (or sign-out/in) usually mints a fresh one. So treat a successful result as "valid right now," not as something you can rely on being available at any arbitrary moment.



\---



\## Privacy \& security notes



\- The script is \*\*read-only\*\*: it does not change device state. (When started as a normal admin it creates and then removes a temporary scheduled task to relaunch itself as SYSTEM.)

\- It never writes the device ticket in full to its log.

\- The device ticket is a credential bound to the device — treat the raw service responses in `%ProgramData%\\AutopilotProbe\\` accordingly.



\## Credits



The underlying flow was documented through the reverse-engineering research of \*\*call4cloud.nl\*\* (the MSA device ticket, the ZTD endpoint, and the `908 HardwareMarkerMismatch` behaviour). This script packages that into a single, self-contained check.



\## License



MIT. Provided as-is, with no warranty. Not affiliated with or endorsed by Microsoft or 2Pint Software.

