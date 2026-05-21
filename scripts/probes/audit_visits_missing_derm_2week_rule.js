// Per Fred's 2-week rule (CLAUDE.md 2026-05-22):
//   any completed visit >2 weeks old that needs DERM SHOULD have a
//   manifest_visits row pointing at a derm_manifests record with both
//   PDF URLs. Missing → data gap.
//
// This probe surfaces every such gap AND tries to find a matching AT
// DERM record by (client + date) — using the same 3 cross-references
// Fred uses manually:
//   1. AT DERM Visits field (preferred — already covered by sister script)
//   2. AT DERM client filter (via Client Code #3 lookup)
//   3. AT DERM date proximity (GT Last Visit OR Date Dump Ticket ±14 days)
//
// Output: for each gap, the matching AT DERM record(s) — Fred can eyeball
// and trigger an insert if confident.
//
// Read-only probe. To act on findings, use:
//   scripts/sync/backfill_manifest_visits_via_at_visits_field.js
//   (or insert manually via REST with proper audit trail).
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function rest(qs) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { headers: H });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  return r.json();
}
async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}
async function atDerm() {
  const all = [];
  let offset = null;
  do {
    const qs = new URLSearchParams({ pageSize: '100' });
    if (offset) qs.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/tblz0CnWim7ViFjcw?${qs}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    }).then(r => r.json());
    all.push(...(r.records || []));
    offset = r.offset;
  } while (offset);
  return all;
}

function daysBetween(a, b) {
  return Math.abs((new Date(a + 'T00:00:00Z') - new Date(b + 'T00:00:00Z')) / 86400000);
}

(async () => {
  // 1) DB visits that SHOULD have DERM per the 2-week rule
  const twoWeeksAgo = new Date(Date.now() - 14 * 86400000).toISOString().slice(0, 10);
  console.log(`Cutoff: visits on or before ${twoWeeksAgo}\n`);

  const gaps = await sql(`
    SELECT v.id, v.visit_date::text, c.client_code, c.name AS client_name,
           v.title, v.service_type
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    WHERE v.visit_status = 'completed'
      AND v.visit_date <= '${twoWeeksAgo}'
      AND COALESCE(v.derm_required, true) = true
      AND v.service_type IN ('GT')
      AND NOT EXISTS (SELECT 1 FROM manifest_visits mv WHERE mv.visit_id = v.id)
    ORDER BY v.visit_date DESC;
  `);

  console.log(`${gaps.length} GT visits >2 weeks old missing DERM link\n`);

  if (!gaps.length) {
    console.log('🎯 Clean — every GT visit older than 2 weeks has its DERM link.');
    return;
  }

  // 2) Pull AT DERM + index by AT client GID
  console.log('Pulling AT DERM table...');
  const atRecs = await atDerm();
  // Index: db_client_id → [AT records]
  const atByClient = {};
  const eslMap = await rest('entity_source_links?entity_type=eq.client&source_system=eq.airtable&select=entity_id,source_id&limit=10000');
  const dbByAtGid = {};
  for (const e of eslMap) dbByAtGid[e.source_id] = e.entity_id;
  for (const r of atRecs) {
    const atClient = (r.fields?.Client || [])[0];
    if (!atClient) continue;
    const dbCid = dbByAtGid[atClient];
    if (!dbCid) continue;
    if (!atByClient[dbCid]) atByClient[dbCid] = [];
    atByClient[dbCid].push(r);
  }

  // 3) For each gap visit, find AT DERM candidates by client + date ±14d
  const findings = [];
  for (const g of gaps) {
    const clientId = (await rest(`clients?client_code=eq.${encodeURIComponent(g.client_code)}&select=id`).then(r => r[0]))?.id;
    const ats = (clientId && atByClient[clientId]) || [];
    const candidates = [];
    for (const r of ats) {
      const gtLast = r.fields?.['GT Last Visit'];
      const dump = r.fields?.['Date Dump Ticket'];
      let best = Infinity, src = null;
      if (gtLast) {
        const d = daysBetween(gtLast, g.visit_date);
        if (d < best) { best = d; src = 'GT Last Visit'; }
      }
      if (dump) {
        const d = daysBetween(dump, g.visit_date);
        if (d < best) { best = d; src = 'Dump Ticket'; }
      }
      if (best <= 30) {
        candidates.push({
          at_id: r.id,
          at_src: src,
          at_days_off: Math.round(best),
          at_yellow: r.fields?.['Yellow Ticket #'] || r.fields?.['White Manifest #'],
          at_gt_last: gtLast,
          at_dump: dump,
          at_visits_field: (r.fields?.Visits || []).join(',') || '(none)',
        });
      }
    }
    candidates.sort((a, b) => a.at_days_off - b.at_days_off);
    findings.push({ ...g, candidates });
  }

  // 4) Report
  const withCandidates = findings.filter(f => f.candidates.length > 0);
  const noCandidates = findings.filter(f => f.candidates.length === 0);

  console.log(`\n=== Gap with plausible AT DERM candidate (${withCandidates.length}) ===`);
  for (const f of withCandidates) {
    console.log(`\n  Visit ${f.id} ${f.visit_date} | ${f.client_code} ${f.client_name?.slice(0,30)}`);
    for (const c of f.candidates.slice(0, 3)) {
      console.log(`    AT ${c.at_id} | ${c.at_src} ${c.at_days_off}d off | ticket ${c.at_yellow || '?'} | dump ${c.at_dump || '?'} | Visits=${c.at_visits_field.slice(0,30)}`);
    }
  }

  console.log(`\n=== Gap with NO AT DERM candidate found (${noCandidates.length}) ===`);
  console.table(noCandidates.slice(0, 30).map(f => ({
    visit_id: f.id,
    visit_date: f.visit_date,
    client_code: f.client_code,
    client_name: f.client_name?.slice(0, 30),
  })));
})().catch(err => { console.error(err); process.exit(1); });
