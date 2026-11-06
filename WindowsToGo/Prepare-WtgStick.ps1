<#
.SYNOPSIS
    Prepares a Windows To Go stick (made with Rufus) from your own PC: puts the Autopilot check on it
    and makes it install itself on the stick's first boot.

.DESCRIPTION
    Run on your normal PC, as administrator, with the Rufus-made Windows To Go stick plugged in.
    Nothing is formatted - it only adds files to the stick's Windows volume:

      X:\AutopilotCheck\                              the tool (incl. WindowsToGo\)
      X:\Windows\Setup\Scripts\SetupComplete.cmd       runs Install-WtgAutopilotCheck.ps1 as SYSTEM
                                                       at the end of the stick's first Windows setup
      X:\Users\Public\Desktop\Install Autopilot check.cmd
                                                       fallback for a stick that was ALREADY booted
                                                       (SetupComplete then no longer runs): double-click
                                                       once. Removed automatically after install.

    The stick's Windows volume is found automatically: a volume on a USB disk that contains
    \Windows\System32\config\SOFTWARE and is not the running system. Use -DriveLetter when there is
    more than one, or when the volume has no drive letter yet (assign one in Disk Management).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WindowsToGo\Prepare-WtgStick.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WindowsToGo\Prepare-WtgStick.ps1 -DriveLetter E
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z]$')][string]$DriveLetter
)
$ErrorActionPreference = 'Stop'

if (-not (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as administrator.'
}

$toolRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $toolRoot 'Get-AutopilotProfile.ps1'))) { throw "Get-AutopilotProfile.ps1 not found in $toolRoot" }

# --- Find the stick's Windows volume ------------------------------------------------------------
$sysLetter = $env:SystemDrive.TrimEnd(':')
function Test-WindowsVolume($l) { Test-Path "$($l):\Windows\System32\config\SOFTWARE" }

if ($DriveLetter) {
    $DriveLetter = $DriveLetter.ToUpper()
    if ($DriveLetter -eq $sysLetter) { throw "$($DriveLetter): is the running system drive." }
    if (-not (Test-WindowsVolume $DriveLetter)) { throw "$($DriveLetter): does not contain a Windows installation." }
    $disk = Get-Partition -DriveLetter $DriveLetter | Get-Disk
    if ($disk.BusType -ne 'USB') { Write-Warning "$($DriveLetter): is on a $($disk.BusType) disk, not USB ($($disk.FriendlyName))." }
} else {
    $candidates = Get-Disk | Where-Object BusType -eq 'USB' | Get-Partition |
                  Where-Object { $_.DriveLetter -and $_.DriveLetter -ne $sysLetter -and (Test-WindowsVolume $_.DriveLetter) }
    if (-not $candidates) { throw 'No Windows To Go volume found on a USB disk. Plug in the stick, give its Windows partition a drive letter, or use -DriveLetter.' }
    if (@($candidates).Count -gt 1) { throw "More than one candidate: $((@($candidates).DriveLetter | ForEach-Object { "$($_):" }) -join ', '). Use -DriveLetter." }
    $DriveLetter = [string]$candidates.DriveLetter
    $disk = $candidates | Get-Disk
}
$root = "$($DriveLetter):"
Write-Host ("Stick: {0}  ({1}, {2:N0} GB)" -f $root, $disk.FriendlyName, ($disk.Size / 1GB)) -ForegroundColor Cyan

# --- 1. Copy the tool --------------------------------------------------------------------------
$dest = "$root\AutopilotCheck"
if ($PSCmdlet.ShouldProcess($dest, 'Copy Autopilot check')) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }        # always a clean copy
    New-Item "$dest\WindowsToGo" -ItemType Directory -Force | Out-Null
    foreach ($f in 'Get-AutopilotProfile.ps1','Run-AutopilotCheck.ps1','PsExec.exe','PsExec64.exe','Readme.md') {
        $p = Join-Path $toolRoot $f; if (Test-Path $p) { Copy-Item $p $dest -Force }
    }
    Copy-Item (Join-Path $PSScriptRoot '*') "$dest\WindowsToGo" -Recurse -Force
    Get-ChildItem $dest -Recurse -File | Unblock-File
    Write-Host "Copied tool to $dest"
}

$installCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SystemDrive%\AutopilotCheck\WindowsToGo\Install-WtgAutopilotCheck.ps1"'
$tagLine    = 'REM AutopilotCheck-Install'

# --- 2. SetupComplete.cmd (first boot, as SYSTEM) ------------------------------------------------
$scDir  = "$root\Windows\Setup\Scripts"
$scFile = Join-Path $scDir 'SetupComplete.cmd'
if ($PSCmdlet.ShouldProcess($scFile, 'Add install step')) {
    New-Item $scDir -ItemType Directory -Force | Out-Null
    $existing = @(if (Test-Path $scFile) { Get-Content $scFile } else { '@echo off' })   # @() keeps it an array
    if ($existing -notcontains $tagLine) {
        Set-Content $scFile -Value ($existing + @($tagLine, $installCmd)) -Encoding Ascii
        Write-Host "SetupComplete.cmd: install step added"
    } else { Write-Host 'SetupComplete.cmd: install step already present' }
}

# --- 3. Fallback on the Public desktop (already-booted stick) ------------------------------------
$pubDesk = "$root\Users\Public\Desktop"
$helper  = Join-Path $pubDesk 'Install Autopilot check.cmd'
if ((Test-Path "$root\Users\Public") -and $PSCmdlet.ShouldProcess($helper, 'Create install helper')) {
    New-Item $pubDesk -ItemType Directory -Force | Out-Null
    @(
        '@echo off'
        'REM Installs the Autopilot check (asks for administrator rights).'
        'powershell.exe -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList ''-NoProfile -ExecutionPolicy Bypass -File %SystemDrive%\AutopilotCheck\WindowsToGo\Install-WtgAutopilotCheck.ps1''"'
    ) | Set-Content $helper -Encoding Ascii
    Write-Host "Fallback helper: $helper"
}

Write-Host "`nDone. Boot a PC from the stick:" -ForegroundColor Green
Write-Host '  - fresh stick: the check is installed automatically during first setup'
Write-Host "  - stick already set up: double-click 'Install Autopilot check' on the desktop once"
Write-Host 'Safely eject the stick before removing it.'
