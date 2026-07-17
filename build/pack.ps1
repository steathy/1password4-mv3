<#
  pack.ps1 - Build a signed .crx of the MV3 port and emit the Windows registry
  script + native-messaging snippet needed to install it without the
  developer-mode nag.

  What it does:
    1. Stages a copy of ..\src with the manifest "key" field removed, so the
       packed extension's ID is derived unambiguously from OUR signing key
       (build\key.pem), not from 1Password's original public key.
    2. Packs the staged copy into build\onepassword-mv3.crx, signing with
       build\key.pem (generated on first run and reused thereafter).
    3. Computes the resulting extension ID (via compute-id.js).
    4. Writes build\install.reg (registry external-extension install) and
       build\allowed_origins.snippet.txt (the ID to add to the native host).

  Usage:
    powershell -ExecutionPolicy Bypass -File .\build\pack.ps1
    (optionally: -Chrome "C:\Path\To\chrome.exe")

  Note: the DEV workflow (load unpacked from ..\src) does NOT need this script.
  Packing is only for the no-nag registry install once the extension works.
#>
param(
  [string]$Chrome = "",
  [string]$SrcDir = "$PSScriptRoot\..\src",
  [string]$BuildDir = "$PSScriptRoot"
)
$ErrorActionPreference = "Stop"

function Find-Chrome {
  if ($Chrome -and (Test-Path $Chrome)) { return $Chrome }
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  throw "chrome.exe not found. Pass -Chrome 'C:\path\to\chrome.exe'."
}

$node = (Get-Command node -ErrorAction SilentlyContinue)
if (-not $node) { throw "node not found on PATH (needed to compute the extension ID)." }

$chromeExe = Find-Chrome
$SrcDir   = (Resolve-Path $SrcDir).Path
$BuildDir = (Resolve-Path $BuildDir).Path
$staging  = Join-Path $BuildDir "staging"
$keyPem   = Join-Path $BuildDir "key.pem"
$crxOut   = Join-Path $BuildDir "onepassword-mv3.crx"

Write-Host "Chrome:  $chromeExe"
Write-Host "Source:  $SrcDir"
Write-Host "Build:   $BuildDir"

# 1. Stage a copy of src with the "key" field stripped from the manifest.
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
Copy-Item -Recurse -Force $SrcDir $staging
$stripJs = @"
const fs=require('fs');const p=process.argv[1];const m=JSON.parse(fs.readFileSync(p,'utf8'));delete m.key;fs.writeFileSync(p,JSON.stringify(m,null,2));
"@
& node -e $stripJs (Join-Path $staging "manifest.json")
Write-Host "Staged (key stripped): $staging"

# 2. Pack. Chrome writes <dir>.crx and, if no key is supplied, <dir>.pem.
$packedCrx = "$staging.crx"
$packedPem = "$staging.pem"
if (Test-Path $packedCrx) { Remove-Item -Force $packedCrx }

if (Test-Path $keyPem) {
  & $chromeExe --pack-extension="$staging" --pack-extension-key="$keyPem" | Out-Null
} else {
  & $chromeExe --pack-extension="$staging" | Out-Null
  if (Test-Path $packedPem) {
    Move-Item -Force $packedPem $keyPem
    Write-Host "Generated signing key: $keyPem  (KEEP THIS - it fixes the extension ID)"
  }
}
if (-not (Test-Path $packedCrx)) { throw "Chrome did not produce $packedCrx" }
Move-Item -Force $packedCrx $crxOut
Write-Host "Packed:  $crxOut"

# 3. Compute the extension ID from the signing key.
$id = (& node (Join-Path $BuildDir "compute-id.js") $keyPem "--id-only").Trim()
Write-Host "Ext ID:  $id"

# 4a. Registry external-extension install script.
$crxRegPath = $crxOut -replace '\\', '\\'
$reg = @"
Windows Registry Editor Version 5.00

; Installs the 1Password MV3 port for Chrome from a local .crx (no dev-mode nag).
; Run: reg import build\install.reg   (or double-click)  then restart Chrome.
[HKEY_LOCAL_MACHINE\SOFTWARE\Google\Chrome\Extensions\$id]
"path"="$crxRegPath"
"version"="4.7.5.90"
"@
$regFile = Join-Path $BuildDir "install.reg"
Set-Content -Path $regFile -Value $reg -Encoding ASCII
Write-Host "Wrote:   $regFile"

# 4b. Native-messaging allowed_origins snippet.
$snip = Join-Path $BuildDir "allowed_origins.snippet.txt"
@"
Add this origin to the "allowed_origins" array of the 1Password native-messaging
host manifest so native messaging authorizes the packed extension:

    "chrome-extension://$id/"

Host manifest is registered under one of:
    HKCU\Software\Google\Chrome\NativeMessagingHosts\2bua8c4s2c.com.agilebits.1password
    HKLM\Software\Google\Chrome\NativeMessagingHosts\2bua8c4s2c.com.agilebits.1password
The (Default) value there is the path to the host's .json manifest to edit.
"@ | Set-Content -Path $snip -Encoding ASCII
Write-Host "Wrote:   $snip"

Write-Host ""
Write-Host "Done. Next:"
Write-Host "  1) reg import `"$regFile`"   (elevated) then restart Chrome"
Write-Host "  2) add the origin from allowed_origins.snippet.txt to the native host manifest"
