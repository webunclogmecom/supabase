// Client-code wave — assign codes to the 39 code-less clients w/ 2026 visits + push to Jobber Company Name.
// Saga per client (strict rollback per Fred): backup -> DB UPDATE (guarded) -> clientEdit -> verify -> rollback on fail.
// Idempotent / skip-if-correct. Modes:  node apply_client_codes.mjs --only <clientId>   |   node apply_client_codes.mjs   (all)
import { readFileSync, writeFileSync, appendFileSync, existsSync } from 'fs';
const env = readFileSync('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env','utf8');
const PAT = env.match(/SUPABASE_PAT=(\S+)/)[1];
const BACKUP = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/backups/2026-07-06_client_code_wave_backup.json';
const LOG = 'C:/Users/FRED/AppData/Local/Temp/claude/C--Users-FRED-Desktop-Virtrify-Yannick-Claude/d7caed02-ce78-4a09-aa3a-cff2a1e60774/scratchpad/client_code_wave_log.jsonl';

// FROZEN approved table (Fred 2026-07-06): clientId -> code. Tweaks applied: 76->000-DP, Millennium->271-MLN.
const TABLE = {44:'247-EC',51:'248-BPM',76:'000-DP',148:'250-LP',183:'251-AS',207:'252-OAU',208:'253-CG',230:'254-LB',234:'255-ACS',239:'256-APR',240:'257-ERI',241:'258-PIO',242:'259-RH',256:'260-FS',272:'261-LC',303:'262-JM',306:'263-LF',309:'264-HW',313:'265-MM',328:'266-S1G',349:'267-SA',350:'268-BE',358:'269-SB',376:'270-T4A',377:'271-MLN',387:'272-1265',388:'273-YMB',448:'274-CEV',465:'275-MLP',470:'276-BRC',479:'277-VSS',480:'278-BHC',483:'279-CB',487:'280-AN',488:'281-MA',490:'282-GP',492:'283-PIK',495:'284-GA',498:'285-NAH'};

const arg = process.argv.slice(2);
const onlyId = arg.includes('--only') ? Number(arg[arg.indexOf('--only')+1]) : null;
const PREFIX_RE = /^\s*\d{3}-\s*[A-Z0-9]*\s+/; // strip any existing NNN-XX prefix defensively

