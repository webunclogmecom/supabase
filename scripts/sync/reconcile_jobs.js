/* reconcile_jobs.js — periodic full reconcile of public.jobs against Jobber, closing the
 * jobs-sync gaps the createdAt-cursored poll can't (status changes, the Frequency custom field,
 * job line items, and deletions). For every non-archived job in our DB it fetches the Jobber job
 * and reconciles:
 *   - job_status      (Jobber jobStatus, lowercased)         — catches archive/complete/etc.
 *   - frequency_days  (Jobber "Frequency" numeric custom field)
 *   - line_items      (job scope) per the rule: Service Agreement jobs carry their agreed services,
 *                     Service Call jobs carry none (wipe + re-insert for SA; wipe only for SC)
 *   - deletions       (Jobber returns null -> the job was deleted upstream -> mark archived)
 * Mirrors webhook-jobber.handleJob (the real-time path); run this as a daily cron for drift/catch-up.
 *   node scripts/sync/reconcile_jobs.js            -> DRY RUN
 *   node scripts/sync/reconcile_jobs.js --execute  -> apply
 * Related: reference_jobs_sync_gaps, sync_job_line_items.js (superseded by this).
 */
const { gql } = require('./lib/jobber.js');
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const PAT = process.env.SUPABASE_PAT, P = process.env.SUPABASE_PROJECT_ID;
const EXECUTE = process.argv.includes('--execute');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const sq = s => String(s).replace(/'/g, "''");
// Management API has a low req/min cap; the execute path bursts past it (UPDATE+DELETE+INSERT per
// job), so back off + retry on ThrottlerException (the sequential await loop then self-paces).
function pg(q, _retry=0){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:`/v1/projects/${P}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{let j;try{j=JSON.parse(d);}catch(e){return rej(new Error('pg parse: '+d.slice(0,200)));} if(!Array.isArray(j)){const msg=JSON.stringify(j); if(/Throttler|Too Many Requests|rate limit/i.test(msg)&&_retry<6){return setTimeout(()=>pg(q,_retry+1).then(res,rej),(_retry+1)*4000);} return rej(new Error('pg error: '+msg.slice(0,200)));} res(j);});});r.on('error',rej);r.write(b);r.end();});}

(async () => {
  const jobs = await pg(`SELECT j.id, j.job_number, j.title, j.job_status, j.frequency_days, esl.source_id AS gid
    FROM jobs j JOIN entity_source_links esl ON esl.entity_type='job' AND esl.source_system='jobber' AND esl.entity_id=j.id
    WHERE j.job_status <> 'archived' ORDER BY j.id`);
  console.log(`${EXECUTE ? 'EXECUTE' : 'DRY'} — ${jobs.length} non-archived jobs`);
  const sum = { statusFixed: 0, titleFixed: 0, freqFixed: 0, liSynced: 0, deletedArchived: 0, errors: 0 };
  for (const j of jobs) {
    if (!j.gid) { sum.errors++; continue; }
    let d;
    try { d = await gql(`{ job(id:"${j.gid}"){ jobStatus title customFields { __typename ... on CustomFieldNumeric { label valueNumeric } } lineItems(first:30){ nodes{ name description quantity unitPrice totalPrice taxable } } } }`); await sleep(300); }
    catch (e) { console.log(`  #${j.job_number}: gql ERR ${e.message}`); sum.errors++; await sleep(700); continue; }
    const job = d.job;
    if (!job) { // deleted in Jobber
      console.log(`  #${j.job_number}: deleted in Jobber -> archive`);
      if (EXECUTE) await pg(`UPDATE jobs SET job_status='archived', updated_at=now() WHERE id=${j.id}`);
      sum.deletedArchived++; continue;
    }
    const liveStatus = (job.jobStatus || '').toLowerCase();
    const freqCF = (job.customFields || []).find(cf => (cf?.label || '').toLowerCase() === 'frequency');
    const liveFreq = (freqCF && typeof freqCF.valueNumeric === 'number') ? freqCF.valueNumeric : null;
    const isSA = (job.title || j.title || '').toLowerCase().startsWith('service agreement');
    const sets = [];
    if (liveStatus && liveStatus !== j.job_status) { sets.push(`job_status='${sq(liveStatus)}'`); sum.statusFixed++; }
    if (liveFreq !== null && liveFreq !== j.frequency_days) { sets.push(`frequency_days=${liveFreq}`); sum.freqFixed++; }
    if (job.title && job.title !== j.title) { sets.push(`title='${sq(job.title)}'`); sum.titleFixed++; }
    if (!EXECUTE) {
      const nodes = job.lineItems?.nodes || [];
      if (isSA && nodes.length) sum.liSynced++;
      if (sets.length) console.log(`  [DRY] #${j.job_number}: ${sets.join(', ')}`);
      continue;
    }
    try {
      if (sets.length) await pg(`UPDATE jobs SET ${sets.join(', ')}, updated_at=now() WHERE id=${j.id}`);
      // line items per the rule
      await pg(`DELETE FROM line_items WHERE job_id=${j.id}`);
      if (isSA) {
        const nodes = job.lineItems?.nodes || [];
        if (nodes.length) {
          const vals = nodes.map(n => `(${j.id}, '${sq(n.name)}', '${sq(n.description||'')}', ${Number(n.quantity)||1}, ${Number(n.unitPrice)||0}, ${Number(n.totalPrice)||0}, ${n.taxable?true:false})`).join(',');
          await pg(`INSERT INTO line_items (job_id, name, description, quantity, unit_price, total_price, taxable) VALUES ${vals}`);
          sum.liSynced++;
        }
      }
    } catch (e) { console.log(`  #${j.job_number}: db ERR ${e.message}`); sum.errors++; }
    await sleep(120);
  }
  console.log('\nDONE —', JSON.stringify(sum));
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
