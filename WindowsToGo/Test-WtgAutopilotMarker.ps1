<#
.SYNOPSIS
    Run ON the stick, as administrator, when Get-AutopilotProfile.ps1 reports "No Autopilot marker".
    Shows why HardwareInfo\AutopilotMarker is missing and tries to let Windows create it.

.DESCRIPTION
    Windows (Autopilot.dll) writes HKLM\SOFTWARE\Microsoft\Provisioning\HardwareInfo, including the
    AutopilotMarker, from the scheduled task \Microsoft\Windows\Management\Autopilot\DetectHardwareChange.
    On a normal PC that runs after OOBE; on a Rufus stick OOBE had no internet, so the task stays
    disabled and never runs. The script enables and starts it (as SYSTEM).

    The script:
      1. collects the state: PC/serial, Windows To Go flag, internet to ztd.dds.microsoft.com,
         HardwareInfo, AutopilotPolicyCache, the Autopilot tasks and their last result
      2. starts DetectHardwareChange and waits up to -WaitSec for the marker to appear
      3. shows the Autopilot event log (Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot)
    and saves everything to D:\AutopilotProbe (UWF data partition) or C:\ProgramData\AutopilotProbe.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Test-WtgAutopilotMarker.ps1
#>
[CmdletBinding()]
param(
    [int]$WaitSec = 90,
    [switch]$NoTrigger               # only collect, do not start the task
)

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'Run this from an elevated PowerShell (Run as administrator).' -ForegroundColor Red; exit 1 }

$hwKey    = 'HKLM:\SOFTWARE\Microsoft\Provisioning\HardwareInfo'
$taskPath = '\Microsoft\Windows\Management\Autopilot\'
$logName  = 'Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot'
$lines    = New-Object Collections.Generic.List[string]
function Out-Section([string]$title, $obj) {
    $lines.Add(''); $lines.Add("=== $title")
    if ($null -eq $obj -or "$obj" -eq '') { $lines.Add('(none)') }
    elseif ($obj -is [string]) { $lines.Add($obj) }
    else { $lines.Add(($obj | Format-List | Out-String -Width 250).Trim()) }
}
function Get-HwInfo { Get-ItemProperty $hwKey -EA SilentlyContinue | Select-Object * -ExcludeProperty PS* }
function Get-Events($since, [int]$max) {
    $f = @{ LogName = $logName }; if ($since) { $f.StartTime = $since }
    Get-WinEvent -FilterHashtable $f -MaxEvents $max -EA SilentlyContinue | Sort-Object TimeCreated | ForEach-Object {
        $m = ($_.Message -replace '\s+', ' ').Trim(); if ($m.Length -gt 230) { $m = $m.Substring(0, 230) + '...' }
        '{0:yyyy-MM-dd HH:mm:ss}  {1,4}  {2}' -f $_.TimeCreated, $_.Id, $m
    }
}
function Test-Ztd {
    try { $c = New-Object Net.Sockets.TcpClient; $ok = $c.ConnectAsync('ztd.dds.microsoft.com', 443).Wait(3000) -and $c.Connected; $c.Dispose(); $ok } catch { $false }
}
function Get-Tasks {
    Get-ScheduledTask -TaskPath $taskPath -EA SilentlyContinue | ForEach-Object {
        $i = $_ | Get-ScheduledTaskInfo
        [pscustomobject]@{ Task = $_.TaskName; State = $_.State; LastRun = $i.LastRunTime; LastResult = ('0x{0:X8}' -f $i.LastTaskResult) }
    }
}

# --- 1. State before ----------------------------------------------------------------------
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$wtg  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PortableOperatingSystem -EA SilentlyContinue).PortableOperatingSystem
Out-Section 'PC' ([pscustomobject]@{
    Model = "$($cs.Manufacturer) $($cs.Model)"; Serial = $bios.SerialNumber; WindowsToGo = [bool]$wtg
    OS = (Get-CimInstance Win32_OperatingSystem).Caption; Internet_ztd = Test-Ztd
})
Out-Section 'HardwareInfo (before)' (Get-HwInfo)
$pc = Get-Item 'HKLM:\SOFTWARE\Microsoft\Provisioning\AutopilotPolicyCache' -EA SilentlyContinue
Out-Section 'AutopilotPolicyCache value names' ($(if ($pc) { ($pc.GetValueNames() -join ', ') }))
if ($pc) {
    $txt = @(foreach ($n in $pc.GetValueNames() | Where-Object { $_ -ne 'PolicyJsonCache' }) { '{0} = {1}' -f $n, $pc.GetValue($n) })
    $json = $pc.GetValue('PolicyJsonCache')
    if ($json) {
        try {
            $j = $json | ConvertFrom-Json
            $txt += $j.PSObject.Properties | ForEach-Object { $v = "$($_.Value)"; if ($v.Length -gt 100) { $v = $v.Substring(0, 100) + '...' }; 'PolicyJsonCache.{0} = {1}' -f $_.Name, $v }
        } catch { $txt += "PolicyJsonCache (not JSON, $($json.Length) chars): $("$json".Substring(0, [Math]::Min(300, "$json".Length)))" }
    }
    Out-Section 'AutopilotPolicyCache content' ($txt -join "`r`n")
}
$ws = "$env:windir\ServiceState\wmansvc"
Out-Section "Files in $ws" ($(if (Test-Path $ws) { (Get-ChildItem $ws | ForEach-Object { '{0}  {1} bytes  {2}' -f $_.Name, $_.Length, $_.LastWriteTime }) -join "`r`n" }))
Out-Section 'Autopilot tasks (before)' ((Get-Tasks | Format-Table -AutoSize | Out-String).Trim())
Out-Section 'Autopilot event log (last 25 before this run)' ((Get-Events $null 25) -join "`r`n")

