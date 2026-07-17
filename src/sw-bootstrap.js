/*
 * sw-bootstrap.js — Manifest V3 service-worker shim for the legacy
 * 1Password 4 extension engine (global.min.js), which was written for a
 * persistent MV2 background page.
 *
 * Strategy (Approach A): polyfill the platform, not the app. We install the
 * few things a service worker lacks, then importScripts() the original engine
 * verbatim. global.min.js and ext/sjcl.js are byte-for-byte the shipped files.
 *
 * The engine only needs three accommodations, all verified by static scan:
 *   1. `window`            — used only as `window.OnePassword`, `window.location`,
 *                            `window.URL`, `window.webkitURL`; all valid via `self`.
 *   2. `chrome.browserAction` — MV3 renamed it to `chrome.action`.
 *   3. blocking webRequest — MV3 dropped it for non-policy extensions. The engine
 *                            registers one blocking listener on `*onepasswdfill=*`
 *                            that (a) schedules an autofill and (b) returns a
 *                            redirect. We keep (a) by re-registering it as a plain
 *                            observer and move (b) to a static declarativeNetRequest
 *                            rule (rules/onepasswdfill.json).
 */

'use strict';

/* 1. window → self ---------------------------------------------------------- */
// Resolves window.OnePassword / window.location / window.URL / window.webkitURL.
self.window = self;

/* 2. chrome.browserAction → chrome.action ----------------------------------- */
// The engine calls browserAction.onClicked / .enable() / .disable(); the MV3
// action API is a drop-in for those three uses.
if (chrome.action && !chrome.browserAction) {
  chrome.browserAction = chrome.action;
}

/* 3. Neutralize blocking webRequest ----------------------------------------- */
// Strip the 'blocking' extraInfoSpec from any webRequest listener the engine
// registers, so the registration succeeds as a passive observer instead of
// throwing under MV3. The engine's onBeforeRequest handler still runs and still
// schedules the autofill (its return value is simply ignored); the actual URL
// redirect is performed by the static DNR rule.
(function stripBlockingWebRequest() {
  const wr = chrome.webRequest;
  if (!wr) return;
  const events = [
    'onBeforeRequest',
    'onBeforeSendHeaders',
    'onHeadersReceived',
    'onAuthRequired',
  ];
  for (const name of events) {
    const ev = wr[name];
    if (!ev || typeof ev.addListener !== 'function') continue;
    const orig = ev.addListener.bind(ev);
    const patched = function (cb, filter, extraInfoSpec) {
      if (Array.isArray(extraInfoSpec)) {
        extraInfoSpec = extraInfoSpec.filter((s) => s !== 'blocking');
        if (extraInfoSpec.length === 0) extraInfoSpec = undefined;
      }
      return extraInfoSpec === undefined
        ? orig(cb, filter)
        : orig(cb, filter, extraInfoSpec);
    };
    try {
      ev.addListener = patched;
      if (ev.addListener !== patched) throw new Error('addListener not writable');
    } catch (e) {
      try {
        Object.defineProperty(ev, 'addListener', {
          value: patched,
          configurable: true,
          writable: true,
        });
      } catch (e2) {
        console.error('[1P-MV3] failed to patch webRequest.' + name, e2);
      }
    }
  }
})();

/* 4. contextMenus.create({onclick}) → contextMenus.onClicked ----------------- */
// MV3 dropped the `onclick` property on contextMenus.create. The engine creates
// its "1Password" menu item with an inline onclick; capture that handler, strip
// the property so create() succeeds, and dispatch it from a single onClicked
// listener keyed by menu id.
(function shimContextMenuOnclick() {
  const cm = chrome.contextMenus;
  if (!cm || typeof cm.create !== 'function') return;
  const handlers = new Map();
  let counter = 0;
  const origCreate = cm.create.bind(cm);
  cm.create = function (props, cb) {
    if (props && typeof props.onclick === 'function') {
      props = Object.assign({}, props);
      const onclick = props.onclick;
      delete props.onclick;
      if (props.id === undefined || props.id === null) {
        props.id = 'op-cm-' + ++counter;
      }
      handlers.set(props.id, onclick);
      return origCreate(props, cb);
    }
    return origCreate(props, cb);
  };
  cm.onClicked.addListener(function (info, tab) {
    const h = handlers.get(info.menuItemId);
    if (h) {
      try {
        h(info, tab);
      } catch (e) {
        console.error('[1P-MV3] contextMenu handler error', e);
      }
    }
  });
})();

