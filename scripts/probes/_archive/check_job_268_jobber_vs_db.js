require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }

(async () => {
  // 1. Get the Jobber GID for job 268
  console.log('=== Step 1: Get Jobber GID for job 268 ===');
  const esl = await pg(`
    SELECT esl.source_id AS jobber_gid, esl.source_system
    FROM entity_source_links esl
    WHERE esl.entity_type='job' AND esl.entity_id = 268;`);
  console.log(JSON.stringify(esl, null, 2));

  if (!esl[0]?.jobber_gid) { console.log('No Jobber GID — exit'); return; }
  const gid = esl[0].jobber_gid;

  // 2. What's our DB line_items.updated_at for this job?
  console.log('\n=== Step 2: Our DB line_items state ===');
  const dbLi = await pg(`
    SELECT id, name, quantity, unit_price, total_price,
      created_at AT TIME ZONE 'America/New_York' AS created_et,
      updated_at AT TIME ZONE 'America/New_York' AS updated_et
    FROM line_items WHERE job_id = 268 ORDER BY id;`);
  for (const r of dbLi) console.log(`  id=${r.id}  name="${r.name}"  $${r.unit_price} created=${r.created_et}  updated=${r.updated_et}`);

  // 3. What webhook events have we processed for job 268 / its Jobber GID?
  console.log('\n=== Step 3: Webhook events touching this job ===');
  const wel = await pg(`
    SELECT event_type, status,
      created_at AT TIME ZONE 'America/New_York' AS created_et,
      payload->>'eventType' AS event_type_payload,
      LEFT(payload::text, 200) AS payload_preview
    FROM webhook_events_log
    WHERE source_system='jobber'
      AND (payload::text ILIKE '%${gid.replace(/'/g, "''")}%' OR payload::text ILIKE '%10000186%')
    ORDER BY created_at DESC LIMIT 10;`);
  console.log(`  ${wel.length} matching events`);
  for (const r of wel) console.log(`    ${r.created_et}  ${r.event_type}  ${r.status}  ${r.payload_preview.slice(0,150)}`);

  // 4. Query Jobber GraphQL for the current state
  console.log('\n=== Step 4: Ask Jobber what it currently says about job 268 ===');
  const tokens = await pg(`SELECT access_token FROM webhook_tokens WHERE source_system='jobber' LIMIT 1;`);
  if (!tokens[0]) { console.log('  No Jobber access token in DB'); return; }
  const accessToken = tokens[0].access_token;

  const query = `
    query GetJob($id: EncodedId!) {
      job(id: $id) {
        id
        title
        lineItems(first: 50) {
          nodes {
            id
            name
            description
            quantity
            unitPrice
            totalPrice
            updatedAt
          }
        }
      }
    }`;

  const body = JSON.stringify({ query, variables: { id: gid } });
  const r = await http({
    hostname: 'api.getjobber.com',
    path: '/api/graphql',
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
      'X-JOBBER-GRAPHQL-VERSION': '2024-04-01',
    }
  }, body);

  if (r.status >= 300) {
    console.log(`  Jobber API ${r.status}: ${r.body.slice(0,300)}`);
    return;
  }
  const j = JSON.parse(r.body);
  if (j.errors) { console.log(`  Jobber errors:`, JSON.stringify(j.errors, null, 2)); return; }

  console.log(`  Jobber job title: "${j.data.job.title}"`);
  console.log(`  Jobber line items:`);
  for (const li of j.data.job.lineItems.nodes) {
    console.log(`    "${li.name}"  qty=${li.quantity}  $${li.unitPrice}  total=$${li.totalPrice}  updatedAt=${li.updatedAt}`);
  }

  // 5. Compare
  console.log('\n=== Comparison ===');
  const dbNames = new Set(dbLi.map(r => r.name?.trim()));
  const jbNames = new Set(j.data.job.lineItems.nodes.map(n => n.name?.trim()));
  const onlyDB = [...dbNames].filter(n => !jbNames.has(n));
  const onlyJB = [...jbNames].filter(n => !dbNames.has(n));
  console.log(`  In our DB but NOT in Jobber:`, onlyDB);
  console.log(`  In Jobber but NOT in our DB:`, onlyJB);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
