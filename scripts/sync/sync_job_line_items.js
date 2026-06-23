/* sync_job_line_items.js — pull each non-archived Service Agreement job's line items from
 * Jobber into public.line_items (job_id scope). The jobs poll is createdAt-cursored and does
 * NOT fetch lineItems, so SA jobs created by the 2026-06-23 restructure have their agreed
 * services only in Jobber — this lands them in our DB so the Calendar "Create Visit" form can
 * read an agreement's services. Service Call jobs are intentionally empty (services chosen at
 * visit time) and are skipped. Idempotent: per job, replaces the job-scoped line_items rows.
 *   node scripts/sync/sync_job_line_items.js            -> DRY RUN
 *   node scripts/sync/sync_job_line_items.js --execute  -> apply
 * Related: reference_jobs_sync_gaps (durable fix = add lineItems to the poll + handleJob).
 */
const { gql } = require('./lib/jobber.js');
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const PAT = process.env.SUPABASE_PAT, P = process.env.SUPABASE_PROJECT_ID;
const EXECUTE = process.argv.includes('--execute');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const sq = s => String(s).replace(/'/g, "''");
function pg(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:`/v1/projects/${P}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{let j;try{j=JSON.parse(d);}catch(e){return rej(new Error('pg parse: '+d.slice(0,200)));} if(!Array.isArray(j))return rej(new Error('pg error: '+JSON.stringify(j).slice(0,200))); res(j);});});r.on('error',rej);r.write(b);r.end();});}

(async () => {
  const jobs = await pg(`SELECT j.id, j.job_number, esl.source_id AS gid
    FROM jobs j JOIN entity_source_links esl ON esl.entity_type='job' AND esl.source_system='jobber' AND esl.entity_id=j.id
    WHERE j.job_status <> 'archived' AND j.title ILIKE 'Service Agreement%'
    ORDER BY j.id`);
  console.log(`${EXECUTE ? 'EXECUTE' : 'DRY'} — ${jobs.length} non-archived SA jobs`);
  let synced = 0, items = 0, empty = 0, errors = 0;
  for (const j of jobs) {
    if (!j.gid) { console.log(`  #${j.job_number}: no GID`); errors++; continue; }
    let nodes;
    try { const d = await gql(`{ job(id:"${j.gid}"){ lineItems(first:30){ nodes{ name description quantity unitPrice totalPrice taxable } } } }`); nodes = d.job.lineItems.nodes || []; await sleep(350); }
    catch (e) { console.log(`  #${j.job_number}: gql ERR ${e.message}`); errors++; await sleep(800); continue; }
    if (!nodes.length) { empty++; continue; }
    items += nodes.length;
    if (!EXECUTE) { console.log(`  [DRY] #${j.job_number}: ${nodes.length} item(s) — ${nodes.map(n=>(n.name||'').slice(0,14)).join(', ')}`); synced++; continue; }
    try {
      await pg(`DELETE FROM line_items WHERE job_id=${j.id} AND visit_id IS NULL AND invoice_id IS NULL AND quote_id IS NULL`);
      const vals = nodes.map(n => `(${j.id}, '${sq(n.name)}', '${sq(n.description||'')}', ${Number(n.quantity)||1}, ${Number(n.unitPrice)||0}, ${Number(n.totalPrice)||0}, ${n.taxable?true:false})`).join(',');
      await pg(`INSERT INTO line_items (job_id, name, description, quantity, unit_price, total_price, taxable) VALUES ${vals}`);
      synced++;
    } catch (e) { console.log(`  #${j.job_number}: db ERR ${e.message}`); errors++; }
    await sleep(150);
  }
  console.log(`\nDONE — jobs synced: ${synced} | line items: ${items} | empty SA jobs: ${empty} | errors: ${errors}`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
