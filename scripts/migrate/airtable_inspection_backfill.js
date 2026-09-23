// ============================================================================
// airtable_inspection_backfill.js - import the shift inspections Airtable holds
// that this warehouse never received.
// ============================================================================
//
// Fred, 2026-09-23: "Go ahead first with the backfill."
//
// WHY THIS EXISTS. The Airtable PRE-POST inspection table has been filling every
// shift since 2025. The feed that copied it into `public.inspections` went quiet
// on 2026-07-14, so the warehouse stopped at 319 rows while Airtable kept going.
// The two Fillout forms were wired straight to `fillout-inspection` on
// 2026-09-23, which fixes the FUTURE and moves none of the history. This moves
// the history.
//
// 🛑 IT IS A READ OF AIRTABLE AND A WRITE TO SUPABASE. Nothing is written back to
// Airtable, ever. Airtable stays the system of record for this data.
//
// IDEMPOTENCY (rule 5). The natural key is the AIRTABLE RECORD ID, held in
// public.entity_source_links (entity_type='inspection', source_system='airtable').
// All 319 existing rows carry one, so the gap is exactly computable and a re-run
// inserts nothing. `public.inspections` itself has NO unique constraint, so that
// link is the only thing standing between a re-run and 444 duplicates: never
// insert an inspection here without writing its link in the same step.
//
// 🛑 THE GO-LIVE CUTOFF IS A CORRECTNESS GUARD, NOT A TIDINESS ONE. A submission
// made after the forms were wired arrives through the webhook AND sits in
// Airtable, and the two carry different natural keys (a Fillout submission id vs
// an Airtable record id), so nothing would stop this script inserting a second
// copy of it. Records created at or after --cutoff are REPORTED and never
// imported. Adjudicating one is a person's job.
//
// SEMANTICS come from the same place the edge function's do: the human's own
// Fillout -> Airtable mapping. See docs/reference/fillout-inspection-intake.md.
//
// CLI:
//   node scripts/migrate/airtable_inspection_backfill.js            # dry run
//   node scripts/migrate/airtable_inspection_backfill.js --execute
//   node scripts/migrate/airtable_inspection_backfill.js --execute --limit=5
// ============================================================================

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../..');
function readEnv(file) {
  const p = path.join(ROOT, file);
  if (!fs.existsSync(p)) return {};
  return Object.fromEntries(
    fs.readFileSync(p, 'utf8').split(/\r?\n/).filter((l) => l.includes('=') && !l.trim().startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
  );
}
const env = readEnv('.env');

const AT_KEY = env.AIRTABLE_API_KEY;
const AT_BASE = env.AIRTABLE_BASE_ID || 'appjMgjjZPeuudqQR';
const AT_TABLE = 'PRE-POST insptection';   // sic, the typo is the real table name
const PAT = env.SUPABASE_PAT;
const REF = env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';

const args = process.argv.slice(2);
const EXECUTE = args.includes('--execute');
const LIMIT = (() => { const a = args.find((x) => x.startsWith('--limit=')); return a ? parseInt(a.split('=')[1], 10) : null; })();
const CUTOFF = (() => {
  const a = args.find((x) => x.startsWith('--cutoff='));
  return new Date(a ? a.split('=')[1] : '2026-09-23T17:00:00.000Z');
})();

if (!AT_KEY) throw new Error('AIRTABLE_API_KEY missing from Supabase/.env');
if (!PAT) throw new Error('SUPABASE_PAT missing from Supabase/.env');

// --- the alias maps, copied from supabase/functions/fillout-inspection/index.ts
// 🛑 KEEP THESE IN STEP WITH THE EDGE FUNCTION. Two copies of one rule is how a
// backfill and a live feed end up disagreeing about who drove.
const DRIVER_ALIASES = {
  'anthony': 'Anthony', 'marc': 'Mark', 'mark': 'Mark', 'grecia': 'Grecia',
  'michael e': 'Michael Escobar', 'michael escobar': 'Michael Escobar',
  'steven': 'Steven', 'jeffry': 'Jeffry', 'aaron': 'Aaron',
  '(old) ray': 'Raymond Lee', '(old) diego': 'Diego', '(old) ishad': 'Ishad Knight',
  '(old) yan': 'Yannick', '(old) kevis': 'Kevis Bell',
};
const TRUCK_ALIASES = {
  'moises 3800': 'Moises', 'moises': 'Moises',
  'goliath 5,000': 'Goliath', 'goliath 5000': 'Goliath', 'goliath': 'Goliath',
  'david 2,000': 'David', 'david 2000': 'David', 'david': 'David',
  'cloggy pickup': 'Cloggy', 'cloggy': 'Cloggy',
};

// --- helpers, same semantics as the edge function -------------------------
const str = (v) => { if (v === null || v === undefined) return null; const s = String(typeof v === 'object' && v.name ? v.name : v).trim(); return s === '' ? null : s; };
const num = (v) => { const s = str(v); if (s === null) return null; const n = Number(s.replace(/[, ]/g, '')); return Number.isFinite(n) ? Math.round(n) : null; };
const bool = (v) => { if (v === true) return true; if (v === false) return false; const s = str(v); if (s === null) return null; const l = s.toLowerCase(); if (['true', 'yes', 'y', '1', 'checked', 'on'].includes(l)) return true; if (['false', 'no', 'n', '0', 'unchecked', 'off'].includes(l)) return false; return null; };
/** The ET CLOCK date. Never a UTC slice: an evening ET shift is the next day in UTC. */
function etClockDate(iso) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(d);
  const get = (t) => parts.find((p) => p.type === t)?.value;
  return `${get('year')}-${get('month')}-${get('day')}`;
}
function inspectionType(v) {
  const s = str(v)?.toLowerCase();
  if (!s) return null;
  if (s.startsWith('pre')) return 'PRE';
  if (s.startsWith('post')) return 'POST';
  return null;
}