/* 5. Quiet benign runtime errors from the engine ---------------------------- */
// Two harmless console errors the engine produces; neither affects fill/save.
//   * chrome.windows.get(id, {windowTypes:['normal']}, cb) fails whenever a
//     NON-normal window gains focus (the DevTools window, the popup, etc.), so the
//     callback receives `undefined` and the engine's `win.focused` read throws
//     ("Cannot read properties of undefined (reading 'focused')" / "No window with
//     id"). Hand it a benign stub so the read is a harmless no-op.
//   * chrome.tabs.sendMessage to a tab with no content script (chrome:// pages,
//     ad-excluded frames) logs "Could not establish connection. Receiving end does
//     not exist." because the engine's callback never reads lastError. Consume it.
(function quietBenignErrors() {
  const w = chrome.windows;
  if (w && typeof w.get === 'function') {
    const origGet = w.get.bind(w);
    w.get = function (id, queryOrCb, cb) {
      let query, callback;
      if (typeof queryOrCb === 'function') callback = queryOrCb;
      else { query = queryOrCb; callback = cb; }
      if (typeof callback !== 'function') {
        return query === undefined ? origGet(id) : origGet(id, query);
      }
      const wrapped = function (win) {
        if (chrome.runtime.lastError || win == null) {
          void chrome.runtime.lastError; // consume
          win = { id: id, focused: false, type: 'normal', tabs: [] };
        }
        callback(win);
      };
      return query === undefined ? origGet(id, wrapped) : origGet(id, query, wrapped);
    };
  }

  const t = chrome.tabs;
  if (t && typeof t.sendMessage === 'function') {
    const origSend = t.sendMessage.bind(t);
    t.sendMessage = function (...args) {
      const last = args[args.length - 1];
      if (typeof last === 'function') {
        args[args.length - 1] = function () {
          void chrome.runtime.lastError; // consume "receiving end does not exist"
          return last.apply(this, arguments);
        };
        return origSend.apply(null, args);
      }
      return origSend.apply(null, args.concat(function () {
        void chrome.runtime.lastError;
      }));
    };
  }
})();

/* Load the original engine (unmodified). ------------------------------------ */
try {
  importScripts('ext/sjcl.js', 'global.min.js');
  console.info('[1P-MV3] engine loaded');
} catch (e) {
  console.error('[1P-MV3] engine failed to load', e);
}

/* 5. Bypass the retired agilebits.com pairing page -------------------------- */
// First-time pairing: the desktop app sends an `authNew` message carrying a
// `code`. The engine's register() does `h ? r.Yb() : this.tb()` — with a code it
// opens https://agilebits.com/browsers/auth.html purely to DISPLAY that code for
// the user to eyeball; without one it calls tb() and self-completes. That domain
// is dead (NXDOMAIN), so a fresh pairing stalls on the load-unpacked/first run.
//
// Crucially, the code is never sent back to the app: whether or not the page
// shows it, pairing completes with the identical wire message
// `authRegister {extId, method, secret}` (register -> tb -> Agent.Rc). The page
// was browser-side UX only; the app does not verify the code. Stripping it from
// the incoming authNew makes register() take the no-page branch and self-complete
// — byte-for-byte the same protocol the original auto-confirming page produced.
(function bypassDeadPairingPage() {
  const AH = self.AgentHandlers;
  if (!AH || typeof AH.authNew !== 'function') {
    console.warn('[1P-MV3] AgentHandlers.authNew missing; pairing bypass inactive');
    return;
  }
  const origAuthNew = AH.authNew;
  AH.authNew = function (a) {
    if (a && a.code != null) {
      console.info('[1P-MV3] first-run pairing: stripping display code to self-complete (agilebits.com page retired)');
      delete a.code;
    }
    return origAuthNew.call(this, a);
  };
  // Suppress the (also-dead) first-run welcome page so it doesn't open an error tab.
  try {
    chrome.storage.local.set({ welcomeScreenShown: 1 });
  } catch (e) {
    /* ignore */
  }
})();

/* Keep-alive ---------------------------------------------------------------- */
// The engine holds the authenticated session and derived encryption keys in
// memory. As a password manager paired with a local desktop app it expects the
// persistent-background-page lifetime it had under MV2. Poll a trivial chrome
// API on an interval to reset the service worker's idle timer while it runs. If
// the worker is ever terminated anyway, any extension event (page navigation via
// the content script, toolbar click, etc.) revives it and the engine's own
// reconnect logic re-establishes the session.
(function keepAlive() {
  const PING_MS = 20000; // under Chrome's 30s idle window
  const ping = () => {
    try {
      chrome.runtime.getPlatformInfo(() => void chrome.runtime.lastError);
    } catch (e) {
      // ignore
    }
    setTimeout(ping, PING_MS);
  };
  setTimeout(ping, PING_MS);
})();
