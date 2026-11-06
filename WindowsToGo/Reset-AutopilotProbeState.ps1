<#
.SYNOPSIS
    Clears the cached Autopilot hardware info, Autopilot profile cache, MSA device tickets and the
    SYSTEM MSA device identity that Get-AutopilotProfile.ps1 relies on, so Windows rebuilds them for
    the CURRENT hardware. No backup - always a clean start.

.DESCRIPTION
    Intended for a Windows To Go stick (or a disk moved to another PC) where these values still
    belong to the device the installation was first provisioned on.

    Cleared:
      HKLM\SOFTWARE\Microsoft\Provisioning\HardwareInfo                        (values: AutopilotMarker, SerialNumber, ...)
      HKLM\SOFTWARE\Microsoft\Provisioning\AutopilotPolicyCache                (cached Autopilot profile JSON)
      HKU\S-1-5-18\SOFTWARE\Microsoft\IdentityCRL\Immersive\production\Token   (cached device tickets)
      HKU\S-1-5-18\SOFTWARE\Microsoft\IdentityCRL\DeviceIdentities             (MSA device identity)
      HKU\S-1-5-18\SOFTWARE\Microsoft\IdentityCRL\StoredIdentities
    (-KeepDeviceIdentity leaves the last two alone.)

    Afterwards wlidsvc is restarted. Reboot the PC (with network) before running the check again.

    NOTE: whether Windows re-creates HardwareInfo\AutopilotMarker outside OOBE is NOT verified. If it
    does not, the check reports "No Autopilot marker" (Unknown) - never a wrong tenant.

    Safety: refuses (exit 3, nothing changed) on a device that is Entra joined, AD domain joined or
    Intune/MDM enrolled, unless -Force is given. The stick (local account) is none of these.

    Needs SYSTEM for the HKU\S-1-5-18 part; started as admin it relaunches itself as SYSTEM via a
    one-shot scheduled task.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Reset-AutopilotProbeState.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Reset-AutopilotProbeState.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$KeepDeviceIdentity,
    [switch]$Force,      # also run on an Entra/AD-joined or Intune/MDM-enrolled device
    [string]$OutDir = "$env:ProgramData\AutopilotProbe"
)

# --- Safety: this is meant for the Windows To Go stick, not for managed production devices ----
function Get-ManagedReasons {
    $why = @()
    $join = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo' -EA SilentlyContinue
    if ($join) { $why += 'Microsoft Entra joined' }
    if ((Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue).PartOfDomain) { $why += 'Active Directory domain joined' }
    $mdm = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -EA SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath -EA SilentlyContinue } |
           Where-Object { $_.ProviderID -eq 'MS DM Server' -and $_.EnrollmentState -eq 1 }
    if ($mdm) { $why += "MDM (Intune) enrolled ($(@($mdm.UPN | Where-Object { $_ }) -join ', '))" }
    return $why
}
if (-not $Force) {
    $reasons = Get-ManagedReasons
    if ($reasons) {
        Write-Warning ("This device is managed: {0}." -f ($reasons -join '; '))
        Write-Warning 'Reset-AutopilotProbeState is meant for the Windows To Go stick. Nothing was changed.'
        Write-Warning 'Use -Force only if you are sure you want to clear these values on this device.'
        exit 3
    }
}
$ErrorActionPreference = 'Continue'
New-Item $OutDir -ItemType Directory -Force | Out-Null
$Tag  = Get-Date -Format 'yyyyMMdd-HHmmss'
$log  = Join-Path $OutDir "reset-$Tag.log"
$done = Join-Path $OutDir 'reset.done'
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l; Add-Content $log $l }

$id       = [Security.Principal.WindowsIdentity]::GetCurrent()
$isSystem = ($id.User.Value -eq 'S-1-5-18')
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as administrator.' }

$targets = @(
    @{ Path='HKLM\SOFTWARE\Microsoft\Provisioning\HardwareInfo';                       Mode='Values'  }
    @{ Path='HKLM\SOFTWARE\Microsoft\Provisioning\AutopilotPolicyCache';               Mode='Values'  }
    @{ Path='HKU\S-1-5-18\SOFTWARE\Microsoft\IdentityCRL\Immersive\production\Token'; Mode='Subkeys' }
)
if (-not $KeepDeviceIdentity) {
    $targets += @{ Path='HKU\S-1-5-18\SOFTWARE\Microsoft\IdentityCRL\DeviceIdentities'; Mode='Subkeys' }
    $targets += @{ Path='HKU\S-1-5-18\SOFTWARE\Microsoft\IdentityCRL\StoredIdentities'; Mode='Subkeys' }
}

# =============================================================================================
#  Not SYSTEM: relaunch as SYSTEM via a one-shot scheduled task
# =============================================================================================
if (-not $isSystem) {
    Write-Host 'Clearing:' -ForegroundColor Yellow
    $targets | ForEach-Object { Write-Host "  [$($_.Mode)] $($_.Path)" }
    if ($WhatIfPreference) { Write-Host '(WhatIf: nothing changed)'; exit 0 }

    Remove-Item $done -EA SilentlyContinue
    $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Force -OutDir `"$OutDir`""   # guard already passed here
    if ($KeepDeviceIdentity) { $arg += ' -KeepDeviceIdentity' }
    $task = "AutopilotProbeReset-$Tag"
    $a = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument $arg
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    Register-ScheduledTask -TaskName $task -Action $a -Settings $s -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    Write-Host 'Running as SYSTEM...'
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline -and -not (Test-Path $done)) { Start-Sleep 2 }
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -EA SilentlyContinue
    if (Test-Path $done) { Get-Content (Get-Content $done -Raw).Trim() } else { Write-Warning "No result from the SYSTEM run within 90 s (see $OutDir\reset-*.log)." }
    exit 0
}

# =============================================================================================
#  SYSTEM: clear
# =============================================================================================
foreach ($t in $targets) {
    $ps = "Registry::$($t.Path)"
    if (-not (Test-Path $ps)) { Log "Not present: $($t.Path)"; continue }
    if (-not $PSCmdlet.ShouldProcess($t.Path, "Clear $($t.Mode)")) { continue }
    if ($t.Mode -eq 'Values') {
        foreach ($v in (Get-Item $ps).Property) { Remove-ItemProperty -Path $ps -Name $v -Force -EA SilentlyContinue }
    } else {
        Get-ChildItem $ps -EA SilentlyContinue | ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -EA SilentlyContinue }
    }
    $left = if ($t.Mode -eq 'Values') { @((Get-Item $ps).Property).Count } else { @(Get-ChildItem $ps -EA SilentlyContinue).Count }
    Log ("Cleared ({0}): {1}{2}" -f $t.Mode, $t.Path, $(if ($left) { "  - WARNING: $left item(s) could not be removed" }))
}

Restart-Service wlidsvc -Force -EA SilentlyContinue
Log 'wlidsvc restarted. Reboot with network, then run the check.'
Set-Content $done $log
exit 0
