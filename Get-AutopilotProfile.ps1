<#
.SYNOPSIS
    Checks online whether this device is registered in Windows Autopilot, the way Windows does in OOBE.
    Minimal working recipe: X-Device-Token (JWT) + X-Autopilot-Marker. Run on a fully running Windows.

.DESCRIPTION
    GET ztd.dds.microsoft.com/ztd/device/autopilotdevicebootstrappolicies with
      - X-Device-Token:     the JWT from HKU\S-1-5-18\...\IdentityCRL\...\Token\{8A6E5826-...}
      - X-Autopilot-Marker: HKLM\SOFTWARE\Microsoft\Provisioning\HardwareInfo\AutopilotMarker
    The hardware hash is NOT required.

    The check needs SYSTEM (the device ticket lives in the SYSTEM profile hive). If you start the
    script as a normal admin it relaunches itself as SYSTEM via a one-shot scheduled task, so both
    -Gui and plain console use work without psexec.

    Modes:
      (default)   Run the check and print the result object.
      -Gui        Run the check and show the result in a window.
      -DoCheck    Internal: used by the SYSTEM relaunch to run the check and write result.json.

    Returns a PSCustomObject and sets DeployR task sequence variables (AutopilotStatus /
    AutopilotTenant / AutopilotProfile) when the DeployR.Utility module is present.
    Exit codes: 0 = registered, 1 = not registered, 2 = unknown.

.NOTES
    Unsupported, undocumented flow. Works only on a running, provisioned Windows (not WinPE/OOBE),
    and only while a valid (unexpired) device ticket is cached. See README.md.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Get-AutopilotProfile.ps1 -Gui
.EXAMPLE
    psexec -s powershell -ExecutionPolicy Bypass -File .\Get-AutopilotProfile.ps1
#>
[CmdletBinding()]
param(
    [switch]$Gui,
    [switch]$DoCheck,
    [string]$Url    = 'https://ztd.dds.microsoft.com/ztd/device/autopilotdevicebootstrappolicies',
    [string]$OutDir = "$env:ProgramData\AutopilotProbe"
)

