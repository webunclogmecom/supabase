// One-shot backfill of 15 Miami-Dade GDOs hand-verified by Viktor on
// 2026-05-22 (Slack #viktor-supabase ts 1779407449.696109). The DERM Bot's
// address-only search returned wrong neighbors on multi-tenant plazas; Viktor
// manually cross-referenced facility-name + address on the DERM portal.
//
// Per CLAUDE.md trust-hierarchy rule 4: DERM portal data is canonical for
// compliance, so Viktor's manually-curated portal pulls qualify as source-
// of-truth for the gdo_number field.
//
// Per CLAUDE.md rule 5: ON CONFLICT (client_id, gdo_number) keeps re-runs
// safe. Per rule 8: audit_gdos trigger fires on INSERT (already opted-in
// per 2026-05-20g migration header).
//
// NOT included:
//   - 140-TYO and 213-TRUE: multi-tenant addresses, Fred's call which unit
//   - 11 not-found cases (Bucket C in Slack thread)
//
// Each row stores facility_name in location_label so future ops can spot
// "huh, permit says G-COFFEE but client is Hubble Bubble" — that's the
// previous tenant. notes documents source + the original DERM Bot mis-pick
// (if any) so we have provenance.
//
// Run:
//   node scripts/sync/backfill_gdos_from_viktor_lookup_2026_05_22.js
//   node scripts/sync/backfill_gdos_from_viktor_lookup_2026_05_22.js --execute
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const EXECUTE = process.argv.includes('--execute');
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' };

// Viktor's 15 confirmed GDOs (Slack ts 1779407449.696109)
// Bot-conflict column documents where the DERM Bot's top pick differed;
// "—" means agreement.
const VIKTOR_PICKS = [
  { code: '201-ALA', gdo: 'GDO-11308', facility: 'ALADDIN MARKET & FOOD, INC.',          confidence: 'strong-name-match',    bot_conflict: 'GDO-11629 U Gas (wrong neighbor)' },
  { code: '214-PER', gdo: 'GDO-03342', facility: 'AROMAS DEL PERU',                       confidence: 'strong-name-match',    bot_conflict: '—' },
  { code: '187-HAI', gdo: 'GDO-07382', facility: 'MACITAS RESTAURANT',                    confidence: 'address-verified',     bot_conflict: '—' },
  { code: '150-KOS', gdo: 'GDO-04943', facility: 'ADRIANA',                               confidence: 'address-verified-old', bot_conflict: '—', age_warning: '2015 permit; verify still in use' },
  { code: '036-LG',  gdo: 'GDO-12484', facility: 'URBAN BRICKS PIZZA CO',                 confidence: 'address-verified',     bot_conflict: 'GDO-11708 La Granja NMB (wrong chain unit)' },
  { code: '058-SOH', gdo: 'GDO-01179', facility: 'APACHE LANDING BAR & GRILL',            confidence: 'address-verified',     bot_conflict: '—' },
  { code: '114-CI',  gdo: 'GDO-05104', facility: 'ANGELOS PIZZARAUNTE',                   confidence: 'address-verified',     bot_conflict: 'GDO-11886 Polynesio Lake (wrong)' },
  { code: '188-ACA', gdo: 'GDO-02118', facility: 'SAN LAZARO CAFETERIA',                  confidence: 'address-verified',     bot_conflict: '—' },
  { code: '192-FRK', gdo: 'GDO-08341', facility: 'COOL WILD COMPANY LLC DBA THAT COOL CAFE', confidence: 'address-verified',  bot_conflict: '—' },
  { code: '193-FRK', gdo: 'GDO-01861', facility: 'PITAS & PLATTERS RESTAURANT',           confidence: 'address-verified-old', bot_conflict: '—', age_warning: '2008 permit (18yr old); verify still in use' },
  { code: '203-GF',  gdo: 'GDO-05563', facility: 'FIRST MOON HOLDINGS LLC DBA CHINA MOON', confidence: 'address-verified',    bot_conflict: '—' },
  { code: '206-CAC', gdo: 'GDO-09070', facility: 'HOLY BAGEL & PIZZARIA',                 confidence: 'address-verified',     bot_conflict: '—' },
  { code: '208-HUB', gdo: 'GDO-08370', facility: 'G-COFFEE',                              confidence: 'address-verified',     bot_conflict: '—' },
  { code: '210-KAY', gdo: 'GDO-06685', facility: 'CHUBBY CHEESE PIZZA',                   confidence: 'address-verified',     bot_conflict: '—' },
  { code: '214-MYK', gdo: 'GDO-08422', facility: 'TRULUCKS RESTAURANT STEAK & SEAFOOD',   confidence: 'address-verified',     bot_conflict: '—' },
];

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  // Resolve client_id + primary property_id for each code
  const rows = [];
  for (const pick of VIKTOR_PICKS) {
    const cs = await rest(`clients?client_code=eq.${encodeURIComponent(pick.code)}&select=id,name,status`);
    if (!cs?.length) {
      console.warn(`  ${pick.code}: client_code not found in DB — SKIP`);
      continue;
    }
    const client = cs[0];
    if (client.status === 'INACTIVE') {
      console.warn(`  ${pick.code}: client is INACTIVE — SKIP`);
      continue;
    }
    const props = await rest(`properties?client_id=eq.${client.id}&is_primary=eq.true&select=id`);
    const property_id = props?.[0]?.id || null;

    // Already there?
    const exists = await rest(`gdos?client_id=eq.${client.id}&gdo_number=eq.${encodeURIComponent(pick.gdo)}&select=id`);
    if (exists?.length) {
      console.log(`  ${pick.code}: ${pick.gdo} already in DB — SKIP`);
      continue;
    }

    rows.push({
      client_id: client.id,
      client_name: client.name,
      client_code: pick.code,
      gdo_number: pick.gdo,
      location_label: pick.facility,
      property_id,
      status: 'ACTIVE',
      notes: [
        `Source: Viktor manual DERM portal lookup 2026-05-22`,
        `Confidence: ${pick.confidence}`,
        pick.bot_conflict !== '—' ? `Bot pick: ${pick.bot_conflict}` : null,
        pick.age_warning || null,
      ].filter(Boolean).join(' · '),
    });
  }

  console.log('\n=== Rows to INSERT ===');
  console.table(rows.map(r => ({
    code: r.client_code,
    gdo: r.gdo_number,
    facility: r.location_label?.slice(0, 40),
    property_id: r.property_id ?? '(none)',
  })));

  if (!EXECUTE) {
    console.log('\n[DRY-RUN] Re-run with --execute to insert.');
    return;
  }

  console.log(`\nInserting ${rows.length} GDOs...`);
  let inserted = 0, failed = 0;
  for (const r of rows) {
    const row = {
      client_id: r.client_id,
      gdo_number: r.gdo_number,
      location_label: r.location_label,
      property_id: r.property_id,
      status: 'ACTIVE',
      notes: r.notes,
    };
    try {
      await rest('gdos?on_conflict=client_id,gdo_number', {
        method: 'POST',
        headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
        body: JSON.stringify(row),
      });
      inserted++;
    } catch (e) {
      console.warn(`  fail ${r.client_code} ${r.gdo_number}:`, e.message?.slice(0, 120));
      failed++;
    }
  }
  console.log(`\nInserted: ${inserted}, failed: ${failed}`);
})().catch(err => { console.error('FATAL:', err); process.exit(1); });
