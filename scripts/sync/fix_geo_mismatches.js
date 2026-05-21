// Fix the 3 geo mismatches surfaced in audit_samsara_geofence_mismatch.js.
//
// Strategy per Fred's directive: Samsara wins where it has the right
// geofence. False-positive matches get their bogus ESL cleaned up.
//
// 1) 151-OAS Oasis Hallandale Master Association — DB and Samsara agree on
//    address text but coords drift 303m. Overwrite DB with Samsara's coords
//    + add ESL.
//
// 2) BHRE Property Management — Samsara has TWO geofences (one per address),
//    DB has 3 properties. Existing ESL incorrectly links property 180 to
//    samsara 322485412 (which is actually property 351's address). Fix by:
//    - move ESL 322485412 from property 180 → 351
//    - add ESL 322485413 → property 357
//    No coord changes needed (DB props match Samsara to within 8m).
//
// 3) Courtyard by Marriott SOBE — Samsara's "yard" geofence is a totally
//    different business 7.7km away (650 NW 33rd St). Existing ESL on the
//    primary property is bogus (gps_100m matcher hit on adjacent client
//    138-ASW Arepas & Sand Wish, 1522 Washington Ave). Just delete the
//    bogus ESL; don't touch lat/lng (DB is correct).
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' };
const EXECUTE = process.argv.includes('--execute');

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}

async function patchProperty(id, body) {
  console.log(`  PATCH property ${id}:`, JSON.stringify(body));
  if (!EXECUTE) return;
  await rest(`properties?id=eq.${id}`, {
    method: 'PATCH',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify(body),
  });
}
async function upsertEsl({ entity_id, source_id, source_name, match_method }) {
  console.log(`  UPSERT esl property=${entity_id} samsara source_id=${source_id} name="${source_name}"`);
  if (!EXECUTE) return;
  // Check if a samsara ESL for this property already exists
  const existing = await rest(`entity_source_links?entity_type=eq.property&entity_id=eq.${entity_id}&source_system=eq.samsara&select=id`);
  if (existing?.length) {
    await rest(`entity_source_links?id=eq.${existing[0].id}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ source_id, source_name, match_method }),
    });
  } else {
    await rest('entity_source_links', {
      method: 'POST',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({
        entity_type: 'property', entity_id, source_system: 'samsara',
        source_id, source_name, match_method,
      }),
    });
  }
}
async function deleteEslById(id) {
  console.log(`  DELETE esl #${id}`);
  if (!EXECUTE) return;
  await rest(`entity_source_links?id=eq.${id}`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  // ============================================================
  // 1) 151-OAS — overwrite DB property 131 coords with Samsara's
  // ============================================================
  console.log('=== 1) 151-OAS Oasis Hallandale — overwrite coords with Samsara ===');
  await patchProperty(131, {
    latitude: 25.9855211,
    longitude: -80.140571,
  });
  await upsertEsl({
    entity_id: 131,
    source_id: 'addr_4000001011455',
    source_name: 'Oasis Master association',
    match_method: 'manual_reconcile_2026-05-21',
  });

  // ============================================================
  // 2) BHRE — fix property↔samsara links
  // ============================================================
  console.log('\n=== 2) BHRE Property Management — fix property↔samsara links ===');
  // Existing wrong link: property 180 → samsara 322485412
  // Should be: property 351 → samsara 322485412 (0m apart), property 357 → samsara 322485413 (8m apart)
  // Find the existing bogus ESL on property 180
  const wrongEsl = await rest('entity_source_links?entity_type=eq.property&entity_id=eq.180&source_system=eq.samsara&select=id,source_id,source_name');
  if (wrongEsl?.length) {
    console.log(`  Bogus ESL #${wrongEsl[0].id} on property 180 (source_id=${wrongEsl[0].source_id}) — deleting`);
    await deleteEslById(wrongEsl[0].id);
  }
  await upsertEsl({
    entity_id: 351,
    source_id: 'addr_322485412',
    source_name: 'BHRE Property Management (1870 NE 187 St)',
    match_method: 'manual_reconcile_2026-05-21',
  });
  await upsertEsl({
    entity_id: 357,
    source_id: 'addr_322485413',
    source_name: 'BHRE Property Management (19531 NE 22nd Ave)',
    match_method: 'manual_reconcile_2026-05-21',
  });

  // ============================================================
  // 3) Courtyard by Marriott SOBE — delete bogus ESL
  // ============================================================
  console.log('\n=== 3) Courtyard by Marriott SOBE — delete bogus ESL ===');
  // Property 203's samsara ESL points to "138-ASW Arepas & Sand Wish" which
  // is a different (INACTIVE) client at the adjacent 1522 Washington Ave.
  const bogus = await rest('entity_source_links?entity_type=eq.property&entity_id=eq.203&source_system=eq.samsara&select=id,source_id,source_name');
  if (bogus?.length) {
    console.log(`  Bogus ESL #${bogus[0].id} on property 203 → ${bogus[0].source_name} (source_id=${bogus[0].source_id}) — deleting`);
    await deleteEslById(bogus[0].id);
  } else {
    console.log('  No samsara ESL on property 203 — already clean');
  }

  console.log('\nDone.');
})().catch(err => { console.error(err); process.exit(1); });
