// backfill_client_status_from_airtable.js
//
// Re-assert Airtable-canonical client status (ACTIVE/RECURRING/PAUSED/INACTIVE)
// onto public.clients. Run AFTER deploying the webhook-jobber no-clobber fix
// (2026-05-31) — otherwise cron_jobber re-clobbers RECURRING→ACTIVE.
//
// Airtable's "ACTIVE/INACTIVE" field is canonical for client status per CLAUDE.md.
// webhook-jobber used to overwrite it with 'ACTIVE' on every replay, causing the
// status to flap. This corrects the historical drift (68 mismatches on 2026-05-31).
//
// Idempotent: only updates rows where DB status differs from AT status (no-op rows
// skipped, so audit.logs stays clean). X-App-Source: sql.
//
//   node scripts/sync/backfill_client_status_from_airtable.js          # dry-run
//   node scripts/sync/backfill_client_status_from_airtable.js --apply  # write

const fs = require('fs');
const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const AT_KEY = process.env.AIRTABLE_API_KEY, AT_BASE = process.env.AIRTABLE_BASE_ID;
const SB_URL = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT, PROJECT = process.env.SUPABASE_PROJECT_ID;
const APPLY = process.argv.includes('--apply');
const VALID = new Set(['ACTIVE', 'RECURRING', 'PAUSED', 'INACTIVE']);

function atGet(p){return new Promise((res,rej)=>{https.get({hostname:'api.airtable.com',path:p,headers:{Authorization:'Bearer '+AT_KEY}},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{if(r.statusCode>=300)return rej(new Error(r.statusCode+': '+d.slice(0,200)));res(JSON.parse(d));});}).on('error',rej);});}
function pg(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:'/v1/projects/'+PROJECT+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},(rs)=>{let d='';rs.on('data',c=>d+=c);rs.on('end',()=>res(d));});r.on('error',rej);r.write(b);r.end();});}
function rest(pathStr, body){return new Promise((res,rej)=>{const p=JSON.stringify(body);const r=https.request({hostname:SB_URL.replace('https://','').split('/')[0],path:pathStr,method:'PATCH',headers:{apikey:KEY,Authorization:'Bearer '+KEY,'Content-Type':'application/json','X-App-Source':'sql',Prefer:'return=minimal','Content-Length':Buffer.byteLength(p)}},(rs)=>{let d='';rs.on('data',c=>d+=c);rs.on('end',()=>res({status:rs.statusCode,body:d}));});r.on('error',rej);r.write(p);r.end();});}
async function atAll(table){let all=[],offset=null;do{const q=new URLSearchParams({pageSize:'100'});if(offset)q.append('offset',offset);const j=await atGet('/v0/'+AT_BASE+'/'+table+'?'+q);all=all.concat(j.records);offset=j.offset;}while(offset);return all;}

(async () => {
  console.log(`Mode: ${APPLY ? 'APPLY' : 'DRY-RUN'}`);
  const at = await atAll('tbl5lXLtHKUWilDDj');
  const atStatusByCode = {};
  for (const r of at) {
    const code = r.fields['Client Code #3'];
    let s = r.fields['ACTIVE/INACTIVE'];
    if (!code || !s) continue;
    s = String(s).toUpperCase().trim();
    if (s === 'RECURING') s = 'RECURRING';
    if (VALID.has(s)) atStatusByCode[code] = s;
  }

  const db = JSON.parse(await pg(`SELECT id, client_code, status FROM public.clients WHERE client_code IS NOT NULL`));
  const toFix = [];
  for (const row of db) {
    const ats = atStatusByCode[row.client_code];
    if (ats && ats !== row.status) toFix.push({ id: row.id, code: row.client_code, from: row.status, to: ats });
  }

  const byPair = {};
  for (const f of toFix) { const k = f.from + '→' + f.to; byPair[k] = (byPair[k]||0)+1; }
  console.log(`AT clients with valid status: ${Object.keys(atStatusByCode).length}`);
  console.log(`DB rows needing correction:   ${toFix.length}`);
  console.log(`By transition: ${JSON.stringify(byPair)}`);

  if (!APPLY) {
    fs.writeFileSync(path.resolve(__dirname,'../../reports/_status_backfill_plan.json'), JSON.stringify({ count: toFix.length, by_pair: byPair, rows: toFix }, null, 2));
    console.log('(dry-run; pass --apply to write). Plan: reports/_status_backfill_plan.json');
    return;
  }

  let ok = 0, fail = 0;
  for (const f of toFix) {
    const r = await rest(`/rest/v1/clients?id=eq.${f.id}`, { status: f.to });
    if (r.status < 300) ok++; else { fail++; console.log(`  FAIL ${f.code}: ${r.status} ${r.body.slice(0,120)}`); }
  }
  console.log(`Applied: ok=${ok} fail=${fail}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
