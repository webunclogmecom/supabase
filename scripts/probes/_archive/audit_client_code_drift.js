// ============================================================================
// audit_client_code_drift.js  [--heal]
// ============================================================================
// Reconciliation safety-net for client_code drift. Heals ONLY on TWO-SOURCE
// AGREEMENT: when a client's Jobber company-name prefix AND its Airtable
// "Client Code #3" agree on a code that differs from the stale DB value.
//
// Why two-source (learned 2026-06-17): the canonical code is assigned in Airtable
// and copied into the Jobber company name by Yan. Neither alone is safe to heal
// from — Jobber's prefix is frequently typo'd/truncated ("133-MU" for 133-MUT,
// "140-TCY" for 140-TYO), and the DB can go stale on a renumber that
// webhook-airtable's code-matching can never reach ("221-MP" stuck for a client
// both Airtable and Jobber call "224-MP"). The DB is healed only when the two
// independent upstreams AGREE against it — matched to Jobber by the STABLE GID
// (entity_source_links), and to Airtable by that agreed code.
//
// Three outcomes are reported:
//   * AGREEMENT DRIFT  — Jobber prefix == an AT code, both != DB  -> healable
//   * JOBBER TYPO      — Jobber prefix != DB and NOT an AT code   -> DB likely fine; fix Jobber company name
//   * (in sync)        — silent
//
// Real-time companion: webhook-jobber handleClient only sets the code when MISSING
// (it must not overwrite from Jobber alone). This probe is the drift catch-all and
// is meant to run on the daily audit cron.
//
// Usage:  node scripts/probes/audit_client_code_drift.js [--heal]
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const { pullDelta } = require('../sync/lib/jobber');

