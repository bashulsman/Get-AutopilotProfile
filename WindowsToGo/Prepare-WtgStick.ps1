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

    Drivers: every .inf under WindowsToGo\Drivers (or -DriverPath) is injected into the stick's
    Windows with DISM /Add-Driver /Recurse. Fill that folder with Get-WtgDriverPack.ps1 (HP/Dell
    driver packs) or by dropping extracted drivers in it. Works on a stick that was already booted
    too. -SkipDrivers skips this step.

    -DataPartitionGB <n>: shrinks the stick's Windows partition by n GB and creates an NTFS partition
    labelled 'DATA' in that space (skipped if a DATA partition already exists on the stick).

    -EnableUwf: makes the stick a read-only (UWF) stick:
      - upgrades the offline image to Enterprise with DISM /Set-Edition if it is not Enterprise/
        Education yet (UWF does not exist in Pro; Enterprise stays unactivated without KMS/MAK/E3)
      - enables the Client-UnifiedWriteFilter feature in the offline image
      - leaves a flag so that Install-WtgAutopilotCheck.ps1 runs Enable-WtgUwf.ps1 on first boot
        (DATA -> D:, logs to D:, UWF tweaks, protect C:). Protection is active from the 2nd boot on.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WindowsToGo\Prepare-WtgStick.ps1 -DriveLetter E
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\WindowsToGo\Prepare-WtgStick.ps1 -DriveLetter E -DataPartitionGB 100 -EnableUwf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z]$')][string]$DriveLetter,
    [ValidateRange(0,2048)][int]$DataPartitionGB = 0,
    [switch]$EnableUwf,
    [string]$DriverPath,             # default: <this script's folder>\Drivers; every .inf below it is injected
    [switch]$SkipDrivers
)
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside param() defaults in Windows PowerShell 5.1 - resolve it here
if (-not $DriverPath) { $DriverPath = Join-Path $PSScriptRoot 'Drivers' }

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
Write-Host ("Stick: {0}  (disk {1}, {2}, {3:N0} GB)" -f $root, $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB)) -ForegroundColor Cyan

# --- 0a. DATA partition ----------------------------------------------------------------------------
if ($DataPartitionGB -gt 0) {
    $existingData = Get-Partition -DiskNumber $disk.Number | Where-Object { ($_ | Get-Volume -EA SilentlyContinue).FileSystemLabel -eq 'DATA' }
    if ($existingData) {
        Write-Host 'DATA partition already present - not changed.'
    } else {
        $winPart = Get-Partition -DriveLetter $DriveLetter
        $newSize = $winPart.Size - ([uint64]$DataPartitionGB * 1GB)
        $sup     = Get-PartitionSupportedSize -DriveLetter $DriveLetter
        if ($newSize -lt $sup.SizeMin) {
            throw ("Cannot free {0} GB: the Windows partition can shrink to at least {1:N1} GB." -f $DataPartitionGB, ($sup.SizeMin / 1GB))
        }
        if ($PSCmdlet.ShouldProcess("$root (disk $($disk.Number))", "Shrink by $DataPartitionGB GB and create DATA partition")) {
            Resize-Partition -DriveLetter $DriveLetter -Size $newSize
            New-Partition -DiskNumber $disk.Number -UseMaximumSize |
                Format-Volume -FileSystem NTFS -NewFileSystemLabel DATA -Confirm:$false | Out-Null
            Write-Host ("DATA partition created ({0} GB); Windows partition now {1:N1} GB" -f $DataPartitionGB, ($newSize / 1GB))
        }
    }
}

