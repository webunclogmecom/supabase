// One-shot: provision Field Portal Sandbox Supabase project via Management API.
// Run once. Outputs new project ref + anon/service keys + db password.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const crypto = require('crypto');

const PAT = process.env.SUPABASE_PAT;
const ORG_ID = 'ollsldgefginswbujzgw';        // Dev - Unclogme org (parent of Prod + Sbx1)
const NAME = 'Field Portal Sandbox';
const REGION = 'us-east-1';
const PLAN = 'free';

if (!PAT) { console.error('Missing SUPABASE_PAT'); process.exit(1); }

// Generate a strong DB password — 32 chars, alphanumeric only so no shell-
// escape headaches when this lands in URLs / .env / GH Secrets.
function genPassword() {
  const alphabet = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let out = '';
  for (let i = 0; i < 32; i++) out += alphabet[crypto.randomInt(alphabet.length)];
  return out;
}

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function api(method, path, body) {
  const r = await http({
    hostname: 'api.supabase.com', path: '/v1' + path, method,
    headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json' },
  }, body ? JSON.stringify(body) : null);
  if (r.status >= 300) throw new Error(`API ${method} ${path} -> ${r.status}: ${r.body.slice(0, 500)}`);
  if (!r.body) return null;
  return JSON.parse(r.body);
}

(async () => {
  const dbPass = genPassword();

  console.log('Creating project:', NAME);
  console.log('  org_id:', ORG_ID, '| region:', REGION, '| plan:', PLAN);
  console.log('  db_pass (KEEP — saved nowhere yet):', dbPass);

  const created = await api('POST', '/projects', {
    name: NAME,
    organization_id: ORG_ID,
    region: REGION,
    plan: PLAN,
    db_pass: dbPass,
  });
  console.log('\nCreate response:');
  console.log(JSON.stringify(created, null, 2));
  const ref = created.id || created.ref;
  if (!ref) throw new Error('No ref returned in create response');

  // Poll for ACTIVE_HEALTHY (project provisioning can take ~60-120s).
  console.log('\nWaiting for project to become ACTIVE_HEALTHY...');
  let info = null;
  for (let i = 0; i < 40; i++) {
    await new Promise(r => setTimeout(r, 5000));
    info = await api('GET', '/projects/' + ref, null);
    console.log(`  poll ${i+1}: status=${info.status}`);
    if (info.status === 'ACTIVE_HEALTHY') break;
  }

  // Pull API keys
  let keys = [];
  try { keys = await api('GET', '/projects/' + ref + '/api-keys', null); }
  catch (e) { console.warn('Could not fetch keys yet:', e.message); }

  const anon = (keys.find(k => k.name === 'anon') || {}).api_key || '<NOT YET AVAILABLE>';
  const service = (keys.find(k => k.name === 'service_role') || {}).api_key || '<NOT YET AVAILABLE>';
  const url = `https://${ref}.supabase.co`;
  const dbUrl = `postgres://postgres.${ref}:${dbPass}@aws-1-us-east-1.pooler.supabase.com:5432/postgres`;

  console.log('\n========== ADD TO .env (no quotes) ==========');
  console.log(`FIELD_PORTAL_SUPABASE_URL=${url}`);
  console.log(`FIELD_PORTAL_SUPABASE_PROJECT_ID=${ref}`);
  console.log(`FIELD_PORTAL_SUPABASE_ANON_KEY=${anon}`);
  console.log(`FIELD_PORTAL_SUPABASE_SERVICE_ROLE_KEY=${service}`);
  console.log(`FIELD_PORTAL_DB_URL=${dbUrl}`);
  console.log('==============================================');
  console.log('\nReady for Lovable: give Yannick the URL +ANON_KEY (NOT the service key).');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
