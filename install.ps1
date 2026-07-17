<#
  install.ps1 - One-command installer for the 1Password 4 MV3 port (Chrome, Windows).

  Run it either way:
    * One command (no clone needed):
        irm https://raw.githubusercontent.com/YOUR_GH_USER/1password4-mv3/main/install.ps1 | iex
    * From a local clone: double-click install.bat, or right-click -> Run with PowerShell.

  It shows a menu:
    [1] Force install  - policy install; no dev-mode nag, can't be user-disabled (needs admin)
    [2] Load unpacked  - no admin; stages files and you click 'Load unpacked' once
    [3] Uninstall      - remove the force-install policy

  When run via irm|iex it downloads this repo's zip to %LOCALAPPDATA%\1Password4-MV3
  and installs from there. Review this script before running it - irm|iex executes
  remote code.
#>
param(
  [ValidateSet('', 'force', 'unpacked', 'uninstall')]
  [string]$Mode = '',
  [string]$PayloadRoot = ''   # internal: set when self-elevating to an already-staged path
)
$ErrorActionPreference = 'Stop'

# ===== Published GitHub repo (change if you fork) =====
$Owner  = 'steathy'
$Repo   = '1password4-mv3'
$Branch = 'main'
# ======================================================

$InstallDir = Join-Path $env:LOCALAPPDATA '1Password4-MV3'

