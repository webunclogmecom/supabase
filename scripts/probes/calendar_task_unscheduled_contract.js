// ============================================================================
// calendar_task_unscheduled_contract.js — can a Jobber TASK exist WITHOUT a date, and can it be
// scheduled and unscheduled afterwards? (Fred, 2026-09-16: a task with no date must sit in the
// Calendar's "to be scheduled" tray and still be mirrored in Jobber.)
//
//   node scripts/probes/calendar_task_unscheduled_contract.js
//
// Creates ONE clearly labelled, UNASSIGNED test task, reads it back after every step, and deletes
// it at the end (verified gone). Nothing else is touched. Helpers copied from
// jobber_write_smoketest.js; the token is read from public.webhook_tokens and never printed.
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true });
const https = require('https');
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function qq(v){ return v==null ? 'NULL' : "'"+String(v).replace(/'/g,"''")+"'"; }
function sql(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:'/v1/projects/'+ref+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{if(x.statusCode>=300)return rej(new Error(x.statusCode+': '+d.slice(0,200)));res(JSON.parse(d));});});r.on('error',rej);r.write(b);r.end();});}
function post(host,path,body,headers){return new Promise((res,rej)=>{const r=https.request({hostname:host,path,method:'POST',headers:{...headers,'Content-Length':Buffer.byteLength(body)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>res({status:x.statusCode,body:d}));});r.on('error',rej);r.write(body);r.end();});}
// Unlike the smoke test this returns the raw envelope: a schema error lives in top-level `errors`
// and a business rejection in data.<field>.userErrors, and this probe must see BOTH.
function gql(tok,query,variables){return post('api.getjobber.com','/api/graphql',JSON.stringify({query,variables}),{Authorization:'Bearer '+tok,'Content-Type':'application/json','X-JOBBER-GRAPHQL-VERSION':'2026-04-16'}).then(r=>{if(!/json/.test(r.body.slice(0,1)==='{'?'json':''))throw new Error('non-JSON reply at HTTP '+r.status+' (waiting room?)');return JSON.parse(r.body);});}
async function getToken(){
  const row=(await sql("SELECT access_token, refresh_token, client_id, client_secret, expires_at::text FROM public.webhook_tokens WHERE source_system='jobber_write'"))[0];
  if(new Date(row.expires_at).getTime() > Date.now()+120000) return row.access_token;
  const body='grant_type=refresh_token&refresh_token='+encodeURIComponent(row.refresh_token)+'&client_id='+encodeURIComponent(row.client_id)+'&client_secret='+encodeURIComponent(row.client_secret);
  const tr=await post('api.getjobber.com','/api/oauth/token',body,{'Content-Type':'application/x-www-form-urlencoded'});
  if(tr.status>=300) throw new Error('refresh '+tr.status+': '+tr.body.slice(0,150));
  const t=JSON.parse(tr.body); const exp=JSON.parse(Buffer.from(t.access_token.split('.')[1],'base64').toString()).exp*1000;
  await sql("UPDATE public.webhook_tokens SET access_token="+qq(t.access_token)+", refresh_token="+qq(t.refresh_token||row.refresh_token)+", expires_at="+qq(new Date(exp).toISOString())+", updated_at=now() WHERE source_system='jobber_write'");
  console.log('[probe] refreshed jobber_write token');
  return t.access_token;
}
const errs=(res,field)=>[...(Array.isArray(res?.errors)?res.errors.map(e=>e.message):[]),...((res?.data?.[field]?.userErrors)||[]).map(e=>e.message)];
const Q_TASK=`query($id: EncodedId!){ task(id:$id){ id title startAt endAt allDay isComplete assignedUsers(first:5){ nodes{ name{ full } } } } }`;

