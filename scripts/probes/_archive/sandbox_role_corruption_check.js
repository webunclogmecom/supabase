require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql, projectId) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${projectId}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res(JSON.parse(b)));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
(async () => {
  console.log('=== Sandbox photo_links.role distribution ===');
  const sbx = await pg(`SELECT role, COUNT(*) AS n FROM photo_links GROUP BY role ORDER BY n DESC;`, SBX);
  console.log(JSON.stringify(sbx, null, 2));

  console.log('\n=== Prod photo_links.role distribution ===');
  const prod = await pg(`SELECT role, COUNT(*) AS n FROM photo_links GROUP BY role ORDER BY n DESC;`, PROD);
  console.log(JSON.stringify(prod, null, 2));

  console.log('\n=== Sandbox: any photo_links with role IN (before, after, completion)? ===');
  const corrupt = await pg(`
    SELECT entity_type, role, COUNT(*) AS n,
      MIN(created_at) AS earliest, MAX(created_at) AS latest
    FROM photo_links
    WHERE role IN ('before','after','completion','during','unknown')
    GROUP BY entity_type, role
    ORDER BY n DESC;`, SBX);
  console.log(JSON.stringify(corrupt, null, 2));

  console.log('\n=== Sample classified rows: what was their role BEFORE Lovable overwrote? (check Prod for comparison) ===');
  const lovableTouched = await pg(`
    SELECT id, photo_id, entity_type, entity_id, role
    FROM photo_links
    WHERE role IN ('before','after','completion','during','unknown')
    ORDER BY id DESC LIMIT 10;`, SBX);
  console.log('Sandbox rows:', JSON.stringify(lovableTouched, null, 2));
  if (lovableTouched.length > 0) {
    const ids = lovableTouched.map(r => r.id).join(',');
    const prodRows = await pg(`SELECT id, photo_id, entity_type, entity_id, role FROM photo_links WHERE id IN (${ids});`, PROD);
    console.log('\nSame IDs in Prod:', JSON.stringify(prodRows, null, 2));
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
