# 1Password 4 Legacy Extension → Manifest V3 Port

**Date:** 2026-07-16
**Status:** Design approved, pending spec review

## Goal

Make the legacy 1Password browser extension (v4.7.5.90, Manifest V2) load and
function in current Chrome (Manifest V3), while preserving compatibility with the
1Password **4.6.1.618** desktop app on Windows 10. The desktop app is deliberately
retained because it is the last version supporting local/Dropbox vault sync. The
same extension already works in MS Edge and Vivaldi; only Chrome broke it (MV2
sunset).

Success = fill and save logins in Chrome against the running 4.6.1 desktop app,
including the app-initiated "open-and-fill" deep link.

## Source material

Unpacked legacy extension at `E:\projects\1pass-chrome-ext\1Password-4.7.5.90\`:

- `manifest.json` — MV2, `background.scripts = [ext/sjcl.js, global.min.js]`,
  persistent background page.
- `global.min.js` (189 KB) — the background engine: transport, crypto glue,
  connection auth, fill/save orchestration.
- `ext/sjcl.js` — Stanford JS Crypto Library.
- `injected.min.js` (42 KB) + `fillStyle.css` — content script (page fill/save UI).
- `assets/` — toolbar + store icons.

### Key facts established during investigation

- **Background code is service-worker-friendly.** No `document`, no `localStorage`,
  no `XMLHttpRequest`, no `indexedDB`. It already uses `chrome.storage.local`,
  WebSocket, and native messaging.
- **Only `window.*` references:** `window.OnePassword` (namespace assignment),
  `window.location`, `window.URL`, `window.webkitURL` — all valid in a worker via
  `self`, covered by a one-line shim.
- **Two transports to the desktop app**, both surviving into MV3:
  - Native messaging host `2bua8c4s2c.com.agilebits.1password` (primary).
  - WebSocket fallback `ws://127.0.0.1:{6263,10196,14826,24866,25012,38156,46365,49806,55735,59488}/4`.
- **Content script → background messaging** uses standard
  `chrome.runtime.sendMessage`/`onMessage` (unchanged in MV3).
- **One genuinely removed API:** blocking `chrome.webRequest` redirect of
  `*onepasswdfill=*` (the app "open-and-fill" deep link). MV3 removed blocking
  webRequest for non-policy extensions.

## Scope decisions (approved)

- **Full fidelity.** Rebuild the "open-and-fill" deep link on
  `declarativeNetRequest` so every original feature works.
- **Policy / registry install** on Windows (no dev-mode nag, ID pinned by our
  signing key).
- **Approach A** — platform shim, original `global.min.js` left untouched. We
  "polyfill the platform, not the app."

### Correction carried into the design

A self-packed `.crx` receives an extension ID derived from **our** signing key, not
1Password's original (we hold their public `key`, not their private signing key, so
the original ID is not reproducible). This is acceptable: the native-messaging host
manifest is a JSON file on the user's own machine, so we add our ID to its
`allowed_origins`. The WebSocket transport authenticates via handshake and is likely
ID-agnostic, providing a fallback.

## Architecture (Approach A)

We change the platform under the code, not the code. One new hand-written file
(`sw-bootstrap.js`) plus a rewritten `manifest.json`; everything else is copied
verbatim from the legacy extension.

### Component 1 — Manifest V3 rewrite

- `manifest_version: 3`.
- `background: { service_worker: "sw-bootstrap.js" }` (no `type: module` — we use
  `importScripts`).
- `browser_action` → `action` (same icons/title).
- Permissions split: `permissions` (`contextMenus`, `nativeMessaging`, `storage`,
  `tabs`, `declarativeNetRequest`, `webRequest`) and `host_permissions`
  (`http://*/*`, `https://*/*`).
- `webRequestBlocking` removed; `declarativeNetRequest` added.
- Keep the `key` field (stable ID for dev load-unpacked).
- `content_scripts` block and `fillStyle.css` copied verbatim.

### Component 2 — `sw-bootstrap.js` (only new logic)

Runs before the imports:

1. **Global shim:** `self.window = self;` — resolves `window.OnePassword`,
   `window.location`, `window.URL`, `window.webkitURL`.
2. **API alias:** `self.chrome.browserAction = self.chrome.action;` — resolves the
   original `enable/disable/onClicked` calls.
