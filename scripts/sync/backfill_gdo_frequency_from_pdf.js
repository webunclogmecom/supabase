// v2: only backfill from a PDF whose GDO number MATCHES the row it is filed under.
// v1 found 17 rows carrying someone else's permit document; importing a frequency
// from one of those would plant another site's DERM compliance ceiling.
const fs = require('fs');
const { parseGdoPermit } = require('../lib/gdo_permit_parser');

const APPLY = process.argv.includes('--apply');
const env = {};
for (const l of fs.readFileSync('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env', 'utf8').split(/\r?\n/)) {
  const i = l.indexOf('=');
  if (i > 0 && !l.trim().startsWith('#')) env[l.slice(0, i).trim()] = l.slice(i + 1).trim();
}
const REF = 'wbasvhvvismukaqdnouk';
const BUCKET = `https://${REF}.supabase.co/storage/v1/object/public/gdo-permits/`;

async function q(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error('HTTP ' + r.status + ' ' + t.slice(0, 400));
  return JSON.parse(t);
}
const digits = s => { const m = String(s || '').match(/\d+/); return m ? parseInt(m[0], 10) : null; };

(async () => {
  const rows = await q(`select id, gdo_number, status, permit_expiration::text as exp,
                               max_frequency_days as freq, permit_document_path
                        from public.gdos where permit_document_path is not null
                        order by gdo_number`);

  const rec = [];
  for (const g of rows) {
    let p = null, fetched = false;
    try {
      const r = await fetch(BUCKET + g.permit_document_path);
      if (r.ok) { p = parseGdoPermit(Buffer.from(await r.arrayBuffer())); fetched = true; }
    } catch (e) {}
    const pdfDigits = p && p.fields.gdo_number_digits;
    rec.push({
      id: g.id, gdo: g.gdo_number, dbFreq: g.freq, dbExp: g.exp,
      fetched, isDerm: !!(p && p.isDermPermit),
      pdfGdo: p && p.fields.gdo_number || null,
      pdfFreq: p && p.fields.max_frequency_days != null ? p.fields.max_frequency_days : null,
      pdfExp: p && p.fields.permit_expiration || null,
      numMatch: pdfDigits != null && digits(g.gdo_number) === pdfDigits,
    });
  }

  const derm = rec.filter(r => r.isDerm);
  const mismatched = derm.filter(r => !r.numMatch);
  const matched = derm.filter(r => r.numMatch);

  const freqCheck = matched.filter(r => r.dbFreq != null && r.pdfFreq != null);
  const freqAgree = freqCheck.filter(r => r.dbFreq === r.pdfFreq);
  const freqDisagree = freqCheck.filter(r => r.dbFreq !== r.pdfFreq);
  const fillable = matched.filter(r => r.dbFreq == null && r.pdfFreq != null);

  console.log('=== SCOPE ===');
  console.log(`  rows with a PDF            : ${rec.length}`);
  console.log(`  parsed as a DERM permit    : ${derm.length}`);
  console.log(`  PDF number MATCHES the row : ${matched.length}`);
  console.log(`  PDF number MISMATCH        : ${mismatched.length}   <- excluded from backfill`);
  console.log('\n=== GROUND TRUTH, matched rows only ===');
  console.log(`  freq agree    : ${freqAgree.length}`);
  console.log(`  freq disagree : ${freqDisagree.length}`);
  freqDisagree.forEach(r => console.log(`      ${r.gdo}: db=${r.dbFreq} pdf=${r.pdfFreq}`));
  console.log(`\n=== BACKFILLABLE (matched, db NULL) : ${fillable.length} ===`);
  const dist = {}; fillable.forEach(r => dist[r.pdfFreq] = (dist[r.pdfFreq] || 0) + 1);
  console.log('  distribution : ' + JSON.stringify(dist));
  console.log('\n=== MISMATCHED PDFs (data-quality finding, NOT touched) ===');
  mismatched.forEach(r => console.log(`  id ${String(r.id).padStart(4)}  row=${r.gdo.padEnd(24)} pdf=${r.pdfGdo}`));

  fs.writeFileSync('backfill_v2.json', JSON.stringify({ fillable, mismatched, freqDisagree }, null, 1));

  if (!APPLY) { console.log('\nDRY RUN. --apply writes only the matched NULLs.'); return; }
  // Block only if a row we are about to WRITE disagrees. A disagreement on a row that
  // already has a value is a finding to report, not a reason to withhold 48 unrelated
  // NULL fills - and we never overwrite an existing value here anyway.
  const fillableIds = new Set(fillable.map(r => r.id));
  const blocking = freqDisagree.filter(r => fillableIds.has(r.id));
  if (blocking.length > 0) { console.log('\nREFUSING: a row being written disagrees with its PDF.'); return; }
  if (freqDisagree.length > 0) {
    console.log(`\nNOTE: ${freqDisagree.length} disagreement(s) on rows that ALREADY have a value.`);
    console.log('      Not written, not overwritten. Reported for a human decision.');
  }
  if (!fillable.length) { console.log('\nNothing to do.'); return; }

  const cases = fillable.map(r => `when ${r.id} then ${r.pdfFreq}`).join(' ');
  const ids = fillable.map(r => r.id).join(',');
  const applied = await q(`
    select set_config('request.headers','{"x-app-source":"gdo-permit-pdf-backfill"}',false);
    update public.gdos set max_frequency_days = case id ${cases} end
     where id in (${ids}) and max_frequency_days is null
     returning id, gdo_number, max_frequency_days;`);
  console.log(`\nAPPLIED: ${applied.length} rows.`);
  fs.writeFileSync('backfill_applied.json', JSON.stringify(applied, null, 1));
})();
