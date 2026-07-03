// validate_rematch.js [--apply] : validate the HIGH-confidence re-match proposals before touching the
// DB. Checks per proposal: (1) code exists -> client id; (2) row still unmatched/low in DB; (3) street-
// number consistency between the agent's OCR address and the client's known property addresses (or the
// stored address_read); (4) no same-sheet duplicate code proposals; (5) code not already matched to
// another row of the same sheet+page. --apply then updates derm.address_row_map (matched_client_id,
// status='matched', confidence='high', flags.rematch) for proposals that PASS every check.
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');
const APPLY = process.argv.includes('--apply');

const num = s => (String(s || '').match(/\d{2,6}/g) || []);

(async () => {
  const results = JSON.parse(fs.readFileSync(path.resolve(__dirname, 'data', '_rematch_result.json'), 'utf8'));
  const props = [];
  for (const r of results) for (const p of (r.proposals || [])) if (p.confidence === 'high' && p.code) props.push({ sheet: r.key, ...p });

  const codes = [...new Set(props.map(p => p.code))];
  const clients = await q(`
    select c.id, c.client_code, c.name,
      (select string_agg(coalesce(p.address,''), ' | ') from properties p where p.client_id=c.id) addrs
    from clients c where c.client_code in (${codes.map(c => `'${c}'`).join(',')})`);
  const byCode = Object.fromEntries(clients.map(c => [c.client_code, c]));

  const ids = props.map(p => p.id);
  const dbrows = await q(`select id, white_manifest_number wm, dump_folder df, page, row_index, address_read, assignment_status, confidence from derm.address_row_map where id in (${ids.join(',')})`);
  const byId = Object.fromEntries(dbrows.map(r => [r.id, r]));

  // existing matched codes per sheet+page (to catch duplicate-code-on-page)
  const pages = [...new Set(dbrows.map(r => `${r.df}|${r.page}`))];
  const existing = await q(`
    select m.dump_folder df, m.page, c.client_code
    from derm.address_row_map m join clients c on c.id=m.matched_client_id
    where m.assignment_status='matched' and (${pages.map(p => { const [df, pg] = p.split('|'); return `(m.dump_folder='${df}' and m.page=${pg})`; }).join(' or ')})`);
  const existingSet = new Set(existing.map(e => `${e.df}|${e.page}|${e.client_code}`));

  const pass = [], fail = [];
  const seenPerPage = {};
  for (const p of props) {
    const cl = byCode[p.code]; const row = byId[p.id];
    const problems = [];
    if (!cl) problems.push('code not in clients');
    if (!row) problems.push('row id not found');
    if (row && !(row.assignment_status === 'unmatched' || row.assignment_status === 'low_confidence' || row.confidence !== 'high')) problems.push(`row already ${row.assignment_status}/${row.confidence}`);
    if (cl && row) {
      // street-number consistency: any number in OCR/stored address appears in client's known addresses
      const seen = new Set([...num(p.ocr_address), ...num(row.address_read)]);
      const clientNums = new Set(num(cl.addrs));
      const overlap = [...seen].some(n => clientNums.has(n));
      if (!overlap && clientNums.size) problems.push(`no street-number overlap (ocr:[${[...seen]}] client:[${[...clientNums]}])`);
      const pageKey = `${row.df}|${row.page}|${p.code}`;
      if (existingSet.has(pageKey)) problems.push('code already matched to another row on this page');
      if (seenPerPage[pageKey]) problems.push('duplicate proposal for same code+page');
      seenPerPage[pageKey] = true;
    }
    (problems.length ? fail : pass).push({ ...p, client_id: cl && cl.id, problems });
  }

  console.log(`HIGH proposals: ${props.length}  ->  PASS ${pass.length} · FAIL ${fail.length}`);
  if (fail.length) { console.log('\n--- FAILED validation (held, NOT applied) ---'); for (const f of fail) console.log(`  id=${f.id} ${f.sheet} ${f.code}: ${f.problems.join('; ')}`); }

  if (!APPLY) { console.log('\n(dry run — pass --apply to write the PASSing matches)'); return; }
  let n = 0;
  for (const p of pass) {
    await q(`update derm.address_row_map set matched_client_id=${p.client_id}, assignment_status='matched', confidence='high',
      agent_agreement='rematch', flags = coalesce(flags,'{}'::jsonb) || '{"rematch_full_roster":"2026-07-03"}'::jsonb, updated_at=now()
      where id=${p.id}`);
    n++;
  }
  console.log(`APPLIED ${n} matches to derm.address_row_map`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
