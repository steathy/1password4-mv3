<#
  uninstall.ps1 - Remove the 1Password MV3 force-install policy (self-elevating),
  then restart Chrome to drop the extension.
#>
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal(
  [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
  Start-Process powershell -Verb RunAs -ArgumentList `
    "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}

$root  = Split-Path -Parent $PSCommandPath
$extId = (Get-Content (Join-Path $root "dist\extension.json") -Raw | ConvertFrom-Json).id
$key   = "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist"

if (Test-Path $key) {
  $item = Get-Item -Path $key
  foreach ($n in $item.GetValueNames()) {
    if ($n -eq '') { continue }
    if (([string]$item.GetValue($n)) -like "$extId;*") {
      Remove-ItemProperty -Path $key -Name $n
      Write-Host "Removed forcelist entry [$n]."
    }
  }
  $remaining = (Get-Item -Path $key).GetValueNames() | Where-Object { $_ -ne '' }
  if (-not $remaining) { Remove-Item -Path $key -Force; Write-Host "Removed empty ExtensionInstallForcelist key." }
} else {
  Write-Host "No ExtensionInstallForcelist policy present."
}

$chromeExe = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ((Get-Process chrome -ErrorAction SilentlyContinue) -and $chromeExe) {
  Write-Host "Restarting Chrome..."
  Start-Process $chromeExe "chrome://restart"
}

Write-Host "Done. If Chrome didn't restart, restart it to finish removal." -ForegroundColor Green
Read-Host "Press Enter to close"