$ErrorActionPreference = 'Continue'
New-Item $OutDir -ItemType Directory -Force | Out-Null
$RunTag     = (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID"
$log        = Join-Path $OutDir "autopilot-$RunTag.log"
$ResultFile = Join-Path $OutDir 'result.json'
Set-Content $log "[$(Get-Date -Format HH:mm:ss)] start, user $([Security.Principal.WindowsIdentity]::GetCurrent().Name), gui=$Gui docheck=$DoCheck"
function Log($m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $line; Add-Content -Path $log -Value $line }

# =====================================================================================
#  The actual check (requires SYSTEM). Returns a PSCustomObject.
# =====================================================================================
function Invoke-Check {
    $r = [pscustomobject]@{
        Status='Unknown'; TenantDomain=$null; TenantId=$null; ProfileName=$null
        SerialNumber=(Get-CimInstance Win32_BIOS -EA SilentlyContinue).SerialNumber; Detail=''; ExitCode=2
    }
    try {
        Add-Type -AssemblyName System.Security
        Add-Type -AssemblyName System.Net.Http
        if (-not (Get-PSDrive HKU -EA SilentlyContinue)) { New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null }

        # ticket (JWT): try every token key and both DPAPI scopes/skips
        function Get-Jwt([byte[]]$blob) {
            foreach ($scope in 'CurrentUser','LocalMachine') { foreach ($skip in 4,0) {
                try { $p = [Security.Cryptography.ProtectedData]::Unprotect([byte[]]$blob[$skip..($blob.Length-1)],$null,$scope) } catch { continue }
                $runs=@(); $c=New-Object Text.StringBuilder
                for ($i=0;$i+1 -lt $p.Length;$i+=2){ if($p[$i] -ge 32 -and $p[$i] -lt 127 -and $p[$i+1] -eq 0){[void]$c.Append([char]$p[$i])} else { if($c.Length -ge 20){$runs+=$c.ToString()}; $c.Clear()|Out-Null } }
                if($c.Length -ge 20){$runs+=$c.ToString()}
                $j=$runs | Where-Object { $_ -like 'eyJ*' } | Sort-Object Length -Descending | Select-Object -First 1
                if($j){return $j}
            } }
            return $null
        }
        $base='HKU:\S-1-5-18\SOFTWARE\Microsoft\IdentityCRL\Immersive\production\Token'
        $dds="$base\{8A6E5826-EA01-989D-989D-158EE04D1518}"
        $ticket=$null
        $keys=@(); if(Test-Path $dds){$keys+=Get-Item $dds}
        if(Test-Path $base){$keys+=Get-ChildItem $base -EA SilentlyContinue | Where-Object { $_.PSChildName -ne '{8A6E5826-EA01-989D-989D-158EE04D1518}' }}
        foreach($k in $keys){ $pp=Get-ItemProperty $k.PSPath -EA SilentlyContinue; if($pp.DeviceTicket){ $ticket=Get-Jwt ([byte[]]$pp.DeviceTicket); if($ticket){break} } }

        $marker=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Provisioning\HardwareInfo' -EA SilentlyContinue).AutopilotMarker
        Log ("Ticket present: {0}  Marker: {1}" -f [bool]$ticket, $marker)

        if (-not $ticket) { $r.Detail='No device ticket. Run as SYSTEM on a running Windows (not WinPE/OOBE), with network.'; Log $r.Detail; return $r }
        if (-not $marker) { $r.Detail='No Autopilot marker (HardwareInfo\AutopilotMarker). Device may never have been Autopilot-provisioned.'; Log $r.Detail; return $r }

        $client=New-Object Net.Http.HttpClient; $client.Timeout=[TimeSpan]::FromSeconds(30)
        $req=New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get,$Url)
        [void]$req.Headers.TryAddWithoutValidation('X-Device-Token',$ticket)
        [void]$req.Headers.TryAddWithoutValidation('X-Autopilot-Marker',$marker)
        [void]$req.Headers.TryAddWithoutValidation('MS-CV',([Convert]::ToBase64String([Guid]::NewGuid().ToByteArray()).Substring(0,16)+'.0'))
        [void]$req.Headers.TryAddWithoutValidation('User-Agent','Dsreg/10.0 (Windows NT 10.0)')
        $resp=$client.SendAsync($req).GetAwaiter().GetResult()
        $body=$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $client.Dispose()
        Set-Content (Join-Path $OutDir "autopilot-$RunTag-response.json") $body
        Log "HTTP $([int]$resp.StatusCode)"

        if ($body -match '"CloudAssignedTenantDomain"\s*:\s*"([^"]+)"') {
            $j=$null; try{$j=$body|ConvertFrom-Json}catch{}
            $r.Status='Registered'; $r.TenantDomain=$Matches[1]; $r.TenantId=$j.CloudAssignedTenantId; $r.ProfileName=$j.DeploymentProfileName; $r.ExitCode=0
            Log "REGISTERED. Tenant: $($r.TenantDomain)  Profile: $($r.ProfileName)"
        }
        elseif ($body -match 'ZtdDeviceIsNotRegistered|\b807\b') {
            $r.Status='NotRegistered'; $r.ExitCode=1; Log 'NOT registered in Autopilot (807).'
        }
        elseif ([int]$resp.StatusCode -eq 401) {
            $r.Detail='Device ticket present but rejected (HTTP 401) - it has most likely expired. Reboot (or sign out/in) to refresh it, then retry.'
            Log $r.Detail
        }
        else { $r.Detail="Unexpected response (HTTP $([int]$resp.StatusCode))."; Log "$($r.Detail) $body" }
    }
    catch { $r.Detail=$_.Exception.Message; Log "Error: $($r.Detail)" }
    return $r
}

function Publish-TsVars($r) {
    try {
        Import-Module "$env:ProgramFiles\2Pint Software\DeployR\Client\PSModules\DeployR.Utility" -ErrorAction Stop
        Set-Item TSEnv:AutopilotStatus  -Value $r.Status               -EA SilentlyContinue
        Set-Item TSEnv:AutopilotTenant  -Value "$($r.TenantDomain)"    -EA SilentlyContinue
        Set-Item TSEnv:AutopilotProfile -Value "$($r.ProfileName)"     -EA SilentlyContinue
    } catch {}
}

