# Read-only Windows To Go stick with the Unified Write Filter (UWF)

Turn the Windows To Go stick into a "live" stick: the Windows partition (C:) is protected by UWF, so **every boot starts from exactly the same, clean state**. A second partition (D:) stays writable for logs and results.

```
USB disk
├─ EFI system partition
├─ C:  Windows + tool       ← protected by UWF: writes go to a RAM overlay, gone after reboot
└─ D:  DATA (2–4 GB, NTFS)  ← NOT protected: logs/results persist
```

For the Autopilot check this has a bonus: the marker, device ticket and MSA device identity are rebuilt for the PC on every boot, so `Reset-AutopilotProbeState.ps1` is no longer needed.

> Do **all** setup (tool, drivers, updates, tweaks) **first**, and enable UWF **last**. Everything you change on C: while UWF is on is lost at the next reboot.

## Automated (recommended)

From your own PC, with the Rufus-made stick plugged in (e.g. as `E:`), in an **elevated** PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsToGo\Prepare-WtgStick.ps1 -DriveLetter E -DataPartitionGB 100 -EnableUwf
```

This does sections 2–5 below for you:

| Where | What |
|---|---|
| Your PC (offline) | Shrinks the Windows partition by 100 GB and creates the **DATA** partition |
| Your PC (offline) | Upgrades the image to **Enterprise** with `DISM /Set-Edition` if it is Pro (stays unactivated without KMS/MAK/E3) |
| Your PC (offline) | Enables the **Client-UnifiedWriteFilter** feature in the image |
| Your PC (offline) | Copies the tool and adds the install step to `SetupComplete.cmd` |
| Stick, first boot | `Install-WtgAutopilotCheck.ps1` → `Enable-WtgUwf.ps1`: DATA → `D:`, junction for the logs, tweaks, UWF config (RAM overlay 4 GB, protect C:) |
| Stick, **second** boot onwards | C: is read-only. Check with `uwfmgr get-config`; log in `D:\AutopilotProbe\uwf-setup-*.log` |

The first session (first logon) is **not** protected yet, so the user profile created then persists. That makes later logons faster.

If the UWF feature was not active yet during the first boot, `Enable-WtgUwf.ps1` enables it and registers a one-shot startup task (`AutopilotCheck-EnableUwf`). UWF is then configured on the second boot and protects C: from the third boot onwards.

Afterwards, still do **section 6 (verify)**. The manual steps below explain what happens, or let you do it by hand.

---

## Requirements

- **Windows 11 Enterprise or Education** (or IoT Enterprise). UWF is **not** available in Pro. Build the stick from an Enterprise ISO. Check on the stick:

  ```powershell
  Get-WindowsEdition -Online
  ```

- Preferably a **USB SSD** rather than a cheap stick. UWF is designed for fixed disks. USB SSDs usually report themselves as *fixed*, cheap sticks often as *removable*. Whether UWF protects a removable-type stick properly has to be tested (step 6 shows whether it works).
- At least 8 GB RAM in the PCs you check (the overlay lives in RAM).

---

## 1. Build the stick as usual

Follow [README-WindowsToGo.md](README-WindowsToGo.md) steps 1–3: Rufus (with an **Enterprise** ISO), `Prepare-WtgStick.ps1`, first boot, tool installed. Optionally set up auto logon.

Then, on the stick:

- Run **Windows Update** until nothing is left, then reboot.
- Run the Autopilot check once to confirm it works.

## 2. Create the data partition (D:)

Rufus uses the whole disk for Windows, so shrink C: and create D:. In an **elevated PowerShell on the stick**:

```powershell
$c    = Get-Partition -DriveLetter C
$disk = $c.DiskNumber
Resize-Partition -DriveLetter C -Size ($c.Size - 4GB)
New-Partition -DiskNumber $disk -UseMaximumSize -DriveLetter D |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel DATA -Confirm:$false
```

`Resize-Partition` fails if unmovable files sit at the end of C:. Use a smaller value, or shrink it in Disk Management (`diskmgmt.msc` → right-click C: → *Shrink Volume*). Then create a new simple volume in the free space: NTFS, drive letter **D**, label **DATA**.

> Rufus's option *Prevent Windows To Go from accessing internal disks* hides the PC's internal disks, not the stick's own partitions, so D: stays visible.

## 3. Redirect the tool's output to D:

The tool writes to `C:\ProgramData\AutopilotProbe`. Replace that folder with a **junction** to D:, so the scripts don't need changing:

```powershell
New-Item D:\AutopilotProbe -ItemType Directory -Force | Out-Null
if (Test-Path C:\ProgramData\AutopilotProbe) {
    Copy-Item C:\ProgramData\AutopilotProbe\* D:\AutopilotProbe -Recurse -Force
    Remove-Item C:\ProgramData\AutopilotProbe -Recurse -Force
}
cmd /c mklink /J C:\ProgramData\AutopilotProbe D:\AutopilotProbe
```

The junction itself is on C:, so it is created now, before UWF is on, and persists. Writes through it land on D:, which UWF does not protect.

## 4. Make Windows UWF-friendly

These avoid filling the RAM overlay with useless writes:

```powershell
# No page file on C: (or move it to D:)
$cs = Get-CimInstance Win32_ComputerSystem
$cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false }
Get-CimInstance Win32_PageFileSetting | Remove-CimInstance

