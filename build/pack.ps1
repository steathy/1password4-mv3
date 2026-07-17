<#
  pack.ps1 - Build a signed .crx of the MV3 port and set it up for a Chrome
  *force-install* (Windows), which installs with no developer-mode nag and cannot
  be disabled by the user. Force-installed extensions are exempt from Chrome's
  "Web Store only" block, unlike a plain external-extension (local crx) install.

  Produces in build\:
    onepassword-mv3.crx     - the signed extension (KEEP where it is; the policy
                              points at this exact path)
    key.pem                 - signing key (KEEP; it fixes the extension ID). Gitignored.
    updates.xml             - Omaha update manifest the policy fetches the crx from
    forcelist-install.reg   - HKCU policy (no admin needed on a personal machine)
    forcelist-install-hklm.reg - HKLM policy (needs admin; use if HKCU is ignored)
    forcelist-uninstall.reg - removes the policy again

  Usage:
    powershell -ExecutionPolicy Bypass -File .\build\pack.ps1
    (optionally: -Chrome "C:\Path\To\chrome.exe")

  The DEV workflow (Load unpacked ..\src) needs none of this. The packed build is
  signed with OUR key, so it gets a different extension ID than the unpacked one
  and re-pairs itself once on first run (automatic via the bootstrap's pairing
  bypass). After it works, remove the load-unpacked copy so you don't run two.
#>
param(
  [string]$Chrome = "",
  [string]$SrcDir = "$PSScriptRoot\..\src",
  [string]$BuildDir = "$PSScriptRoot"
)
$ErrorActionPreference = "Stop"

function Find-Chrome {
  if ($Chrome -and (Test-Path $Chrome)) { return $Chrome }
  $c = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $c) { throw "chrome.exe not found. Pass -Chrome 'C:\path\to\chrome.exe'." }
  return $c
}
function To-FileUrl([string]$p) { 'file:///' + ($p -replace '\\', '/') }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw "node not found on PATH (needed to compute the extension ID)."
}
$chromeExe = Find-Chrome
$SrcDir   = (Resolve-Path $SrcDir).Path
$BuildDir = (Resolve-Path $BuildDir).Path
$staging  = Join-Path $BuildDir "staging"
$keyPem   = Join-Path $BuildDir "key.pem"
$crxOut   = Join-Path $BuildDir "onepassword-mv3.crx"
$updates  = Join-Path $BuildDir "updates.xml"
$version  = (Get-Content (Join-Path $SrcDir "manifest.json") -Raw | ConvertFrom-Json).version

Write-Host "Chrome:  $chromeExe"
Write-Host "Source:  $SrcDir  (v$version)"

# 1. Stage a copy of src with the "key" field stripped so the crx ID comes
#    unambiguously from our signing key.
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
Copy-Item -Recurse -Force $SrcDir $staging
& node -e "const fs=require('fs');const p=process.argv[1];const m=JSON.parse(fs.readFileSync(p,'utf8'));delete m.key;fs.writeFileSync(p,JSON.stringify(m,null,2));" (Join-Path $staging "manifest.json")

# 2. Pack (generate key.pem on first run, reuse thereafter).
$packedCrx = "$staging.crx"; $packedPem = "$staging.pem"
if (Test-Path $packedCrx) { Remove-Item -Force $packedCrx }
if (Test-Path $keyPem) {
  & $chromeExe --pack-extension="$staging" --pack-extension-key="$keyPem" | Out-Null
} else {
  & $chromeExe --pack-extension="$staging" | Out-Null
  if (Test-Path $packedPem) { Move-Item -Force $packedPem $keyPem; Write-Host "Generated signing key: $keyPem  (KEEP THIS)" }
}
if (-not (Test-Path $packedCrx)) { throw "Chrome did not produce $packedCrx" }
Move-Item -Force $packedCrx $crxOut
Remove-Item -Recurse -Force $staging
Write-Host "Packed:  $crxOut"

# 3. Extension ID from the signing key.
$id = (& node (Join-Path $BuildDir "compute-id.js") $keyPem "--id-only").Trim()
Write-Host "Ext ID:  $id"

# 4. Update manifest (Omaha gupdate) that the force-install policy fetches from.
$crxUrl = To-FileUrl $crxOut
@"
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$id'>
    <updatecheck codebase='$crxUrl' version='$version' />
  </app>
</gupdate>
"@ | Set-Content -Path $updates -Encoding UTF8
Write-Host "Wrote:   $updates"

# 5. Force-install policy .reg files. Value form: "<id>;<update-manifest-url>".
$policyVal = "$id;" + (To-FileUrl $updates)
function Write-Reg([string]$file, [string]$root) {
@"
Windows Registry Editor Version 5.00

[$root\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist]
"1"="$policyVal"
"@ | Set-Content -Path $file -Encoding ASCII
}
Write-Reg (Join-Path $BuildDir "forcelist-install.reg")      "HKEY_CURRENT_USER"
Write-Reg (Join-Path $BuildDir "forcelist-install-hklm.reg") "HKEY_LOCAL_MACHINE"
@"
Windows Registry Editor Version 5.00

[-HKEY_CURRENT_USER\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist]
[-HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist]
"@ | Set-Content -Path (Join-Path $BuildDir "forcelist-uninstall.reg") -Encoding ASCII
Write-Host "Wrote:   forcelist-install.reg (+ -hklm, + -uninstall)"

Write-Host ""
Write-Host "Next:"
Write-Host "  1) reg import `"$(Join-Path $BuildDir 'forcelist-install.reg')`""
Write-Host "     (no admin). Fully restart Chrome (chrome://restart)."
Write-Host "  2) 1Password appears on chrome://extensions as 'Installed by policy'."
Write-Host "     It re-pairs itself once. Then remove the Load-unpacked copy."
Write-Host "  If it does NOT appear: reg import the -hklm.reg from an elevated prompt."
Write-Host "  Do not move/delete onepassword-mv3.crx or updates.xml - the policy points at them."