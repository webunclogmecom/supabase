// Write entity_source_links rows for the 7 reconciled Samsara→DB property
// mappings where Samsara's geofence code drifted from AT/DB canonical.
//
// Reconciliation derived from scripts/probes/reconcile_code_drifts.js.
// 019-GT is intentionally omitted (Samsara has 1 geofence for what AT splits
// into 2 rows: 019-G7 G7 Kitchen 34 + 215-GT G7 Kitchen 35) — needs Yannick
// to disambiguate.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SAM = process.env.SAMSARA_API_TOKEN;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' };
const EXECUTE = process.argv.includes('--execute');

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}
async function samsara(p) {
  const r = await fetch(`https://api.samsara.com${p}`, { headers: { Authorization: `Bearer ${SAM}` } });
  if (!r.ok) throw new Error(`Samsara ${r.status}`);
  return r.json();
}

// (Samsara geofence name needle, DB client_code, AT canonical name for source_name)
const RECONCILED = [
  { needle: '014-FEN Fendi',     db_code: '167-FEN', canon_name: 'Fendi Château Residences' },
  { needle: '132-PU Pummarola',  db_code: '132-PUM', canon_name: 'Pummarola' },
  { needle: '133-MU Mutra',      db_code: '133-MUT', canon_name: 'Mutra' },
  { needle: '140-TCY Tacos',     db_code: '140-TYO', canon_name: 'Tacos yoyo' },
  { needle: '167-JOY The Joyce', db_code: '014-JOY', canon_name: 'The Joyce' },
  { needle: '199-STK Steak',     db_code: '199-JZ',  canon_name: 'JZ Steak House' },
  { needle: '057-BAY Bayshore',  db_code: '057-SLS', canon_name: 'Shaulson Lyft Station' },
];

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  // Pull all Samsara geofences once
  const gfs = [];
  let nxt = '';
  while (true) {
    const qs = nxt ? `&after=${encodeURIComponent(nxt)}` : '';
    const r = await samsara(`/addresses?limit=512${qs}`);
    for (const g of r.data || []) gfs.push(g);
    if (!r.pagination?.hasNextPage) break;
    nxt = r.pagination.endCursor;
  }

  for (const m of RECONCILED) {
    // 1) Find Samsara geofence by needle
    const gf = gfs.find(g => (g.name || '').includes(m.needle));
    if (!gf) { console.log(`✗ ${m.needle} → no Samsara geofence found`); continue; }

    // 2) Resolve DB client + primary property
    const clients = await rest(`clients?client_code=eq.${encodeURIComponent(m.db_code)}&select=id`);
    if (!clients?.length) { console.log(`✗ ${m.db_code} → no DB client`); continue; }
    const client_id = clients[0].id;
    const props = await rest(`properties?client_id=eq.${client_id}&is_primary=eq.true&select=id&limit=1`);
    if (!props?.length) { console.log(`✗ ${m.db_code} → no primary property`); continue; }
    const prop_id = props[0].id;

    // 3) Check if a samsara link already exists for this property
    const existing = await rest(`entity_source_links?entity_type=eq.property&entity_id=eq.${prop_id}&source_system=eq.samsara&select=id,source_id,source_name`);

    const targetSourceId = `addr_${gf.id}`;
    if (existing?.length) {
      // Existing link already points to the right Samsara geofence (the
      // numeric ID portion matches either bare or addr_-prefixed). Just
      // refresh source_name to the canonical AT name so audits read cleanly.
      // Don't churn source_id — bare and addr_-prefixed are both valid
      // conventions in this DB and changing it risks breaking older lookups.
      const e = existing[0];
      const numericMatch = e.source_id === String(gf.id) || e.source_id === targetSourceId;
      if (!numericMatch) {
        console.log(`⚠ ${m.db_code} esl#${e.id} points to ${e.source_id} but Samsara geofence is ${gf.id} — skipping (manual check needed)`);
        continue;
      }
      if (e.source_name === m.canon_name) {
        console.log(`✓ ${m.db_code} link already canonical (esl#${e.id})`);
      } else {
        console.log(`↻ ${m.db_code} → updating esl#${e.id} source_name "${e.source_name}" → "${m.canon_name}"`);
        if (EXECUTE) {
          await rest(`entity_source_links?id=eq.${e.id}`, {
            method: 'PATCH',
            headers: { Prefer: 'return=minimal' },
            body: JSON.stringify({
              source_name: m.canon_name,
              match_method: 'manual_reconcile_2026-05-21',
            }),
          });
        }
      }
    } else {
      console.log(`+ ${m.db_code} → INSERT esl property=${prop_id} samsara source_id=${targetSourceId}`);
      if (EXECUTE) {
        await rest('entity_source_links', {
          method: 'POST',
          headers: { Prefer: 'return=minimal' },
          body: JSON.stringify({
            entity_type: 'property',
            entity_id: prop_id,
            source_system: 'samsara',
            source_id: targetSourceId,
            source_name: m.canon_name,
            match_method: 'manual_reconcile_2026-05-21',
          }),
        });
      }
    }
  }
})().catch(err => { console.error(err); process.exit(1); });
