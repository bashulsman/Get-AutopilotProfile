<#
.SYNOPSIS
    Installs the Autopilot check ON the Windows To Go installation and makes it start automatically
    at every logon.

.DESCRIPTION
    Normally runs by itself on first boot: Prepare-WtgStick.ps1 adds it to
    Windows\Setup\Scripts\SetupComplete.cmd (runs as SYSTEM at the end of Windows setup).
    You can also run it by hand (as administrator) on a stick that was already set up.

    It:
      - makes sure the tool is in C:\AutopilotCheck (copies it there if run from elsewhere)
      - registers the logon task 'AutopilotCheck-AtLogon' for the Administrators group (elevated,
        interactive) that runs WindowsToGo\Start-AutopilotCheck.ps1
      - puts an 'Autopilot check' shortcut on the Public desktop (asks for UAC elevation)
      - disables sleep on AC and hibernation
      - removes the 'Install Autopilot check.cmd' helper from the Public desktop

    -AutoLogon (interactive only): Windows signs in automatically with the current account. Prompts
    for the password; it is stored in the registry (Winlogon DefaultPassword) - only on a dedicated
    service stick.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Install-WtgAutopilotCheck.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Install-WtgAutopilotCheck.ps1 -AutoLogon
#>
[CmdletBinding()]
param(
    [string]$Target = "$env:SystemDrive\AutopilotCheck",
    [switch]$AutoLogon
)
$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script as administrator.' }
$isSystem = ($id.User.Value -eq 'S-1-5-18')

New-Item "$env:ProgramData\AutopilotProbe" -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$env:ProgramData\AutopilotProbe\install-$(Get-Date -Format yyyyMMdd-HHmmss).log" -Force | Out-Null

try {
    # --- Make sure the tool is in $Target ------------------------------------------------------
    $src = Split-Path $PSScriptRoot -Parent          # tool root (contains Get-AutopilotProfile.ps1)
    if (-not (Test-Path (Join-Path $src 'Get-AutopilotProfile.ps1'))) { throw "Get-AutopilotProfile.ps1 not found in $src" }
    if ((Resolve-Path $src).Path.TrimEnd('\') -ne [IO.Path]::GetFullPath($Target).TrimEnd('\')) {
        New-Item $Target -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $src '*') $Target -Recurse -Force
        Write-Host "Files copied to $Target"
    }
    Get-ChildItem $Target -Recurse -File | Unblock-File

    $launcher = Join-Path $Target 'WindowsToGo\Start-AutopilotCheck.ps1'
    $psExe    = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $psArgs   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""

    # --- Logon task: any administrator logging on, elevated, in the user's session -------------
    $a = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
    $t = New-ScheduledTaskTrigger -AtLogOn
    $t.Delay = 'PT3S'     # short: the launcher shows its status window right away
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $p = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-544' -RunLevel Highest     # BUILTIN\Administrators (language independent)
    Register-ScheduledTask -TaskName 'AutopilotCheck-AtLogon' -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null
    Write-Host "Logon task 'AutopilotCheck-AtLogon' registered (Administrators group)"

    # --- Public desktop shortcut (elevates via UAC, then runs the launcher) ---------------------
    $pubDesk = [Environment]::GetFolderPath('CommonDesktopDirectory')
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut((Join-Path $pubDesk 'Autopilot check.lnk'))
    $sc.TargetPath   = $psExe
    # inner args without double quotes (they would clash with -Command "..."); $Target has no spaces by default
    $innerArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $launcher"
    $sc.Arguments    = "-NoProfile -WindowStyle Hidden -Command `"Start-Process '$psExe' -Verb RunAs -ArgumentList '$innerArgs'`""
    $sc.IconLocation = "$env:SystemRoot\System32\imageres.dll,109"
    $sc.WindowStyle  = 7
    $sc.Save()
    Remove-Item (Join-Path $pubDesk 'Install Autopilot check.cmd') -Force -EA SilentlyContinue
    Write-Host 'Public desktop shortcut created'

    # --- Power -----------------------------------------------------------------------------------
    powercfg /change standby-timeout-ac 0 | Out-Null
    powercfg /hibernate off 2>$null | Out-Null

    # --- Optional auto logon (interactive only) --------------------------------------------------
    if ($AutoLogon) {
        if ($isSystem) { Write-Warning '-AutoLogon needs an interactive run by the account itself; skipped.' }
        else {
            $user = $id.Name
            $cred = Get-Credential -UserName $user -Message 'Password for automatic logon on this stick'
            $dom, $name = if ($user -match '\\') { $user -split '\\',2 } else { $env:COMPUTERNAME, $user }
            $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-ItemProperty $wl AutoAdminLogon '1'
            Set-ItemProperty $wl DefaultUserName $name
            Set-ItemProperty $wl DefaultDomainName $dom
            Set-ItemProperty $wl DefaultPassword $cred.GetNetworkCredential().Password
            Write-Host 'Auto logon enabled.'
        }
    }
    Write-Host 'Done. The check starts automatically after each logon.'
}
finally { Stop-Transcript | Out-Null }

# --- UWF (only when the stick was prepared with Prepare-WtgStick.ps1 -EnableUwf) ------------------
# Runs after Stop-Transcript: Enable-WtgUwf moves ProgramData\AutopilotProbe to the DATA partition.
$uwfFlag = Join-Path $Target 'WindowsToGo\enable-uwf.flag'
if (Test-Path $uwfFlag) {
    & (Join-Path $Target 'WindowsToGo\Enable-WtgUwf.ps1')
    Remove-Item $uwfFlag -Force -EA SilentlyContinue
}
