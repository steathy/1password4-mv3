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

## Install for real (packed .crx, no developer-mode nag)

Once it works in dev, package it and install via the Windows registry so Chrome
stops nagging and can't silently disable it.

```powershell
# from the repo root
powershell -ExecutionPolicy Bypass -File .\build\pack.ps1
```

This produces, in `build/`:

- `onepassword-mv3.crx` — the signed package.
- `key.pem` — the signing key (**keep it**; it fixes the extension ID). Gitignored.
- `install.reg` — registry keys that install the `.crx` for all users.
- `allowed_origins.snippet.txt` — the packed extension's ID to add to the native
  host.

Then:

1. `reg import build\install.reg` (elevated) and restart Chrome.
2. The packed build is signed with **your** key, so its ID differs from the
   original. Add the `chrome-extension://<id>/` line from
   `allowed_origins.snippet.txt` to the `allowed_origins` array of the native host
   manifest (`2bua8c4s2c.com.agilebits.1password`). The host manifest's path is the
   `(Default)` value under
   `HKCU\Software\Google\Chrome\NativeMessagingHosts\2bua8c4s2c.com.agilebits.1password`
   (or the `HKLM` equivalent).

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
build/                  packaging + install tooling (artifacts gitignored)
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
