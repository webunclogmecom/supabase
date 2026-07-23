// Client-code wave 2026-07-23 — assign codes to 4 code-less Aromas del Peru locations
// and RENUMBER BHRE off the 248 collision (Chabad keeps 248-CHA, Fred's call 2026-07-23).
//
// isCompany-AWARE (fixes the 2026-07-06 wave bug that set companyName on a non-company
// client, leaving BHRE's code invisible): edit companyName for companies, firstName for
// individuals — Jobber's DISPLAY name (and our webhook's derived name) comes from
// firstName+lastName when isCompany=false.
//
// Saga per client (strict rollback, Fred's ACID rule): backup -> guarded DB UPDATE ->
// clientEdit(correct field) -> verify re-read -> rollback DB (and Jobber if edited) on fail.
// Idempotent / skip-if-correct. Read-only DRY by default; pass --execute to write.
import { readFileSync, writeFileSync, appendFileSync, existsSync } from 'fs';

const ROOT = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude';
const env = readFileSync(ROOT + '/Supabase/.env', 'utf8');
const g = k => env.match(new RegExp('^' + k + '=(.*)$', 'm'))?.[1]?.replace(/^["']|["']$/g, '');
const PAT = g('SUPABASE_PAT');
const BACKUP = ROOT + '/backups/2026-07-23_client_code_aromas_bhre_backup.json';
const LOG = 'C:/Users/FRED/AppData/Local/Temp/claude/C--Users-FRED-Desktop-Virtrify-Yannick-Claude/40638e19-110b-49a4-a53c-84f93eeb9a08/scratchpad/aromas_bhre_log.jsonl';
const RESULT = 'C:/Users/FRED/AppData/Local/Temp/claude/C--Users-FRED-Desktop-Virtrify-Yannick-Claude/40638e19-110b-49a4-a53c-84f93eeb9a08/scratchpad/aromas_bhre_result.json';
const EXECUTE = process.argv.includes('--execute');

// FROZEN plan (Fred-approved 2026-07-23). code, and for renumbers the expected old code.
// mode 'fill' = DB code currently NULL; 'renumber' = DB code currently oldCode.
const PLAN = [
  { id: 508, code: '288-PER', mode: 'fill' },
  { id: 509, code: '289-PER', mode: 'fill' },
  { id: 510, code: '290-PER', mode: 'fill' },
  { id: 511, code: '291-PER', mode: 'fill' },
  { id: 51,  code: '292-BPM', mode: 'renumber', oldCode: '248-BPM' },
];
const PREFIX_RE = /^\s*\d{3}-\s*[A-Z0-9]*\s+/; // strip any existing NNN-XX prefix defensively

async function pg(q) {
  const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query',
    { method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: q }) });
  const j = await r.json();
  if (!Array.isArray(j)) throw new Error('PG ' + JSON.stringify(j).slice(0, 300));
  return j;
}
const esc = s => String(s).replace(/'/g, "''");

let TOK, TOKROW;
async function loadTok() { TOKROW = (await pg(`SELECT access_token, refresh_token, client_id, client_secret FROM webhook_tokens WHERE source_system='jobber' LIMIT 1`))[0]; TOK = TOKROW.access_token; }
async function refreshTok() {
  const r = await fetch('https://api.getjobber.com/api/oauth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ client_id: TOKROW.client_id, client_secret: TOKROW.client_secret, grant_type: 'refresh_token', refresh_token: TOKROW.refresh_token }) });
  const j = await r.json(); if (!j.access_token) throw new Error('refresh failed ' + JSON.stringify(j).slice(0, 200));
  TOK = j.access_token; await pg(`UPDATE webhook_tokens SET access_token='${esc(TOK)}', updated_at=now() WHERE source_system='jobber'`); console.log('  (refreshed jobber token)');
}
async function gql(query, variables) {
  for (let a = 0; a < 6; a++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', { method: 'POST', headers: { Authorization: `Bearer ${TOK}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' }, body: JSON.stringify({ query, variables }) });
    if (r.status === 401) { await refreshTok(); continue; }
    const j = await r.json();
    if (j.errors && JSON.stringify(j.errors).includes('THROTTLED')) { await new Promise(s => setTimeout(s, 18000)); continue; }
    return j;
  }
  throw new Error('gql: exhausted retries');
}
async function readClient(encodedId) {
  const j = await gql(`query($id:EncodedId!){ client(id:$id){ id companyName name firstName lastName isCompany } }`, { id: encodedId });
  if (j.errors) throw new Error('read ' + JSON.stringify(j.errors).slice(0, 200));
  return j.data.client;
}
async function clientEdit(encodedId, input) {
  const j = await gql(`mutation($id:EncodedId!,$input:ClientEditInput!){ clientEdit(clientId:$id,input:$input){ client{ id companyName name firstName lastName } userErrors{ message } } }`, { id: encodedId, input });
  if (j.errors) return { ok: false, err: JSON.stringify(j.errors).slice(0, 200) };
  const ue = j.data?.clientEdit?.userErrors || [];
  if (ue.length) return { ok: false, err: 'userErrors ' + JSON.stringify(ue).slice(0, 200) };
  return { ok: true, client: j.data.clientEdit.client };
}

