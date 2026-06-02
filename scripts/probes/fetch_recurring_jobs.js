// fetch_recurring_jobs.js — pull all recurring Jobber jobs + their line items,
// joined to our client_code, into a JSON file. Sheet generation happens
// downstream (xlsx skill).

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const TOK = process.env.JOBBER_ACCESS_TOKEN;
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function jobber(query) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query });
    const req = https.request({
      hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: { Authorization: 'Bearer ' + TOK, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2025-01-20', 'Content-Length': Buffer.byteLength(body) }
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('Pulling our DB client lookup...');
  const dbClients = await pg(`
    SELECT esl.source_id AS jobber_gid, c.client_code, c.name
    FROM public.entity_source_links esl
    JOIN public.clients c ON c.id = esl.entity_id
    WHERE esl.entity_type='client' AND esl.source_system='jobber'`);
  const byGid = Object.fromEntries(dbClients.map(r => [r.jobber_gid, { client_code: r.client_code, name: r.name }]));
  console.log('  ', dbClients.length, 'Jobber→Supabase client mappings loaded');

  // Paginate Jobber recurring jobs. Page size 15 keeps cost ~360 per page;
  // 2s sleep restores ~1000 query points (rate is 500/sec) so we never hit
  // the THROTTLED ceiling.
  let allJobs = [];
  let cursor = null;
  let page = 0;
  while (true) {
    page++;
    const after = cursor ? `, after: "${cursor}"` : '';
    const q = `{
      jobs(filter: { jobType: RECURRING }, first: 15${after}) {
        totalCount
        pageInfo { endCursor hasNextPage }
        nodes {
          id jobNumber jobType jobStatus title total
          startAt endAt
          client { id name companyName }
          property { id }
          lineItems { nodes { name description quantity unitPrice totalPrice taxable } }
        }
      }
    }`;
    let r;
    for (let attempt = 1; attempt <= 4; attempt++) {
      r = await jobber(q);
      if (r.errors && r.errors[0]?.extensions?.code === 'THROTTLED') {
        const wait = 3 * attempt;
        console.log(`  throttled on page ${page} (attempt ${attempt}), sleeping ${wait}s`);
        await new Promise(res => setTimeout(res, wait * 1000));
        continue;
      }
      break;
    }
    if (r.errors) { console.error('Jobber errors:', JSON.stringify(r.errors)); process.exit(1); }
    const j = r.data.jobs;
    const cost = r.extensions?.cost;
    allJobs = allJobs.concat(j.nodes);
    console.log(`  page ${page}: ${j.nodes.length} jobs (total ${allJobs.length}/${j.totalCount}) — cost ${cost?.actualQueryCost} · avail ${cost?.throttleStatus?.currentlyAvailable}`);
    if (!j.pageInfo.hasNextPage) break;
    cursor = j.pageInfo.endCursor;
    await new Promise(res => setTimeout(res, 2000));
  }
  console.log('Total recurring jobs fetched:', allJobs.length);

  // Enrich with our client_code lookup
  for (const j of allJobs) {
    const mapped = byGid[j.client.id];
    j.our_client_code = mapped ? mapped.client_code : null;
    j.our_client_name = mapped ? mapped.name : null;
  }

  // Group by client (sort: client_code asc, then job_number)
  const byClient = {};
  for (const j of allJobs) {
    const key = j.our_client_code || j.client.companyName || j.client.name || '(no client)';
    if (!byClient[key]) byClient[key] = { client_code: j.our_client_code, client_name: j.our_client_name || j.client.companyName || j.client.name, jobber_client_id: j.client.id, jobs: [] };
    byClient[key].jobs.push(j);
  }
  const groups = Object.values(byClient).sort((a, b) => {
    const ka = a.client_code || 'zzz_' + (a.client_name || '');
    const kb = b.client_code || 'zzz_' + (b.client_name || '');
    return ka.localeCompare(kb);
  });
  for (const g of groups) g.jobs.sort((a, b) => (a.jobNumber || 0) - (b.jobNumber || 0));

  // Write JSON
  const outPath = path.resolve(__dirname, '../../docs/audits/2026-05-19/recurring_jobs.json');
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify({ generated_at: new Date().toISOString(), total_jobs: allJobs.length, client_count: groups.length, groups }, null, 2));
  console.log('\nWritten:', outPath);
  console.log('Clients:', groups.length, '· Jobs:', allJobs.length, '· Line items:', allJobs.reduce((s, j) => s + (j.lineItems?.nodes?.length || 0), 0));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
