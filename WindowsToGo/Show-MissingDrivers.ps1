<#
.SYNOPSIS
    Run ON the stick: lists devices without a working driver, with hardware ID and chip vendor, plus
    the PC model/system ID you need for Get-WtgDriverPack.ps1. Writes a copy to the log folder.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\AutopilotCheck\WindowsToGo\Show-MissingDrivers.ps1
#>
$vendors = @{ '8086'='Intel'; '10EC'='Realtek'; '14C3'='MediaTek'; '17CB'='Qualcomm'; '168C'='Qualcomm Atheros'
              '14E4'='Broadcom'; '1022'='AMD'; '10DE'='NVIDIA'; '1002'='AMD/ATI'; '8087'='Intel (USB)'; '0BDA'='Realtek (USB)' }

$cs = Get-CimInstance Win32_ComputerSystem
$bb = Get-CimInstance Win32_BaseBoard
$pc = [pscustomobject]@{
    Manufacturer = $cs.Manufacturer; Model = $cs.Model
    'SystemId (HP: baseboard)'   = $bb.Product
    'SystemId (Dell: SKU)'       = $cs.SystemSKUNumber
}

$missing = Get-PnpDevice -PresentOnly | Where-Object { "$($_.ConfigManagerErrorCode)" -notin '0','CM_PROB_NONE' } | ForEach-Object {
    $hw  = @((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -EA SilentlyContinue).Data)[0]
    $ven = if ($hw -match '(?:VEN|VID)_([0-9A-F]{4})') { $v = $Matches[1]; if ($vendors[$v]) { "$($vendors[$v]) ($v)" } else { $v } }
    [pscustomobject]@{ Class = $_.Class; Name = $_.FriendlyName; ChipVendor = $ven; Error = $_.ConfigManagerErrorCode; HardwareId = $hw }
}

$net = Get-NetAdapter -Physical -EA SilentlyContinue | Where-Object Status -ne 'Not Present' | Select-Object Name, InterfaceDescription, Status

$report = @(
    '=== PC'; ($pc | Format-List | Out-String).Trim()
    ''; '=== Network adapters with a driver'; ($net | Format-Table -AutoSize | Out-String).Trim()
    ''; '=== Devices without a working driver'
    if ($missing) { ($missing | Sort-Object Class | Format-Table -AutoSize -Wrap | Out-String -Width 220).Trim() } else { 'None - all devices have a driver.' }
) -join "`r`n"

Write-Host $report
$logDir = if (Test-Path 'D:\AutopilotProbe') { 'D:\AutopilotProbe' } else { "$env:ProgramData\AutopilotProbe" }
New-Item $logDir -ItemType Directory -Force | Out-Null
$out = Join-Path $logDir "missing-drivers-$($env:COMPUTERNAME)-$(Get-Date -Format yyyyMMdd-HHmmss).txt"
Set-Content $out $report
Write-Host "`nSaved to $out"
if (-not ($net | Where-Object InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11')) {
    Write-Host "`nNo Wi-Fi adapter with a driver. Quick workaround: USB-C/USB Ethernet adapter or USB tethering from a phone (both use built-in Windows drivers)." -ForegroundColor Yellow
}