# --- 0b. UWF: Enterprise edition + feature in the offline image ------------------------------------
if ($EnableUwf) {
    $dism = "$env:SystemRoot\System32\dism.exe"
    $img  = "/Image:$root\"
    $cur  = & $dism /English $img /Get-CurrentEdition | Out-String
    $edition = if ($cur -match 'Current Edition\s*:\s*(\S+)') { $Matches[1] } else { throw "Could not read the edition of the image on $root.`n$cur" }
    Write-Host "Current edition: $edition"
    if ($edition -notin 'Enterprise','Education','IoTEnterprise','EnterpriseS','IoTEnterpriseS') {
        $targets = & $dism /English $img /Get-TargetEditions | Out-String
        if ($targets -notmatch 'Target Edition\s*:\s*Enterprise\b') { throw "Edition $edition cannot be upgraded offline to Enterprise.`n$targets" }
        if ($PSCmdlet.ShouldProcess($root, 'DISM /Set-Edition:Enterprise (takes a few minutes)')) {
            Write-Host 'Upgrading offline image to Enterprise (this takes a few minutes)...'
            & $dism /English $img /Set-Edition:Enterprise
            if ($LASTEXITCODE -notin 0,3010) { throw "DISM /Set-Edition failed ($LASTEXITCODE)." }
        }
    }
    $fi = & $dism /English $img /Get-FeatureInfo /FeatureName:Client-UnifiedWriteFilter | Out-String
    if ($fi -match 'State\s*:\s*Enabled') { Write-Host 'UWF feature already enabled in the image.' }
    elseif ($PSCmdlet.ShouldProcess($root, 'DISM /Enable-Feature Client-UnifiedWriteFilter')) {
        & $dism /English $img /Enable-Feature /FeatureName:Client-UnifiedWriteFilter /All
        if ($LASTEXITCODE -notin 0,3010) { throw "DISM /Enable-Feature failed ($LASTEXITCODE)." }
        Write-Host 'UWF feature enabled in the image.'
    }
}

# --- 0c. Drivers: inject into the offline image -----------------------------------------------------
# Works on a fresh stick AND on one that was booted before (also with UWF on: offline writes go to
# the disk itself). Windows installs them for the matching hardware at the next boot.
if (-not $SkipDrivers -and (Test-Path $DriverPath)) {
    $infCount = @(Get-ChildItem $DriverPath -Recurse -Filter *.inf -EA SilentlyContinue).Count
    if ($infCount -eq 0) { Write-Host "No drivers (.inf) in $DriverPath - skipped." }
    elseif ($PSCmdlet.ShouldProcess($root, "DISM /Add-Driver: $infCount .inf from $DriverPath")) {
        Write-Host "Injecting $infCount drivers from $DriverPath (can take several minutes)..."
        $dlog = Join-Path $env:TEMP "WtgAddDriver-$(Get-Date -Format yyyyMMdd-HHmmss).log"
        & "$env:SystemRoot\System32\dism.exe" /English "/Image:$root\" /Add-Driver "/Driver:$DriverPath" /Recurse "/LogPath:$dlog" |
            Select-String -Pattern 'Installing \d+ of \d+|successfully|Error' | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) { Write-Warning "DISM /Add-Driver finished with code $LASTEXITCODE - some drivers may be missing. Log: $dlog" }
        else { Write-Host 'Drivers injected.' }
    }
}

# --- 1. Copy the tool --------------------------------------------------------------------------
$dest = "$root\AutopilotCheck"
if ($PSCmdlet.ShouldProcess($dest, 'Copy Autopilot check')) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }        # always a clean copy
    New-Item "$dest\WindowsToGo" -ItemType Directory -Force | Out-Null
    foreach ($f in 'Get-AutopilotProfile.ps1','Run-AutopilotCheck.ps1','PsExec.exe','PsExec64.exe','Readme.md') {
        $p = Join-Path $toolRoot $f; if (Test-Path $p) { Copy-Item $p $dest -Force }
    }
    # the Drivers folder stays behind: its drivers are already injected into Windows (step 0c)
    Get-ChildItem $PSScriptRoot | Where-Object Name -ne 'Drivers' | Copy-Item -Destination "$dest\WindowsToGo" -Recurse -Force
    if ($EnableUwf) { Set-Content "$dest\WindowsToGo\enable-uwf.flag" 'Run Enable-WtgUwf.ps1 after install' -Encoding Ascii }
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

# USB SSDs often show up as 'Fixed' disks with write caching on: without a flush, pulling the stick
# can make NTFS roll back the copied files.
try { Write-VolumeCache -DriveLetter $DriveLetter -ErrorAction Stop; Write-Host 'Write cache flushed to the stick.' }
catch { Write-Warning "Could not flush the write cache: $($_.Exception.Message)" }

Write-Host "`nDone. Boot a PC from the stick:" -ForegroundColor Green
Write-Host '  - fresh stick: the check is installed automatically during first setup'
Write-Host "  - stick already set up: double-click 'Install Autopilot check' on the desktop once"
if ($EnableUwf) {
    Write-Host '  - UWF: configured during the first boot; C: is read-only from the SECOND boot on.'
    Write-Host '    Check on the stick: uwfmgr get-config   (log: D:\AutopilotProbe\uwf-setup-*.log)'
}
Write-Host 'Safely eject the stick before removing it.'
