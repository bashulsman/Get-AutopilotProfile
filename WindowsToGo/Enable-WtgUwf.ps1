<#
.SYNOPSIS
    Runs ON the Windows To Go stick: sets up the DATA partition, redirects the tool's logs to it, makes
    Windows UWF-friendly and enables the Unified Write Filter (UWF) for C:.

.DESCRIPTION
    Normally called automatically by Install-WtgAutopilotCheck.ps1 when Prepare-WtgStick.ps1 was run
    with -EnableUwf (flag file WindowsToGo\enable-uwf.flag). Can also be run by hand as administrator.

    Steps:
      1. DATA partition (label 'DATA', same disk as C:) gets drive letter D: (or the first free one)
      2. C:\ProgramData\AutopilotProbe becomes a junction to <DATA>:\AutopilotProbe
      3. UWF-friendly tweaks: no page file, no hibernation, no defrag/indexing/SysMain/System Restore,
         no automatic Windows Update
      4. UWF: RAM overlay 4 GB, protect C:, filter on. Takes effect after the NEXT reboot.
         If the UWF feature is not active yet, it is enabled and a one-shot startup task retries
         this script after the reboot.

    Requires Windows 11 Enterprise/Education. Log: <DATA>:\AutopilotProbe\uwf-setup-<time>.log
#>
[CmdletBinding()]
param(
    [string]$DataLabel     = 'DATA',
    [int]$OverlaySizeMB    = 4096,
    [string]$ToolOutDir    = "$env:ProgramData\AutopilotProbe"
)
$ErrorActionPreference = 'Continue'
$RetryTask = 'AutopilotCheck-EnableUwf'
$uwfmgr    = "$env:SystemRoot\System32\uwfmgr.exe"

if (-not (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as administrator.' }

$script:LogLines = @()
function Log($m) { $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l; $script:LogLines += $l }

# --- 1. DATA partition -> D: ---------------------------------------------------------------------
$sysDisk = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':'))).DiskNumber
$dataPart = Get-Partition -DiskNumber $sysDisk | Where-Object { ($_ | Get-Volume -EA SilentlyContinue).FileSystemLabel -eq $DataLabel } | Select-Object -First 1
$dataRoot = $null
if (-not $dataPart) {
    Log "No '$DataLabel' partition on disk $sysDisk - logs stay on C: (lost after each reboot once UWF is on)."
} else {
    if ($dataPart.DriveLetter -ne 'D') {
        $dTaken = Get-Volume -DriveLetter D -EA SilentlyContinue
        if (-not $dTaken) {
            if ($dataPart.DriveLetter) { Remove-PartitionAccessPath -DiskNumber $sysDisk -PartitionNumber $dataPart.PartitionNumber -AccessPath "$($dataPart.DriveLetter):\" -EA SilentlyContinue }
            Set-Partition -DiskNumber $sysDisk -PartitionNumber $dataPart.PartitionNumber -NewDriveLetter D -EA SilentlyContinue
        } elseif (-not $dataPart.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $sysDisk -PartitionNumber $dataPart.PartitionNumber -AssignDriveLetter -EA SilentlyContinue
        }
        $dataPart = Get-Partition -DiskNumber $sysDisk -PartitionNumber $dataPart.PartitionNumber
    }
    if ($dataPart.DriveLetter) { $dataRoot = "$($dataPart.DriveLetter):"; Log "DATA partition: $dataRoot" }
    else { Log 'DATA partition has no drive letter - logs stay on C:.' }
}

# --- 2. Logs -> DATA via junction ------------------------------------------------------------------
if ($dataRoot) {
    $target = "$dataRoot\AutopilotProbe"
    New-Item $target -ItemType Directory -Force | Out-Null
    $item = Get-Item $ToolOutDir -Force -EA SilentlyContinue
    if ($item -and $item.LinkType -eq 'Junction') {
        Log "Junction already present: $ToolOutDir -> $($item.Target)"
    } else {
        if ($item) {
            Copy-Item "$ToolOutDir\*" $target -Recurse -Force -EA SilentlyContinue
            Remove-Item $ToolOutDir -Recurse -Force -EA SilentlyContinue
        }
        if (Test-Path $ToolOutDir) { Log "Could not remove $ToolOutDir (in use?) - junction NOT created." }
        else { cmd /c mklink /J "$ToolOutDir" "$target" | Out-Null; Log "Junction: $ToolOutDir -> $target" }
    }
}

# --- 3. UWF-friendly tweaks ------------------------------------------------------------------------
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false } }
    Get-CimInstance Win32_PageFileSetting -EA SilentlyContinue | Remove-CimInstance -EA SilentlyContinue
    Log 'Page file disabled (after reboot)'
} catch { Log "Page file: $($_.Exception.Message)" }
powercfg /hibernate off 2>$null | Out-Null
Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -EA SilentlyContinue | Out-Null
foreach ($svc in 'WSearch','SysMain') { Stop-Service $svc -Force -EA SilentlyContinue; Set-Service $svc -StartupType Disabled -EA SilentlyContinue }
Disable-ComputerRestore -Drive "$env:SystemDrive\" -EA SilentlyContinue
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item $au -Force | Out-Null; Set-ItemProperty $au NoAutoUpdate 1 -Type DWord
Log 'Tweaks applied: hibernate off, defrag/WSearch/SysMain/System Restore off, automatic updates off'

