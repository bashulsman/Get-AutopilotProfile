<#
.SYNOPSIS
    Downloads and extracts the official OEM driver pack (HP or Dell) for a laptop model into
    WindowsToGo\Drivers\<model>, so Prepare-WtgStick.ps1 can inject it into the stick.

.DESCRIPTION
    Uses the vendors' public driver pack catalogs:
      HP   https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab
      Dell https://downloads.dell.com/catalog/DriverPackCatalog.cab

    Picks the newest Windows 11 x64 pack for the model (falls back to Windows 10 x64), downloads it,
    verifies the hash from the catalog and the Authenticode signature (HP Inc. / Dell Inc.), and
    extracts it. Nothing is installed on this PC.

    Find the model or system ID on the target laptop (e.g. booted from the stick):
      (Get-CimInstance Win32_ComputerSystem).Model      -> "HP ProBook 440 G8 Notebook PC"
      (Get-CimInstance Win32_BaseBoard).Product         -> HP system ID, e.g. "8807"
      (Get-CimInstance Win32_ComputerSystem).SystemSKUNumber -> Dell system ID, e.g. "0A23"

    -ListOnly shows the matching packs without downloading them.

.EXAMPLE
    .\Get-WtgDriverPack.ps1 -Vendor HP -Model 'ProBook 440 G8' -ListOnly
.EXAMPLE
    .\Get-WtgDriverPack.ps1 -Vendor HP -Model 'ProBook 440 G8'
.EXAMPLE
    .\Get-WtgDriverPack.ps1 -Vendor Dell -SystemId 0A23
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('HP','Dell')][string]$Vendor,
    [string]$Model,
    [string]$SystemId,
    [string]$OutRoot,                # default: <this script's folder>\Drivers
    [switch]$ListOnly
)
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside param() defaults in Windows PowerShell 5.1 - resolve it here
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutRoot) { $OutRoot = Join-Path $here 'Drivers' }
$ProgressPreference    = 'SilentlyContinue'      # Invoke-WebRequest is very slow with the progress bar
if (-not $Model -and -not $SystemId) { throw 'Give -Model (part of the model name) and/or -SystemId.' }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$work = Join-Path $env:TEMP ("WtgDriverPack_" + [Guid]::NewGuid().ToString('N'))
New-Item $work -ItemType Directory -Force | Out-Null

