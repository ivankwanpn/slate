#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only ADB audit for preinstalled carrier-DM / surveillance components.
.NOTES
  This script NEVER uninstalls, disables or modifies anything.
  Tested against a vivo device running Android 16.
#>
param(
  [string]$Serial = '',
  [string]$AdbPath = 'C:\platform-tools\adb.exe'
)

$ErrorActionPreference = 'SilentlyContinue'
if (-not (Test-Path $AdbPath)) {
  $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
  if ($cmd) { $AdbPath = $cmd.Source } else { Write-Error 'adb not found'; exit 1 }
}
$prefix = @()
if ($Serial) { $prefix = @('-s', $Serial) }
function SH([string]$c) { (& $AdbPath @prefix shell $c 2>&1) -join "`n" }
function Hdr([string]$t) { Write-Host ''; Write-Host ('=== ' + $t + ' ===') -ForegroundColor Cyan }

Hdr 'DEVICE'
foreach ($p in @('ro.product.brand','ro.product.model','ro.product.device','ro.build.version.release','ro.build.display.id','ro.build.version.security_patch')) {
  '{0} = {1}' -f $p, (SH "getprop $p").Trim()
}

$patterns = 'systemhelper|mobiletools|dmreg|guardprovider|securitycenter|misight|anti-?fraud|fanzha|fraud'
$pkgs = (SH 'pm list packages') -split "`n" | Where-Object { $_ -match $patterns }
Hdr 'MATCHING PACKAGES'
if (-not $pkgs) { Write-Host 'none found' -ForegroundColor Green; exit 0 }
$pkgs

foreach ($line in $pkgs) {
  $pkg = $line -replace '^package:', ''
  Hdr "DETAIL: $pkg"
  'path    : ' + (SH "pm path $pkg").Trim()
  'version : ' + (((SH "dumpsys package $pkg") -split "`n" | Where-Object { $_ -match 'versionName' }) | Select-Object -First 1).Trim()
  'running : ' + ((((SH 'ps -A') -split "`n") | Where-Object { $_ -match [regex]::Escape($pkg) }) -join ' | ')
  Write-Host '-- granted permissions --'
  ((SH "dumpsys package $pkg") -split "`n") | Where-Object { $_ -match 'granted=true' } | ForEach-Object { '  ' + $_.Trim() } | Select-Object -First 25
  Write-Host '-- exported components --'
  ((SH "pm dump $pkg") -split "`n") | Where-Object { $_ -match 'exported=true' } | ForEach-Object { '  ' + $_.Trim() } | Select-Object -First 20
  'switch  : operator_service_improve_plan = ' + (SH 'settings get secure operator_service_improve_plan').Trim()
}

Hdr 'ALARMS'
((SH 'dumpsys alarm') -split "`n") | Where-Object { $_ -match $patterns } | ForEach-Object { $_.Trim() } | Select-Object -First 15

Hdr 'SOCKETS (30s sample, uid 10159 = systemhelper)'
$hits = 0
for ($i = 0; $i -lt 6; $i++) {
  $t = SH 'cat /proc/net/tcp /proc/net/tcp6'
  if ($t -match '\s10159\s') { $hits++ }
  Start-Sleep -Seconds 5
}
Write-Host ("samples with uid 10159 sockets: $hits / 6")

Write-Host ''
Write-Host 'READ-ONLY AUDIT COMPLETE - nothing was modified.' -ForegroundColor Green
