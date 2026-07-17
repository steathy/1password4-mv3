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

/* Load the original engine (unmodified). ------------------------------------ */
try {
  importScripts('ext/sjcl.js', 'global.min.js');
  console.info('[1P-MV3] engine loaded');
} catch (e) {
  console.error('[1P-MV3] engine failed to load', e);
}

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
