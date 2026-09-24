// analytics-token-guard.js: stop Lovable's page tracker from sending sign-in tokens to its analytics.
//
// WHY. Lovable injects `/~flock.js` into every published app. About 300 ms after a page loads (and on
// every hashchange, pushState and popstate) it POSTs `window.location.href` to `/~api/analytics`. The
// URL a Google sign-in or a password-reset link lands on carries the session in its fragment
// (`#access_token=...&refresh_token=...&type=recovery`), and auth-js only clears it after a network
// round trip. Measured 2026-09-24 on planner, hub, clients and calendar with fake tokens: the tracker's
// POST carried the tokens every time, on the reset pages before auth-js had even started. Lovable has
// no setting to turn the tracker off.
//
// WHAT IT DOES. It does NOT touch the URL (auth-js must still read it, and so must each app's
// password-recovery detection). It wraps the three ways a page can send data (XMLHttpRequest, fetch,
// navigator.sendBeacon) and, for requests to `/~api/analytics` ONLY, replaces the value of every
// `access_token`, `refresh_token`, `provider_token`, `provider_refresh_token`, `token_hash` and `code`
// parameter with `redacted`. A body it cannot read as text is dropped (the tracker loses one page view,
// never a token). Every other request passes through untouched.
//
// HOW IT SHIPS. As the FIRST inline <script> in <head> of every staff app, byte-identical to the
// one-line `GUARD` printed by `node analytics-token-guard.test.mjs --print`. It must run before the
// tracker: the tracker is `defer`, so any plain inline script in the page runs first. The test
// (`analytics-token-guard.test.mjs`) proves the scrub, and `flock-race.mjs` proves it on the live apps.
(function () {
  if (window.__unclogmeAnalyticsGuard) return;
  window.__unclogmeAnalyticsGuard = true;
  var TOKENS = /([?#&])((?:access|refresh|provider|provider_refresh)_token|token_hash|code)=[^&#"'\\\s]*/g;
  function isAnalytics(u) {
    try { return String(u && u.url ? u.url : u).indexOf('/~api/analytics') !== -1 } catch (e) { return false }
  }
  function scrub(body) { return body.replace(TOKENS, '$1$2=redacted') }
  var X = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
  if (X) {
    var open = X.open, send = X.send;
    X.open = function (method, url) { this.__unclogmeAnalytics = isAnalytics(url); return open.apply(this, arguments) };
    X.send = function (body) {
      if (!this.__unclogmeAnalytics) return send.apply(this, arguments);
      if (typeof body !== 'string') return;
      return send.call(this, scrub(body));
    };
  }
  if (window.fetch) {
    var fetchOriginal = window.fetch;
    window.fetch = function (input, init) {
      if (!isAnalytics(input)) return fetchOriginal.apply(this, arguments);
      if (!init || typeof init.body !== 'string') return Promise.resolve(new Response(null, { status: 204 }));
      var copy = {};
      for (var k in init) copy[k] = init[k];
      copy.body = scrub(init.body);
      return fetchOriginal.call(this, input, copy);
    };
  }
  if (window.navigator && navigator.sendBeacon) {
    var beacon = navigator.sendBeacon.bind(navigator);
    navigator.sendBeacon = function (url, data) {
      if (!isAnalytics(url)) return beacon(url, data);
      return typeof data === 'string' ? beacon(url, scrub(data)) : true;
    };
  }
})();