# --- 2. Trigger ---------------------------------------------------------------------------
$start = Get-Date
if (-not $NoTrigger) {
    if (-not (Test-Ztd)) { $lines.Add(''); $lines.Add('WARNING: ztd.dds.microsoft.com:443 not reachable - the task needs internet.') }
    $lines.Add(''); $lines.Add("=== Starting $taskPath`DetectHardwareChange, waiting up to $WaitSec s for the marker")
    Write-Host "Starting DetectHardwareChange, waiting up to $WaitSec s..."
    # On a Rufus stick the task is disabled (OOBE never downloaded a profile). Enable + start it:
    # first as this admin, and if the task is still disabled, as SYSTEM through a one-shot helper task.
    $tn = 'DetectHardwareChange'
    try { Enable-ScheduledTask -TaskPath $taskPath -TaskName $tn -EA Stop | Out-Null; $lines.Add('Enabled as admin.') }
    catch { $lines.Add("Enable as admin failed: $($_.Exception.Message)") }

    if ((Get-ScheduledTask -TaskPath $taskPath -TaskName $tn -EA SilentlyContinue).State -eq 'Disabled') {
        $helper = 'AutopilotCheck-EnableDetectHw'
        $outTxt = "$env:windir\Temp\$helper.txt"
        $cmd = "(schtasks /Change /TN `"$taskPath$tn`" /ENABLE & schtasks /Run /TN `"$taskPath$tn`")"
        try {
            $act = New-ScheduledTaskAction -Execute "$env:windir\System32\cmd.exe" -Argument "/c $cmd > `"$outTxt`" 2>&1"
            # AllowStartIfOnBatteries: without it the helper silently never starts on a laptop on battery
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
            Register-ScheduledTask -TaskName $helper -Action $act -Settings $set -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force -EA Stop | Out-Null
            Start-ScheduledTask -TaskName $helper -EA Stop
            Start-Sleep 2
            for ($i = 0; $i -lt 20 -and (Get-ScheduledTask -TaskName $helper).State -eq 'Running'; $i++) { Start-Sleep 1 }
            $hr = '0x{0:X8}' -f (Get-ScheduledTaskInfo -TaskName $helper).LastTaskResult
            $lines.Add("Enable + run as SYSTEM (helper result $hr): " + ((Get-Content $outTxt -EA SilentlyContinue) -join ' / '))
        } catch { $lines.Add("Enable as SYSTEM failed: $($_.Exception.Message)") }
        finally {
            Unregister-ScheduledTask -TaskName $helper -Confirm:$false -EA SilentlyContinue
            Remove-Item $outTxt -Force -EA SilentlyContinue
        }
    } else {
        try { Start-ScheduledTask -TaskPath $taskPath -TaskName $tn -EA Stop; $lines.Add('Started.') }
        catch { $lines.Add("Start failed: $($_.Exception.Message)") }
    }
    $lines.Add("Task state now: $((Get-ScheduledTask -TaskPath $taskPath -TaskName $tn -EA SilentlyContinue).State)")
    $deadline = $start.AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 3
        $busy = @(Get-ScheduledTask -TaskPath $taskPath -EA SilentlyContinue | Where-Object State -eq 'Running').Count
        if ((Get-HwInfo).AutopilotMarker -and -not $busy) { break }
    }
    $lines.Add(('Waited {0:N0} s' -f ((Get-Date) - $start).TotalSeconds))
}

# --- 3. State after -----------------------------------------------------------------------
$hw = Get-HwInfo
Out-Section 'HardwareInfo (after)' $hw
Out-Section 'Autopilot tasks (after)' ((Get-Tasks | Format-Table -AutoSize | Out-String).Trim())
Out-Section 'Autopilot event log (this run)' ((Get-Events $start.AddSeconds(-2) 100) -join "`r`n")

$lines.Add('')
if ($hw.AutopilotMarker) {
    $lines.Add("RESULT: marker present ($($hw.AutopilotMarker)). Run the Autopilot check again.")
} else {
    $lines.Add('RESULT: still no AutopilotMarker. Send this file to whoever maintains the tool.')
}
if ($hw.SerialNumber -and $bios.SerialNumber -and $hw.SerialNumber.Trim() -ne $bios.SerialNumber.Trim()) {
    $lines.Add("NOTE: HardwareInfo serial $($hw.SerialNumber) is not this PC ($($bios.SerialNumber)) - stale data, see Reset-AutopilotProbeState.ps1.")
}

$report = $lines -join "`r`n"
Write-Host $report
$logDir = if (Test-Path 'D:\AutopilotProbe') { 'D:\AutopilotProbe' } else { "$env:ProgramData\AutopilotProbe" }
New-Item $logDir -ItemType Directory -Force | Out-Null
$out = Join-Path $logDir "marker-diag-$($env:COMPUTERNAME)-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
Set-Content $out $report
Write-Host "`nSaved to $out" -ForegroundColor Cyan