function Test-Admin {
  (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
  ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
function Find-Chrome {
  @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
function Restart-Chrome {
  $exe = Find-Chrome
  if ($exe -and (Get-Process chrome -ErrorAction SilentlyContinue)) {
    Write-Host "Restarting Chrome (tabs will be restored)..."
    Start-Process $exe "chrome://restart"
  } elseif ($exe) {
    Write-Host "Start Chrome to activate."
  }
}
function Test-Payload($root) {
  $root -and (Test-Path (Join-Path $root 'dist\onepassword-mv3.crx')) `
        -and (Test-Path (Join-Path $root 'dist\extension.json'))
}
function Get-Payload {
  if (Test-Payload $script:PayloadRoot) { return $script:PayloadRoot }
  if (Test-Payload $PSScriptRoot)       { return $PSScriptRoot }
  # Remote run: download the repo zip and stage it.
  Write-Host "Downloading $Owner/$Repo ($Branch)..."
  $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    $zip = Join-Path $env:TEMP '1p4mv3.zip'
    $ex  = Join-Path $env:TEMP '1p4mv3_extract'
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Owner/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip
    if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
    Expand-Archive -Path $zip -DestinationPath $ex -Force
    $inner = Get-ChildItem $ex -Directory | Select-Object -First 1
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    Move-Item -Path $inner.FullName -Destination $InstallDir
    Remove-Item -Force $zip -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $ex -ErrorAction SilentlyContinue
  } finally { $ProgressPreference = $prev }
  if (-not (Test-Payload $InstallDir)) {
    throw "Downloaded payload has no dist\ - check `$Owner/`$Repo/`$Branch at the top of this script."
  }
  return $InstallDir
}
function Invoke-Elevated($payload, $modeName) {
  $script = Join-Path $payload 'install.ps1'
  if (-not (Test-Path $script)) { throw "Cannot find $script to elevate." }
  Write-Host "Requesting administrator rights..."
  Start-Process powershell -Verb RunAs -ArgumentList `
    "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Mode $modeName -PayloadRoot `"$payload`""
}

function Install-Force($payload) {
  if (-not (Test-Admin)) { Invoke-Elevated $payload 'force'; return }
  $crx     = Join-Path $payload 'dist\onepassword-mv3.crx'
  $meta    = Get-Content (Join-Path $payload 'dist\extension.json') -Raw | ConvertFrom-Json
  $extId   = $meta.id; $version = $meta.version
  $updates = Join-Path $payload 'dist\updates.xml'
  $crxUrl  = 'file:///' + ($crx -replace '\\', '/')
  @"
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$extId'>
    <updatecheck codebase='$crxUrl' version='$version' />
  </app>
</gupdate>
"@ | Set-Content -Path $updates -Encoding UTF8
  $updateUrl = 'file:///' + ($updates -replace '\\', '/')

  $key = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
  New-Item -Path $key -Force | Out-Null
  $item = Get-Item -Path $key; $target = $null; $max = 0
  foreach ($n in $item.GetValueNames()) {
    if ($n -eq '') { continue }
    if (([string]$item.GetValue($n)) -like "$extId;*") { $target = $n }
    if ($n -match '^\d+$' -and [int]$n -gt $max) { $max = [int]$n }
  }
  if (-not $target) { $target = [string]($max + 1) }
  Set-ItemProperty -Path $key -Name $target -Value "$extId;$updateUrl"

  Write-Host "Force-install policy set for $extId (v$version)." -ForegroundColor Green
  Restart-Chrome
  Write-Host "chrome://extensions shows 'Installed by policy'; it re-pairs once."
  Write-Host "If it doesn't appear: chrome://policy -> Reload policies, or restart Chrome."
  Read-Host "Press Enter to close"
}
function Install-Unpacked($payload) {
  $src = Join-Path $payload 'src'
  if (-not (Test-Path $src)) { throw "Missing $src." }
  try { Set-Clipboard -Value $src } catch {}
  Write-Host ""
  Write-Host "Load-unpacked setup" -ForegroundColor Green
  Write-Host "  Files staged at: $src   (path copied to clipboard)"
  Write-Host "  1) Chrome -> chrome://extensions"
  Write-Host "  2) Turn on 'Developer mode' (top-right)"
  Write-Host "  3) Click 'Load unpacked' and pick that folder (Ctrl+V pastes the path)"
  Write-Host "  Keep the folder where it is - Chrome loads it from there each launch."
  $exe = Find-Chrome
  if ($exe) { Start-Process $exe "chrome://extensions" }
  Read-Host "Press Enter to close"
}
function Uninstall-Force($payload) {
  if (-not (Test-Admin)) { Invoke-Elevated $payload 'uninstall'; return }
  $extId = (Get-Content (Join-Path $payload 'dist\extension.json') -Raw | ConvertFrom-Json).id
  $key   = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
  if (Test-Path $key) {
    $item = Get-Item -Path $key
    foreach ($n in $item.GetValueNames()) {
      if ($n -eq '') { continue }
      if (([string]$item.GetValue($n)) -like "$extId;*") {
        Remove-ItemProperty -Path $key -Name $n; Write-Host "Removed forcelist entry [$n]."
      }
    }
    $rem = (Get-Item -Path $key).GetValueNames() | Where-Object { $_ -ne '' }
    if (-not $rem) { Remove-Item -Path $key -Force }
  }
  Restart-Chrome
  Write-Host "Force-install policy removed." -ForegroundColor Green
  Read-Host "Press Enter to close"
}

# ---- main ----
[Net.ServicePointManager]::SecurityProtocol = `
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$payload = Get-Payload

if (-not $Mode) {
  Write-Host ""
  Write-Host "  1Password 4  -  MV3 port for Chrome"
  Write-Host "  ----------------------------------"
  Write-Host "  [1] Force install   (recommended; needs admin, no dev-mode nag)"
  Write-Host "  [2] Load unpacked   (no admin; one manual click)"
  Write-Host "  [3] Uninstall       (remove force-install policy)"
  Write-Host "  [Q] Quit"
  switch ((Read-Host "Choose").Trim().ToLower()) {
    '1' { $Mode = 'force' }
    '2' { $Mode = 'unpacked' }
    '3' { $Mode = 'uninstall' }
    default { return }
  }
}
switch ($Mode) {
  'force'     { Install-Force     $payload }
  'unpacked'  { Install-Unpacked  $payload }
  'uninstall' { Uninstall-Force   $payload }
}
