# Autopilot check on a Windows To Go stick (Rufus)

🇳🇱 [Nederlandse versie](README-WindowsToGo.nl.md)

A USB stick you boot a PC from to see straight away whether, and in which tenant, that PC is registered in Autopilot. Nothing on the PC's internal disk is changed.

## Files

| File | Run where | Purpose |
|---|---|---|
| `Prepare-WtgStick.ps1` | **Your own PC**, stick plugged in | Puts the tool on a Rufus-made stick and makes it install itself on the stick's first boot |
| `Install-WtgAutopilotCheck.ps1` | On the stick (normally automatic) | Creates the logon task, desktop shortcut and power settings |
| `Start-AutopilotCheck.ps1` | On the stick (automatic after logon) | Waits for internet, then runs `Get-AutopilotProfile.ps1 -Gui` |
| `Reset-AutopilotProbeState.ps1` | On the stick | Clears the cached marker/ticket/device identity: always a clean start |

## 1. Create the stick with Rufus

- A **fast** USB stick/SSD of ≥ 64 GB (a USB 3.x SSD is strongly recommended)
- A Windows 11 Enterprise/Pro ISO
- Rufus → *Image option*: **Windows To Go**
- In the "Windows User Experience" dialog, tick:
  - **Prevent Windows To Go from accessing internal disks**
  - **Remove requirement for an online Microsoft account**
  - **Create a local account using username:** e.g. `apcheck`
  - **Disable BitLocker automatic device encryption**

## 2. Prepare the stick (on your own PC)

Leave the stick plugged in after Rufus and run, **as administrator**:

```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsToGo\Prepare-WtgStick.ps1
```

The script finds the stick's Windows partition by itself: a USB disk with a Windows installation that is not your own system drive. If it finds more than one, or the partition has no drive letter, pass `-DriveLetter E`. **Nothing is formatted.** The script:

- copies the tool to `X:\AutopilotCheck` (a clean copy every time)
- adds a line to `X:\Windows\Setup\Scripts\SetupComplete.cmd` that starts the installation
- puts `Install Autopilot check.cmd` on the Public desktop as a fallback

Run the script again to put a newer version of the tool on the stick.

## 3. First boot of the stick

1. Boot a PC from the stick (F12/boot menu; Secure Boot can stay on) and finish the first setup.
2. Normally `SetupComplete.cmd` installs the tool by itself.
3. Do you still see the **Install Autopilot check** shortcut on the desktop after logging on? Double-click it once and confirm the UAC prompt. This happens when the stick was booted before, or when Windows skipped `SetupComplete.cmd` — for example when the PC has an OEM product key in its firmware. The shortcut disappears after installation.
4. Optional automatic logon (only on a stick used just for this check):

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Install-WtgAutopilotCheck.ps1 -AutoLogon
   ```

Installation logs are in `C:\ProgramData\AutopilotProbe\install-*.log`.

## 4. Usage

1. Plug the stick into the PC you want to check and boot from it.
2. Log on (or automatically). After ~10 s the *Waiting for internet* window appears. Plug in a network cable or pick Wi-Fi; the Wi-Fi settings open by themselves.
3. The result appears in the window (Registered/Not registered/Unknown, with tenant and profile).
4. To run it again: the **Autopilot check** shortcut on the desktop (asks for UAC).

**Did the check really go online?** Look in `C:\ProgramData\AutopilotProbe\`. Only a run that actually reached the service has an `HTTP <code>` line in `autopilot-*.log` and an `autopilot-*-response.json` file with Microsoft's response.

On **HTTP 401** (ticket expired) or **"No device ticket"**, reboot the PC from the stick, with network, and try again.

## Switching PCs: stale data

The check uses the **AutopilotMarker** and **serial number** from `HKLM\SOFTWARE\Microsoft\Provisioning\HardwareInfo`, plus SYSTEM's MSA **device ticket**. If these still belong to a previous PC, `Get-AutopilotProfile.ps1` reports **Unknown** ("Cached hardware info belongs to another device"). So you never see a wrong tenant.

Tested on an Entra-joined PC: after clearing, Windows re-created `HardwareInfo` within seconds, with the **same** marker. The marker is therefore derived from the hardware, so on the stick I expect it to be rebuilt correctly per PC. **Test this on two different PCs** before putting the stick into use.

### Clean start: `Reset-AutopilotProbeState.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Reset-AutopilotProbeState.ps1
```

Run as administrator; the script then relaunches itself as SYSTEM. **No backup** is made. It clears:

- `HardwareInfo`
- `AutopilotPolicyCache`
- SYSTEM's device tickets and MSA device identity

Then it restarts `wlidsvc`. Reboot with network afterwards. `-WhatIf` only shows what would be cleared; `-KeepDeviceIdentity` leaves the MSA device identity in place.

**Safety:** on a PC that is Entra-joined, AD domain-joined or Intune/MDM-enrolled, the script refuses to run (exit code 3, nothing is changed) unless you pass `-Force`. The stick uses a local account, so it is not affected.
