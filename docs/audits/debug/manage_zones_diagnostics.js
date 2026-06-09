// manage_zones_diagnostics.js
//
// Paste this whole file into the browser DevTools console (F12 → Console tab)
// while on calendar.unclogme.app OR the Lovable sandbox/preview URL.
//
// What it does:
//   1. Installs global error listeners so anything thrown after this point is
//      captured into window.__zonesDebug.errors (incl. promise rejections,
//      console.error calls, runtime exceptions).
//   2. Patches React Query so every query/mutation result lands in
//      window.__zonesDebug.queries with the cache key + data + status.
//   3. Inspects the current Manage Zones modal DOM and reports row counts,
//      input counts, error elements, and React error boundary state.
//   4. Fetches public.zones_with_usage directly via PostgREST so you can
//      compare what's IN the DB vs what's RENDERED.
//   5. Captures the build hash from the loaded JS bundle so we know exactly
//      which version is misbehaving.
//
// After pasting:
//   - Open the Manage Zones modal (click gear next to FILTER BY ZONE).
//   - Try editing a code or triggering whatever's broken.
//   - In the console run:  zonesDebug.report()
//   - Copy the resulting JSON and paste it back into chat with Claude.

(() => {
  if (window.zonesDebug?.installed) {
    console.warn('[zonesDebug] already installed. Run zonesDebug.report() instead.');
    return;
  }

  const DB = {
    errors: [],
    queries: [],
    installed: true,
    installed_at: new Date().toISOString(),
  };
  window.__zonesDebug = DB;

  // ─── 1. Global error capture ───────────────────────────────────────────────
  window.addEventListener('error', (e) => {
    DB.errors.push({
      kind: 'window.error',
      time: new Date().toISOString(),
      msg: e.message,
      file: e.filename,
      line: e.lineno,
      col: e.colno,
      stack: e.error?.stack?.split('\n').slice(0, 12).join('\n'),
    });
  });
  window.addEventListener('unhandledrejection', (e) => {
    DB.errors.push({
      kind: 'unhandledrejection',
      time: new Date().toISOString(),
      reason: String(e.reason),
      stack: e.reason?.stack?.split('\n').slice(0, 12).join('\n'),
    });
  });
  const origConsoleError = console.error;
  console.error = function (...args) {
    try {
      DB.errors.push({
        kind: 'console.error',
        time: new Date().toISOString(),
        args: args.map((a) => {
          try {
            if (a instanceof Error) return { _error: a.message, stack: a.stack?.split('\n').slice(0, 10).join('\n') };
            if (typeof a === 'object') return JSON.parse(JSON.stringify(a, (k, v) => (typeof v === 'function' ? '[fn]' : v))).valueOf?.() ?? String(a).slice(0, 800);
            return String(a).slice(0, 800);
          } catch {
            return String(a).slice(0, 800);
          }
        }),
      });
    } catch {}
    return origConsoleError.apply(this, args);
  };

  // ─── 2. React Query inspection ─────────────────────────────────────────────
  // React Query attaches its devtools globals when QueryClient.mount() runs.
  // Find it by walking React fiber tree from a known root.
  function findQueryClient() {
    const reactRoot = document.getElementById('root') || document.body.firstElementChild;
    if (!reactRoot) return null;
    const key = Object.keys(reactRoot).find((k) => k.startsWith('__reactContainer$'));
    if (!key) return null;
    let fiber = reactRoot[key]?.stateNode?.current;
    if (!fiber) return null;
    // BFS down the tree looking for a fiber whose memoizedState has a QueryClient
    const queue = [fiber];
    const seen = new WeakSet();
    let i = 0;
    while (queue.length && i++ < 5000) {
      const node = queue.shift();
      if (!node || seen.has(node)) continue;
      seen.add(node);
      const probe = node.memoizedProps || node.memoizedState;
      if (probe) {
        const client = probe.client || probe.queryClient || probe.value?.client;
        if (client && typeof client.getQueryCache === 'function') return client;
      }
      if (node.child) queue.push(node.child);
      if (node.sibling) queue.push(node.sibling);
    }
    return null;
  }

  // ─── 3. DOM inspection of the Manage Zones modal ──────────────────────────
  function inspectModal() {
    const dlg = document.querySelector('[role="dialog"]');
    if (!dlg) return { dialog_open: false };
    return {
      dialog_open: true,
      dialog_text_first_300: dlg.innerText?.slice(0, 300),
      dialog_children: dlg.children.length,
      inner_html_bytes: dlg.innerHTML.length,
      input_count: dlg.querySelectorAll('input').length,
      button_count: dlg.querySelectorAll('button').length,
      // Row candidates — common patterns shadcn / Tailwind grids use
      grid_row_candidates: dlg.querySelectorAll('[class*="grid-cols"]').length,
      tr_count: dlg.querySelectorAll('tr').length,
      li_count: dlg.querySelectorAll('li').length,
      grip_handle_count: dlg.querySelectorAll('[class*="grip" i]').length,
      // Look for error-y elements
      error_classes: [...dlg.querySelectorAll('[class*="error" i], [class*="destructive" i]')].slice(0, 5).map((el) => el.outerHTML.slice(0, 200)),
      // The "no rows" state usually has a placeholder
      empty_state_text: [...dlg.querySelectorAll('p, span, div')].filter((el) => /no\s+(zones|rows|data|results)/i.test(el.innerText || '')).map((el) => el.innerText?.slice(0, 100)),
    };
  }

  // ─── 4. Direct DB fetch for comparison ────────────────────────────────────
  async function fetchZonesFromDB() {
    // Try to find the supabase client on the page
    let anon = null;
    let url = null;
    // 1) check window.supabase
    if (window.supabase?.supabaseUrl && window.supabase?.supabaseKey) {
      anon = window.supabase.supabaseKey;
      url = window.supabase.supabaseUrl;
    }
    // 2) try scanning script for the anon JWT
    if (!anon) {
      const allScriptText = [...document.querySelectorAll('script')]
        .map((s) => s.innerText)
        .join('\n');
      const m = allScriptText.match(/eyJhbGciOi[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/);
      if (m) {
        anon = m[0];
        url = 'https://wbasvhvvismukaqdnouk.supabase.co';
      }
    }
    if (!anon || !url) {
      return { error: 'Could not extract anon key from page. Set zonesDebug.anonKey = "<your key>" before running.' };
    }
    if (window.zonesDebug?.anonKey) anon = window.zonesDebug.anonKey;

    try {
      const r = await fetch(`${url}/rest/v1/zones_with_usage?select=*&order=sort_order`, {
        headers: { apikey: anon, Authorization: `Bearer ${anon}` },
      });
      const text = await r.text();
      let parsed;
      try { parsed = JSON.parse(text); } catch { parsed = text; }
      return {
        status: r.status,
        row_count: Array.isArray(parsed) ? parsed.length : null,
        first_row_keys: Array.isArray(parsed) && parsed.length ? Object.keys(parsed[0]) : null,
        sample: Array.isArray(parsed) ? parsed.slice(0, 2) : parsed,
      };
    } catch (e) {
      return { error: String(e?.message || e) };
    }
  }

  // ─── 5. React Query cache snapshot ────────────────────────────────────────
  function snapshotQueries() {
    const client = findQueryClient();
    if (!client) return { error: 'QueryClient not found on page' };
    try {
      const all = client.getQueryCache().getAll();
      return all
        .filter((q) => JSON.stringify(q.queryKey).match(/zone/i))
        .map((q) => ({
          key: q.queryKey,
          state: q.state.status,
          error: q.state.error?.message,
          updated_at: q.state.dataUpdatedAt && new Date(q.state.dataUpdatedAt).toISOString(),
          row_count: Array.isArray(q.state.data) ? q.state.data.length : (q.state.data ? 1 : 0),
          first_row_keys: Array.isArray(q.state.data) && q.state.data[0] ? Object.keys(q.state.data[0]) : null,
          sample_row: Array.isArray(q.state.data) ? q.state.data[0] : null,
        }));
    } catch (e) {
      return { error: String(e?.message || e) };
    }
  }

  // ─── 6. Build / bundle info ───────────────────────────────────────────────
  function buildInfo() {
    const scripts = [...document.querySelectorAll('script[src]')].map((s) => s.src);
    const main = scripts.filter((s) => s.match(/(index|main|bundle).*\.js$/));
    return {
      url: location.href,
      user_agent: navigator.userAgent.slice(0, 120),
      time: new Date().toISOString(),
      script_count: scripts.length,
      main_chunks: main.slice(0, 10),
    };
  }

  // ─── 7. Public report API ─────────────────────────────────────────────────
  window.zonesDebug = {
    installed: true,
    installed_at: DB.installed_at,
    errors: DB.errors,
    anonKey: null, // set this if the auto-extract fails

    async report() {
      const out = {
        installed_at: DB.installed_at,
        report_at: new Date().toISOString(),
        build: buildInfo(),
        modal: inspectModal(),
        queries: snapshotQueries(),
        db_fetch: await fetchZonesFromDB(),
        errors_count: DB.errors.length,
        errors: DB.errors.slice(-20), // last 20 errors
      };
      const json = JSON.stringify(out, null, 2);
      console.log('%c=== zonesDebug.report() ===', 'background:#E85A1F;color:#fff;padding:4px 8px;font-weight:bold');
      console.log(json);
      try {
        await navigator.clipboard.writeText(json);
        console.log('%c✓ Report copied to clipboard. Paste into chat with Claude.', 'color:#1E7F4F;font-weight:bold');
      } catch {
        console.log('%c⚠ Could not auto-copy. Manually copy the JSON above.', 'color:#B07A1E');
      }
      return out;
    },

    clearErrors() {
      DB.errors.length = 0;
      console.log('[zonesDebug] errors cleared.');
    },
  };

  console.log('%c✓ zonesDebug installed.', 'background:#1E7F4F;color:#fff;padding:4px 8px;font-weight:bold');
  console.log('Now reproduce the bug, then run:  zonesDebug.report()');
  console.log('Or just inspect:  zonesDebug.errors  /  await zonesDebug.report()');
})();
