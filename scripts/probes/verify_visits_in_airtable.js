// For each "completed but no photo" visit in our DB, look up its source
// record in Airtable and report:
//   - Does the record actually exist in Airtable?
//   - If so, what's its date in Airtable vs in our DB?
//   - Visit Status?
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    req.end();
  });
}

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>res({status:r.statusCode,body:d})); });
    req.on('error', rej); req.write(body); req.end();
  });
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0,200)}`);
  return JSON.parse(r.body);
}

async function airtableGet(table, recordId) {
  const r = await http({
    hostname: 'api.airtable.com',
    path: `/v0/${AT_BASE}/${encodeURIComponent(table)}/${recordId}`,
    method: 'GET',
    headers: { Authorization: `Bearer ${AT_KEY}` },
  });
  if (r.status === 404) return { notFound: true };
  if (r.status >= 300) return { error: `${r.status}: ${r.body.slice(0,80)}` };
  return JSON.parse(r.body);
}

(async () => {
  console.log('Pulling all missing-photo visits with Airtable IDs from last 4 weeks...\n');
  const visits = await pg(`
    SELECT v.id, v.visit_date, c.client_code,
           esl.source_id AS at_id
    FROM visits v
    JOIN clients c ON c.id=v.client_id
    JOIN entity_source_links esl
      ON esl.entity_type='visit' AND esl.source_system='airtable' AND esl.entity_id=v.id
    WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
      AND v.visit_date <= current_date
      AND v.visit_status = 'completed'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
    ORDER BY v.visit_date DESC LIMIT 30;
  `);
  console.log(`Checking ${visits.length} Airtable-linked visits...\n`);

  const results = [];
  let foundCount = 0, missingCount = 0, dateMatchCount = 0, dateMismatchCount = 0;
  for (const v of visits) {
    const at = await airtableGet('Visits', v.at_id);
    let status, atDate, atStatus, dateMatch;

    if (at.notFound) {
      status = '✗ NOT FOUND in Airtable';
      missingCount++;
    } else if (at.error) {
      status = `ERR ${at.error}`;
    } else {
      foundCount++;
      const f = at.fields || {};
      atDate = f['Visit Date'] || f['Date'] || f['Service Date'] || null;
      atStatus = f['Status'] || f['Visit Status'] || null;
      const ourDate = String(v.visit_date).slice(0,10);
      const atDateClean = atDate ? String(atDate).slice(0,10) : null;
      dateMatch = atDateClean === ourDate ? '✓' : `✗ AT=${atDateClean}`;
      if (atDateClean === ourDate) dateMatchCount++; else dateMismatchCount++;
      status = `✓ FOUND  date=${dateMatch}  AT-status=${atStatus || '(n/a)'}`;
    }
    results.push({ db_id: v.id, our_date: String(v.visit_date).slice(0,10), code: v.client_code,
                   at_id: v.at_id, status });
    await new Promise(r => setTimeout(r, 200));
  }
  console.table(results);

  console.log(`\n=== Summary ===`);
  console.log(`  Total checked:              ${visits.length}`);
  console.log(`  Found in Airtable:          ${foundCount}`);
  console.log(`  NOT in Airtable (orphan):   ${missingCount}`);
  console.log(`  Date matches (ours = AT):   ${dateMatchCount}`);
  console.log(`  Date MISMATCH:              ${dateMismatchCount}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
