// Backfill visit_assignments for visits where the webhook silently dropped
// driver capture (the numericId-vs-base64-gid bug — fixed 2026-05-15 in the
// edge function).
//
// For each visit lacking assignments:
//   1. Look up its Jobber visit gid via entity_source_links
//   2. Fetch from Jobber API: assignedUsers.nodes[].id
//   3. Map each member.id → our employees.id via entity_source_links
//   4. INSERT into visit_assignments (idempotent — ON CONFLICT DO NOTHING)
//
// Usage:
//   node scripts/sync/backfill_visit_assignments_from_jobber.js              # all missing
//   node scripts/sync/backfill_visit_assignments_from_jobber.js --limit 5    # test first

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const LIMIT = process.argv.includes('--limit') ? parseInt(process.argv[process.argv.indexOf('--limit')+1]) : null;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({status: r.statusCode, body: Buffer.concat(c).toString()}));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROD}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`);
  return JSON.parse(r.body);
}
async function jobberGql(token, query, variables) {
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
    }
  }, JSON.stringify({ query, variables }));
  if (r.status !== 200) throw new Error(`Jobber ${r.status}: ${r.body.slice(0,200)}`);
  return JSON.parse(r.body);
}

async function getJobberToken() {
  const rows = await pg("SELECT access_token, refresh_token, client_id, client_secret, expires_at FROM webhook_tokens WHERE source_system='jobber' LIMIT 1;");
  if (!rows.length) throw new Error('No jobber token in webhook_tokens');
  const t = rows[0];
  // Valid (with 60s buffer)
  if (t.access_token && new Date(t.expires_at) > new Date(Date.now() + 60_000)) return t.access_token;
  // Refresh
  console.log('  token expired — refreshing...');
  const resp = await http({
    hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST',
    headers: { 'Content-Type': 'application/json' }
  }, JSON.stringify({
    grant_type: 'refresh_token', refresh_token: t.refresh_token,
    client_id: t.client_id, client_secret: t.client_secret,
  }));
  if (resp.status !== 200) throw new Error(`Token refresh ${resp.status}: ${resp.body}`);
  const tok = JSON.parse(resp.body);
  const expiresAt = new Date(Date.now() + (tok.expires_in ?? 7200) * 1000).toISOString();
  await pg(`UPDATE webhook_tokens SET access_token='${tok.access_token.replace(/'/g,"''")}', refresh_token='${(tok.refresh_token ?? t.refresh_token).replace(/'/g,"''")}', expires_at='${expiresAt}', updated_at=now() WHERE source_system='jobber';`);
  console.log('  fresh token, expires:', expiresAt);
  return tok.access_token;
}

(async () => {
  console.log('Fetching Jobber access token...');
  const token = await getJobberToken();

  console.log('Building employee Jobber-gid → employee_id map (one query)...');
  const empRows = await pg(`SELECT esl.source_id, esl.entity_id FROM entity_source_links esl WHERE esl.entity_type='employee' AND esl.source_system='jobber';`);
  const empMap = new Map(empRows.map(r => [r.source_id, r.entity_id]));
  console.log(`  ${empMap.size} employees mapped`);

  const limitClause = LIMIT ? `LIMIT ${LIMIT}` : '';
  const visits = await pg(`
    SELECT v.id AS visit_id, c.client_code, v.visit_date,
           esl.source_id AS jobber_visit_gid
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.visit_status='completed'
      AND NOT EXISTS (SELECT 1 FROM visit_assignments WHERE visit_id=v.id)
    ORDER BY v.visit_date DESC
    ${limitClause};
  `);
  console.log(`  ${visits.length} visits to backfill`);

  let visitsFixed = 0, assignmentsWritten = 0, jobberEmptyAssignments = 0, fail = 0;
  const failures = [];

  for (const v of visits) {
    try {
      const data = await jobberGql(token, `
        query($id: EncodedId!) {
          visit(id: $id) {
            id
            assignedUsers { nodes { id } }
          }
        }
      `, { id: v.jobber_visit_gid });

      if (data.errors) throw new Error(JSON.stringify(data.errors));
      const nodes = data.data?.visit?.assignedUsers?.nodes || [];
      if (!nodes.length) { jobberEmptyAssignments++; continue; }

      const empIds = nodes.map(n => empMap.get(n.id)).filter(Boolean);
      if (!empIds.length) {
        failures.push({ visit_id: v.visit_id, reason: `Jobber returned ${nodes.length} members but none mapped (gids: ${nodes.map(n=>n.id).join(',')})` });
        fail++;
        continue;
      }

      const values = empIds.map(eid => `(${v.visit_id}, ${eid})`).join(',');
      await pg(`INSERT INTO visit_assignments (visit_id, employee_id) VALUES ${values} ON CONFLICT (visit_id, employee_id) DO NOTHING;`);
      visitsFixed++;
      assignmentsWritten += empIds.length;
    } catch (e) {
      failures.push({ visit_id: v.visit_id, reason: e.message.slice(0, 200) });
      fail++;
    }
    if ((visitsFixed + jobberEmptyAssignments + fail) % 20 === 0) {
      console.log(`  progress: ${visitsFixed} fixed (+${assignmentsWritten} rows), ${jobberEmptyAssignments} truly unassigned in Jobber, ${fail} failed`);
    }
  }

  console.log(`\n=== Result ===`);
  console.log(`  visits fixed:                ${visitsFixed}`);
  console.log(`  assignments inserted:        ${assignmentsWritten}`);
  console.log(`  jobber truly had no driver:  ${jobberEmptyAssignments}`);
  console.log(`  failed:                      ${fail}`);
  if (failures.length) {
    console.log('\nFailures:');
    failures.slice(0, 20).forEach(f => console.log(`  visit ${f.visit_id}: ${f.reason}`));
  }

  console.log('\n=== Verify: 092-TCE 2026-05-04 (visit 3915) ===');
  console.log(await pg(`
    SELECT v.id, v.visit_date, c.client_code,
           (SELECT string_agg(e.full_name, ', ') FROM visit_assignments va JOIN employees e ON e.id=va.employee_id WHERE va.visit_id=v.id) AS drivers
    FROM visits v JOIN clients c ON c.id=v.client_id
    WHERE v.id = 3915;
  `));

  console.log('\n=== Coverage: completed visits without drivers (should be near 0) ===');
  console.log(await pg(`
    SELECT
      COUNT(*) FILTER (WHERE v.visit_status='completed')::int AS total_completed,
      COUNT(*) FILTER (WHERE v.visit_status='completed' AND NOT EXISTS (SELECT 1 FROM visit_assignments WHERE visit_id=v.id))::int AS still_without_drivers
    FROM visits v;
  `));
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