(async()=>{
  const tok=await getToken();
  const out={};
  const read=async(id,label)=>{const r=await gql(tok,Q_TASK,{id});const t=r?.data?.task;out[label]=t?{startAt:t.startAt,endAt:t.endAt,allDay:t.allDay,isComplete:t.isComplete,assigned:t.assignedUsers.nodes.length}:{task:null,errors:errs(r,'task')};console.log('[probe]',label,JSON.stringify(out[label]));return t;};

  // 1. create WITHOUT startAt / endAt / allDay
  const c=await gql(tok,`mutation($in: TaskCreateInput!){ taskCreate(input:$in){ task{ id } userErrors{ message } } }`,{in:{title:'PROBE unscheduled calendar task (auto-delete)',instructions:'Contract test from the UnclogMe Calendar build. Safe to delete.'}});
  const e1=errs(c,'taskCreate'); if(e1.length){console.log('[probe] taskCreate WITHOUT startAt refused:',e1.join('; '));out.create_without_date='REFUSED: '+e1.join('; ');}
  const id=c?.data?.taskCreate?.task?.id;
  if(!id){console.log(JSON.stringify(out,null,1));return;}
  out.create_without_date='ACCEPTED '+id;
  await read(id,'after_create');

  // 2. schedule it with taskEdit
  const d=new Date(Date.now()+2*86400000); const day=d.toISOString().slice(0,10);
  const e=await gql(tok,`mutation($id: EncodedId!, $in: TaskEditInput!){ taskEdit(taskId:$id, input:$in){ task{ id } userErrors{ message } } }`,{id,in:{startAt:day+'T14:00:00Z',endAt:day+'T14:30:00Z',allDay:false}});
  out.schedule_via_taskEdit=errs(e,'taskEdit').length?('REFUSED: '+errs(e,'taskEdit').join('; ')):'ACCEPTED';
  await read(id,'after_schedule');

  // 3. unschedule via appointmentEditSchedule
  const u=await gql(tok,`mutation($id: EncodedId!, $in: AppointmentEditScheduleInput!){ appointmentEditSchedule(appointmentId:$id, input:$in){ userErrors{ message } } }`,{id,in:{unschedule:true}});
  out.unschedule_via_appointmentEditSchedule=errs(u,'appointmentEditSchedule').length?('REFUSED: '+errs(u,'appointmentEditSchedule').join('; ')):'ACCEPTED';
  await read(id,'after_unschedule');

  // 3b. can taskEdit clear the date directly?
  const n=await gql(tok,`mutation($id: EncodedId!, $in: TaskEditInput!){ taskEdit(taskId:$id, input:$in){ task{ id } userErrors{ message } } }`,{id,in:{startAt:day+'T15:00:00Z',endAt:day+'T15:30:00Z',allDay:false}});
  out.reschedule_after_unschedule=errs(n,'taskEdit').length?('REFUSED: '+errs(n,'taskEdit').join('; ')):'ACCEPTED';
  await read(id,'after_reschedule');
  const n2=await gql(tok,`mutation($id: EncodedId!, $in: TaskEditInput!){ taskEdit(taskId:$id, input:$in){ task{ id } userErrors{ message } } }`,{id,in:{startAt:null,endAt:null}});
  out.taskEdit_startAt_null=errs(n2,'taskEdit').length?('REFUSED: '+errs(n2,'taskEdit').join('; ')):'ACCEPTED';
  await read(id,'after_taskEdit_null');

  // 4. delete + verify gone
  const del=await gql(tok,`mutation($ids: [EncodedId!]!){ taskDelete(taskIds:$ids){ userErrors{ message } } }`,{ids:[id]});
  out.delete=errs(del,'taskDelete').length?('REFUSED: '+errs(del,'taskDelete').join('; ')):'ACCEPTED';
  const g=await gql(tok,Q_TASK,{id}); out.verified_gone=!!(g&&Object.prototype.hasOwnProperty.call(g,'data')&&g.data&&g.data.task===null);
  console.log('\n[probe] RESULT\n'+JSON.stringify(out,null,1));
})().catch(e=>{console.error('[probe] FAILED', e.message);process.exit(1);});