const HEAL = process.argv.includes('--heal');
const PAT = process.env.SUPABASE_PAT;
const REF = (process.env.SUPABASE_URL || '').match(/https?:\/\/([^.]+)\./)[1];
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function pg(sql) {
  return new Promise((res, rej) => {
    const b = JSON.stringify({ query: sql });
    const r = https.request({ hostname: 'api.supabase.com', path: `/v1/projects/${REF}/database/query`, method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } },
      rs => { let d = ''; rs.on('data', c => d += c); rs.on('end', () => rs.statusCode < 300 ? res(JSON.parse(d)) : rej(new Error(`HTTP ${rs.statusCode} ${d.slice(0, 300)}`))); });
    r.on('error', rej); r.write(b); r.end();
  });
}
const q = s => String(s).replace(/'/g, "''");

// Known, ACCEPTED Jobber company-name variances (created manually by Diego; the DB +
// Airtable hold the canonical code, Jobber's prefix differs on purpose). Keyed
// canonical client_code -> the accepted Jobber prefix. Suppressed from the report so
// the weekly audit stays signal-only. A DIFFERENT Jobber prefix for the same client
// (a NEW variance) still surfaces. 146-54W was aligned in Jobber 2026-06-17, so it's
// no longer here.
const ACCEPTED_JOBBER_VARIANCE = {
  '057-SLS': '057-BAY',
  '132-PUM': '132-PU',
  '133-MUT': '133-MU',
  '140-TYO': '140-TCY',
  '199-JZ': '199-STK',
  '213-TRUE': '213-TRU',
};

// Same prefix parse as webhook-jobber handleClient (only a real NNN-XX with alpha suffix).
function parsePrefix(name) {
  if (!name) return null;
  const m = String(name).match(/^\s*(\d{3})-\s*([A-Z0-9]*)\s+/);
  return m && m[2] ? `${m[1]}-${m[2]}` : null;
}

async function airtableCodes() {
  const codes = new Set();
  let offset = null;
  do {
    const qs = new URLSearchParams({ pageSize: '100' });
    if (offset) qs.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/Clients?${qs}`, { headers: { Authorization: `Bearer ${AT_KEY}` } }).then(x => x.json());
    for (const rec of (r.records || [])) {
      const code = rec.fields?.['Client Code #3'];
      if (code) codes.add(String(code).trim());
    }
    offset = r.offset;
  } while (offset);
  return codes;
}

(async () => {
  const atCodes = await airtableCodes();                                   // canonical AT codes
  const jclients = await pullDelta({ entityField: 'clients', nodeFields: 'id name companyName', updatedAfter: null });
  const prefixByGid = {};
  for (const c of jclients) {
    const pre = parsePrefix(c.name) || parsePrefix(c.companyName);
    if (pre) prefixByGid[c.id] = pre;
  }
  const rows = await pg(`select c.id, c.client_code, c.name, esl.source_id as gid from clients c join entity_source_links esl on esl.entity_id=c.id and esl.entity_type='client' and esl.source_system='jobber'`);
  const dbHolders = {};
  for (const r of rows) if (r.client_code) (dbHolders[r.client_code] = dbHolders[r.client_code] || []).push(r.id);

  const agreementDrifts = [], jobberTypos = [], accepted = [];
  for (const r of rows) {
    const pre = prefixByGid[r.gid];
    if (!pre || r.client_code === pre) continue;
    if (atCodes.has(pre)) {
      // Jobber prefix AND Airtable agree on `pre`; DB disagrees -> heal candidate.
      const otherHolders = (dbHolders[pre] || []).filter(id => id !== r.id);
      agreementDrifts.push({ id: r.id, name: r.name, db_code: r.client_code, agreed_code: pre, collision_with: otherHolders });
    } else if (ACCEPTED_JOBBER_VARIANCE[r.client_code] === pre) {
      // Known/accepted Diego variance — DB is canonical; stay quiet.
      accepted.push({ id: r.id, name: r.name, db_code: r.client_code, jobber_prefix: pre });
    } else {
      // Jobber prefix is not a real AT code -> Jobber-side typo; DB (matching AT) left alone.
      jobberTypos.push({ id: r.id, name: r.name, db_code: r.client_code, jobber_prefix: pre, db_code_is_at: r.client_code ? atCodes.has(r.client_code) : false });
    }
  }
  const healable = agreementDrifts.filter(d => d.collision_with.length === 0);
  const blocked = agreementDrifts.filter(d => d.collision_with.length > 0);

  console.log(`AT canonical codes: ${atCodes.size} | Jobber clients: ${jclients.length} | DB Jobber-linked: ${rows.length}`);
  console.log(`AGREEMENT DRIFTS (Jobber+AT agree vs DB): ${agreementDrifts.length}  (healable: ${healable.length}, collision-blocked: ${blocked.length})`);
  for (const d of agreementDrifts) console.log(`  ${d.collision_with.length ? 'BLOCKED ' : 'heal    '}  client ${d.id} "${d.name}"  DB=${d.db_code || '(none)'} -> ${d.agreed_code}${d.collision_with.length ? `  (target held by ${d.collision_with.join(',')})` : ''}`);
  console.log(`JOBBER COMPANY-NAME TYPOS (new, DB canonical): ${jobberTypos.length}  | accepted/known variances suppressed: ${accepted.length}`);
  for (const t of jobberTypos) console.log(`  client ${t.id} "${t.name}"  DB=${t.db_code || '(none)'}${t.db_code_is_at ? ' [=AT]' : ' [DB code NOT in AT!]'}  Jobber=${t.jobber_prefix}`);

  if (HEAL && healable.length) {
    for (const d of healable) {
      await pg(`update clients set client_code='${q(d.agreed_code)}' where id=${d.id}`);
      await pg(`insert into webhook_events_log (source_system, event_type, status, error_message, payload) values ('jobber','client_code_drift_healed','info','probe healed client ${d.id} client_code ${q(d.db_code || '(none)')} -> ${q(d.agreed_code)} (Jobber+AT agree)','${q(JSON.stringify({ client_id: d.id, from: d.db_code, to: d.agreed_code, by: 'audit_client_code_drift' }))}'::jsonb)`);
    }
    console.log(`HEALED ${healable.length} agreement-drift(s).`);
  } else if (healable.length) {
    console.log('Run with --heal to auto-fix the healable agreement-drifts.');
  }
  console.log(`--- audit complete --- ${JSON.stringify({ probe: 'client_code_drift', agreement_drifts: agreementDrifts.length, healable: healable.length, blocked: blocked.length, jobber_typos: jobberTypos.length, accepted_suppressed: accepted.length, healed: HEAL ? healable.length : 0 })}`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