# No hibernation / fast startup
powercfg /hibernate off

# No defrag, indexing, prefetch, System Restore
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag'
Set-Service WSearch -StartupType Disabled
Set-Service SysMain -StartupType Disabled
Disable-ComputerRestore -Drive 'C:\'

# Windows Update: don't download in the background (updates are done in maintenance, see section 8)
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' NoAutoUpdate 1
```

Reboot once afterwards.

## 5. Enable and configure UWF

Elevated PowerShell on the stick:

```powershell
# 1. Install the feature (reboot required)
Enable-WindowsOptionalFeature -Online -FeatureName Client-UnifiedWriteFilter -All
Restart-Computer
```

After the reboot:

```powershell
uwfmgr overlay set-type RAM
uwfmgr overlay set-size 4096                 # MB; overlay maximum
uwfmgr overlay set-warningthreshold 3072     # MB
uwfmgr overlay set-criticalthreshold 3584    # MB
uwfmgr volume protect C:
uwfmgr filter enable
uwfmgr get-config                            # check "Next Session" settings
Restart-Computer
```

UWF configuration changes **only take effect after a reboot**; `get-config` shows them under *Next Session Settings*.

Optional file/registry exclusions (writes that **must** survive a reboot even though they are on C:):

```powershell
uwfmgr file add-exclusion C:\Some\Folder
uwfmgr registry add-exclusion "HKLM\SOFTWARE\Some\Key"
```

You don't need any for the Autopilot check: logs go to D: via the junction.

## 6. Verify

After the reboot:

```powershell
uwfmgr get-config            # Current Session: Filter state ON, Volume C: protected
```

Test:

```powershell
'test' | Set-Content C:\Users\Public\Desktop\uwf-test.txt
'test' | Set-Content D:\uwf-test.txt
Restart-Computer
```

After the reboot, the file on the **desktop is gone** and the file on **D: is still there** → UWF works. If `uwfmgr volume protect C:` gave an error or the desktop file survived, the stick is probably not supported (removable type). Use a USB SSD instead.

Then boot the stick on two different PCs and check that the Autopilot result is correct for each one, with the logs on `D:\AutopilotProbe`.

## 7. Daily use

Nothing changes: boot, log on, the check starts by itself. Each boot starts clean.

Check how full the overlay is:

```powershell
uwfmgr overlay get-consumption
uwfmgr overlay get-availablespace
```

When the overlay fills up completely, Windows becomes unstable and has to reboot. For a check that takes a few minutes, 4 GB is more than enough.

## 8. Maintenance (updates, tool changes)

Simplest: switch UWF off temporarily.

```powershell
uwfmgr filter disable
Restart-Computer
# ... Windows Update, update the tool (run Prepare-WtgStick.ps1 from another PC, or copy by hand), etc. ...
uwfmgr filter enable
Restart-Computer
```

> Updating the tool with `Prepare-WtgStick.ps1` from your own PC works **regardless of UWF**: UWF only filters while the stick's own Windows is running. Writing to the stick from another PC goes straight to disk. The same goes for anything else you change on the stick from outside.

Alternative: `uwfmgr servicing enable`. On the next reboot UWF starts a servicing mode that installs Windows updates, then turns protection back on by itself. This takes longer and gives you less control, so the manual route is clearer.

## Commands at a glance

| Command | Effect |
|---|---|
| `uwfmgr get-config` | Current and next-session configuration |
| `uwfmgr filter enable` / `disable` | Protection on/off (after reboot) |
| `uwfmgr volume protect C:` / `unprotect C:` | Protect/unprotect a volume |
| `uwfmgr overlay set-size <MB>` | Overlay size |
| `uwfmgr overlay get-consumption` | Current overlay usage |
| `uwfmgr file commit <path>` | Write one changed file permanently to disk |
| `uwfmgr file add-exclusion <path>` | Always write this path directly to disk |
| `uwfmgr registry add-exclusion <key>` | Same, for a registry key |
| `uwfmgr servicing enable` | Servicing mode on next reboot (updates) |

## Not verified

This guide was not tested on real hardware. Check in particular:

- Whether UWF protects C: on your stick type (step 6).
- Whether Windows Enterprise **activation** on the stick causes problems on different PCs. An unactivated Enterprise works, with a watermark and limited personalization.
- Whether the check still works when the MSA device identity is rebuilt on every boot. That should be the same situation as after `Reset-AutopilotProbeState.ps1`, which worked on a test laptop.
