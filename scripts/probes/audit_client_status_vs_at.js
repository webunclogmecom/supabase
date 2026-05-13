// Cross-reference clients.status (Sbx) vs ACTIVE/INACTIVE (AT) for every
// linked client. Flag any drift — AT says one thing, Sbx says another.
//
// AT's option "Recuring" (typo) is normalized to "RECURRING" on read.
// "Active" / "ACTIVE" / "RECURRING" / "PAUSED" / "INACTIVE" supported.
//
// Run with no flag = audit only. Pass --execute to UPDATE Sbx to match AT.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const EXECUTE = process.argv.includes('--execute');

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(s) { const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:s})); if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300)); return JSON.parse(r.body); }
async function listAT(table, fields, filter) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => 'fields%5B%5D='+enc(f)).join('&');
    const ff = filter ? '&filterByFormula='+enc(filter) : '';
    const path = '/v0/'+AT_BASE+'/'+enc(table)+'?'+fp+'&pageSize=100'+ff+(offset?'&offset='+enc(offset):'');
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:'Bearer '+AT_KEY}});
    if (r.status>=300) throw new Error('AT '+r.status+': '+r.body.slice(0,200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields});
    offset = j.offset;
  } while (offset);
  return out;
}
function normStatus(s) {
  if (!s) return null;
  const name = (s && s.name) || s;
  const v = String(name).toUpperCase().trim();
  if (v === 'RECURING') return 'RECURRING';
  return v;
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE (will sync Sbx to AT)' : 'AUDIT ONLY'}\n`);
  const sbx = await pg(`
    SELECT c.id, c.client_code, c.name, c.status,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable' LIMIT 1) AS at_id
    FROM clients c;
  `);
  const at = await listAT('Clients', ['Client Name','ACTIVE/INACTIVE']);
  const atById = new Map(at.map(c => [c.id, c]));

  const drifts = [];
  for (const c of sbx) {
    if (!c.at_id) continue;
    const ac = atById.get(c.at_id);
    if (!ac) continue;
    const atStatus = normStatus(ac['ACTIVE/INACTIVE']);
    if (!atStatus) continue;
    if (atStatus !== c.status) {
      drifts.push({ client_code: c.client_code, name: c.name, sbx: c.status, at: atStatus, id: c.id });
    }
  }

  console.log('Status drift (Sbx ≠ AT):', drifts.length);
  for (const d of drifts) console.log('  '+(d.client_code||'(no code)').padEnd(11)+'Sbx='+d.sbx.padEnd(11)+'AT='+d.at.padEnd(11)+(d.name||''));

  if (!EXECUTE || drifts.length === 0) {
    if (drifts.length && !EXECUTE) console.log('\n[AUDIT] Re-run with --execute to sync Sbx to AT.');
    return;
  }

  console.log('\nUpdating Sbx to match AT...');
  let ok = 0;
  for (const d of drifts) {
    const r = await pg(`UPDATE clients SET status='${d.at}' WHERE id=${d.id} RETURNING id;`);
    if (r.length) ok++;
  }
  console.log('Updated', ok, 'rows.');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
