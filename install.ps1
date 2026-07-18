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

# ---- MAS-style dedicated window --------------------------------------------
# Run the interactive menu in its own console window (like Microsoft Activation
# Scripts) for a clean, correctly-sized, colored UI even when launched via
# `irm | iex`. Re-entry is guarded by OP4_WIN=1; the self-elevation path already
# opens its own window and passes -Mode, so it does not double up here. No -NoExit:
# the menu loops until the user picks [0] Quit, and then the window closes.
if (-not $Mode -and $env:OP4_WIN -ne '1') {
  $reenter = if ($PSCommandPath) {
    "& '" + ($PSCommandPath -replace "'", "''") + "'"
  } else {
    "irm '$RawBase/install.ps1' | iex"
  }
  Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
    "`$env:OP4_WIN='1'; $reenter"
  ) | Out-Null
  return
}

# ---- centered block output -------------------------------------------------
# Everything prints inside one fixed-width panel that is centered AS A WHOLE
# (like `margin: 0 auto` on a div); content stays left-aligned WITHIN the panel,
# so all lines share one left edge instead of each being centered on its own.
$script:PanelW = 62
function Get-Width  { try { $Host.UI.RawUI.WindowSize.Width } catch { 80 } }
function Get-Margin { [Math]::Max(0, [int]( ((Get-Width) - $script:PanelW) / 2 )) }
function Write-Mid {
  param([string]$Text = '', [string]$Color)
  $line = (' ' * (Get-Margin)) + $Text
  if ($Color) { Write-Host $line -ForegroundColor $Color } else { Write-Host $line }
}
function Write-MidSeg {
  # Colored segments (@(@{T='text';C='Color'},...)) printed at the panel margin.
  param([object[]]$Segs)
  Write-Host (' ' * (Get-Margin)) -NoNewline
  foreach ($s in $Segs) {
    if ($s.C) { Write-Host $s.T -ForegroundColor $s.C -NoNewline } else { Write-Host $s.T -NoNewline }
  }
  Write-Host ''
}