function Get-Catalog([string]$url) {
    $cab = Join-Path $work (Split-Path $url -Leaf)
    Write-Host "Downloading catalog $url"
    Invoke-WebRequest $url -OutFile $cab -UseBasicParsing
    # The catalog cab holds one XML file. Expand to an explicit file name: 'expand -F:*' names the
    # output after the cab (no .xml), and next to the cab itself it would collide with it.
    $xmlFile = Join-Path $work 'catalog.xml'
    $out = & expand.exe $cab $xmlFile 2>&1
    if (-not (Test-Path $xmlFile)) { throw "Could not extract the catalog from $cab.`n$($out -join "`n")" }
    $x = New-Object Xml.XmlDocument; $x.Load($xmlFile); return $x
}
function Get-OsRank([string]$os) {
    # Windows 11 beats Windows 10; within one, the higher release (e.g. 24H2) wins
    $major = if ($os -match '11') { 11 } elseif ($os -match '10') { 10 } else { 0 }
    $rel   = if ($os -match '(\d{2})H(\d)') { [int]$Matches[1] * 10 + [int]$Matches[2] } else { 0 }
    return $major * 1000 + $rel
}

# =================================================================================================
#  Find the pack in the catalog
# =================================================================================================
$packs = @()
if ($Vendor -eq 'HP') {
    $x = Get-Catalog 'https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab'
    $softpaqs = @{}
    foreach ($sp in $x.SelectNodes("//*[local-name()='SoftPaq']")) { $softpaqs[$sp.Id] = $sp }
    foreach ($p in $x.SelectNodes("//*[local-name()='ProductOSDriverPack']")) {
        if ($p.OSName -notmatch 'Windows 1[01]' -or $p.OSName -notmatch '64') { continue }
        if ($Model    -and $p.SystemName -notlike "*$Model*") { continue }
        if ($SystemId -and (($p.SystemId -split '\s*,\s*') -notcontains $SystemId)) { continue }
        $sp = $softpaqs[$p.SoftPaqId]; if (-not $sp) { continue }
        $packs += [pscustomobject]@{
            System = $p.SystemName; SystemId = $p.SystemId; OS = $p.OSName; Rank = Get-OsRank $p.OSName
            Name = "$($sp.Name) $($sp.Version)"; Url = $sp.Url; SizeMB = [math]::Round([double]$sp.Size / 1MB)
            Hash = $sp.SHA256; HashAlg = 'SHA256'; Signer = 'HP Inc'
        }
    }
} else {
    $x = Get-Catalog 'https://downloads.dell.com/catalog/DriverPackCatalog.cab'
    $base = $x.DocumentElement.baseLocation; if (-not $base) { $base = 'downloads.dell.com' }
    foreach ($d in $x.SelectNodes("//*[local-name()='DriverPackage']")) {
        if ($d.type -and $d.type -ne 'win') { continue }
        $oses = @($d.SelectNodes(".//*[local-name()='OperatingSystem']") | Where-Object { $_.osCode -match '^Windows1[01]$' -and $_.osArch -match '64' })
        if (-not $oses) { continue }
        $models = @($d.SelectNodes(".//*[local-name()='Model']"))
        $hit = $models | Where-Object {
            (-not $Model -or $_.name -like "*$Model*") -and (-not $SystemId -or $_.systemID -eq $SystemId)
        }
        if (-not $hit) { continue }
        $os = ($oses | Sort-Object { Get-OsRank $_.osCode } -Descending | Select-Object -First 1).osCode
        $dt = try { [datetime]$d.dateTime } catch { [datetime]::MinValue }      # newest release wins within one OS
        $packs += [pscustomobject]@{
            System = ($hit.name | Select-Object -Unique) -join ', '; SystemId = ($hit.systemID | Select-Object -Unique) -join ', '
            OS = $os; Rank = (Get-OsRank $os) + [double]$dt.ToString('yyyyMMdd') / 1e8
            Name = (Split-Path $d.path -Leaf); Url = "https://$base/$($d.path)"; SizeMB = [math]::Round([double]$d.size / 1MB)
            Hash = $d.hashMD5; HashAlg = 'MD5'; Signer = 'Dell'
        }
    }
}

if (-not $packs) { Remove-Item $work -Recurse -Force; throw "No $Vendor Windows 10/11 x64 driver pack found for model '$Model' / system ID '$SystemId'." }
$packs = $packs | Sort-Object Rank -Descending
Write-Host "`nMatching packs (newest OS first):" -ForegroundColor Cyan
$packs | Select-Object System, SystemId, OS, Name, SizeMB | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

$systems = @($packs.System | Select-Object -Unique)
if ($systems.Count -gt 1) {
    Remove-Item $work -Recurse -Force
    throw "The search matches several models ($($systems -join ' | ')). Make -Model more specific or use -SystemId."
}
if ($ListOnly) { Remove-Item $work -Recurse -Force; return }

# =================================================================================================
#  Download, verify, extract
# =================================================================================================
$pack = $packs[0]
$safe = ($pack.System -replace '[^\w\-\. ]','' -replace '\s+','-')
$dest = Join-Path $OutRoot "$Vendor-$safe"
$file = Join-Path $work (Split-Path $pack.Url -Leaf)
Write-Host ("Downloading {0} ({1} MB) for {2}, {3}..." -f (Split-Path $pack.Url -Leaf), $pack.SizeMB, $pack.System, $pack.OS)
Invoke-WebRequest $pack.Url -OutFile $file -UseBasicParsing

if ($pack.Hash) {
    $h = (Get-FileHash $file -Algorithm $pack.HashAlg).Hash
    if ($h -ne $pack.Hash.ToUpper()) { throw "$($pack.HashAlg) mismatch for $file (catalog $($pack.Hash), file $h). Not extracting." }
    Write-Host "$($pack.HashAlg) OK"
}
$sig = Get-AuthenticodeSignature $file
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $pack.Signer) {
    throw "Signature check failed for $file ($($sig.Status), $($sig.SignerCertificate.Subject)). Not extracting."
}
Write-Host "Signature OK: $($sig.SignerCertificate.Subject)"

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item $dest -ItemType Directory -Force | Out-Null
Write-Host "Extracting to $dest ..."
if ($file -like '*.cab') {
    & expand.exe $file -F:* $dest | Out-Null
} elseif ($Vendor -eq 'HP') {
    Start-Process $file -ArgumentList '/s','/e','/f',"`"$dest`"" -Wait -NoNewWindow
} else {
    Start-Process $file -ArgumentList '/s',"/e=`"$dest`"" -Wait -NoNewWindow
}
$infs = @(Get-ChildItem $dest -Recurse -Filter *.inf)
Remove-Item $work -Recurse -Force
if (-not $infs) { throw "Extraction produced no .inf files in $dest." }
Write-Host ("Done: {0} drivers (.inf) in {1}" -f $infs.Count, $dest) -ForegroundColor Green
Write-Host 'Next: run Prepare-WtgStick.ps1 with the stick plugged in to inject them.'
