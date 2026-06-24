// cron_gdo_permit_pdf_ingest.js
// Backfill/refresh public.gdos.permit_document_path + the gdo-permits storage bucket
// from Miami-Dade DERM operating-permit PDFs, so the Visit Calendar drawer's
// "View permit" resolves. Generalizes docs/audits/2026-05-25-gdo-phase-2/probes/18_phase_6_pdf_backfill.js:
//   - source 1: the Phase-2 bot result JSONs (pre-found pdf_url per gdo_number)
//   - source 2 (NEW): live DERM Strategy-0 case-number lookup for GDOs the bot
//                     never resolved (derm_lookup.py lookup_gdo_permit(gdo_number=...))
//
// For every ACTIVE gdo missing a permit_document_path: resolve a pdf_url, download
// it, upload to gdo-permits/gdo/<gdo_number>.<ext>, and set permit_document_path.
// The bucket is PUBLIC (2026-06-24 decision) so the drawer serves it directly.
//
// Idempotent: skips a gdo whose permit_document_path already points at an existing
// object. Guarded UPDATE (only when NULL or different). Default DRY-RUN; pass --apply
// to download/upload/write. NEVER prints secrets. Needs SUPABASE_SERVICE_ROLE_KEY.
//
// Usage:  node scripts/sync/cron_gdo_permit_pdf_ingest.js            # dry-run
//         node scripts/sync/cron_gdo_permit_pdf_ingest.js --apply    # write

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
const SUPABASE_URL = env.SUPABASE_URL || `https://${PROJECT}.supabase.co`;
const SERVICE_KEY = env.SUPABASE_SERVICE_ROLE_KEY;
const BUCKET = 'gdo-permits';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const DERM_DELAY = 600;

function pg(sql) {
  return new Promise((res) => {
    const b = JSON.stringify({ query: sql });
    const r = https.request({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { let j; try { j = JSON.parse(d); } catch { j = { raw: d }; } res({ status: x.statusCode, body: j }); }); });
    r.on('error', e => res({ status: 0, body: { err: e.message } })); r.write(b); r.end();
  });
}
const digits = g => { const m = /(\d+)/.exec(String(g || '')); return m ? parseInt(m[1], 10) : null; };
const normGdo = g => { const n = digits(g); return n == null ? null : 'GDO-' + String(n).padStart(5, '0'); };

function dermLookup(gdoNumber) {
  return new Promise((res) => {
    const caseN = normGdo(gdoNumber);
    const b = JSON.stringify({ page: '1', limit: '10', sortOrder: 'date_desc', searchTerm: '', facilityName: '', caseNumber: caseN,
      folio: '', documentType: 'OPERATING PERMIT', startDate: '', endDate: '', houseNumber: '', streetDirection: '', streetName: '', streetType: '', zipCode: '', description: '' });
    const r = https.request({ hostname: 'api-ecmrer.miamidade.gov', path: '/derm/documents', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b), 'User-Agent': UA, 'Accept': 'application/json, text/plain, */*' } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => {
        let j; try { j = JSON.parse(d); } catch { j = {}; }
        const data = Array.isArray(j.data) ? j.data : [];
        // exact integer-digit case-number match (handles GDO-000951 vs GDO-00951), most recent first
        const want = digits(gdoNumber);
        const hit = data.find(rec => digits(rec.caseNumber) === want && /\.(pdf|tif)$/i.test(rec.url || ''));
        res(hit ? hit.url : null);
      }); });
    r.on('error', () => res(null)); r.write(b); r.end();
  });
}

function httpFetch(url) {
  return new Promise((res, rej) => {
    const u = new URL(url);
    https.get({ hostname: u.hostname, path: u.pathname + u.search, headers: { 'User-Agent': UA } }, r => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) { res(httpFetch(r.headers.location)); return; }
      const chunks = []; r.on('data', c => chunks.push(c)); r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(chunks) }));
    }).on('error', rej);
  });
}

