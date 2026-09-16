// ============================================================================
// calendar_task_jobber_edit.js — edit ONE Jobber Task directly (simulating a change made in the
// Jobber UI) so the poll's inbound adoption can be tested. Write token read from
// public.webhook_tokens, never printed.
//   node scripts/probes/calendar_task_jobber_edit.js <our calendar_task id> '<TaskEditInput JSON>'
//   e.g. ... 245 '{"title":"Renamed in Jobber","startAt":"2026-09-20T14:00:00Z","endAt":"2026-09-20T14:30:00Z","allDay":false}'
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true });
const https = require('https');
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const [taskId, inputJson] = process.argv.slice(2);
if (!taskId || !inputJson) { console.error('usage: <task id> <TaskEditInput json>'); process.exit(1); }

function qq(v){ return v==null ? 'NULL' : "'"+String(v).replace(/'/g,"''")+"'"; }
function sql(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:'/v1/projects/'+ref+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{if(x.statusCode>=300)return rej(new Error(x.statusCode+': '+d.slice(0,200)));res(JSON.parse(d));});});r.on('error',rej);r.write(b);r.end();});}
function post(host,path,body,headers){return new Promise((res,rej)=>{const r=https.request({hostname:host,path,method:'POST',headers:{...headers,'Content-Length':Buffer.byteLength(body)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>res({status:x.statusCode,body:d}));});r.on('error',rej);r.write(body);r.end();});}
function gql(tok,query,variables){return post('api.getjobber.com','/api/graphql',JSON.stringify({query,variables}),{Authorization:'Bearer '+tok,'Content-Type':'application/json','X-JOBBER-GRAPHQL-VERSION':'2026-04-16'}).then(r=>{if(r.body.slice(0,1)!=='{')throw new Error('non-JSON reply at HTTP '+r.status);return JSON.parse(r.body);});}
async function getToken(){
  const row=(await sql("SELECT access_token, refresh_token, client_id, client_secret, expires_at::text FROM public.webhook_tokens WHERE source_system='jobber_write'"))[0];
  if(new Date(row.expires_at).getTime() > Date.now()+120000) return row.access_token;
  const body='grant_type=refresh_token&refresh_token='+encodeURIComponent(row.refresh_token)+'&client_id='+encodeURIComponent(row.client_id)+'&client_secret='+encodeURIComponent(row.client_secret);
  const tr=await post('api.getjobber.com','/api/oauth/token',body,{'Content-Type':'application/x-www-form-urlencoded'});
  if(tr.status>=300) throw new Error('refresh '+tr.status+': '+tr.body.slice(0,150));
  const t=JSON.parse(tr.body); const exp=JSON.parse(Buffer.from(t.access_token.split('.')[1],'base64').toString()).exp*1000;
  await sql("UPDATE public.webhook_tokens SET access_token="+qq(t.access_token)+", refresh_token="+qq(t.refresh_token||row.refresh_token)+", expires_at="+qq(new Date(exp).toISOString())+", updated_at=now() WHERE source_system='jobber_write'");
  return t.access_token;
}
const errs=(res,field)=>[...(Array.isArray(res?.errors)?res.errors.map(e=>e.message):[]),...((res?.data?.[field]?.userErrors)||[]).map(e=>e.message)];

(async()=>{
  const link=(await sql("SELECT source_id FROM public.entity_source_links WHERE entity_type='calendar_task' AND source_system='jobber' AND entity_id="+Number(taskId)))[0];
  if(!link){ console.error('no Jobber link for calendar task '+taskId); process.exit(1); }
  const gid=link.source_id;
  const input=JSON.parse(inputJson);
  // an employee id list in "assignee_employee_ids" is translated to Jobber user GIDs here
  if(Array.isArray(input.assignee_employee_ids)){
    const rows=await sql("SELECT entity_id, source_id FROM public.entity_source_links WHERE entity_type='employee' AND source_system='jobber' AND entity_id IN ("+input.assignee_employee_ids.map(Number).join(',')+")");
    input.assignedTo=rows.map(r=>r.source_id); delete input.assignee_employee_ids;
  }
  const tok=await getToken();
  const e=await gql(tok,`mutation($id: EncodedId!, $in: TaskEditInput!){ taskEdit(taskId:$id, input:$in){ task{ id } userErrors{ message } } }`,{id:gid,in:input});
  const ee=errs(e,'taskEdit'); if(ee.length){ console.error('taskEdit refused:', ee.join('; ')); process.exit(1); }
  const r=await gql(tok,`query($id: EncodedId!){ task(id:$id){ title instructions startAt endAt allDay isComplete assignedUsers(first:10){ nodes{ name{ full } } } } }`,{id:gid});
  const t=r.data.task;
  console.log(JSON.stringify({task_id:Number(taskId), jobber_now:{title:t.title,instructions:t.instructions,startAt:t.startAt,endAt:t.endAt,allDay:t.allDay,isComplete:t.isComplete,assigned:t.assignedUsers.nodes.map(n=>n.name.full)}},null,1));
})().catch(e=>{console.error('FAILED', e.message);process.exit(1);});
