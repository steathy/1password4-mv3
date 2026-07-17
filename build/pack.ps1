<#
  pack.ps1 - Build (or rebuild) the signed .crx and refresh the portable install
  artifacts in dist\. Run this only when you change something under src\.

  Outputs:
    dist\onepassword-mv3.crx  - the signed extension (committed; install.ps1 uses it)
    dist\extension.json       - { id, version } (committed; install.ps1 reads it)
    build\key.pem             - signing key (gitignored; KEEP - it fixes the ID)

  Installation is a separate one-click step: ..\install.ps1 (or install.bat).

  Usage:
    powershell -ExecutionPolicy Bypass -File .\build\pack.ps1
    (optionally: -Chrome "C:\Path\To\chrome.exe")

  Note: the crx is signed with build\key.pem. If key.pem is absent it is generated
  fresh, which CHANGES the extension ID (the extension then re-pairs once). Keep
  key.pem to preserve a stable ID across rebuilds.
#>
param(
  [string]$Chrome  = "",
  [string]$SrcDir  = "$PSScriptRoot\..\src",
  [string]$DistDir = "$PSScriptRoot\..\dist",
  # Where the crx will be served from (must match install.ps1). Change if you fork.
  [string]$Owner   = "steathy",
  [string]$Repo    = "1password4-mv3",
  [string]$Branch  = "main"
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
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw "node not found on PATH (needed to compute the extension ID)."
}

$chromeExe = Find-Chrome
$SrcDir    = (Resolve-Path $SrcDir).Path
if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Path $DistDir | Out-Null }
$DistDir   = (Resolve-Path $DistDir).Path
$BuildDir  = $PSScriptRoot
$staging   = Join-Path $BuildDir "staging"
$keyPem    = Join-Path $BuildDir "key.pem"
$crxOut    = Join-Path $DistDir "onepassword-mv3.crx"
$version   = (Get-Content (Join-Path $SrcDir "manifest.json") -Raw | ConvertFrom-Json).version

Write-Host "Chrome:  $chromeExe"
Write-Host "Source:  $SrcDir  (v$version)"

# 1. Stage src with the "key" stripped so the ID comes from our signing key.
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

# 3. Extension ID -> dist\extension.json.
$id = (& node (Join-Path $BuildDir "compute-id.js") $keyPem "--id-only").Trim()
@{ id = $id; version = $version } | ConvertTo-Json | Set-Content -Path (Join-Path $DistDir "extension.json") -Encoding UTF8
Write-Host "Ext ID:  $id  ->  dist\extension.json"

# 4. Update manifest served over https from GitHub (Chrome force-installs from it).
$crxUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/dist/onepassword-mv3.crx"
@"
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$id'>
    <updatecheck codebase='$crxUrl' version='$version' />
  </app>
</gupdate>
"@ | Set-Content -Path (Join-Path $DistDir "updates.xml") -Encoding UTF8
Write-Host "Wrote:   dist\updates.xml -> $crxUrl"
Write-Host ""
Write-Host "Commit dist\ and push, then install with:  .\install.ps1  (or install.bat)"
