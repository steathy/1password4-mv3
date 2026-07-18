<#
  seed-op4.ps1 - first-run fix for machines where the extension connects but never
  registers (service-worker log stops at "connected to port 6263", no reply).

  ROOT CAUSE (found by reverse-engineering Agile1pAgent.exe): 1Password 4 verifies
  the connecting browser's Authenticode code-signature and only accepts browsers
  whose signer name matches a hardcoded list ("Google Inc", "Vivaldi Technologies
  AS", "Microsoft Corporation"). Google renamed its signing certificate to "Google
  LLC" around 2018, so modern Chrome fails the check and the agent silently drops
  the connection. The check is controlled by the registry DWORD
  HKCU\Software\AgileBits\1Password 4\VerifyCodeSignature  (0 = skip the check).
  Machines that set up a browser years ago have it = 0 already; a fresh machine
  lacks it and defaults to "verify", which blocks Chrome (and any other browser
  whose signer name is not on the list). Setting it to 0 accepts every browser.

  This sets VerifyCodeSignature = 0 and restarts 1Password + its agent so the new
  value takes effect. No admin needed (HKCU only). ASCII-only for PowerShell 5.1.

  Run:  powershell -ExecutionPolicy Bypass -File .\seed-op4.ps1
#>
$ErrorActionPreference = 'Stop'
$key = 'HKCU:\Software\AgileBits\1Password 4'

if (-not (Test-Path $key)) {
  Write-Host "!! $key not found - install and run 1Password 4 once, then re-run." -ForegroundColor Red
  return
}

$cur = (Get-ItemProperty $key -ErrorAction SilentlyContinue).VerifyCodeSignature
if ($cur -eq 0) {
  Write-Host "VerifyCodeSignature is already 0 (code-signature check disabled)." -ForegroundColor Yellow
} else {
  Set-ItemProperty -Path $key -Name 'VerifyCodeSignature' -Value 0 -Type DWord
  Write-Host "Set VerifyCodeSignature = 0 (was: $(if ($null -eq $cur) {'<not set>'} else {$cur}))." -ForegroundColor Green
}

# The agent (Agile1pAgent.exe) reads this at startup and is a SEPARATE long-lived
# process - quitting 1Password alone does not restart it. Kill both so the agent
# re-reads the setting; 1Password relaunches the agent when you reopen it.
Write-Host "Restarting 1Password + agent so the change takes effect..."
Stop-Process -Name '1Password','Agile1pAgent' -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Host ""
Write-Host "Done. Now:" -ForegroundColor Cyan
Write-Host "  1) Start 1Password 4 and UNLOCK it (it relaunches the agent)."
Write-Host "  2) " -NoNewline; Write-Host "Fully quit and reopen your browser" -ForegroundColor Yellow -NoNewline
Write-Host " (Chrome, Edge, or another"
Write-Host "     Chromium browser). A plain extension 'Reload' is NOT enough for the"
Write-Host "     first pairing - close every browser window, then start it again."
Write-Host "  3) The service worker console should then show"
Write-Host "     '[CHROME]: Established connection to 1Password'."
Write-Host ""
Write-Host "----- to undo later -----" -ForegroundColor DarkGray
Write-Host "Remove-ItemProperty -Path '$key' -Name VerifyCodeSignature" -ForegroundColor DarkGray
