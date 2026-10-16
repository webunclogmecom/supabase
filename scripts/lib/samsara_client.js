// samsara_client.js: the one Samsara GET both collectors use (cron_samsara_locations_history.js, cron_samsara_tank_readings.js).
//   const samsara = samsaraClient({ fetch, sleep, token });   // functions, read on every call (tests swap them)
//   await samsara.get('/fleet/...?...')                        -> parsed JSON
//   await samsara.paged('/readings/...?...', { pauseMs })     -> every page's data[], in order
// get(): 60 s timeout per request. Retries 429 (Retry-After, else 2 s), any 5xx, and a network error or timeout,
// 3 attempts in all (5 s then 10 s back-off). Why: on 2026-10-13/14 one Samsara 504 on /readings/history failed
// three tank-readings runs and Railway mailed "Deploy Crashed". Anything else, or the 3rd failure, throws.
// paged(): follows pagination.endCursor; past pageCap pages it THROWS, never returns a partial window (a partial
// window would let a data-derived cursor move past the rest).
// Check: scripts/lib/samsara_client.test.js (and both collectors' tests run through it).
function samsaraClient({ fetch, sleep, token, attempts = 3, timeoutMs = 60000 }) {
  async function get(path) {
    for (let attempt = 1; ; attempt++) {
      let r, body;
      try {   // the body read is inside: a reset or timeout after the headers is a network error too
        r = await fetch('https://api.samsara.com' + path, { signal: AbortSignal.timeout(timeoutMs),
          headers: { Authorization: 'Bearer ' + token(), Accept: 'application/json' } });
        if (!((r.status === 429 || r.status >= 500) && attempt < attempts)) body = await r.text();
      } catch (e) {
        if (attempt < attempts) { await sleep(5000 * attempt); continue; }
        throw e;
      }
      if (r.status === 429 && attempt < attempts) { await sleep((Number(r.headers.get('retry-after')) || 2) * 1000); continue; }
      if (r.status >= 500 && attempt < attempts) { await sleep(5000 * attempt); continue; }
      if (!r.ok) throw new Error(`Samsara HTTP ${r.status} on ${path.split('?')[0]}: ${body.slice(0, 200)}`);
      return JSON.parse(body);
    }
  }
  async function paged(path, { pauseMs = 0, pageCap = 1000 } = {}) {
    const out = [];
    let after = '', pages = 0;
    do {
      if (pauseMs) await sleep(pauseMs);
      const j = await get(path + (after ? '&after=' + encodeURIComponent(after) : ''));
      out.push(...(j.data || []));
      after = j.pagination?.hasNextPage ? j.pagination.endCursor : '';
      if (++pages > pageCap) throw new Error('page cap hit on ' + path.split('?')[0]);
    } while (after);
    return out;
  }
  return { get, paged };
}

module.exports = { samsaraClient };