// --- transports ------------------------------------------------------------
async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`SQL ${r.status}: ${t.slice(0, 400)}`);
  return JSON.parse(t);
}
const lit = (v) => (v === null || v === undefined ? 'NULL' : typeof v === 'number' ? String(v) : typeof v === 'boolean' ? (v ? 'TRUE' : 'FALSE') : `'${String(v).replace(/'/g, "''")}'`);

async function airtableAll() {
  const out = [];
  let offset = null;
  do {
    const q = new URLSearchParams({ pageSize: '100' });
    if (offset) q.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(AT_TABLE)}?${q}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    if (!r.ok) throw new Error(`Airtable ${r.status}: ${(await r.text()).slice(0, 300)}`);
    const j = await r.json();
    out.push(...(j.records || []));
    offset = j.offset;
  } while (offset);
  return out;
}

// --- the mapping -----------------------------------------------------------
function toRow(rec, employees, vehicles) {
  const f = rec.fields || {};
  const unresolved = [];

  const type = inspectionType(f['Pre/Post']);
  // The driver picks "Date"; 3 of 444 records have none, so fall back to when
  // Airtable received it. That is a worse answer than the driver's and a much
  // better one than dropping the inspection.
  const submittedAt = str(f['Date']) || rec.createdTime;
  const shiftDate = etClockDate(submittedAt);

  let employee_id = null;
  const driverRaw = str(f['Driver']);
  if (driverRaw) {
    const target = DRIVER_ALIASES[driverRaw.toLowerCase()];
    if (!target) unresolved.push(`driver:${driverRaw}`);
    else if (employees[target]) employee_id = employees[target];
    else unresolved.push(`driver:${driverRaw}->${target}`);
  }

  let vehicle_id = null;
  const truckRaw = str(f['Truck']);
  if (truckRaw) {
    const target = TRUCK_ALIASES[truckRaw.toLowerCase()];
    if (!target) unresolved.push(`truck:${truckRaw}`);
    else if (vehicles[target]) vehicle_id = vehicles[target];
    else unresolved.push(`truck:${truckRaw}->${target}`);
  }

  const issueNote = str(f['Report Issue']);
  const issuePics = Array.isArray(f['Issue pictures']) ? f['Issue pictures'].length : 0;

  return {
    rec_id: rec.id,
    createdTime: rec.createdTime,
    type,
    shiftDate,
    unresolved,
    row: {
      vehicle_id,
      employee_id,
      shift_date: shiftDate,
      inspection_type: type,
      submitted_at: submittedAt,
      sludge_gallons: num(f['SLUDGE Tank level']),
      water_gallons: num(f['WATER Tank level']),
      gas_level: str(f['Gas Level']),
      is_valve_closed: bool(f['Valve is closed']),
      // ⚠ Airtable has no "is there an issue" question on these historical
      // records, so this is DERIVED: a note or an issue photo means yes. The
      // existing 319 rows carry the same derivation, and keeping one convention
      // across one series matters more than the NULL the live function would use
      // (the live POST form asks the question outright, so it never has to guess).
      has_issue: !!(issueNote || issuePics),
      issue_note: issueNote,
    },
  };
}

