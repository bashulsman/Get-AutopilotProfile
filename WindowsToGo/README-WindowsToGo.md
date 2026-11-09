# Autopilot check on a Windows To Go stick (Rufus)

A USB stick you boot a PC from to see straight away whether, and in which tenant, that PC is registered in Autopilot. Nothing on the PC's internal disk is changed.

## Files

| File | Run where | Purpose |
|---|---|---|
| `Prepare-WtgStick.ps1` | **Your own PC**, stick plugged in | Puts the tool on a Rufus-made stick and makes it install itself on the stick's first boot |
| `Install-WtgAutopilotCheck.ps1` | On the stick (normally automatic) | Creates the logon task, desktop shortcut and power settings |
| `Start-AutopilotCheck.ps1` | On the stick (automatic after logon) | Waits for internet, then runs `Get-AutopilotProfile.ps1 -Gui` |
| `Reset-AutopilotProbeState.ps1` | On the stick | Clears the cached marker/ticket/device identity: always a clean start |
| `Enable-WtgUwf.ps1` | On the stick (automatic with `-EnableUwf`) | DATA partition → D:, logs to D:, UWF tweaks, Unified Write Filter on C: |
| `Get-WtgDriverPack.ps1` | **Your own PC** | Downloads the official HP/Dell driver pack for a model into `Drivers\<model>` |
| `Show-MissingDrivers.ps1` | On the stick | Lists devices without a driver (hardware ID, chip vendor) and the PC model/system ID |
| `Test-WtgAutopilotMarker.ps1` | On the stick, as admin | On "No Autopilot marker": collects the Autopilot state, starts Windows' `DetectHardwareChange` task and checks whether the marker appears |

Want a read-only stick that starts clean on every boot, with a separate writable data partition? See [README-UWF.md](README-UWF.md) (Unified Write Filter).

## 1. Create the stick with Rufus

