// Is Jobber still auto-generating visits (recurring jobs ON)?
// Query Jobber directly for FUTURE visits (startAt >= today). Many systematic
// future visits => recurring jobs firing. Few/none => off (only manual).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true });
const fs = require('fs');
const path = require('path');
const https = require('https');
const SB = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
function req({host,path,method='GET',headers={},body=null}){return new Promise((resolve,reject)=>{const p=body==null?null:(typeof body==='string'?body:JSON.stringify(body));const r=https.request({hostname:host,path,method,headers:{...headers,...(p?{'Content-Length':Buffer.byteLength(p)}:{})}},(res)=>{let d='';res.on('data',c=>d+=c);res.on('end',()=>resolve({status:res.statusCode,body:d}));});r.on('error',reject);r.setTimeout(60000,()=>r.destroy(new Error('timeout')));if(p)r.write(p);r.end();});}
async function getToken(){const r=await req({host:SB.replace('https://','').split('/')[0],path:'/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at',headers:{apikey:KEY,Authorization:`Bearer ${KEY}`}});const row=JSON.parse(r.body)[0];if(new Date(row.expires_at).getTime()>Date.now()+60000)return row.access_token;const body=`grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(process.env.JOBBER_CLIENT_ID)}&client_secret=${encodeURIComponent(process.env.JOBBER_CLIENT_SECRET)}`;const tr=await req({host:'api.getjobber.com',path:'/api/oauth/token',method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body});const t=JSON.parse(tr.body);const exp=JSON.parse(Buffer.from(t.access_token.split('.')[1],'base64').toString()).exp*1000;await req({host:SB.replace('https://','').split('/')[0],path:'/rest/v1/webhook_tokens?source_system=eq.jobber',method:'PATCH',headers:{apikey:KEY,Authorization:`Bearer ${KEY}`,'Content-Type':'application/json'},body:JSON.stringify({access_token:t.access_token,refresh_token:t.refresh_token||row.refresh_token,expires_at:new Date(exp).toISOString(),updated_at:new Date().toISOString()})});return t.access_token;}

(async () => {
  const TK = await getToken();
  const todayISO = new Date().toISOString().slice(0,10) + 'T00:00:00Z';
  const all = [];
  let after = null, pages = 0;
  do {
    const q = `query($after:String,$filter:VisitFilterAttributes){ visits(first:50, after:$after, filter:$filter){ pageInfo{ hasNextPage endCursor } totalCount nodes{ id title startAt visitStatus createdAt client{ name } job{ jobNumber } } } }`;
    const r = await req({host:'api.getjobber.com',path:'/api/graphql',method:'POST',headers:{Authorization:`Bearer ${TK}`,'Content-Type':'application/json','X-JOBBER-GRAPHQL-VERSION':'2026-04-16'},body:JSON.stringify({query:q,variables:{after,filter:{startAt:{after:todayISO}}}})});
    const j = JSON.parse(r.body);
    if (j.errors) { fs.writeFileSync(path.resolve(__dirname,'../../reports/_jobber_future.json'), JSON.stringify({error:j.errors},null,2)); process.stdout.write('GQL_ERR:'+JSON.stringify(j.errors[0])+'\n'); return; }
    const conn = j.data.visits;
    if (pages === 0) var totalCount = conn.totalCount;
    for (const n of conn.nodes) all.push(n);
    after = conn.pageInfo.hasNextPage ? conn.pageInfo.endCursor : null;
    pages++;
  } while (after && pages < 6);

  // analyze
  const byMonth = {}, byCreatedDay = {}, byClient = {}; let scheduled = 0;
  const next90 = []; const cutoff90 = new Date(Date.now() + 90*86400000).toISOString().slice(0,10);
  for (const v of all) {
    const m = (v.startAt||'').slice(0,7); byMonth[m] = (byMonth[m]||0)+1;
    const cd = (v.createdAt||'').slice(0,10); byCreatedDay[cd] = (byCreatedDay[cd]||0)+1;
    const cl = v.client?.name || '?'; byClient[cl] = (byClient[cl]||0)+1;
    if (v.visitStatus === 'ACTIVE' || v.visitStatus === 'LATE' || !v.completedAt) scheduled++;
    const sd = (v.startAt||'').slice(0,10);
    if (sd >= todayISO.slice(0,10) && sd <= cutoff90 && !/^112-YA/.test(cl)) next90.push({ start: sd, client: cl, title: v.title, created: (v.createdAt||'').slice(0,10), status: v.visitStatus });
  }
  const byClientSorted = Object.fromEntries(Object.entries(byClient).sort((a,b)=>b[1]-a[1]));
  const out = { ran_at:new Date().toISOString(), today: todayISO.slice(0,10), total_future_visits_in_jobber: typeof totalCount!=='undefined'?totalCount:all.length, fetched: all.length, by_start_month: byMonth, by_created_day: byCreatedDay, by_client: byClientSorted, next90_non_112ya: next90.sort((a,b)=>a.start.localeCompare(b.start)) };
  fs.writeFileSync(path.resolve(__dirname,'../../reports/_jobber_future.json'), JSON.stringify(out,null,2));
  process.stdout.write('JOBBER_FUTURE total='+out.total_future_visits_in_jobber+' fetched='+all.length+' months='+JSON.stringify(byMonth)+'\n');
})().catch(e => { process.stdout.write('ERR:'+e.message+'\n'); process.exit(1); });
