<#
.SYNOPSIS
    Launcher used on the Windows To Go stick: shows a status window from the start, waits for
    internet, runs the Autopilot check and keeps showing what it is doing until the result appears.

.DESCRIPTION
    Started at logon by the scheduled task that Install-WtgAutopilotCheck.ps1 creates (elevated), and
    by the 'Autopilot check' desktop shortcut.
    1. Opens a status window straight away (moving progress bar + elapsed time).
    2. Waits until ztd.dds.microsoft.com:443 is reachable. Without network the window says so, offers
       a 'Wi-Fi settings' button and opens the Wi-Fi settings by itself after 15 s.
    3. Runs Get-AutopilotProfile.ps1 -Gui (which relaunches itself as SYSTEM) and shows its current
       step, read live from the check's log (device ticket, building the marker, asking Microsoft).
    4. Closes when the result window of Get-AutopilotProfile.ps1 appears.
#>
[CmdletBinding()]
param(
    [string]$ToolDir,                # default: parent of this script's folder
    [int]$NetworkTimeoutSec = 600,
    [string]$OutDir = "$env:ProgramData\AutopilotProbe",
    [string]$ProbeHost = 'ztd.dds.microsoft.com'
)

# $PSScriptRoot is empty inside param() defaults in Windows PowerShell 5.1 - resolve it here
if (-not $ToolDir) { $ToolDir = Split-Path $PSScriptRoot -Parent }
$script = Join-Path $ToolDir 'Get-AutopilotProfile.ps1'
if (-not (Test-Path $script)) { $script = Join-Path $PSScriptRoot 'Get-AutopilotProfile.ps1' }
$resultFile = Join-Path $OutDir 'result.json'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# --- Window ------------------------------------------------------------------------------------
$form = New-Object Windows.Forms.Form -Property @{
    Text = 'Autopilot profile check'; ClientSize = New-Object Drawing.Size(560, 236); StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; TopMost = $true; BackColor = 'White'
}
$head   = New-Object Windows.Forms.Label -Property @{ Location = New-Object Drawing.Point(20, 18);  Size = New-Object Drawing.Size(520, 34); Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold); Text = 'Starting the Autopilot check...' }
$detail = New-Object Windows.Forms.Label -Property @{ Location = New-Object Drawing.Point(20, 56);  Size = New-Object Drawing.Size(520, 52); Font = New-Object Drawing.Font('Segoe UI', 10); ForeColor = [Drawing.Color]::DimGray }
$bar    = New-Object Windows.Forms.ProgressBar -Property @{ Location = New-Object Drawing.Point(20, 114); Size = New-Object Drawing.Size(520, 18); Style = 'Marquee'; MarqueeAnimationSpeed = 30 }
$clock  = New-Object Windows.Forms.Label -Property @{ Location = New-Object Drawing.Point(20, 138); Size = New-Object Drawing.Size(520, 20); Font = New-Object Drawing.Font('Segoe UI', 9); ForeColor = [Drawing.Color]::Gray }
$btnWifi   = New-Object Windows.Forms.Button -Property @{ Text = 'Wi-Fi settings'; Location = New-Object Drawing.Point(20, 182);  Size = New-Object Drawing.Size(140, 36); Visible = $false }
$btnCancel = New-Object Windows.Forms.Button -Property @{ Text = 'Cancel';         Location = New-Object Drawing.Point(420, 182); Size = New-Object Drawing.Size(120, 36) }
$form.Controls.AddRange(@($head, $detail, $bar, $clock, $btnWifi, $btnCancel))

# All state in one hashtable: event handlers can change its keys without scope issues
$S = @{ Phase = 'net'; Start = Get-Date; PhaseStart = Get-Date; Client = $null; Conn = $null; ConnStart = $null
        Waited = $false; WifiOpened = $false; Child = $null; CheckStart = $null; ExitCode = 2 }

function Set-Status([string]$h, [string]$d) { $head.Text = $h; $detail.Text = $d }

function Get-StepText([string]$line) {
    switch -Regex ($line) {
        'relaunching as SYSTEM'                       { 'Starting the check...'; break }
        'start, user NT AUTHORITY'                    { 'Requesting a device ticket from Windows...'; break }
        'Fresh device ticket|cached ticket'           { 'Checking the Autopilot hardware info...'; break }
        'Marker missing|Clearing stale|DetectHard'    { 'Building the Autopilot hardware info for this PC (up to a minute)...'; break }
        'Ticket present'                              { 'Asking Microsoft Autopilot...'; break }
        '^HTTP|REGISTERED|NOT registered'             { 'Answer received'; break }
        default                                       { 'Running the Autopilot check...' }
    }
}

