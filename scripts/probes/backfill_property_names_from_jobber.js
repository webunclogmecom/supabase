// One-shot: pull `name` from Jobber for every property where Sbx has it NULL.
// The handler bug (fixed in 4bbcfb7) had left 458 of 470 properties with no
// name. Going forward the patched handleProperty fixes new updates; this
// script clears the historical backlog.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const CLIENT_ID = process.env.JOBBER_CLIENT_ID;
const CLIENT_SECRET = process.env.JOBBER_CLIENT_SECRET;

function http(opts, body) { return new Promise((res, rej) => {
  const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
  const req = https.request({...opts, headers:{...(opts.headers||{}), ...(payload?{'Content-Length':Buffer.byteLength(payload)}:{})}}, r => {
    const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()}));
  });
  req.on('error',rej); req.setTimeout(30000,()=>req.destroy(new Error('timeout')));
  if(payload) req.write(payload); req.end();
});}
async function pg(s){const r=await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}},JSON.stringify({query:s}));if(r.status>=300)throw new Error('PG '+r.status+': '+r.body.slice(0,300));return JSON.parse(r.body);}
async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({hostname:u.hostname,path:u.pathname+u.search,method:opts.method||'GET',headers:{apikey:SVC,Authorization:'Bearer '+SVC,'Content-Type':'application/json',...(opts.headers||{})}}, opts.body);
  if(r.status>=300) throw new Error('REST '+r.status+': '+r.body.slice(0,300));
  return r.body ? JSON.parse(r.body) : null;
}

// Jobber token mgmt (mirrors cron_jobber.js)
async function getJobberToken() {
  const rows = await rest('/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at');
  const row = rows[0];
  if (!row) throw new Error('no jobber token row');
  if (new Date(row.expires_at).getTime() > Date.now() + 60_000) return row.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(CLIENT_ID)}&client_secret=${encodeURIComponent(CLIENT_SECRET)}`;
  const tr = await http({hostname:'api.getjobber.com',path:'/api/oauth/token',method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'}}, body);
  if (tr.status>=300) throw new Error(`token refresh ${tr.status}: ${tr.body.slice(0,200)}`);
  const tokens = JSON.parse(tr.body);
  const newExp = JSON.parse(Buffer.from(tokens.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await rest('/webhook_tokens?source_system=eq.jobber', { method: 'PATCH', body: JSON.stringify({access_token:tokens.access_token,refresh_token:tokens.refresh_token||row.refresh_token,expires_at:new Date(newExp).toISOString(),updated_at:new Date().toISOString()})});
  return tokens.access_token;
}
async function gql(token, query) {
  const r = await http({hostname:'api.getjobber.com',path:'/api/graphql',method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json','X-JOBBER-GRAPHQL-VERSION':'2026-04-16'}},JSON.stringify({query}));
  if (r.status>=300) throw new Error('gql '+r.status+': '+r.body.slice(0,300));
  const j = JSON.parse(r.body);
  if (j.errors?.length) throw new Error('gql err: '+JSON.stringify(j.errors[0]));
  return j.data;
}

(async () => {
  const token = await getJobberToken();
  console.log('Got Jobber token.\n');

  // Pull all properties with NULL name + their Jobber GID
  const rows = await pg(`
    SELECT p.id, esl.source_id AS gid
    FROM properties p
    JOIN entity_source_links esl ON esl.entity_type='property' AND esl.entity_id=p.id AND esl.source_system='jobber'
    WHERE p.name IS NULL OR p.name = '';
  `);
  console.log('Properties to backfill:', rows.length);

  let ok = 0, fail = 0, skipped = 0;
  for (const r of rows) {
    try {
      const data = await gql(token, `{ property(id: "${r.gid}") { name } }`);
      const name = data?.property?.name;
      if (!name) { skipped++; continue; }
      await rest(`/properties?id=eq.${r.id}&name=is.null`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ name }) });
      // Also handle empty-string case
      await rest(`/properties?id=eq.${r.id}&name=eq.`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ name }) });
      ok++;
      if (ok % 50 === 0) console.log('  '+ok+'/'+rows.length);
    } catch (e) {
      fail++;
      if (fail <= 5) console.log('  FAIL prop '+r.id+' gid='+r.gid.slice(0,16)+'...: '+e.message);
    }
  }
  console.log('\nDone: '+ok+' filled, '+skipped+' Jobber also empty, '+fail+' failed');

  // Verify
  const final = await pg("SELECT COUNT(*)::int AS n FROM properties WHERE name IS NULL OR name='';");
  console.log('Remaining NULL name:', final[0].n);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