3. **webRequest→DNR bridge:** wrap `chrome.webRequest.onBeforeRequest.addListener`
   so that when `global.min.js` registers its blocking `*onepasswdfill=*` redirect,
   we intercept the registration and route it through Component 3 instead of the
   (absent) blocking engine.
4. **contextMenus.onclick shim:** MV3 dropped the `onclick` property on
   `contextMenus.create`; the engine uses it for its "1Password" menu item. We
   wrap `create`, strip `onclick`, and dispatch it from a single
   `contextMenus.onClicked` listener keyed by menu id. (Found during the API scan;
   not in the original design.)

Then `importScripts('ext/sjcl.js', 'global.min.js')`.

*API-scan result:* every other API the engine touches survives into MV3 —
`chrome.tabs` (create/query/update/sendMessage/onUpdated), `chrome.windows`,
`chrome.storage.local`, `chrome.contextMenus.removeAll`, `chrome.runtime`
(connectNative/getPlatformInfo/onMessage returning `true` for async). No
`chrome.extension`, `chrome.notifications`, `tabs.executeScript`, `insertCSS`,
`XMLHttpRequest`, `document`, or `localStorage`.

### Component 3 — "Open-and-fill" deep link on declarativeNetRequest

**Simplified after reading the engine.** The lookup function `r.yb(url)` turned out
to be fully self-contained: it parses `onepasswdfill` (the item UUID) and
`onepasswdvault` straight out of the incoming URL's own query string, and the clean
redirect target is just that same URL with those two params removed. There is **no
separate "announce" step to hook** and **no runtime-varying token→URL mapping**.

That collapses the design to two static pieces:

1. **A single static DNR rule** ([`src/rules/onepasswdfill.json`](../src/rules/onepasswdfill.json)):
   redirect any `main_frame` request whose URL contains `onepasswdfill=`, using a
   `queryTransform.removeParams` of `["onepasswdfill", "onepasswdvault"]`. Removing
   the params means the redirected URL no longer matches, so there is no loop and no
   dynamic-rule bookkeeping.
2. **The engine's own listener, kept as an observer.** `sw-bootstrap.js` strips the
   `'blocking'` flag from the engine's `onBeforeRequest` registration. The handler
   still fires and still calls `r.kb(...)` to schedule the autofill (its side
   effect); only its now-ignored `{redirectUrl}` return is superseded by the DNR
   rule. `global.min.js` is not modified.

This is strictly simpler and more robust than the originally-planned dynamic session
rules.

### Component 7 — First-run pairing without the retired agilebits.com page

**Discovered during testing.** A *fresh* install (no cached pairing, unlike Edge/
Vivaldi which paired years ago) must complete the first-time pairing handshake. The
engine drives that by opening `https://agilebits.com/browsers/auth.html` — a domain
1Password retired after rebranding, so the tab dies with `DNS_PROBE_FINISHED_NXDOMAIN`
and pairing stalls. (This is transport-agnostic and not MV3-specific; it would break
on any current browser doing a fresh pair.)

Tracing the engine settled what that page actually does:

- The app sends `authNew` with a `code`. `register()` runs
  `h ? r.Yb() : this.tb()` — with a code it opens the page **only to display the
  code** for the user to eyeball; without a code it calls `tb()` and self-completes.
- The code is **never echoed back to the app**. Both paths finish pairing with the
  identical wire message `authRegister {extId, method, secret}` (`register → tb →
  Agent.Rc`). The page's `authCodeReady` reply just calls the same `tb()`. So the
  app does not verify the code — it is browser-side UX only.

**Fix (in `sw-bootstrap.js`, no engine edit):** after `importScripts`, wrap the
globally-exposed `self.AgentHandlers.authNew` to delete the `code` before the engine
sees it. `register()` then takes the no-page branch and self-completes, producing
byte-for-byte the same handshake the original auto-confirming page produced. The
(also-dead) first-run welcome page is suppressed by pre-setting `welcomeScreenShown`.

*Security note:* the discarded code was an anti-phishing visual check (compare the
browser's code against the app's). On a local single-user machine pairing a known
extension, dropping it is acceptable; the encrypted channel's security rests on the
per-pairing `secret`, which is unaffected.

*Alternative considered:* copying an already-paired browser's `chrome.storage.local`
credential (`OPExtensionIdentifier` + `extSecret`) into Chrome. Rejected as the
default because it makes Chrome share another browser's `extId`, so the two cannot
connect to 1Password concurrently. The bypass gives Chrome its own identity.

### Component 4 — Service-worker lifecycle / keep-alive