function Set-ConsoleFont {
  # Bump the console font ~25% for readability. Best-effort: ignored if it fails
  # (e.g. output redirected). Runs in our own window, so it affects nothing else.
  try {
    if (-not ('OP4.ConFont' -as [type])) {
      Add-Type -Namespace OP4 -Name ConFont -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
public struct FONTINFO {
  public uint cbSize; public uint nFont;
  public short X; public short Y;
  public uint Family; public uint Weight;
  [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Face;
}
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetCurrentConsoleFontEx(IntPtr h, bool m, ref FONTINFO f);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetCurrentConsoleFontEx(IntPtr h, bool m, ref FONTINFO f);
'@
    }
    $h = [OP4.ConFont]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
    $f = New-Object 'OP4.ConFont+FONTINFO'
    $f.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($f)
    [void][OP4.ConFont]::GetCurrentConsoleFontEx($h, $false, [ref]$f)
    $cur = [int]$f.Y; if ($cur -le 0) { $cur = 16 }
    $f.Y = [short][math]::Max($cur + 2, [int][math]::Round($cur * 1.25))
    $f.X = 0
    if ([string]::IsNullOrEmpty($f.Face)) { $f.Face = 'Consolas' }
    [void][OP4.ConFont]::SetCurrentConsoleFontEx($h, $false, [ref]$f)
  } catch {}
}

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
    Write-Mid 'Closing Chrome to apply the policy...' 'Yellow'
    foreach ($p in $running) { try { $p.CloseMainWindow() | Out-Null } catch {} }
    Start-Sleep -Seconds 3
    $still = Get-Process chrome -ErrorAction SilentlyContinue
    if ($still) { try { $still | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Seconds 1 }
    if ($exe) { Start-Process $exe; Write-Mid 'Chrome relaunched.' 'Green' }
  } else {
    Write-Mid 'Start Chrome to activate.' 'Gray'
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
function Get-RemoteSha {
  # The branch head commit SHA is a cheap content fingerprint - a few bytes over
  # the API instead of re-downloading the whole zip. `Accept: ...github.sha` makes
  # the endpoint return the raw 40-char SHA as text. Returns $null if unreachable.
  try {
    $u = "https://api.github.com/repos/$Owner/$Repo/commits/$Branch"
    $h = @{ 'User-Agent' = 'op4-mv3-installer'; 'Accept' = 'application/vnd.github.sha' }
    return ([string](Invoke-RestMethod -UseBasicParsing -Uri $u -Headers $h -TimeoutSec 10)).Trim()
  } catch { return $null }
}
function Get-Payload {
  if (Test-Payload $script:PayloadRoot) { return $script:PayloadRoot }
  if (Test-Payload $PSScriptRoot)       { return $PSScriptRoot }

  # Remote run: reuse the previous download unless the branch head moved. The SHA
  # of the last download is stored in $InstallDir\.commit and compared each run.
  $shaFile   = Join-Path $InstallDir '.commit'
  $remoteSha = Get-RemoteSha
  if (Test-Payload $InstallDir) {
    $localSha = if (Test-Path $shaFile) { (Get-Content $shaFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
    if (-not $remoteSha) {
      Write-Host "Can't reach GitHub - using the cached download." -ForegroundColor Yellow
      return $InstallDir
    }
    if ($localSha -eq $remoteSha) {
      Write-Host ("Cached download is current ({0}) - not re-downloading." -f $remoteSha.Substring(0, 7)) -ForegroundColor DarkGray
      return $InstallDir
    }
    Write-Host ("Update available ({0}) - refreshing download..." -f $remoteSha.Substring(0, 7)) -ForegroundColor Yellow
  }

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
  if ($remoteSha) { Set-Content -Path (Join-Path $InstallDir '.commit') -Value $remoteSha -Encoding ASCII }
  return $InstallDir
}
function Invoke-Elevated($payload, $modeName) {
  $script = Join-Path $payload 'install.ps1'
  if (-not (Test-Path $script)) { throw "Cannot find $script to elevate." }
  Write-Mid 'Requesting administrator rights...' 'Yellow'
  Start-Process powershell -Verb RunAs -ArgumentList `
    "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Mode $modeName -PayloadRoot `"$payload`""
}

function Install-Force($payload) {
  $extId = (Get-Content (Join-Path $payload 'dist\extension.json') -Raw | ConvertFrom-Json).id
  if (-not (Test-Admin)) {
    if (-not (Test-Managed)) {
      Write-Host ''
      Write-Mid 'This PC is not enterprise-managed, so Chrome will BLOCK a' 'Yellow'
      Write-Mid 'force-install of any non-Web-Store extension (chrome://policy' 'Yellow'
      Write-Mid 'shows it [BLOCKED]). Load unpacked works on any PC.' 'Yellow'
      Write-Host ''
      if ((Read-Host ((' ' * (Get-Margin)) + 'Use Load unpacked instead? [Y/n]')).Trim().ToLower() -ne 'n') {
        Install-Unpacked $payload; return
      }
      Write-Mid 'Proceeding with force-install (works only on a managed device).' 'Gray'
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

  Write-Host ''
  Write-Mid 'Force-install policy set for extension:' 'Green'
  Write-Mid ('  ' + $extId) 'Green'
  Restart-Chrome
  Write-Host ''
  Write-Mid "chrome://extensions should show 'Installed by policy'." 'Gray'
  Write-Mid 'If not: chrome://policy -> Reload policies, then restart Chrome.' 'Gray'
}
function Install-Unpacked($payload) {
  $src = Join-Path $payload 'src'
  if (-not (Test-Path $src)) { throw "Missing $src." }
  # First-run fix: let 1Password 4 accept modern Chrome (see Set-VerifyCodeSignatureOff).
  if (Set-VerifyCodeSignatureOff) { Restart-Agent }

  # Browser table: extensions URL to clipboard (step 1) + process/paths for the
  # optional auto-restart (step 4).
  $browsers = @(
    @{ Key = '1'; Name = 'Chrome';  Url = 'chrome://extensions';  Proc = 'chrome';
       Paths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                 "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                 "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") }
    @{ Key = '2'; Name = 'Edge';    Url = 'edge://extensions';    Proc = 'msedge';
       Paths = @("$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                 "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe") }
    @{ Key = '3'; Name = 'Vivaldi'; Url = 'vivaldi://extensions'; Proc = 'vivaldi';
       Paths = @("$env:LOCALAPPDATA\Vivaldi\Application\vivaldi.exe",
                 "$env:ProgramFiles\Vivaldi\Application\vivaldi.exe") }
    @{ Key = '4'; Name = 'Opera';   Url = 'opera://extensions';   Proc = 'opera';
       Paths = @("$env:LOCALAPPDATA\Programs\Opera\opera.exe") }
    @{ Key = '5'; Name = 'Brave';   Url = 'brave://extensions';   Proc = 'brave';
       Paths = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
                 "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe") }
    @{ Key = '6'; Name = 'Other';   Url = '';                     Proc = ''; Paths = @() }
  )

  # ---- Step 1 of 5: pick a browser ----
  Clear-Host
  Write-Mid '=== Load unpacked  -  step 1 of 5 ===' 'Cyan'
  Write-Host ''
  Write-Mid 'Which browser are you installing into?' 'White'
  Write-Host ''
  foreach ($b in $browsers) { Write-MidSeg @( @{T = "[$($b.Key)] "; C = 'Green' }, @{T = $b.Name; C = 'White' } ) }
  Write-Host ''
  $sel = (Read-Host ((' ' * (Get-Margin)) + 'Choose your browser')).Trim()
  $browser = $browsers | Where-Object { $_.Key -eq $sel } | Select-Object -First 1
  if (-not $browser) { $browser = $browsers[-1] }   # anything else -> Other

  # ---- Step 2 of 5: open the extensions page (URL to clipboard) ----
  Clear-Host
  Write-Mid '=== Load unpacked  -  step 2 of 5 ===' 'Cyan'
  Write-Host ''
  Write-Mid ('Open the extensions page in ' + $browser.Name) 'White'
  Write-Host ''
  if ($browser.Url) {
    try { Set-Clipboard -Value $browser.Url } catch {}
    Write-Mid ('Copied to clipboard:   ' + $browser.Url) 'Green'
    Write-Host ''
    Write-Mid 'Click the address bar, press Ctrl+V, then Enter.' 'Gray'
  } else {
    Write-Mid 'Go to your browser extensions page' 'Gray'
    Write-Mid '(Chromium browsers: usually  <name>://extensions ).' 'Gray'
  }
  Write-Host ''
  Read-Host ((' ' * (Get-Margin)) + 'Press Enter (or y) when the page is open') | Out-Null

  # ---- Step 3 of 5: developer mode ----
  Clear-Host
  Write-Mid '=== Load unpacked  -  step 3 of 5 ===' 'Cyan'
  Write-Host ''
  Write-Mid 'Turn ON "Developer mode"' 'White'
  Write-Host ''
  Write-Mid 'It is the toggle in the top-right of the page.' 'Gray'
  Write-Mid 'One-time - it stays on.' 'Gray'
  Write-Host ''
  Read-Host ((' ' * (Get-Margin)) + 'Press Enter (or y) when Developer mode is on') | Out-Null

  # ---- Step 4 of 5: Load unpacked, paste the folder ----
  try { Set-Clipboard -Value $src } catch {}
  Clear-Host
  Write-Mid '=== Load unpacked  -  step 4 of 5 ===' 'Cyan'
  Write-Host ''
  Write-Mid 'Click "Load unpacked", then paste the folder' 'White'
  Write-Host ''
  Write-Mid ('Copied to clipboard:   ' + $src) 'Green'
  Write-Host ''
  Write-Mid 'In the folder picker, press Ctrl+V then Enter.' 'Gray'
  Write-Mid 'Keep that folder in place - the browser reloads it each launch.' 'Gray'
  Write-Host ''
  Read-Host ((' ' * (Get-Margin)) + 'Press Enter (or y) when the extension has loaded') | Out-Null

  # ---- Step 5 of 5: restart the browser (auto or manual) ----
  Clear-Host
  Write-Mid '=== Load unpacked  -  step 5 of 5 ===' 'Cyan'
  Write-Host ''
  Write-Mid 'Restart your browser to finish first-time pairing' 'White'
  Write-Host ''
  Write-Mid 'A plain "Reload" is NOT enough - restart the whole browser once.' 'Gray'
  Write-Host ''
  $canKill = $browser.Proc -and (Get-Process -Name $browser.Proc -ErrorAction SilentlyContinue)
  if ($canKill) {
    Write-MidSeg @( @{T = '[Y] '; C = 'Green' },  @{T = ('Close and reopen ' + $browser.Name + ' for me now'); C = 'White' } )
    Write-MidSeg @( @{T = '[N] '; C = 'Yellow' }, @{T = 'I will restart it myself'; C = 'White' } )
    Write-Host ''
    $ans = (Read-Host ((' ' * (Get-Margin)) + 'Choose')).Trim().ToLower()
    if ($ans -eq '' -or $ans -eq 'y') {
      Write-Host ''
      Write-Mid ('Closing ' + $browser.Name + '...') 'Yellow'
      foreach ($p in (Get-Process -Name $browser.Proc -ErrorAction SilentlyContinue)) { try { $p.CloseMainWindow() | Out-Null } catch {} }
      Start-Sleep -Seconds 3
      $still = Get-Process -Name $browser.Proc -ErrorAction SilentlyContinue
      if ($still) { try { $still | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Seconds 1 }
      $exe = $browser.Paths | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($exe) { Start-Process $exe; Write-Mid ($browser.Name + ' reopened.') 'Green' }
      else { Write-Mid ('Now open ' + $browser.Name + ' again.') 'Gray' }
    } else {
      Write-Host ''
      Write-Mid ('Fully quit ' + $browser.Name + ' (close every window), then open it again.') 'Gray'
    }
  } else {
    Write-Mid 'Fully quit your browser (close every window), then open it again.' 'Gray'
  }

  Write-Host ''
  Write-Mid 'Done! Open the toolbar button; on a saved site it should fill.' 'Cyan'
  Write-Mid "If it doesn't fill yet, unlock 1Password 4 and restart the browser." 'Gray'
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
        Remove-ItemProperty -Path $key -Name $n; Write-Mid ("Removed forcelist entry [" + $n + "].") 'Gray'
      }
    }
    $rem = (Get-Item -Path $key).GetValueNames() | Where-Object { $_ -ne '' }
    if (-not $rem) { Remove-Item -Path $key -Force }
  }
  Restart-Chrome
  Write-Host ''
  Write-Mid 'Force-install policy removed.' 'Green'
}

# ---- main ----
[Net.ServicePointManager]::SecurityProtocol = `
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Set-ConsoleFont

# Elevated / non-interactive single action (set by -Mode when self-elevating).
if ($Mode) {
  try { $Host.UI.RawUI.WindowTitle = '1Password 4 Legacy Ext - MV3 Port' } catch {}
  $payload = Get-Payload
  switch ($Mode) {
    'force'     { Install-Force     $payload }
    'unpacked'  { Install-Unpacked  $payload }
    'uninstall' { Uninstall-Force   $payload }
  }
  Write-Host ''
  Read-Host ((' ' * (Get-Margin)) + 'Press Enter to close') | Out-Null
  return
}

# Interactive: dedicated-window menu that loops until [0] Quit.
try { $Host.UI.RawUI.WindowTitle = '1Password 4 Legacy Ext - MV3 Port' } catch {}
try {
  $payload = Get-Payload
} catch {
  Write-Host ''
  Write-Mid ('Error: ' + $_.Exception.Message) 'Red'
  Read-Host ((' ' * (Get-Margin)) + 'Press Enter to close') | Out-Null
  return
}

while ($true) {
  Clear-Host
  $inner = 60
  $bar   = '+' + ('=' * $inner) + '+'
  $title = '1Password 4 Legacy Ext - MV3 Port'
  $tp    = $inner - $title.Length; $lp = [int]($tp / 2); $rp = $tp - $lp
  Write-Host ''
  Write-Mid $bar 'Cyan'
  Write-MidSeg @( @{T = '|'; C = 'Cyan' }, @{T = (' ' * $lp) + $title + (' ' * $rp); C = 'White' }, @{T = '|'; C = 'Cyan' } )
  Write-Mid $bar 'Cyan'
  Write-Host ''
  $rows = @(
    @{ Key = '[1]'; KeyColor = 'Green';  Label = 'Load unpacked'; Hint = 'recommended - any PC, no admin' },
    @{ Key = '[2]'; KeyColor = 'Yellow'; Label = 'Force install'; Hint = 'no dev-mode nag, managed devices only' },
    @{ Key = '[3]'; KeyColor = 'Yellow'; Label = 'Uninstall';     Hint = 'remove the force-install policy' },
    @{ Key = '[0]'; KeyColor = 'Red';    Label = 'Quit';          Hint = '' }
  )
  $labelW = 15; $first = $true
  foreach ($r in $rows) {
    if (-not $first) { Write-Host '' }   # blank line = ~1 line gap (a console's minimum step)
    $first = $false
    Write-Host (' ' * (Get-Margin)) -NoNewline
    Write-Host $r.Key -ForegroundColor $r.KeyColor -NoNewline
    Write-Host (' ' + $r.Label.PadRight($labelW)) -ForegroundColor White -NoNewline
    Write-Host $r.Hint -ForegroundColor Gray
  }
  Write-Host ''
  $choice = (Read-Host ((' ' * (Get-Margin)) + 'Choose')).Trim().ToLower()
  if ($choice -eq '0' -or $choice -eq 'q') { break }
  if ($choice -notin '1', '2', '3') { continue }
  try {
    switch ($choice) {
      '1' { Install-Unpacked $payload }
      '2' { Install-Force    $payload }
      '3' { Uninstall-Force  $payload }
    }
  } catch {
    Write-Host ''
    Write-Mid ('Error: ' + $_.Exception.Message) 'Red'
  }
  Write-Host ''
  Read-Host ((' ' * (Get-Margin)) + 'Press Enter to return to the menu') | Out-Null
}