async function pg(q){ const r=await fetch(`https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query`,{method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},body:JSON.stringify({query:q})}); const j=await r.json(); if(!Array.isArray(j)) throw new Error('PG '+JSON.stringify(j).slice(0,300)); return j; }
const esc = s => String(s).replace(/'/g,"''");

// --- Jobber token (read app fbd14714, has write_clients). Use stored; refresh on 401. ---
let TOK, TOKROW;
async function loadTok(){ TOKROW=(await pg(`SELECT access_token, refresh_token, client_id, client_secret FROM webhook_tokens WHERE source_system='jobber' LIMIT 1`))[0]; TOK=TOKROW.access_token; }
async function refreshTok(){
  const r=await fetch('https://api.getjobber.com/api/oauth/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:TOKROW.client_id,client_secret:TOKROW.client_secret,grant_type:'refresh_token',refresh_token:TOKROW.refresh_token})});
  const j=await r.json(); if(!j.access_token) throw new Error('refresh failed '+JSON.stringify(j).slice(0,200));
  TOK=j.access_token; await pg(`UPDATE webhook_tokens SET access_token='${esc(TOK)}', updated_at=now() WHERE source_system='jobber'`);
  console.log('  (refreshed jobber token)');
}
async function gql(query, variables){
  for(let attempt=0; attempt<6; attempt++){
    const r=await fetch('https://api.getjobber.com/api/graphql',{method:'POST',headers:{Authorization:`Bearer ${TOK}`,'X-JOBBER-GRAPHQL-VERSION':'2026-04-16','Content-Type':'application/json'},body:JSON.stringify({query,variables})});
    if(r.status===401){ await refreshTok(); continue; }
    const j=await r.json();
    if(j.errors && JSON.stringify(j.errors).includes('THROTTLED')){ await new Promise(s=>setTimeout(s,18000)); continue; }
    return j;
  }
  throw new Error('gql: exhausted retries');
}
const b64 = s => Buffer.from(s,'utf8').toString('base64');
async function readClient(gid){
  const j=await gql(`query($id:EncodedId!){ client(id:$id){ id companyName name firstName lastName isCompany } }`, {id:b64(gid)});
  if(j.errors) throw new Error('read '+JSON.stringify(j.errors).slice(0,200));
  return j.data.client;
}
async function editCompanyName(gid, companyName){
  const j=await gql(`mutation($id:EncodedId!,$input:ClientEditInput!){ clientEdit(clientId:$id,input:$input){ client{ id companyName name } userErrors{ message } } }`, {id:b64(gid), input:{companyName}});
  if(j.errors) return {ok:false, err:JSON.stringify(j.errors).slice(0,200)};
  const ue=j.data?.clientEdit?.userErrors||[];
  if(ue.length) return {ok:false, err:'userErrors '+JSON.stringify(ue).slice(0,200)};
  return {ok:true, client:j.data.clientEdit.client};
}

(async () => {
  await loadTok();
  const decoded=JSON.parse(Buffer.from(TOK.split('.')[1],'base64').toString('utf8'));
  if(!(decoded.scope||'').includes('write_clients')) throw new Error('ABORT: token lacks write_clients');
  console.log('token OK (write_clients present)');

  const ids = onlyId ? [onlyId] : Object.keys(TABLE).map(Number);
  // fetch DB rows + gids
  const rows = await pg(`SELECT c.id, c.name, c.client_code, c.status, esl.source_id
    FROM clients c JOIN entity_source_links esl ON esl.entity_type='client' AND esl.source_system='jobber' AND esl.entity_id=c.id
    WHERE c.id IN (${ids.join(',')})`);
  const byId={}; for(const r of rows) byId[r.id]=r;

  const results=[];
  let first=true;
  for(const id of ids){
    const code=TABLE[id]; const row=byId[id];
    const gid = row ? Buffer.from(row.source_id,'base64').toString('utf8') : null;
    const rec={id, code, name: row?.name, status: row?.status};
    if(!row){ rec.result='SKIP_no_db_row'; results.push(rec); console.log(`SKIP ${code} id=${id}: no DB/ESL row`); continue; }

    // fresh Jobber read (compose from live value; skip-if-correct)
    let jc;
    try { jc = await readClient(gid); } catch(e){ rec.result='FAIL_jobber_read'; rec.err=e.message; results.push(rec); console.log(`FAIL ${code} id=${id}: jobber read ${e.message}`); if(first){console.log('CANARY read failed — aborting'); break;} continue; }
    const base = ((jc.companyName || jc.name || row.name) || '').replace(PREFIX_RE,'').trim();
    const newName = `${code} ${base}`;
    rec.old_companyName = jc.companyName; rec.old_jobber_name = jc.name; rec.isCompany = jc.isCompany; rec.new_companyName = newName;

    // skip-if-correct
    if(row.client_code===code && jc.companyName===newName){ rec.result='SKIP_already_correct'; results.push(rec); console.log(`SKIP ${code} id=${id}: already correct`); first=false; continue; }

    // backup (append)
    let backupArr=[]; if(existsSync(BACKUP)){ try{ backupArr=JSON.parse(readFileSync(BACKUP,'utf8')); }catch{} }
    backupArr.push({ts:new Date().toISOString(), id, name:row.name, old_client_code:row.client_code, gid, old_companyName:jc.companyName, old_jobber_name:jc.name, isCompany:jc.isCompany, new_client_code:code, new_companyName:newName});
    writeFileSync(BACKUP, JSON.stringify(backupArr,null,1));

    // 1) DB write (guarded)
    let dbSet=false;
    try {
      const upd = await pg(`UPDATE clients SET client_code='${esc(code)}' WHERE id=${id} AND client_code IS NULL RETURNING id`);
      if(upd.length){ dbSet=true; }
      else { const cur=(await pg(`SELECT client_code FROM clients WHERE id=${id}`))[0]?.client_code; rec.result='SKIP_db_not_null'; rec.db_current=cur; results.push(rec); console.log(`SKIP ${code} id=${id}: client_code already '${cur}'`); first=false; continue; }
    } catch(e){ rec.result='FAIL_db_write'; rec.err=e.message; results.push(rec); console.log(`FAIL ${code} id=${id}: DB ${e.message}`); if(first){console.log('CANARY DB write failed — aborting'); break;} continue; }

    // 2) Jobber push
    const ed = await editCompanyName(gid, newName);
    if(!ed.ok){
      // rollback DB
      await pg(`UPDATE clients SET client_code=NULL WHERE id=${id} AND client_code='${esc(code)}'`);
      rec.result='ROLLBACK_jobber_edit_failed'; rec.err=ed.err; results.push(rec); console.log(`ROLLBACK ${code} id=${id}: ${ed.err}`);
      if(first){console.log('CANARY Jobber edit failed — aborting'); break;} continue;
    }
    // 3) verify (re-read)
    await new Promise(s=>setTimeout(s,800));
    let ver; try{ ver=await readClient(gid); }catch(e){ ver=null; }
    if(!ver || ver.companyName!==newName){
      await pg(`UPDATE clients SET client_code=NULL WHERE id=${id} AND client_code='${esc(code)}'`);
      rec.result='ROLLBACK_verify_mismatch'; rec.verify_got=ver?.companyName; results.push(rec); console.log(`ROLLBACK ${code} id=${id}: verify got '${ver?.companyName}'`);
      if(first){console.log('CANARY verify failed — aborting'); break;} continue;
    }
    rec.result='OK'; results.push(rec); console.log(`OK   ${code}  <-  id=${id}  "${jc.companyName??jc.name}" -> "${newName}"`);
    appendFileSync(LOG, JSON.stringify(rec)+'\n');
    first=false;
    await new Promise(s=>setTimeout(s,1500)); // rate-limit courtesy
  }

  const ok=results.filter(r=>r.result==='OK').length;
  const skip=results.filter(r=>String(r.result).startsWith('SKIP')).length;
  const bad=results.filter(r=>String(r.result).startsWith('FAIL')||String(r.result).startsWith('ROLLBACK'));
  console.log(`\n=== DONE: OK=${ok} SKIP=${skip} FAIL/ROLLBACK=${bad.length} of ${results.length} ===`);
  if(bad.length) console.log('problems: '+JSON.stringify(bad.map(b=>({code:b.code,id:b.id,result:b.result,err:b.err||b.verify_got})),null,1));
  writeFileSync('C:/Users/FRED/AppData/Local/Temp/claude/C--Users-FRED-Desktop-Virtrify-Yannick-Claude/d7caed02-ce78-4a09-aa3a-cff2a1e60774/scratchpad/apply_result.json', JSON.stringify({ok,skip,bad:bad.length,results},null,1));
})().catch(e=>{ console.error('FATAL', e.message); process.exit(1); });