# --- 4. UWF ------------------------------------------------------------------------------------------
function Register-Retry {
    $a = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $t = New-ScheduledTaskTrigger -AtStartup
    # AllowStartIfOnBatteries: without it the task does not start on a laptop running on battery
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName $RetryTask -Action $a -Trigger $t -Settings $s -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
    Log "Retry task '$RetryTask' registered: UWF is configured on the next boot."
}

$feat = Get-WindowsOptionalFeature -Online -FeatureName Client-UnifiedWriteFilter -EA SilentlyContinue
if (-not $feat) {
    Log 'UWF feature not available in this Windows edition (needs Enterprise/Education). UWF NOT enabled.'
}
elseif ($feat.State -ne 'Enabled' -or -not (Test-Path $uwfmgr)) {
    Log "UWF feature state: $($feat.State) - enabling it now."
    Enable-WindowsOptionalFeature -Online -FeatureName Client-UnifiedWriteFilter -All -NoRestart -EA SilentlyContinue | Out-Null
    Register-Retry
}
else {
    $ok = $true
    foreach ($args_ in @(
        @('overlay','set-type','RAM'),
        @('overlay','set-size',"$OverlaySizeMB"),
        @('overlay','set-warningthreshold',"$([int]($OverlaySizeMB*0.75))"),
        @('overlay','set-criticalthreshold',"$([int]($OverlaySizeMB*0.9))"),
        @('volume','protect',$env:SystemDrive),
        @('filter','enable'))) {
        $out = & $uwfmgr @args_ 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { $ok = $false; Log "uwfmgr $($args_ -join ' ') FAILED ($LASTEXITCODE): $($out.Trim())" }
        else { Log "uwfmgr $($args_ -join ' '): OK" }
    }
    if ($ok) {
        Unregister-ScheduledTask -TaskName $RetryTask -Confirm:$false -EA SilentlyContinue
        Log 'UWF configured. Protection of C: becomes active after the next reboot.'
        if ($dataRoot) { Set-Content "$dataRoot\AutopilotProbe\uwf-configured.txt" (Get-Date -Format s) }
    } else {
        Log 'UWF configuration incomplete - see errors above. Check with: uwfmgr get-config'
    }
    $cfg = & $uwfmgr get-config 2>&1 | Out-String
    $script:LogLines += $cfg
}

# --- write log -----------------------------------------------------------------------------------------
$logDir = if ($dataRoot) { "$dataRoot\AutopilotProbe" } else { $ToolOutDir }
New-Item $logDir -ItemType Directory -Force | Out-Null
$script:LogLines | Set-Content (Join-Path $logDir "uwf-setup-$(Get-Date -Format yyyyMMdd-HHmmss).log")