function uploadToBucket(objectPath, body, contentType) {
  return new Promise((res, rej) => {
    const u = new URL(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${objectPath}`);
    const r = https.request({ hostname: u.hostname, path: u.pathname, method: 'POST',
      headers: { Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': contentType, 'Content-Length': body.length, 'x-upsert': 'true' } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res({ status: x.statusCode, body: d })); });
    r.on('error', rej); r.write(body); r.end();
  });
}

function loadGdoUrlMap() {
  const map = new Map();
  const dir = path.resolve(__dirname, '../../docs/audits/2026-05-25-gdo-phase-2/probes');
  for (const fn of ['09_phase_2b_results.json', '12_phase_2c_results.json']) {
    const p = path.join(dir, fn); if (!fs.existsSync(p)) continue;
    const data = JSON.parse(fs.readFileSync(p, 'utf8'));
    for (const r of (data.results || [])) {
      const bot = r.bot || {};
      for (const g of [bot.gdo_number, r.gdo_number].filter(Boolean)) if (bot.pdf_url && !map.has(g)) map.set(g, bot.pdf_url);
    }
  }
  return map;
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  if (!PAT) { console.error('Need SUPABASE_PAT'); process.exit(1); }
  if (APPLY && !SERVICE_KEY) { console.error('--apply needs SUPABASE_SERVICE_ROLE_KEY'); process.exit(1); }
  console.log(`Mode: ${APPLY ? 'APPLY (download+upload+write)' : 'DRY-RUN (resolve URLs only)'}`);

  const urlMap = loadGdoUrlMap();
  const gdos = (await pg(`SELECT id, gdo_number, permit_document_path FROM public.gdos WHERE status='ACTIVE' AND permit_document_path IS NULL ORDER BY gdo_number`)).body;
  console.log(`ACTIVE GDOs missing a permit_document_path: ${gdos.length}\n`);

  let fromJson = 0, fromDerm = 0, noDoc = 0, uploaded = 0, errors = 0;
  const unresolved = [];
  for (let i = 0; i < gdos.length; i++) {
    const g = gdos[i];
    let url = urlMap.get(g.gdo_number) || null;
    let src = url ? 'json' : null;
    if (!url && digits(g.gdo_number) != null) { url = await dermLookup(g.gdo_number); if (url) src = 'derm'; await sleep(DERM_DELAY); }
    if (!url) { noDoc++; unresolved.push(g.gdo_number); continue; }
    if (src === 'json') fromJson++; else fromDerm++;

    const ext = /\.tif$/i.test(url) ? '.tif' : '.pdf';
    const ct = ext === '.tif' ? 'image/tiff' : 'application/pdf';
    const objectPath = `gdo/${g.gdo_number}${ext}`;
    if (!APPLY) { if ((fromJson + fromDerm) % 15 === 0) console.log(`  ...resolved ${fromJson + fromDerm} (json=${fromJson} derm=${fromDerm}), noDoc=${noDoc}`); continue; }

    try {
      const fetched = await httpFetch(url);
      if (fetched.status !== 200) { console.log(`  ${g.gdo_number}: DL HTTP ${fetched.status}`); errors++; continue; }
      const up = await uploadToBucket(objectPath, fetched.body, ct);
      if (up.status !== 200 && up.status !== 201) { console.log(`  ${g.gdo_number}: UP HTTP ${up.status} ${up.body.slice(0, 80)}`); errors++; continue; }
      const note = `[2026-06-24 ingest] permit_document_path backfilled from ${src === 'derm' ? 'DERM Strategy-0 case-number lookup' : 'Phase-2 bot pdf_url'}; uploaded to Supabase Storage bucket "${BUCKET}".`;
      await pg(`UPDATE public.gdos SET permit_document_path='${objectPath}', notes=COALESCE(notes||E'\\n','')||'${note.replace(/'/g, "''")}' WHERE id=${g.id} AND (permit_document_path IS NULL OR permit_document_path<>'${objectPath}')`);
      uploaded++;
      if (uploaded % 10 === 0) console.log(`  uploaded ${uploaded} (json=${fromJson} derm=${fromDerm}, noDoc=${noDoc}, err=${errors})`);
    } catch (e) { console.log(`  ${g.gdo_number}: ERR ${String(e).slice(0, 80)}`); errors++; }
  }

  console.log(`\n=== GDO permit ingest summary (${APPLY ? 'APPLY' : 'DRY-RUN'}) ===`);
  console.log(`Resolvable from bot JSON:   ${fromJson}`);
  console.log(`Resolvable from DERM live:  ${fromDerm}`);
  console.log(`No DERM operating permit:   ${noDoc}`);
  if (APPLY) { console.log(`Uploaded + linked:          ${uploaded}`); console.log(`Errors:                     ${errors}`); }
  if (unresolved.length) console.log(`Unresolved (${unresolved.length}), e.g.: ${unresolved.slice(0, 12).join(', ')}`);

  if (APPLY) {
    const after = (await pg(`SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int active, COUNT(*) FILTER (WHERE status='ACTIVE' AND permit_document_path IS NOT NULL)::int with_path FROM public.gdos`)).body;
    const orphan = (await pg(`SELECT COUNT(*)::int n FROM public.gdos g WHERE g.permit_document_path IS NOT NULL AND NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id='${BUCKET}' AND o.name=g.permit_document_path)`)).body;
    console.log(`\nDB final: ${JSON.stringify(after)}  orphans(path->no object): ${JSON.stringify(orphan)}`);
  } else {
    console.log('\n(dry-run; pass --apply to download/upload/write)');
  }
})().catch(e => { console.error('FATAL', e); process.exit(1); });
