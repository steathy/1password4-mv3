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
$RawBase    = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
# Force-install fetches this manifest (and the crx it points to) over https from
# GitHub. NOTE: Chrome only honors off-Web-Store force-install on ENTERPRISE-MANAGED
# devices; on a normal personal PC it is blocked, so load-unpacked is the default.
$UpdateUrl  = "$RawBase/dist/updates.xml"

function Test-Managed {
  # Chrome allows off-Web-Store force-install only on enterprise-managed devices.
  try { if ((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain) { return $true } } catch {}
  try {
    $ds = (& dsregcmd /status 2>$null) -join "`n"
    if ($ds -match 'AzureAdJoined\s*:\s*YES' -or
        $ds -match 'DomainJoined\s*:\s*YES' -or
        $ds -match 'EnterpriseJoined\s*:\s*YES') { return $true }
  } catch {}
  return $false
}
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
  # Reliably restart Chrome so it re-reads policy. `chrome.exe chrome://restart`
  # from the CLI only opens a window, so close Chrome gracefully and relaunch.
  $exe = Find-Chrome
  $running = Get-Process chrome -ErrorAction SilentlyContinue
  if ($running) {
    Write-Host "Closing Chrome to apply the policy..."
    foreach ($p in $running) { try { $p.CloseMainWindow() | Out-Null } catch {} }
    Start-Sleep -Seconds 3
    $still = Get-Process chrome -ErrorAction SilentlyContinue
    if ($still) { try { $still | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Seconds 1 }
    if ($exe) { Start-Process $exe; Write-Host "Chrome relaunched." }
  } else {
    Write-Host "Start Chrome to activate."
  }
}
function Set-VerifyCodeSignatureOff {
  # 1Password 4's agent verifies the connecting browser's Authenticode signer name
  # against a hardcoded list ("Google Inc", "Microsoft Corporation", "Vivaldi
  # Technologies AS"). Modern Chrome signs as "Google LLC", so with the check on the
  # agent silently drops Chrome (extension connects but never registers). This DWORD
  # (0 = skip) is what working machines already have; a fresh machine lacks it and
  # defaults to verify. HKCU, no admin. Returns $true if it actually changed.
  $key = 'HKCU:\Software\AgileBits\1Password 4'
  if (-not (Test-Path $key)) {
    Write-Host "Note: 1Password 4 settings key not found - skipping VerifyCodeSignature (is the app installed?)." -ForegroundColor Yellow
    return $false
  }
  if ((Get-ItemProperty $key -ErrorAction SilentlyContinue).VerifyCodeSignature -eq 0) { return $false }
  Set-ItemProperty -Path $key -Name 'VerifyCodeSignature' -Value 0 -Type DWord
  Write-Host "Set VerifyCodeSignature=0 so 1Password 4 accepts Chrome (now signed 'Google LLC') and other browsers not in its signer allow-list." -ForegroundColor Green
  return $true
}
function Restart-Agent {
  # Agile1pAgent.exe reads VerifyCodeSignature at startup and is a separate,
  # long-lived process; quitting 1Password alone does not restart it.
  Stop-Process -Name '1Password','Agile1pAgent' -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  Write-Host "Restarted 1Password + agent - reopen 1Password 4 and UNLOCK it." -ForegroundColor Cyan
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
  $extId = (Get-Content (Join-Path $payload 'dist\extension.json') -Raw | ConvertFrom-Json).id
  if (-not (Test-Admin)) {
    if (-not (Test-Managed)) {
      Write-Host ""
      Write-Host "This PC is not enterprise-managed, so Chrome will BLOCK a force-install of" -ForegroundColor Yellow
      Write-Host "any extension that isn't in the Chrome Web Store (chrome://policy shows it as" -ForegroundColor Yellow
      Write-Host "[BLOCKED]). Load unpacked works on any PC and is the recommended option." -ForegroundColor Yellow
      if ((Read-Host "Use Load unpacked instead? [Y/n]").Trim().ToLower() -ne 'n') {
        Install-Unpacked $payload; return
      }
      Write-Host "Proceeding with force-install anyway (only works once the device is managed)."
    }
    Invoke-Elevated $payload 'force'; return
  }

  # Policy value: "<id>;<update-manifest-url>". The manifest and crx are served over
  # https from GitHub, so nothing local needs to persist for force-install.
  $key = 'HKLM:\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist'
  New-Item -Path $key -Force | Out-Null
  $item = Get-Item -Path $key; $target = $null; $max = 0
  foreach ($n in $item.GetValueNames()) {
    if ($n -eq '') { continue }
    if (([string]$item.GetValue($n)) -like "$extId;*") { $target = $n }
    if ($n -match '^\d+$' -and [int]$n -gt $max) { $max = [int]$n }
  }
  if (-not $target) { $target = [string]($max + 1) }
  Set-ItemProperty -Path $key -Name $target -Value "$extId;$UpdateUrl"

  Write-Host "Force-install policy set: $extId -> $UpdateUrl" -ForegroundColor Green
  Restart-Chrome
  Write-Host "chrome://extensions should show 'Installed by policy'; it re-pairs once."
  Write-Host "If not: chrome://policy -> Reload policies, or fully quit + reopen Chrome."
  Read-Host "Press Enter to close"
}
function Install-Unpacked($payload) {
  $src = Join-Path $payload 'src'
  if (-not (Test-Path $src)) { throw "Missing $src." }
  # First-run fix: let 1Password 4 accept modern Chrome (see Set-VerifyCodeSignatureOff).
  if (Set-VerifyCodeSignatureOff) { Restart-Agent }
  try { Set-Clipboard -Value $src } catch {}
  # Make sure a Chrome window exists to work in, but DON'T pass chrome://extensions
  # on the command line - Chrome blocks navigating to privileged pages that way and
  # just opens a blank window. The user types the URL instead.
  $exe = Find-Chrome
  if ($exe -and -not (Get-Process chrome -ErrorAction SilentlyContinue)) { Start-Process $exe }
  Write-Host ""
  Write-Host "Load-unpacked setup - do these in your browser (Chrome, Edge, or any" -ForegroundColor Green
  Write-Host "Chromium browser with MV3 support):" -ForegroundColor Green
  Write-Host ""
  Write-Host "  1) In the address bar, type the extensions page and press Enter:"
  Write-Host "       Chrome: chrome://extensions     Edge: edge://extensions"
  Write-Host "     (the browser won't let a script open that page for you, so type it yourself.)"
  Write-Host "  2) Turn ON 'Developer mode' (top-right toggle). One-time - it stays on."
  Write-Host "  3) Click 'Load unpacked'. In the folder picker press Ctrl+V (the path is"
  Write-Host "     already on your clipboard), then Enter."
  Write-Host ""
  Write-Host "  Extension folder (also on clipboard):"
  Write-Host "    $src" -ForegroundColor Cyan
  Write-Host "  Keep that folder where it is - your browser loads it from there each launch."
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
  Write-Host "  [1] Load unpacked   (recommended; works on any PC, no admin)"
  Write-Host "  [2] Force install   (no dev-mode nag, but ENTERPRISE-MANAGED devices only)"
  Write-Host "  [3] Uninstall       (remove force-install policy)"
  Write-Host "  [Q] Quit"
  switch ((Read-Host "Choose").Trim().ToLower()) {
    '1' { $Mode = 'unpacked' }
    '2' { $Mode = 'force' }
    '3' { $Mode = 'uninstall' }
    default { return }
  }
}
switch ($Mode) {
  'force'     { Install-Force     $payload }
  'unpacked'  { Install-Unpacked  $payload }
  'uninstall' { Uninstall-Force   $payload }
}