function Show-ResultGui($result) {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    switch ($result.Status) {
        'Registered'    { $col=[Drawing.Color]::FromArgb(22,101,52);  $head='Registered in Autopilot' }
        'NotRegistered' { $col=[Drawing.Color]::FromArgb(154,52,18);  $head='Not registered' }
        default         { $col=[Drawing.Color]::FromArgb(75,75,75);   $head='Unknown' }
    }
    $f = New-Object Windows.Forms.Form -Property @{ Text='Autopilot profile check'; Width=600; Height=420; StartPosition='CenterScreen'; FormBorderStyle='FixedDialog'; MaximizeBox=$false; MinimizeBox=$false; BackColor='White'; TopMost=$true }
    $banner = New-Object Windows.Forms.Panel -Property @{ Dock='Top'; Height=90; BackColor=$col }
    $lblH   = New-Object Windows.Forms.Label -Property @{ Dock='Fill'; Text=$head; ForeColor='White'; Font=New-Object Drawing.Font('Segoe UI',22,[Drawing.FontStyle]::Bold); TextAlign='MiddleCenter' }
    $banner.Controls.Add($lblH)

    $body = "Serial:  $($result.SerialNumber)`r`n`r`n"
    if     ($result.Status -eq 'Registered')    { $body += "Tenant:    $($result.TenantDomain)`r`nProfile:   $($result.ProfileName)`r`nTenant ID: $($result.TenantId)" }
    elseif ($result.Status -eq 'NotRegistered') { $body += "This device is not in any Autopilot tenant." }
    else                                        { $body += "$($result.Detail)" }
    $lblB = New-Object Windows.Forms.Label -Property @{ Dock='Fill'; Text=$body; Font=New-Object Drawing.Font('Segoe UI',13); Padding='24,24,24,0'; TextAlign='TopLeft' }

    $pnl  = New-Object Windows.Forms.Panel -Property @{ Dock='Bottom'; Height=70; BackColor='White' }
    $copy = New-Object Windows.Forms.Button -Property @{ Text='Copy'; Width=120; Height=38; Left=24;  Top=16; Font=New-Object Drawing.Font('Segoe UI',11) }
    $ok   = New-Object Windows.Forms.Button -Property @{ Text='Close'; Width=120; Height=38; Left=440; Top=16; Font=New-Object Drawing.Font('Segoe UI',11); DialogResult='OK' }
    $copy.Add_Click({ Set-Clipboard (($result | Format-List | Out-String).Trim()) })
    $ok.Add_Click({ $f.Close() })
    $pnl.Controls.AddRange(@($copy,$ok))

    $f.Controls.AddRange(@($lblB,$banner,$pnl))
    $f.AcceptButton = $ok
    [void]$f.ShowDialog()
}

$isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')

# =====================================================================================
#  SYSTEM branch: run the check, write result, output/print (and GUI for a direct run)
# =====================================================================================
if ($isSystem -or $DoCheck) {
    $result = Invoke-Check
    $result | ConvertTo-Json | Set-Content $ResultFile
    Publish-TsVars $result
    if (-not $DoCheck) {                 # direct SYSTEM run (e.g. via the psexec runner)
        if ($Gui) { Show-ResultGui $result } else { $result }
    }
    exit $result.ExitCode
}

# =====================================================================================
#  Non-SYSTEM branch: relaunch as SYSTEM via a one-shot scheduled task, then show result
# =====================================================================================
Log 'Not SYSTEM - relaunching as SYSTEM via scheduled task...'
Remove-Item $ResultFile -ErrorAction SilentlyContinue
$task = "AutopilotProfileCheck-$RunTag"
$ps   = Join-Path $PSHOME 'powershell.exe'
$arg  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -DoCheck -OutDir `"$OutDir`""
try {
    $a = New-ScheduledTaskAction -Execute $ps -Argument $arg
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    Register-ScheduledTask -TaskName $task -Action $a -Settings $s -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName $task
} catch { Log "Task error: $($_.Exception.Message)" }

$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline -and -not (Test-Path $ResultFile)) { Start-Sleep 2 }
Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue

$result = if (Test-Path $ResultFile) { Get-Content $ResultFile -Raw | ConvertFrom-Json }
          else { [pscustomobject]@{ Status='Unknown'; TenantDomain=$null; TenantId=$null; ProfileName=$null; SerialNumber=$env:COMPUTERNAME; Detail='No result from the SYSTEM check (see log).'; ExitCode=2 } }

# --- GUI or console --------------------------------------------------------------------
if ($Gui) { Show-ResultGui $result } else { $result }
exit $result.ExitCode