function backup(rec) {
  let arr = []; if (existsSync(BACKUP)) { try { arr = JSON.parse(readFileSync(BACKUP, 'utf8')); } catch {} }
  arr.push(rec); writeFileSync(BACKUP, JSON.stringify(arr, null, 1));
}

(async () => {
  await loadTok();
  const decoded = JSON.parse(Buffer.from(TOK.split('.')[1], 'base64').toString('utf8'));
  if (!(decoded.scope || '').includes('write_clients')) throw new Error('ABORT: token lacks write_clients');
  console.log(`token OK (write_clients). MODE=${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  const ids = PLAN.map(p => p.id);
  const rows = await pg(`SELECT c.id, c.name, c.client_code, c.status, esl.source_id
    FROM clients c JOIN entity_source_links esl ON esl.entity_type='client' AND esl.source_system='jobber' AND esl.entity_id=c.id
    WHERE c.id IN (${ids.join(',')})`);
  const byId = {}; for (const r of rows) byId[r.id] = r;

  const results = [];
  let first = true;
  for (const p of PLAN) {
    const row = byId[p.id];
    const rec = { id: p.id, code: p.code, mode: p.mode };
    if (!row) { rec.result = 'SKIP_no_db_row'; results.push(rec); console.log(`SKIP ${p.code} id=${p.id}: no DB/ESL row`); continue; }
    const encId = row.source_id; // ESL source_id is the base64 EncodedId

    let jc; try { jc = await readClient(encId); } catch (e) { rec.result = 'FAIL_jobber_read'; rec.err = e.message; results.push(rec); console.log(`FAIL ${p.code} id=${p.id}: jobber read ${e.message}`); if (first) { console.log('CANARY read failed — aborting'); break; } continue; }
    rec.isCompany = jc.isCompany; rec.old_db_code = row.client_code;
    rec.old_companyName = jc.companyName; rec.old_firstName = jc.firstName; rec.old_lastName = jc.lastName;

    // Compose the correct Jobber edit by client type.
    let input, displayField, expectDisplay;
    const base = ((jc.companyName || jc.name || row.name) || '').replace(PREFIX_RE, '').trim();
    if (jc.isCompany) {
      const newCompany = `${p.code} ${base}`;
      input = { companyName: newCompany }; displayField = 'companyName'; expectDisplay = newCompany;
    } else {
      // individual: the code must live in the DISPLAY name = firstName + lastName.
      const first_ = (jc.firstName || '').replace(PREFIX_RE, '').trim();     // "BHRE"
      const newFirst = `${p.code} ${first_}`.trim();                         // "292-BPM BHRE"
      const newCompany = `${p.code} ${base}`;                               // keep companyName consistent, no stale old code
      input = { firstName: newFirst, companyName: newCompany }; displayField = 'firstName'; expectDisplay = newFirst;
    }
    rec.new_input = input; rec.expect_display = expectDisplay;

    // skip-if-correct
    if (row.client_code === p.code && jc[displayField] === expectDisplay) { rec.result = 'SKIP_already_correct'; results.push(rec); console.log(`SKIP ${p.code} id=${p.id}: already correct`); first = false; continue; }

    if (!EXECUTE) { rec.result = 'DRY'; results.push(rec); console.log(`DRY  ${p.code} id=${p.id} (${jc.isCompany ? 'company' : 'individual'}): ${displayField} "${jc[displayField]}" -> "${expectDisplay}"; db_code ${row.client_code} -> ${p.code}`); first = false; continue; }

    // backup
    backup({ ts: new Date().toISOString(), id: p.id, mode: p.mode, name: row.name, old_db_code: row.client_code, gid: encId, isCompany: jc.isCompany, old_companyName: jc.companyName, old_firstName: jc.firstName, old_lastName: jc.lastName, new_db_code: p.code, new_input: input });

    // 1) DB write (guarded by mode)
    const guard = p.mode === 'fill' ? `client_code IS NULL` : `client_code='${esc(p.oldCode)}'`;
    let dbSet = false;
    try {
      const upd = await pg(`UPDATE clients SET client_code='${esc(p.code)}' WHERE id=${p.id} AND ${guard} RETURNING id`);
      if (upd.length) dbSet = true;
      else { const cur = (await pg(`SELECT client_code FROM clients WHERE id=${p.id}`))[0]?.client_code; rec.result = 'SKIP_db_guard'; rec.db_current = cur; results.push(rec); console.log(`SKIP ${p.code} id=${p.id}: DB guard (code='${cur}', expected ${p.mode === 'fill' ? 'NULL' : p.oldCode})`); first = false; continue; }
    } catch (e) { rec.result = 'FAIL_db_write'; rec.err = e.message; results.push(rec); console.log(`FAIL ${p.code} id=${p.id}: DB ${e.message}`); if (first) { console.log('CANARY DB write failed — aborting'); break; } continue; }

    // 2) Jobber edit
    const ed = await clientEdit(encId, input);
    if (!ed.ok) {
      await pg(`UPDATE clients SET client_code=${p.mode === 'fill' ? 'NULL' : `'${esc(p.oldCode)}'`} WHERE id=${p.id} AND client_code='${esc(p.code)}'`);
      rec.result = 'ROLLBACK_jobber_edit_failed'; rec.err = ed.err; results.push(rec); console.log(`ROLLBACK ${p.code} id=${p.id}: ${ed.err}`);
      if (first) { console.log('CANARY Jobber edit failed — aborting'); break; } continue;
    }
    // 3) verify (re-read)
    await new Promise(s => setTimeout(s, 900));
    let ver; try { ver = await readClient(encId); } catch { ver = null; }
    if (!ver || ver[displayField] !== expectDisplay) {
      // rollback DB; restore Jobber field(s) to old values
      await pg(`UPDATE clients SET client_code=${p.mode === 'fill' ? 'NULL' : `'${esc(p.oldCode)}'`} WHERE id=${p.id} AND client_code='${esc(p.code)}'`);
      const restore = jc.isCompany ? { companyName: jc.companyName } : { firstName: jc.firstName, companyName: jc.companyName };
      await clientEdit(encId, restore).catch(() => {});
      rec.result = 'ROLLBACK_verify_mismatch'; rec.verify_got = ver?.[displayField]; results.push(rec); console.log(`ROLLBACK ${p.code} id=${p.id}: verify got '${ver?.[displayField]}'`);
      if (first) { console.log('CANARY verify failed — aborting'); break; } continue;
    }
    rec.result = 'OK'; results.push(rec); console.log(`OK   ${p.code}  id=${p.id} (${jc.isCompany ? 'company' : 'individual'}): ${displayField} -> "${expectDisplay}"`);
    appendFileSync(LOG, JSON.stringify(rec) + '\n');
    first = false;
    await new Promise(s => setTimeout(s, 1500));
  }

  const ok = results.filter(r => r.result === 'OK').length;
  const dry = results.filter(r => r.result === 'DRY').length;
  const skip = results.filter(r => String(r.result).startsWith('SKIP')).length;
  const bad = results.filter(r => String(r.result).startsWith('FAIL') || String(r.result).startsWith('ROLLBACK'));
  console.log(`\n=== DONE: OK=${ok} DRY=${dry} SKIP=${skip} FAIL/ROLLBACK=${bad.length} of ${results.length} ===`);
  if (bad.length) console.log('problems: ' + JSON.stringify(bad.map(b => ({ code: b.code, id: b.id, result: b.result, err: b.err || b.verify_got })), null, 1));
  writeFileSync(RESULT, JSON.stringify({ ok, dry, skip, bad: bad.length, results }, null, 1));
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
