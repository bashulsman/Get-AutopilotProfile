<#
.SYNOPSIS
    Runner for Get-AutopilotProfile.ps1: downloads PsExec (Sysinternals) if needed, then runs the
    real script as SYSTEM. By default it shows the GUI.

.DESCRIPTION
    Get-AutopilotProfile.ps1 can self-elevate via a scheduled task, but some environments block that.
    This runner takes the simple, explicit route: it fetches PsExec into its own folder (only if not
    already there) and launches the check interactively as NT AUTHORITY\SYSTEM via `psexec -s -i`.

    Put this next to Get-AutopilotProfile.ps1 and run it (as administrator).

.PARAMETER Args
    Extra arguments passed through to Get-AutopilotProfile.ps1 (default: -Gui).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Run-AutopilotCheck.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Run-AutopilotCheck.ps1 -Args @()   # console output, no GUI
#>
[CmdletBinding()]
param([string[]]$Args = @('-Gui'))

$ErrorActionPreference = 'Stop'
$dir    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script = Join-Path $dir 'Get-AutopilotProfile.ps1'
$psexec = Join-Path $dir 'PsExec64.exe'

if (-not (Test-Path $script)) { throw "Get-AutopilotProfile.ps1 not found next to this runner ($dir)." }

# --- Ensure PsExec is present ---------------------------------------------------------
if (-not (Test-Path $psexec)) {
    Write-Host "PsExec not found - downloading PSTools from Sysinternals..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $env:TEMP 'PSTools.zip'
    $tmp = Join-Path $env:TEMP ('PSTools_' + [Guid]::NewGuid().ToString('N'))
    Invoke-WebRequest -Uri 'https://download.sysinternals.com/files/PSTools.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    foreach ($exe in 'PsExec64.exe','PsExec.exe') {
        $src = Join-Path $tmp $exe
        if (Test-Path $src) { Copy-Item $src (Join-Path $dir $exe) -Force }
    }
    Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $psexec)) { $psexec = Join-Path $dir 'PsExec.exe' }   # fall back to 32-bit
    if (-not (Test-Path $psexec)) { throw 'Could not obtain PsExec.' }
    Write-Host "PsExec ready: $psexec"
}

# --- Run the check as SYSTEM (interactive, so the GUI can show) ------------------------
$psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script`"") + $Args
$allArgs = @('-accepteula','-nobanner','-s','-i','powershell.exe') + $psArgs
Write-Host "Launching as SYSTEM: powershell $($psArgs -join ' ')"
& $psexec @allArgs
Write-Host "Done. Log and result in $env:ProgramData\AutopilotProbe"