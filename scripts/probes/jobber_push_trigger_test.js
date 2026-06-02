// ============================================================================
// jobber_push_trigger_test.js — verify the REALTIME trigger auto-fires the push.
// Inserts a source='visit-calendar' visit on 112-YA and WAITS (no manual function
// call) for the trigger -> pg_net -> Edge Function -> Jobber chain to link the GID.
// Then cleans up everything. Safe: 112-YA test account.
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true, quiet: true });
const https = require('https');
const SUP = process.env.SUPABASE_URL, PAT = process.env.SUPABASE_PAT;
const ref = SUP.match(/https?:\/\/([^.]+)\./)[1];
const sleep = ms => new Promise(r => setTimeout(r, ms));
function sql(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:'/v1/projects/'+ref+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{if(x.statusCode>=300)return rej(new Error(x.statusCode+': '+d.slice(0,200)));res(JSON.parse(d));});});r.on('error',rej);r.write(b);r.end();});}
function post(host,path,body,headers){return new Promise((res,rej)=>{const r=https.request({hostname:host,path,method:'POST',headers:{...headers,'Content-Length':Buffer.byteLength(body)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>res({status:x.statusCode,body:d}));});r.on('error',rej);r.write(body);r.end();});}
async function tok(){const row=(await sql("SELECT access_token,refresh_token,client_id,client_secret,expires_at::text e FROM public.webhook_tokens WHERE source_system='jobber_write'"))[0];if(new Date(row.e).getTime()>Date.now()+120000)return row.access_token;const b='grant_type=refresh_token&refresh_token='+encodeURIComponent(row.refresh_token)+'&client_id='+encodeURIComponent(row.client_id)+'&client_secret='+encodeURIComponent(row.client_secret);const tr=await post('api.getjobber.com','/api/oauth/token',b,{'Content-Type':'application/x-www-form-urlencoded'});const t=JSON.parse(tr.body);const exp=JSON.parse(Buffer.from(t.access_token.split('.')[1],'base64').toString()).exp*1000;await sql("UPDATE public.webhook_tokens SET access_token='"+t.access_token+"',refresh_token='"+(t.refresh_token||row.refresh_token)+"',expires_at='"+new Date(exp).toISOString()+"',updated_at=now() WHERE source_system='jobber_write'");return t.access_token;}
async function jvisit(tk,gid){const r=await post('api.getjobber.com','/api/graphql',JSON.stringify({query:'query($id:EncodedId!){ visit(id:$id){ id title startAt endAt allDay } }',variables:{id:gid}}),{Authorization:'Bearer '+tk,'Content-Type':'application/json','X-JOBBER-GRAPHQL-VERSION':'2026-04-16'});return JSON.parse(r.body).data?.visit??null;}
async function linkGid(vid){const l=await sql("SELECT source_id FROM public.entity_source_links WHERE entity_type='visit' AND entity_id="+vid+" AND source_system='jobber'");return l[0]?.source_id??null;}

(async()=>{
  const tk=await tok();
  let vid;
  try{
    const sli=(await sql("SELECT id FROM public.service_line_items WHERE code='01'"))[0].id;
    vid=(await sql("INSERT INTO public.visits (client_id, job_id, visit_date, title, service_type, visit_status, source, service_line_item_id) VALUES (381, 159, '2026-06-29', '01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning', 'GT', 'scheduled', 'visit-calendar', "+sli+") RETURNING id"))[0].id;
    console.log('[trig] inserted visit-calendar visit id='+vid+' — NO manual call; waiting for the trigger to auto-push...');
    let gid=null;
    for(let i=0;i<9;i++){ await sleep(2000); gid=await linkGid(vid); if(gid){ console.log('[trig] ✅ auto-pushed + linked after ~'+((i+1)*2)+'s: '+gid); break; } }
    if(!gid){
      console.log('[trig] ❌ no link after ~18s. Diagnostics:');
      const resp=await sql("SELECT id, status_code, left(content,160) content, error_msg FROM net._http_response ORDER BY id DESC LIMIT 3").catch(e=>('('+e.message+')'));
      console.log('[trig]   net._http_response:', JSON.stringify(resp));
      console.log('[trig]   flag:', JSON.stringify(await sql("SELECT reason, detail FROM public.visit_sync_flags WHERE visit_id="+vid)));
    } else {
      console.log('[trig]   jobber visit:', JSON.stringify(await jvisit(tk,gid)));
    }
  } finally {
    if(vid){
      const gid=await linkGid(vid);
      if(gid && await jvisit(tk,gid)){ await post('api.getjobber.com','/api/graphql',JSON.stringify({query:'mutation($ids:[EncodedId!]!){ visitDelete(visitIds:$ids){ userErrors{ message } } }',variables:{ids:[gid]}}),{Authorization:'Bearer '+tk,'Content-Type':'application/json','X-JOBBER-GRAPHQL-VERSION':'2026-04-16'}); console.log('[trig] deleted jobber visit',gid); }
      await sql("DELETE FROM public.entity_source_links WHERE entity_type='visit' AND entity_id="+vid);
      await sql("DELETE FROM public.visit_sync_flags WHERE visit_id="+vid);
      await sql("DELETE FROM public.visits WHERE id="+vid);
      console.log('[trig] cleaned up test visit',vid);
    }
  }
})().catch(e=>{console.error('[trig] FATAL:',e.message);process.exit(1);});