function Start-Check {
    $S.Phase = 'check'; $S.CheckStart = Get-Date; $S.PhaseStart = $S.CheckStart
    $btnWifi.Visible = $false
    Set-Status 'Running the Autopilot check...' 'Starting'
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script`"", '-Gui', '-OutDir', "`"$OutDir`"")
    $S.Child = Start-Process "$PSHOME\powershell.exe" -ArgumentList $psArgs -WindowStyle Hidden -PassThru
    $null = $S.Child.Handle    # keep the handle so ExitCode is available after the process ends
}

$btnWifi.Add_Click({ Start-Process 'ms-settings:network-wifi' })
$btnCancel.Add_Click({ $S.Phase = 'cancel'; $form.Close() })

# --- State machine, ticks every 500 ms (never blocks the window) ---------------------------------
$timer = New-Object Windows.Forms.Timer -Property @{ Interval = 500 }
$timer.Add_Tick({
    $now = Get-Date
    $clock.Text = 'Busy for {0:mm\:ss}' -f ($now - $S.Start)
    switch ($S.Phase) {
        'net' {
            if (-not $S.Conn) {
                $S.Client = New-Object Net.Sockets.TcpClient
                $S.Conn = $S.Client.ConnectAsync($ProbeHost, 443); $S.ConnStart = $now
                if (-not $S.Waited) { Set-Status 'Checking the internet connection...' "Connecting to $ProbeHost" }
                return
            }
            if (-not $S.Conn.IsCompleted -and ($now - $S.ConnStart).TotalSeconds -lt 3) { return }
            $ok = $S.Conn.IsCompleted -and -not $S.Conn.IsFaulted -and $S.Client.Connected
            $S.Client.Dispose(); $S.Conn = $null
            if ($ok) {
                if ($S.Waited) {   # just came online: give wlidsvc a moment to refresh the device ticket
                    $S.Phase = 'settle'; $S.PhaseStart = $now
                    Set-Status 'Internet connected' 'Giving Windows a few seconds to refresh its device identity...'
                } else { Start-Check }
                return
            }
            if (-not $S.Waited) { $S.Waited = $true; $S.PhaseStart = $now }
            $btnWifi.Visible = $true
            $waited = ($now - $S.PhaseStart).TotalSeconds
            Set-Status 'Waiting for internet...' "No connection to $ProbeHost yet. Plug in a network cable or pick a Wi-Fi network; the check starts by itself."
            if (-not $S.WifiOpened -and $waited -ge 15) { Start-Process 'ms-settings:network-wifi'; $S.WifiOpened = $true }
            if ($waited -ge $NetworkTimeoutSec) { $S.Phase = 'nonet'; $form.Close() }
        }
        'settle' { if (($now - $S.PhaseStart).TotalSeconds -ge 5) { Start-Check } }
        'check' {
            $log = Get-ChildItem $OutDir -Filter 'autopilot-*.log' -EA SilentlyContinue |
                   Where-Object { $_.LastWriteTime -ge $S.CheckStart.AddSeconds(-2) } | Sort-Object LastWriteTime | Select-Object -Last 1
            if ($log) {
                $line = (Get-Content $log.FullName -Tail 1 -EA SilentlyContinue) -replace '^\[[\d:]+\]\s*', ''
                if ($line) { Set-Status (Get-StepText $line) $line }
            }
            $res = Get-Item $resultFile -EA SilentlyContinue
            if (($res -and $res.LastWriteTime -ge $S.CheckStart) -or $S.Child.HasExited) {
                $S.Phase = 'done'; $timer.Stop(); $form.Close()    # the result window takes over
            }
        }
    }
})
$form.Add_Shown({ $form.Activate(); $timer.Start() })
[void]$form.ShowDialog()
$timer.Stop(); $form.Dispose()

switch ($S.Phase) {
    'done'   { $S.Child.WaitForExit(); exit $S.Child.ExitCode }
    'nonet'  {
        [Windows.Forms.MessageBox]::Show("No connection to $ProbeHost.`r`nConnect to the internet and run 'Autopilot check' from the desktop.", 'Autopilot profile check') | Out-Null
        exit 2
    }
    default  {   # cancelled or window closed
        if ($S.Child -and -not $S.Child.HasExited) { $S.Child.Kill() }
        exit 2
    }
}