// --- main ------------------------------------------------------------------
(async () => {
  console.log('='.repeat(72));
  console.log('airtable_inspection_backfill.js   mode=' + (EXECUTE ? 'EXECUTE' : 'DRY-RUN'));
  console.log('  cutoff (records at/after this are reported, never imported): ' + CUTOFF.toISOString());
  console.log('='.repeat(72));

  const [records, links, emps, vehs] = await Promise.all([
    airtableAll(),
    sql(`select source_id from public.entity_source_links where entity_type='inspection' and source_system='airtable'`),
    sql(`select id, full_name from public.employees`),
    sql(`select id, name from public.vehicles`),
  ]);
  const have = new Set(links.map((l) => l.source_id));
  const employees = Object.fromEntries(emps.map((e) => [e.full_name, e.id]));
  const vehicles = Object.fromEntries(vehs.map((v) => [v.name, v.id]));

  console.log(`airtable records: ${records.length}`);
  console.log(`already linked:   ${have.size}`);

  const missing = records.filter((r) => !have.has(r.id));
  const afterCutoff = missing.filter((r) => new Date(r.createdTime) >= CUTOFF);
  let todo = missing.filter((r) => new Date(r.createdTime) < CUTOFF).map((r) => toRow(r, employees, vehicles));

  // A row with no type cannot be stored: inspection_type is NOT NULL and CHECKed.
  const noType = todo.filter((t) => !t.type);
  const noDate = todo.filter((t) => !t.shiftDate);
  todo = todo.filter((t) => t.type && t.shiftDate);
  if (LIMIT) todo = todo.slice(0, LIMIT);

  console.log(`missing:          ${missing.length}`);
  console.log(`  after cutoff (SKIPPED, needs a person): ${afterCutoff.length}`);
  console.log(`  no Pre/Post     (SKIPPED, unstorable):  ${noType.length}`);
  console.log(`  no usable date  (SKIPPED, unstorable):  ${noDate.length}`);
  console.log(`  importable:     ${todo.length}${LIMIT ? ` (limited to ${LIMIT})` : ''}`);
  if (afterCutoff.length) console.log('  after-cutoff ids: ' + afterCutoff.map((r) => r.id).join(', '));
  if (noType.length) console.log('  no-type ids: ' + noType.map((t) => t.rec_id).join(', '));

  const withUnresolved = todo.filter((t) => t.unresolved.length);
  console.log(`  of those, unresolved driver/truck: ${withUnresolved.length}`);
  const byType = todo.reduce((a, t) => { a[t.type] = (a[t.type] || 0) + 1; return a; }, {});
  const dates = todo.map((t) => t.shiftDate).sort();
  console.log(`  types: ${JSON.stringify(byType)}   date range: ${dates[0]} .. ${dates[dates.length - 1]}`);

  if (!EXECUTE) {
    console.log('\nsample of 3:');
    for (const t of todo.slice(0, 3)) console.log('  ' + t.rec_id + ' ' + JSON.stringify(t.row));
    console.log('\nDRY RUN, nothing written. Re-run with --execute.');
    return;
  }

  let ok = 0, failed = 0;
  for (const t of todo) {
    const r = t.row;
    // One statement, one transaction: the inspection and its link are written
    // together or not at all. An inspection without its link is a duplicate
    // waiting for the next run.
    const q = `
      with ins as (
        insert into public.inspections
          (vehicle_id, employee_id, shift_date, inspection_type, submitted_at,
           sludge_gallons, water_gallons, gas_level, is_valve_closed, has_issue, issue_note)
        select ${lit(r.vehicle_id)}, ${lit(r.employee_id)}, ${lit(r.shift_date)}::date,
               ${lit(r.inspection_type)}, ${lit(r.submitted_at)}::timestamptz,
               ${lit(r.sludge_gallons)}, ${lit(r.water_gallons)}, ${lit(r.gas_level)},
               ${lit(r.is_valve_closed)}, ${lit(r.has_issue)}, ${lit(r.issue_note)}
         where not exists (
           select 1 from public.entity_source_links
            where entity_type='inspection' and source_system='airtable' and source_id=${lit(t.rec_id)})
        returning id)
      insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
      select 'inspection', ins.id, 'airtable', ${lit(t.rec_id)} from ins
      returning entity_id;`;
    try {
      const res = await sql(q);
      if (res.length) ok++; else console.log(`  skip ${t.rec_id} (already linked)`);
    } catch (e) {
      failed++;
      console.error(`  FAIL ${t.rec_id}: ${e.message.slice(0, 200)}`);
    }
  }
  console.log(`\ninserted ${ok}, failed ${failed}`);

  const after = await sql(`select count(*) n, max(shift_date)::text mx from public.inspections`);
  const linked = await sql(`select count(*) n from public.entity_source_links where entity_type='inspection' and source_system='airtable'`);
  const orphan = await sql(`select count(*) n from public.inspections i where not exists (select 1 from public.entity_source_links l where l.entity_type='inspection' and l.entity_id=i.id)`);
  console.log(`inspections now ${after[0].n} (latest shift ${after[0].mx}), airtable links ${linked[0].n}, UNLINKED inspections ${orphan[0].n}`);
})().catch((e) => { console.error('ERR ' + e.message); process.exit(1); });
