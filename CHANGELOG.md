# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project uses
[Semantic Versioning](https://semver.org/). (The version here is the *port's*
release version; the bundled extension keeps its own `4.7.5.90` manifest version.)

## [1.0.2] - 2026-07-17

### Changed
- **Load-unpacked is now the recommended install; force-install is documented as
  enterprise-managed-only.** Testing on a second PC showed Chrome refuses to
  policy-install any off-Web-Store extension on a device that isn't enterprise
  managed (`chrome://policy` reports `[BLOCKED]` / *"not detected as enterprise
  managed"*) — so self-hosted force-install (whether `file://` or https) can't work
  on a normal personal machine. The installer now:
  - lists **Load unpacked** first as `[1]` (recommended, works on any PC);
  - detects a non-managed device before force-installing and offers to switch to
    load-unpacked instead of silently producing a blocked policy.
- README documents the managed-device requirement and the Chrome Browser Cloud
  Management route for those who want the no-nag force-install anyway.

## [1.0.1] - 2026-07-17

### Fixed
- **Force install now works reliably on a fresh machine.** The previous release
  pointed the `ExtensionInstallForcelist` policy at a local `file://` update
  manifest, which many Chrome builds silently reject — so the policy was set but
  nothing installed. The crx and its `updates.xml` are now served over **https from
  GitHub**, which Chrome accepts (verified `Content-Type: application/octet-stream`).
  As a bonus, force-install no longer needs any local file to persist.
- **Chrome restart in the installer.** `chrome.exe chrome://restart` only opened a
  new window instead of restarting; the installer now gracefully closes and relaunches
  Chrome so the policy is actually applied.

### Changed
- `dist/updates.xml` is now a committed static manifest (https crx codebase);
  `build/pack.ps1` regenerates it and takes `-Owner/-Repo/-Branch`.

## [1.0.0] - 2026-07-16

First working release. The legacy 1Password 4 extension loads and works in current
Chrome under Manifest V3, talking to an unmodified 1Password 4 desktop app. Verified
on 1Password 4.6.1.618 (Windows 10).

### Added
- **Manifest V3 port** of the 1Password 4 (v4.7.5.90) extension. The 1Password
  engine (`global.min.js`, `ext/sjcl.js`, `injected.min.js`) ships byte-for-byte;
  all MV3 work lives in `src/sw-bootstrap.js`:
  - `window → self` shim; `chrome.browserAction → chrome.action` alias.
  - Strips the `blocking` flag from the engine's `webRequest` listener; the app
    "open-and-fill" redirect is reproduced with a static `declarativeNetRequest`
    rule (`src/rules/onepasswdfill.json`).
  - Shims `contextMenus.create({onclick})` onto `contextMenus.onClicked`.
  - Keep-alive so the authenticated session survives the service-worker idle timer.
- **First-run pairing without the retired `agilebits.com` page.** The bootstrap
  strips the display `code` from the incoming `authNew` so the engine self-completes
  pairing (the code was browser-side UX only; the app never verifies it). Chrome
  pairs under its own extension ID, so it runs concurrently with Edge/Vivaldi.
- **Console cleanup:** guards for benign `chrome.windows.get` (non-normal-window
  focus) and `chrome.tabs.sendMessage` (no content-script) errors.
- **One-command installer** (`install.ps1`): run via `irm … | iex` or from a clone;
  menu offers force-install (policy, no dev-mode nag), load-unpacked, or uninstall.
  Self-elevates only for the registry step.
- **Packaging** (`build/pack.ps1`, `build/compute-id.js`): builds the signed crx and
  refreshes `dist/`. Committed `dist/onepassword-mv3.crx` makes installs build-tool-free.
- **`original/1Password-4.7.5.90.crx`**: the unmodified original MV2 extension, for
  reference and for use in browsers that still accept MV2.
- Design notes in `docs/design.md`; `LICENSE` (MIT, for original work) and `NOTICE`
  (third-party components).

### Notes
- Windows transport is WebSocket (`ws://127.0.0.1`); 1Password 4 ships no
  native-messaging host on Windows, so the native-messaging attempt always falls
  back — cosmetic, no performance impact.

[1.0.2]: https://github.com/steathy/1password4-mv3/releases/tag/v1.0.2
[1.0.1]: https://github.com/steathy/1password4-mv3/releases/tag/v1.0.1
[1.0.0]: https://github.com/steathy/1password4-mv3/releases/tag/v1.0.0
