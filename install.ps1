<#
  install.ps1 - One-click force-install of the 1Password 4 MV3 port into Chrome
  on Windows. No build tools needed: it installs the pre-built crx in dist\.

  What it does (self-elevating):
    1. Writes dist\updates.xml (an Omaha update manifest whose crx path is
       resolved for THIS machine).
    2. Writes the HKLM ExtensionInstallForcelist policy pointing Chrome at it.
       Force-installed extensions install with no developer-mode nag and cannot
       be user-disabled (a plain local-crx install would be blocked by Chrome).
    3. Restarts Chrome to activate.

  Run:  right-click -> Run with PowerShell   (or double-click install.bat)
  Undo: uninstall.ps1

  The packed build is signed with this repo's key, so it gets its own extension
  ID and re-pairs with the 1Password desktop app once on first run (automatic).
#>
$ErrorActionPreference = 'Stop'

# --- self-elevate ----------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal(
  [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
  Write-Host "Requesting administrator rights..."
  Start-Process powershell -Verb RunAs -ArgumentList `
    "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}

$root     = Split-Path -Parent $PSCommandPath
$crx      = Join-Path $root "dist\onepassword-mv3.crx"
$metaFile = Join-Path $root "dist\extension.json"
$updates  = Join-Path $root "dist\updates.xml"

if (-not (Test-Path $crx))      { throw "Missing $crx  (run build\pack.ps1 first)." }
if (-not (Test-Path $metaFile)) { throw "Missing $metaFile." }
$meta    = Get-Content $metaFile -Raw | ConvertFrom-Json
$extId   = $meta.id
$version = $meta.version
Write-Host "Extension: $extId  v$version"

# --- update manifest (absolute crx path for this machine) ------------------
$crxUrl = 'file:///' + ($crx -replace '\\', '/')
@"
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$extId'>
    <updatecheck codebase='$crxUrl' version='$version' />
  </app>
</gupdate>
"@ | Set-Content -Path $updates -Encoding UTF8
$updateUrl = 'file:///' + ($updates -replace '\\', '/')

# --- force-install policy (HKLM), reusing/appending an index ---------------
$key = "HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist"
New-Item -Path $key -Force | Out-Null
$item = Get-Item -Path $key
$target = $null; $max = 0
foreach ($n in $item.GetValueNames()) {
  if ($n -eq '') { continue }
  if (([string]$item.GetValue($n)) -like "$extId;*") { $target = $n }
  if ($n -match '^\d+$' -and [int]$n -gt $max) { $max = [int]$n }
}
if (-not $target) { $target = [string]($max + 1) }
Set-ItemProperty -Path $key -Name $target -Value "$extId;$updateUrl"
Write-Host "Policy set: [$target] = $extId;$updateUrl"

# --- restart Chrome to activate --------------------------------------------
$chromeExe = @(
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
  "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (Get-Process chrome -ErrorAction SilentlyContinue) {
  if ($chromeExe) {
    Write-Host "Restarting Chrome (your tabs will be restored)..."
    Start-Process $chromeExe "chrome://restart"
  }
} else {
  Write-Host "Start Chrome to activate."
}

Write-Host ""
Write-Host "Done. 1Password ($extId) is force-installed." -ForegroundColor Green
Write-Host "chrome://extensions shows it as 'Installed by policy'; it re-pairs once."
Write-Host "If it doesn't appear: open chrome://policy, click 'Reload policies', or restart Chrome."
Read-Host "Press Enter to close"
