// ============================================================================
// jobber_write_smoketest.js — prove the Calendar→Jobber write path end-to-end
// on the 112-YA TEST client only. Creates a visit on one of 112-YA's jobs, reads
// it back, then DELETES it (cleanup). notifyTeam:false so no crew gets pinged.
//
//   node scripts/probes/jobber_write_smoketest.js            # create -> verify -> delete
//   node scripts/probes/jobber_write_smoketest.js --keep     # create -> verify, DO NOT delete
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true });
const https = require('https');
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const KEEP = process.argv.includes('--keep');
const YA_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ='; // 112-YA test client

function qq(v){ return v==null ? 'NULL' : "'"+String(v).replace(/'/g,"''")+"'"; }
function sql(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:'/v1/projects/'+ref+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{if(x.statusCode>=300)return rej(new Error(x.statusCode+': '+d.slice(0,200)));res(JSON.parse(d));});});r.on('error',rej);r.write(b);r.end();});}
function post(host,path,body,headers){return new Promise((res,rej)=>{const r=https.request({hostname:host,path,method:'POST',headers:{...headers,'Content-Length':Buffer.byteLength(body)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>res({status:x.statusCode,body:d}));});r.on('error',rej);r.write(body);r.end();});}
function gql(tok,query,variables){return post('api.getjobber.com','/api/graphql',JSON.stringify({query,variables}),{Authorization:'Bearer '+tok,'Content-Type':'application/json','X-JOBBER-GRAPHQL-VERSION':'2026-04-16'}).then(r=>{const j=JSON.parse(r.body);if(j.errors)throw new Error('GraphQL: '+JSON.stringify(j.errors).slice(0,300));return j;});}

// read+refresh the jobber_write token
async function getToken(){
  const row=(await sql("SELECT access_token, refresh_token, client_id, client_secret, expires_at::text FROM public.webhook_tokens WHERE source_system='jobber_write'"))[0];
  if(new Date(row.expires_at).getTime() > Date.now()+120000) return row.access_token;
  const body='grant_type=refresh_token&refresh_token='+encodeURIComponent(row.refresh_token)+'&client_id='+encodeURIComponent(row.client_id)+'&client_secret='+encodeURIComponent(row.client_secret);
  const tr=await post('api.getjobber.com','/api/oauth/token',body,{'Content-Type':'application/x-www-form-urlencoded'});
  if(tr.status>=300) throw new Error('refresh '+tr.status+': '+tr.body.slice(0,150));
  const t=JSON.parse(tr.body); const exp=JSON.parse(Buffer.from(t.access_token.split('.')[1],'base64').toString()).exp*1000;
  await sql("UPDATE public.webhook_tokens SET access_token="+qq(t.access_token)+", refresh_token="+qq(t.refresh_token||row.refresh_token)+", expires_at="+qq(new Date(exp).toISOString())+", updated_at=now() WHERE source_system='jobber_write'");
  console.log('[smoke] refreshed jobber_write token');
  return t.access_token;
}

(async()=>{
  const tok = await getToken();

  // 1) find a job on 112-YA
  const cj = await gql(tok, `query($id: EncodedId!){ client(id:$id){ id name jobs(first:10){ nodes{ id jobNumber title jobStatus jobType } } } }`, { id: YA_GID });
  const client = cj.data.client;
  if(!client){ console.log('112-YA client not found via API'); return; }
  console.log('[smoke] client:', client.name, '| jobs:', client.jobs.nodes.length);
  client.jobs.nodes.forEach(j=>console.log('   job#'+j.jobNumber, j.jobType, j.jobStatus, '|', JSON.stringify(j.title)));
  const job = client.jobs.nodes.find(j=>j.jobStatus!=='archived') || client.jobs.nodes[0];
  if(!job){ console.log('[smoke] 112-YA has NO jobs — cannot attach a visit. (Would need jobCreate first.)'); return; }
  console.log('[smoke] using job#'+job.jobNumber, JSON.stringify(job.title));

  // 2) introspect visitDelete args (so cleanup is correct)
  const vdArgs = (await gql(tok, `{ __type(name:"Mutation"){ fields{ name args{ name type{ kind name ofType{ kind name } } } } } }`))
    .data.__type.fields.find(f=>f.name==='visitDelete');
  const unwrap=t=>!t?'?':t.kind==='NON_NULL'?unwrap(t.ofType)+'!':t.kind==='LIST'?'['+unwrap(t.ofType)+']':t.name;
  console.log('[smoke] visitDelete('+vdArgs.args.map(a=>a.name+':'+unwrap(a.type)).join(', ')+')');

  // 3) visitCreate a clearly-labelled TEST visit
  const variables = { jobId: job.id, input: { visits: [{
    title: 'SMOKE TEST - Calendar sync (auto-delete)',
    instructions: 'Automated write-path smoke test. Safe to delete.',
    schedule: {
      startAt: { date: '2026-06-20', time: '09:00:00', timezone: 'America/New_York' },
      endAt:   { date: '2026-06-20', time: '10:00:00', timezone: 'America/New_York' },
      notifyTeam: false, teamMemberIdsToAssign: []
    }
  }]}};
  const cr = await gql(tok, `mutation($jobId: EncodedId!, $input: VisitCreateInput!){ visitCreate(jobId:$jobId, input:$input){ createdVisits{ id title startAt endAt } userErrors{ message path } } }`, variables);
  const payload = cr.data.visitCreate;
  if(payload.userErrors && payload.userErrors.length){ console.log('[smoke] ❌ userErrors:', JSON.stringify(payload.userErrors)); return; }
  const visit = payload.createdVisits[0];
  console.log('[smoke] ✅ created visit:', JSON.stringify(visit));

  // 4) read it back
  const rb = await gql(tok, `query($id: EncodedId!){ visit(id:$id){ id title startAt endAt job{ id jobNumber } } }`, { id: visit.id });
  console.log('[smoke] read-back:', JSON.stringify(rb.data.visit));

  // 5) cleanup
  if(KEEP){ console.log('[smoke] --keep set; LEAVING the test visit in Jobber:', visit.id); return; }
  const del = await gql(tok, `mutation($ids: [EncodedId!]!){ visitDelete(visitIds:$ids){ userErrors{ message path } } }`, { ids: [visit.id] });
  const de = del.data.visitDelete;
  if(de.userErrors && de.userErrors.length){ console.log('[smoke] ⚠️ delete userErrors:', JSON.stringify(de.userErrors), '— visit', visit.id, 'still in Jobber, delete manually'); }
  else console.log('[smoke] ✅ deleted test visit', visit.id, '— Jobber clean.');
})().catch(e=>{ console.error('[smoke] FATAL:', e.message); process.exit(1); });
