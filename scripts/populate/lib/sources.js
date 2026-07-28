// ============================================================================
// sources.js — Pull live data from Airtable, Samsara, Fillout into memory
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../../.env') });
const https = require('https');

// ----------------------------------------------------------------------------
// HTTPS GET helper
// ----------------------------------------------------------------------------
function httpsGet(host, path, headers) {
  return new Promise((res, rej) => {
    https.request({ hostname: host, path, headers }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 200 && r.statusCode < 300) {
          try { res(JSON.parse(d)); } catch (e) { rej(new Error('bad json: ' + d.slice(0, 300))); }
        } else rej(new Error(`HTTP ${r.statusCode} ${host}${path}: ${d.slice(0, 300)}`));
      });
    }).on('error', rej).end();
  });
}

// ----------------------------------------------------------------------------
// AIRTABLE
// ----------------------------------------------------------------------------
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const AT_HDR = { Authorization: `Bearer ${AT_KEY}` };

async function airtableFetchAll(tableNameOrId) {
  const all = [];
  let offset = null, pages = 0;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await httpsGet('api.airtable.com', `/v0/${AT_BASE}/${encodeURIComponent(tableNameOrId)}?${q}`, AT_HDR);
    all.push(...(r.records || []));
    offset = r.offset;
    pages++;
    if (pages > 50) break;
  } while (offset);
  return all;
}

// ⚠ AIRTABLE IS RETIRED (2026-07-24). This function now FAILS LOUDLY instead of returning data.
//
// It is kept (rather than deleted) only because `scripts/populate/populate.js` still imports it by
// name, so removing the export would break that script's require() at load time. It must never
// silently succeed: every one of those eight `airtableFetchAll()` calls would now come back EMPTY
// (the fetch helper returns [] on a non-200), so the old body would have printed
// "clients=0 visits=0 derm=0 …" and handed populate.js an empty-but-valid dataset. A bulk populate
// fed empty upstream data reads as "Airtable had nothing to add" rather than "Airtable is gone" —
// and this is the initial-population path, so the blast radius is the whole warehouse.
//
// Throwing is the correct behaviour: there is no valid way to complete an Airtable pull today, and a
// caller that wants Airtable data has a bug that should surface at the call site, immediately.
// Do NOT restore the body. Jobber + Samsara are the sources (CLAUDE.md rule 4).
async function pullAirtable() {
  throw new Error(
    'pullAirtable() is retired: Airtable was fully decommissioned 2026-07-24 and every table read ' +
    'would return empty, which is indistinguishable from "no new records". Use Jobber/Samsara ' +
    '(CLAUDE.md rule 4). If you hit this from populate.js, drop the Airtable stage from that run.'
  );
}

// ----------------------------------------------------------------------------
// SAMSARA
// ----------------------------------------------------------------------------
const SAM_TOKEN = process.env.SAMSARA_API_TOKEN;
const SAM_HDR = { Authorization: `Bearer ${SAM_TOKEN}` };

async function samsaraFetchAll(path) {
  const all = [];
  let after = null, pages = 0;
  do {
    const sep = path.includes('?') ? '&' : '?';
    const p = path + (after ? `${sep}after=${encodeURIComponent(after)}` : '');
    const r = await httpsGet('api.samsara.com', p, SAM_HDR);
    all.push(...(r.data || []));
    after = r.pagination && r.pagination.hasNextPage && r.pagination.endCursor ? r.pagination.endCursor : null;
    pages++;
    if (pages > 50) break;
  } while (after);
  return all;
}

async function pullSamsara() {
  console.log('  → Samsara...');
  const [vehicles, addresses, drivers] = await Promise.all([
    samsaraFetchAll('/fleet/vehicles?limit=100'),
    samsaraFetchAll('/addresses?limit=512'),
    samsaraFetchAll('/fleet/drivers?limit=100'),
  ]);
  console.log(`    vehicles=${vehicles.length} addresses=${addresses.length} drivers=${drivers.length}`);
  return { vehicles, addresses, drivers };
}

module.exports = { pullAirtable, pullSamsara };
