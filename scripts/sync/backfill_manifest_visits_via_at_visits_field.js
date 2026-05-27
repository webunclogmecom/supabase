// Catch manifest_visits links the webhook missed because AT's "GT Last
// Visit" date drifted from the actual visit date (e.g. Chima Steakhouse
// 3/18 visit linked to a DERM record whose GT Last Visit was 4/20).
//
// Strategy:
//   1. For each AT DERM record, read its "Visits" field (AT visit GIDs).
//   2. For each AT visit GID, fetch the AT visit's date.
//   3. Find a matching Jobber-sourced visit in our DB: same client + same
//      date (or ±1 day for timezone slack).
//   4. INSERT manifest_visits link if missing.
//
// Per CLAUDE.md rules:
//   - manifest_visits PK = (visit_id, manifest_id), so on_conflict=do-nothing
//     keeps re-runs safe.
//   - Audit triggers fire automatically on manifest_visits INSERT.
//   - Never deletes, only adds.
//   - 3NF preserved.
//
// Run:
//   node scripts/sync/backfill_manifest_visits_via_at_visits_field.js
//   node scripts/sync/backfill_manifest_visits_via_at_visits_field.js --execute
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const EXECUTE = process.argv.includes('--execute');

const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' };

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}
async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}
async function atFetchAll(table, params = '') {
  const all = [];
  let offset = null;
  do {
    const qs = new URLSearchParams({ pageSize: '100' });
    if (offset) qs.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(table)}?${qs}${params}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    }).then(r => r.json());
    all.push(...(r.records || []));
    offset = r.offset;
  } while (offset);
  return all;
}
async function atFetchOne(table, id) {
  const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(table)}/${id}`, {
    headers: { Authorization: `Bearer ${AT_KEY}` },
  }).then(r => r.json());
  return r;
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  // 1) Pull all AT DERM records that have at least one Visits-field GID
  console.log('Pulling AT DERM table...');
  const derm = await atFetchAll('tblz0CnWim7ViFjcw');
  console.log(`  ${derm.length} AT DERM records`);

  // 2) Index DB derm_manifests by AT GID (via ESL)
  const eslMap = await rest('entity_source_links?entity_type=eq.derm_manifest&source_system=eq.airtable&select=entity_id,source_id&limit=10000');
  const dbIdByAtGid = {};
  for (const e of eslMap) dbIdByAtGid[e.source_id] = e.entity_id;

  // 3) Index DB visits by (client_id, visit_date). Filter to service_type='GT'
  // — DERM manifests are issued for grease-trap dumps only, so matching CL
  // (drain cleaning) or LS (lift station) visits causes false-positive links
  // that the DERM Tracker then shows on the wrong visit. Caught 2026-05-27
  // by a Claudie May 14 GT visit showing "Missing manifest" because its
  // manifest had been mis-linked to a same-week CL service call.
  const visits = (await sql(`SELECT id, client_id, visit_date::text FROM visits WHERE visit_status='completed' AND service_type='GT'`));
  const dbVisitByClientDate = {};
  for (const v of visits) {
    dbVisitByClientDate[`${v.client_id}|${v.visit_date}`] = v.id;
  }

  // 4) Existing links
  const existingLinks = await rest('manifest_visits?select=manifest_id,visit_id&limit=10000');
  const haveLink = new Set(existingLinks.map(l => `${l.manifest_id}|${l.visit_id}`));

  // 5) For each AT DERM with Visits, expand AT visit GIDs → dates → DB visit
  let candidates = 0, would_add = 0, skipped_have = 0, skipped_no_db = 0, skipped_no_at_visit = 0;
  const adds = [];
  const atVisitCache = {};

  for (const rec of derm) {
    const atVisits = rec.fields?.Visits || [];
    if (!atVisits.length) continue;
    const manifestDbId = dbIdByAtGid[rec.id];
    if (!manifestDbId) continue;

    // Get client from AT DERM
    const atClient = (rec.fields?.Client || [])[0];
    let dbClientId = null;
    if (atClient) {
      const r = await rest(`entity_source_links?entity_type=eq.client&source_system=eq.airtable&source_id=eq.${atClient}&select=entity_id`);
      if (r?.[0]) dbClientId = r[0].entity_id;
    }
    if (!dbClientId) continue;

    for (const visitGid of atVisits) {
      candidates++;
      let atVisit = atVisitCache[visitGid];
      if (!atVisit) {
        atVisit = await atFetchOne('Visits', visitGid);
        atVisitCache[visitGid] = atVisit;
      }
      const atDate = atVisit?.fields?.Date || atVisit?.fields?.['Visit Date'];
      if (!atDate) { skipped_no_at_visit++; continue; }

      // Look for DB visit at same client + date (±1 day fallback)
      const dates = [atDate];
      try {
        const d = new Date(atDate + 'T00:00:00Z');
        const dPrev = new Date(d); dPrev.setUTCDate(d.getUTCDate() - 1);
        const dNext = new Date(d); dNext.setUTCDate(d.getUTCDate() + 1);
        dates.push(dPrev.toISOString().slice(0,10), dNext.toISOString().slice(0,10));
      } catch {}

      let dbVisitId = null;
      for (const dt of dates) {
        const k = `${dbClientId}|${dt}`;
        if (dbVisitByClientDate[k]) { dbVisitId = dbVisitByClientDate[k]; break; }
      }
      if (!dbVisitId) { skipped_no_db++; continue; }

      const linkKey = `${manifestDbId}|${dbVisitId}`;
      if (haveLink.has(linkKey)) { skipped_have++; continue; }
      would_add++;
      adds.push({
        manifest_id: manifestDbId,
        visit_id: dbVisitId,
        at_derm: rec.id,
        at_visit: visitGid,
        at_visit_date: atDate,
      });
    }
  }

  console.log('\n=== Summary ===');
  console.table([
    { metric: 'AT-listed candidates', count: candidates },
    { metric: 'already linked',       count: skipped_have },
    { metric: 'no matching DB visit', count: skipped_no_db },
    { metric: 'AT visit lookup failed', count: skipped_no_at_visit },
    { metric: 'NEW links to add',     count: would_add },
  ]);

  if (adds.length) {
    console.log('\n=== Links to add (first 20) ===');
    console.table(adds.slice(0, 20));
  }

  if (!EXECUTE) {
    console.log('\n[DRY-RUN] Re-run with --execute to insert.');
    return;
  }

  console.log(`\nInserting ${adds.length} new links...`);
  let inserted = 0, failed = 0;
  for (const a of adds) {
    try {
      await rest('manifest_visits', {
        method: 'POST',
        headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
        body: JSON.stringify({ manifest_id: a.manifest_id, visit_id: a.visit_id }),
      });
      inserted++;
    } catch (e) {
      console.warn(`  fail (${a.manifest_id} ↔ ${a.visit_id}):`, e.message?.slice(0, 100));
      failed++;
    }
  }
  console.log(`\nInserted: ${inserted}, failed: ${failed}`);
})().catch(err => { console.error('FATAL:', err); process.exit(1); });