The authenticated session and derived `payloadKey` live in memory
(`ConnectionAuthenticator`). SW termination loses them and forces a re-handshake
(`authBegin`/`authVerify`) on wake. Mitigations:

- An open native-messaging port / WebSocket normally keeps the worker alive.
- Add a lightweight keep-alive (`chrome.alarms` heartbeat and/or reliance on the
  connection's own traffic) as insurance against idle termination.
- If a re-handshake is ever needed, the original reconnect logic (`Xc`, port
  cycling, `pause().then(connect)`) already handles it — we lean on code built to
  reconnect.

### Component 5 — Transports (kept, unchanged)

Native messaging (`2bua8c4s2c.com.agilebits.1password`) and the `ws://127.0.0.1`
port-scan fallback both work from an MV3 SW. We change neither.

**Field finding (Windows): WebSocket is the only real transport.** On the test
machine, 1Password 4.6.1 (`D:\Program Files (x86)\1Password 4\`) ships **no
native-messaging host** — no host manifest JSON anywhere in the install, and
`Agile1pAgent.exe` (the process listening on port 6263) contains none of the
native-messaging markers (`allowed_origins`, `nativeMessaging`, `stdin`,
`NativeMessagingHosts`); it is purely a WebSocket server. The extension's
`connectNative` attempt is macOS-oriented code that on Windows always fails with
"Specified native messaging host not found." and falls back to `ws://127.0.0.1` —
in Chrome, Edge, and Vivaldi alike. The resulting console lines are cosmetic and
one-time-per-connect, with no performance cost. Consequences:

- There is nothing to register for native messaging, and no `allowed_origins` to
  edit, so **Component 6's ID-authorization step is unnecessary on Windows** — the
  packed `.crx` build (different signing-key ID) connects over WebSocket regardless
  of ID.
- The WebSocket handshake authenticates by the `extId`/`extSecret` pairing, not the
  Chrome extension ID.

### Component 6 — Install + ID authorization (Windows)

1. Generate a `.pem` once; pack a `.crx`; record the resulting stable ID.
2. Install via registry external-extension keys
   (`HKLM\SOFTWARE\Google\Chrome\Extensions\<id>` → `path` + `version`): no dev-mode
   nag, not casually disableable.
3. Add `<id>` to the native-messaging host manifest's `allowed_origins` so native
   messaging authorizes us. (WebSocket auth is handshake-based, likely ID-agnostic —
   fallback while the native path is sorted.)

## Directory layout

```
E:\projects\1pass-chrome-ext\
  1Password-4.7.5.90\          # untouched legacy source (reference)
  1password-mv3-port\
    src\                       # the MV3 extension (loadable / packable)
      manifest.json            # new (v3)
      sw-bootstrap.js          # new
      global.min.js            # copied verbatim
      injected.min.js          # copied verbatim
      fillStyle.css            # copied verbatim
      ext\sjcl.js              # copied verbatim
      assets\                  # copied verbatim
    build\                     # packed .crx + .pem + registry .reg script
  docs\superpowers\specs\
    2026-07-16-1password-mv3-port-design.md
```

## Testing strategy

1. **Load-unpacked** first (fast iterate) with the dev ID temporarily added to the
   native host `allowed_origins`.
2. In the SW devtools console, confirm the worker reaches 1Password 4.6.1
   (connection/`welcome`), then verify fill and save on a real login page.
3. Verify the deep link: app "open-and-fill" redirects and autofills.
4. Pack `.crx`, registry-install, confirm the packed-ID path end-to-end.
5. **Edge/Vivaldi remain the reference oracle** for correct behavior throughout.

## Risks / open questions

- **SW idle termination vs. session keys** — primary risk; mitigated by keep-alive
  and the existing reconnect path. Confirm empirically.
- **WebSocket to `ws://127.0.0.1` from an MV3 SW** — expected to work (extension
  origin is exempt from Private Network Access); confirm.
- **DNR redirect timing** — the announce step must land before navigation. Confirm
  ordering against the real app.
- **Native host `allowed_origins` editability** — assumed writable by the user
  (their own machine); confirm the file path/permissions.
- **No git repo yet** — `E:\projects\1pass-chrome-ext` is not initialized;
  design doc not yet committed.

## Non-goals

- Publishing to the Chrome Web Store (that is AgileBits' listing).
- Supporting 1Password 7/8 or account-based (non-local) vaults.
- Rewriting the fill/save/crypto engine.
