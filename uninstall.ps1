<#
  uninstall.ps1 - Remove the 1Password MV3 force-install policy.
  Thin wrapper around install.ps1's uninstall mode (self-elevates, restarts Chrome).
#>
& (Join-Path (Split-Path -Parent $PSCommandPath) 'install.ps1') -Mode uninstall
