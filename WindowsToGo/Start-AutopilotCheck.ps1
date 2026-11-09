<#
.SYNOPSIS
    Launcher used on the Windows To Go stick: waits for internet, then runs the Autopilot check (GUI).

.DESCRIPTION
    Started at logon by the scheduled task that Install-WtgAutopilotCheck.ps1 creates (elevated).
    1. Waits until ztd.dds.microsoft.com:443 is reachable. If there is no network it opens the
       Wi-Fi settings once so you can connect, and keeps waiting.
    2. Runs Get-AutopilotProfile.ps1 -Gui (which relaunches itself as SYSTEM).
#>
[CmdletBinding()]
param(
    [string]$ToolDir,                # default: parent of this script's folder
    [int]$NetworkTimeoutSec = 600
)

# $PSScriptRoot is empty inside param() defaults in Windows PowerShell 5.1 - resolve it here
if (-not $ToolDir) { $ToolDir = Split-Path $PSScriptRoot -Parent }
$script = Join-Path $ToolDir 'Get-AutopilotProfile.ps1'
if (-not (Test-Path $script)) { $script = Join-Path $PSScriptRoot 'Get-AutopilotProfile.ps1' }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Test-Ztd {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $c.ConnectAsync('ztd.dds.microsoft.com', 443).Wait(3000) -and $c.Connected
        $c.Dispose(); return $ok
    } catch { return $false }
}

# --- Wait for network (small status window) ----------------------------------------------
if (-not (Test-Ztd)) {
    $f   = New-Object Windows.Forms.Form -Property @{ Text='Autopilot profile check'; Width=520; Height=200; StartPosition='CenterScreen'; FormBorderStyle='FixedDialog'; MaximizeBox=$false; MinimizeBox=$false; TopMost=$true; BackColor='White' }
    $lbl = New-Object Windows.Forms.Label -Property @{ Dock='Fill'; Font=New-Object Drawing.Font('Segoe UI',12); TextAlign='MiddleCenter'; Text="Waiting for internet (ztd.dds.microsoft.com)...`r`nConnect a network cable or Wi-Fi." }
    $btn = New-Object Windows.Forms.Button -Property @{ Text='Cancel'; Dock='Bottom'; Height=36 }
    $btn.Add_Click({ $f.Tag = 'cancel'; $f.Close() })
    $f.Controls.AddRange(@($lbl,$btn))
    $f.Show(); [Windows.Forms.Application]::DoEvents()

    $deadline   = (Get-Date).AddSeconds($NetworkTimeoutSec)
    $openedWifi = $false
    while ((Get-Date) -lt $deadline -and $f.Tag -ne 'cancel' -and $f.Visible) {
        if (Test-Ztd) { break }
        if (-not $openedWifi -and (Get-Date) -gt $deadline.AddSeconds(-$NetworkTimeoutSec + 15)) {
            Start-Process 'ms-settings:network-wifi'; $openedWifi = $true
        }
        for ($i=0; $i -lt 20; $i++) { Start-Sleep -Milliseconds 100; [Windows.Forms.Application]::DoEvents() }
    }
    $cancelled = ($f.Tag -eq 'cancel')
    $f.Close(); $f.Dispose()
    if ($cancelled) { exit 2 }
    if (-not (Test-Ztd)) {
        [Windows.Forms.MessageBox]::Show("No connection to ztd.dds.microsoft.com.`r`nConnect to the internet and run 'Autopilot check' from the desktop.",'Autopilot profile check') | Out-Null
        exit 2
    }
    Start-Sleep 5   # give wlidsvc a moment to refresh the device ticket once online
}

# --- Run the check --------------------------------------------------------------------------
& "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $script -Gui
exit $LASTEXITCODE
