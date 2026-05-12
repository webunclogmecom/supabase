// For each of the 10 overdue clients, verify whether they're SUPPOSED to be
// on a recurring GT/CL schedule, by checking:
//   - clients.status (our DB)
//   - Airtable Clients fields (Status, Days of the week, GT Frequency, Hours)
//   - Jobber jobs.recurring (via webhook-jobber data)
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  for (let i = 0; i < 3; i++) {
    const r = await http({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, JSON.stringify({ query: sql }));
    if (r.status < 300) return JSON.parse(r.body);
    await new Promise(rs => setTimeout(rs, 4000));
  }
  throw new Error('5xx');
}

async function airtableGet(recordId) {
  const r = await http({
    hostname: 'api.airtable.com',
    path: `/v0/${AT_BASE}/Clients/${recordId}`,
    method: 'GET',
    headers: { Authorization: `Bearer ${AT_KEY}` }
  });
  if (r.status >= 300) return { error: `HTTP ${r.status}` };
  return JSON.parse(r.body);
}

async function jobberGql(query, variables) {
  const { getValidToken } = require('../sync/jobber_token.js');
  const tok = await getValidToken({ verbose: false });
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${tok}`,
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-13',
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
  }, body);
  return JSON.parse(r.body);
}

const CLIENTS = [
  ['013-DIM',  'CL'],
  ['026-HAP',  'CL'],
  ['172-NU',   'GT'],
  ['174-VIN',  'GT'],
  ['029-JOS',  'GT'],
  ['069-TCE',  'GT'],
  ['070-TCE',  'CL'],
  ['089-COW',  'GT'],
  ['083-SHUL', 'CL'],
  ['112-YA',   'GT'],
];

(async () => {
  const codeList = CLIENTS.map(c => `'${c[0]}'`).join(',');

  // Pull our DB status + jobber + airtable record IDs
  const dbRows = await pg(`
    SELECT
      c.client_code, c.id AS our_id, c.status AS db_status, c.name,
      MAX(CASE WHEN esl.source_system='airtable' THEN esl.source_id END) AS at_id,
      MAX(CASE WHEN esl.source_system='jobber'   THEN esl.source_id END) AS jobber_gid
    FROM clients c
    LEFT JOIN entity_source_links esl ON esl.entity_type='client' AND esl.entity_id=c.id
    WHERE c.client_code IN (${codeList})
    GROUP BY c.id, c.client_code, c.status, c.name;
  `);
  const dbMap = Object.fromEntries(dbRows.map(r => [r.client_code, r]));

  // Pull jobs per client to check for recurring
  const jobsByClient = {};
  for (const r of dbRows) {
    if (!r.jobber_gid) continue;
    try {
      const out = await jobberGql(
        `query($id: EncodedId!) { client(id: $id) { jobs(first: 30) { nodes { id title jobberWebUri jobStatus startAt endAt jobType } } } }`,
        { id: r.jobber_gid }
      );
      jobsByClient[r.client_code] = (out.data?.client?.jobs?.nodes || []);
    } catch (e) {
      jobsByClient[r.client_code] = [];
    }
  }

  console.log(`code     | DB status | AT Status         | AT GT Freq | AT CL Freq | AT Days       | Jobber jobs (open recurring?)`);
  console.log(`---------|-----------|-------------------|------------|------------|---------------|------------------------------`);

  for (const [code, svc] of CLIENTS) {
    const db = dbMap[code];
    if (!db) { console.log(`${code} not found`); continue; }
    let at = {};
    if (db.at_id) {
      const r = await airtableGet(db.at_id);
      if (!r.error) at = r.fields || {};
    }
    const status = at['Status'] || at['Active'] || at['Type'] || '';
    const gtFreq = at['GT Frequency'] || '';
    const clFreq = at['CL Frequency'] || '';
    const days   = at['Days of the week'] || at['Days of the Week'] || at['Service Days'] || '';
    const daysStr = Array.isArray(days) ? days.join(',') : String(days);

    const jobs = jobsByClient[code] || [];
    const recurring = jobs.filter(j => /recurring/i.test(j.jobType || ''));
    const open = jobs.filter(j => !/archived|complete/i.test(j.jobStatus || ''));
    const jobSummary = jobs.length === 0 ? 'no jobs found' :
      `${jobs.length} total, ${recurring.length} recurring, ${open.length} open` +
      (jobs.length ? ` [latest jobType=${jobs[0].jobType || '?'} status=${jobs[0].jobStatus || '?'}]` : '');

    console.log(`${code.padEnd(8)} | ${(db.db_status || '?').padEnd(9)} | ${String(status).slice(0,17).padEnd(17)} | ${String(gtFreq).padStart(10)} | ${String(clFreq).padStart(10)} | ${daysStr.slice(0,13).padEnd(13)} | ${jobSummary}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
