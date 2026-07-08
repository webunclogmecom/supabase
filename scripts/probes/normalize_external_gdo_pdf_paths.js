// normalize_external_gdo_pdf_paths.js  (2026-07-08, one-off, re-runnable)
// 14 ACTIVE gdos rows (June AT-ingest wave) store permit_document_path as an ABSOLUTE
// stecmrerportal.blob.core.windows.net URL instead of the canonical bucket path
// 'gdo/<GDO_NUMBER>.pdf'. External URLs can rot and the apps build links from the
// gdo-permits public bucket. This script: for each such row, downloads the external
// PDF, uploads it to gdo-permits/gdo/<gdo_number>.pdf (upsert), and repoints
// permit_document_path. Idempotent: skips rows already bucket-relative; upload is
// upsert; UPDATE guarded on the old value. Backup JSON written to ../backups/.
// Default DRY-RUN; --apply to write. NEVER prints secrets.

const https = require('https');
const fs = require('fs');
const path = require('path');

const APPLY = process.argv.includes('--apply');
const env = Object.fromEntries(
  fs.readFileSync(path.resolve(__dirname, '../../.env'), 'utf8')
    .split(/\r?\n/).filter(l => l.includes('=') && !l.trim().startsWith('#'))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; })
);
const PAT = env.SUPABASE_PAT;
const PROJECT = env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';
const SERVICE_KEY = env.SUPABASE_SERVICE_ROLE_KEY;
const BUCKET = 'gdo-permits';

function pg(sql) {
  return new Promise((res) => {
    const b = JSON.stringify({ query: sql });
    const r = https.request({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { let j; try { j = JSON.parse(d); } catch { j = { raw: d }; } res({ status: x.statusCode, body: j }); }); });
    r.on('error', e => res({ status: 0, body: { err: e.message } })); r.write(b); r.end();
  });
}

function download(url) {
  return new Promise((res) => {
    https.get(url, (x) => {
      if (x.statusCode !== 200) { res(null); return; }
      const chunks = [];
      x.on('data', c => chunks.push(c));
      x.on('end', () => res(Buffer.concat(chunks)));
    }).on('error', () => res(null));
  });
}

function upload(objectPath, buf) {
  return new Promise((res) => {
    const r = https.request({ hostname: `${PROJECT}.supabase.co`, path: `/storage/v1/object/${BUCKET}/${objectPath}`, method: 'POST',
      headers: { Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/pdf', 'x-upsert': 'true', 'Content-Length': buf.length } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res({ status: x.statusCode, body: d.slice(0, 120) })); });
    r.on('error', e => res({ status: 0, body: e.message })); r.write(buf); r.end();
  });
}

const esc = s => String(s).replace(/'/g, "''");

(async () => {
  const { body: rows } = await pg(`
    select g.id, c.client_code, g.gdo_number, g.permit_document_path
    from gdos g join clients c on c.id = g.client_id
    where g.permit_document_path like 'https://%'
    order by c.client_code`);
  if (!Array.isArray(rows)) { console.log('query failed', JSON.stringify(rows).slice(0, 200)); return; }
  console.log(`External-URL permit paths: ${rows.length}  (${APPLY ? 'APPLY' : 'DRY-RUN'})`);

  // backup
  const backupPath = path.resolve(__dirname, '../../../backups/2026-07-08_gdo_external_paths_backup.json');
  if (APPLY) fs.writeFileSync(backupPath, JSON.stringify(rows, null, 2));

  let ok = 0, fail = 0;
  for (const r of rows) {
    const m = /^GDO-\d+$/.exec(r.gdo_number || '');
    if (!m) { console.log(`  SKIP ${r.client_code} — non-canonical gdo_number '${r.gdo_number}'`); fail++; continue; }
    const objectPath = `gdo/${r.gdo_number}.pdf`;
    if (!APPLY) { console.log(`  would: ${r.client_code} ${r.gdo_number} -> ${objectPath}`); ok++; continue; }
    const buf = await download(r.permit_document_path);
    if (!buf || buf.length < 5000) { console.log(`  FAIL download ${r.client_code} ${r.gdo_number} (${buf ? buf.length + 'B' : 'null'})`); fail++; continue; }
    const up = await upload(objectPath, buf);
    if (up.status !== 200) { console.log(`  FAIL upload ${r.client_code} ${r.gdo_number}: ${up.status} ${up.body}`); fail++; continue; }
    const { body: upd } = await pg(`update gdos set permit_document_path='${esc(objectPath)}'
      where id=${r.id} and permit_document_path='${esc(r.permit_document_path)}' returning id`);
    if (Array.isArray(upd) && upd.length === 1) { console.log(`  ok ${r.client_code} ${r.gdo_number} (${(buf.length / 1024).toFixed(0)}KB)`); ok++; }
    else { console.log(`  FAIL update ${r.client_code}: ${JSON.stringify(upd).slice(0, 120)}`); fail++; }
    await new Promise(s => setTimeout(s, 400));
  }
  console.log(`done: ok=${ok} fail=${fail}`);
  const { body: fin } = await pg(`select count(*) filter (where permit_document_path like 'https://%') ext,
    count(*) filter (where status='ACTIVE' and permit_document_path is not null) active_with_path from gdos`);
  console.log('DB final:', JSON.stringify(fin));
})();