- A **fast** USB stick/SSD of ≥ 64 GB (a USB 3.x SSD is strongly recommended)
- A Windows 11 Enterprise/Pro ISO
- **USB SSD not listed in Rufus?** Rufus hides USB hard drives/SSDs by default. Press **Alt+F** in Rufus to list them, or open *Show advanced drive properties* and tick **List USB Hard Drives**. Double-check you picked the stick: Rufus wipes the whole disk.
- Rufus → *Image option*: **Windows To Go**
- After *Start*, Rufus shows the "Windows User Experience" dialog:

  | Option | Setting |
  |---|---|
  | Prevent Windows To Go from accessing internal disks | ✅ on — the PC's own disk stays untouched |
  | Remove requirement for an online Microsoft account | ✅ on |
  | Create a local account with username | ✅ on, e.g. `apcheck` |
  | Set regional options to the same values as this user's | ☐ off |
  | Disable data collection (Skip privacy questions) | ✅ on |
  | QoL improvements (Don't force Copilot, OneDrive, Outlook, Fast Startup, etc.) | ✅ on |
  | Use 'Windows CA 2023' signed bootloaders (Requires a compatible target PC) | ☐ off — older PCs without the 2023 Secure Boot certificate would not boot the stick |

## 2. Drivers (on your own PC)

Windows itself only has generic drivers. Wi-Fi in particular is usually missing on laptops, and without network the check cannot run. Put the drivers for the models you want to check in `WindowsToGo\Drivers\`; `Prepare-WtgStick.ps1` injects **every** `.inf` below that folder into the stick. Windows then picks the matching drivers per PC, so one stick can hold drivers for several models.

**HP and Dell:** download the official driver pack per model:

```powershell
.\WindowsToGo\Get-WtgDriverPack.ps1 -Vendor HP -Model 'ProBook 440 G8' -ListOnly   # show what it would download
.\WindowsToGo\Get-WtgDriverPack.ps1 -Vendor HP -Model 'ProBook 440 G8'
.\WindowsToGo\Get-WtgDriverPack.ps1 -Vendor Dell -Model 'Latitude 5420'
```

It picks the newest Windows 11 x64 pack (falls back to Windows 10), checks the hash from the vendor catalog and the HP/Dell signature, and extracts it to `Drivers\<vendor>-<model>`. If the model name matches several models, use `-SystemId` (see below).

**Other vendors / single drivers:** extract the driver (the folder with `.inf`, `.sys`, `.cat`) into a subfolder of `Drivers\`, e.g. `Drivers\Intel-WiFi-24.80.0`.

**Which driver is missing?** Boot the PC from the stick and run:

```powershell
powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Show-MissingDrivers.ps1
```

It shows the model, the system ID for `Get-WtgDriverPack.ps1` and every device without a driver, with its hardware ID and chip vendor (e.g. `PCI\VEN_10EC…` = Realtek Wi-Fi, `PCI\VEN_8086…` = Intel). A copy goes to the log folder.

**No Wi-Fi right now?** Use a USB/USB-C Ethernet adapter or USB tethering from a phone. Both work with drivers built into Windows, so you can run the check without waiting for the right Wi-Fi driver.

The `Drivers` folder is not copied into `X:\AutopilotCheck` (the drivers are already in Windows) and is excluded from git.

## 3. Prepare the stick (on your own PC)

Leave the stick plugged in after Rufus (or plug in a stick you already used) and run, **as administrator**:

```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsToGo\Prepare-WtgStick.ps1
```

The script finds the stick's Windows partition by itself: a USB disk with a Windows installation that is not your own system drive. If it finds more than one, or the partition has no drive letter, pass `-DriveLetter E`. **Nothing is formatted.** The script:

- injects all drivers from `WindowsToGo\Drivers\` with `DISM /Add-Driver /Recurse` (skip with `-SkipDrivers`). This also works on a stick that was already booted: you do **not** need to recreate it. Windows installs them at the next boot.
- copies the tool to `X:\AutopilotCheck` (a clean copy every time)
- adds a line to `X:\Windows\Setup\Scripts\SetupComplete.cmd` that starts the installation
- puts `Install Autopilot check.cmd` on the Public desktop as a fallback

Run the script again to put a newer version of the tool on the stick.

## 4. First boot of the stick

1. Boot a PC from the stick (F12/boot menu; Secure Boot can stay on) and finish the first setup.
2. Normally `SetupComplete.cmd` installs the tool by itself.
3. Do you still see the **Install Autopilot check** shortcut on the desktop after logging on? Double-click it once and confirm the UAC prompt. This happens when the stick was booted before, or when Windows skipped `SetupComplete.cmd` — for example when the PC has an OEM product key in its firmware. The shortcut disappears after installation.
4. Optional automatic logon (only on a stick used just for this check):

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Install-WtgAutopilotCheck.ps1 -AutoLogon
   ```

Installation logs are in `C:\ProgramData\AutopilotProbe\install-*.log`.

## 5. Usage

1. Plug the stick into the PC you want to check and boot from it.
2. Log on (or automatically). After ~10 s the *Waiting for internet* window appears. Plug in a network cable or pick Wi-Fi; the Wi-Fi settings open by themselves.
3. The result appears in the window (Registered/Not registered/Unknown, with tenant and profile).
4. To run it again: the **Autopilot check** shortcut on the desktop (asks for UAC).

**Did the check really go online?** Look in `C:\ProgramData\AutopilotProbe\`. Only a run that actually reached the service has an `HTTP <code>` line in `autopilot-*.log` and an `autopilot-*-response.json` file with Microsoft's response.

The check asks Windows for a fresh device ticket and, when the marker is missing (always the case on a Rufus stick, because its OOBE never reached Autopilot), starts Windows' `DetectHardwareChange` task to create it. Still **"No Autopilot marker"**? Run `Test-WtgAutopilotMarker.ps1` as administrator and look at its report. Still **HTTP 401** or **"No device ticket"**? Reboot the PC from the stick, with network, and try again.

## Switching PCs: stale data

The check uses the **AutopilotMarker** and **serial number** from `HKLM\SOFTWARE\Microsoft\Provisioning\HardwareInfo`, plus a fresh MSA **device ticket** it requests from Windows. When `HardwareInfo` is missing or its serial is another PC's, `Get-AutopilotProfile.ps1` clears it and starts Windows' `DetectHardwareChange` task, which rebuilds it (with the marker) for the PC the stick is booted on. Only if that fails does it report **Unknown** ("Cached hardware info belongs to another device"), so you never see a wrong tenant.

Tested with one stick on two laptops (HP ProBook 440 G8 and a second laptop): each got its own marker and its own tenant.

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
