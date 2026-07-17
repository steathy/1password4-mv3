# 1Password 4 extension — Manifest V3 port

A minimal Manifest V3 port of the legacy **1Password 4 (v4.7.5.90)** browser
extension — the one that pairs with the **1Password 4.6.1.618** desktop app (the
last desktop version supporting local / Dropbox vault sync). The original
extension still works in Edge and Vivaldi but stopped loading in Chrome after the
Manifest V2 sunset. This port makes it load and work in current Chrome again.

It talks to the **unmodified** desktop app over the same two transports the
original used — native messaging (`2bua8c4s2c.com.agilebits.1password`) and a
`ws://127.0.0.1` fallback — so no changes to 1Password 4.6.1 are required.

## How it works

The port follows one rule: **polyfill the platform, don't touch the app.** The
189 KB engine (`global.min.js`) and `ext/sjcl.js` are the shipped files,
byte-for-byte. Everything MV3-specific lives in one small file,
[`src/sw-bootstrap.js`](src/sw-bootstrap.js), which runs before the engine and:

1. Sets `self.window = self` — the engine's only `window` uses are
   `window.OnePassword`, `window.location`, `window.URL`, `window.webkitURL`, all
   valid in a service worker via `self`.
2. Aliases `chrome.browserAction` to the MV3 `chrome.action` API.
3. Strips the `'blocking'` flag from the engine's one blocking `webRequest`
   listener (MV3 removed blocking webRequest for non-policy extensions). The
   listener still runs and still schedules autofill; the URL redirect it used to
   do is handled instead by a static `declarativeNetRequest` rule
   ([`src/rules/onepasswdfill.json`](src/rules/onepasswdfill.json)) that strips
   the `onepasswdfill` / `onepasswdvault` params — reproducing the app's
   "open-and-fill" deep link.

Then it `importScripts()` the engine and starts a keep-alive so the authenticated
session to the desktop app survives the service worker's idle timer.

It also handles **first-run pairing**. A fresh install must pair with the desktop
app, and the engine does that by opening `agilebits.com/browsers/auth.html` — a
domain 1Password retired, so the page is dead. That page only *displayed* a
verification code; the code is never sent back to the app, and pairing completes
with the same `authRegister {extId, secret}` message either way. So the bootstrap
strips the `code` from the incoming `authNew` message, which makes the engine
self-complete the pairing with no page. See [`docs/design.md`](docs/design.md)
(Component 7) for the full trace.

## Quick start (development — no packaging)

This is the fastest way to test. Because `src/manifest.json` keeps 1Password's
original `key`, a load-unpacked install gets 1Password's **original extension ID**,
which the native-messaging host installed by 4.6.1 already authorizes — so native
messaging should work with no further setup.

1. Make sure 1Password **4.6.1.618** desktop is running and unlocked.
2. Chrome → `chrome://extensions` → enable **Developer mode**.
3. **Load unpacked** → select this repo's [`src/`](src/) folder.
4. Click **service worker** (the blue link on the extension's card) to open its
   DevTools console. You should see `[1P-MV3] engine loaded` and, shortly after,
   connection logs (`connected to port …` or a native-messaging `welcome`).
5. Go to a login page you have saved, and confirm the 1Password inline fill
   appears / the toolbar button fills. Save a new login to confirm the round trip.

If native messaging does not connect, the `ws://127.0.0.1` fallback should still
engage automatically; watch the console for `[AGENT:WS]` lines.

## Install (one command)

Open **Windows PowerShell** and run:

```powershell
irm https://raw.githubusercontent.com/YOUR_GH_USER/1password4-mv3/main/install.ps1 | iex
```

It downloads this repo, then shows a menu:

```
[1] Force install   (recommended; needs admin, no dev-mode nag, can't be disabled)
[2] Load unpacked   (no admin; you click 'Load unpacked' once)
[3] Uninstall       (remove force-install policy)
```

- **Force install** self-elevates (one UAC prompt), writes an `ExtensionInstallForcelist`
  policy pointing at the bundled signed crx, and restarts Chrome. `chrome://extensions`
  then shows 1Password as **"Installed by policy."** It re-pairs with the desktop app
  once (the packed build has its own extension ID). A plain local-crx install would be
  blocked by Chrome's "Web Store only" rule — force-installed extensions are exempt.
- **Load unpacked** stages the files under `%LOCALAPPDATA%\1Password4-MV3\src`, opens
  `chrome://extensions`, and copies the path to your clipboard; you flip on Developer
  mode and click **Load unpacked**. No admin.

> `irm … | iex` runs remote code — review [`install.ps1`](install.ps1) first if you like.
> The same script works from a local clone too: double-click **`install.bat`**.

No `allowed_origins` / native-messaging step is needed — on Windows the extension
connects over `ws://127.0.0.1`, which authenticates by pairing secret, not by
extension ID (see [`docs/design.md`](docs/design.md), Component 5).

**Uninstall:** menu option 3, or run [`uninstall.ps1`](uninstall.ps1).

**Rebuild after changing `src/`:** run `build\pack.ps1` (needs Chrome + Node). It
re-signs the crx and refreshes `dist/onepassword-mv3.crx` + `dist/extension.json`;
commit those and the one-command install picks them up.

> Publishing: set `$Owner` / `$Repo` / `$Branch` at the top of `install.ps1` to your
> GitHub repo before pushing, and use your account in the `irm` URL above.

## Layout

```
src/                    the loadable / packable MV3 extension
  manifest.json         MV3 manifest (keeps original key for dev)
  sw-bootstrap.js       the only hand-written logic (shims + import)
  rules/                declarativeNetRequest rule for the deep link
  global.min.js         1Password engine, unmodified
  injected.min.js       content script, unmodified
  ext/sjcl.js           crypto library, unmodified
  fillStyle.css         content-script styles, unmodified
  assets/               icons
build/                  pack.ps1 + compute-id.js (rebuild the crx; key.pem gitignored)
dist/                   committed install artifacts: signed crx + extension.json
install.ps1 / .bat      one-click force-install (self-elevating)
uninstall.ps1           remove the force-install policy
docs/                   design spec
```

## Status

**Working.** Loaded unpacked in current Chrome against 1Password 4.6.1 on Windows:
the service worker connects, first-run pairing self-completes (no dead page), and
fill/save work. Chrome pairs under its own `extId`, so it runs concurrently with the
existing Edge/Vivaldi installs.

Remaining: the no-dev-nag ship install (`build/pack.ps1` → `.crx` + registry).

## Known risks

- **Service-worker lifetime.** The engine keeps the session and derived keys in
  memory. A keep-alive holds the worker up while it runs; if Chrome terminates it
  anyway, the next page navigation revives it and the engine reconnects
  (re-handshake). Watch for reconnect churn in the console.
- **`ws://127.0.0.1` from a service worker** is expected to work (extension origin
  is exempt from Private Network Access); confirm on your setup.
- Not for the Chrome Web Store; not for 1Password 7/8 or account-based vaults.
  See [`docs/`](docs/) for the full design.
