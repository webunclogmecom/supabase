/* sa_skipped_cycle.js — find SA (Service Agreement) clients who skipped / will skip a service cycle.
 *
 * "Skipped a cycle" = the client will go (or has gone) meaningfully longer than one SA frequency
 * between services. Evaluated per ACTIVE SA job (frequency_days > 0, non-archived, client
 * ACTIVE/RECURRING), EXCLUDING billing-only "Warranty of Drainage" jobs (0 visits by design).
 *
 * ANCHOR = the client's last COMPLETED visit of ANY service type (GT / CL / null) — the last time
 *   they were actually serviced. ANY type ON PURPOSE: pre-restructure visits are often typed CL/null,
 *   so a GT-only anchor misses them entirely (the 221-YAS / 222-SPE case: their last real service is
 *   on the old combined "Service" job, typed CL → the generator sees "no last GT visit" and defaults
 *   the next visit far out).
 * NEXT_SA = the SA job's earliest SCHEDULED visit on/after today.
 *
 * FLAGS:
 *   cycle_skipped       — has history AND next_sa lands >= max(14, freq/4) days later than
 *                         (anchor + freq)  [i.e. the next visit is more than ~1 cycle after last service].
 *   overdue_no_upcoming — has history AND no upcoming SA visit AND it's been > freq since last service.
 *   no_history_far      — NO completed visit to anchor to AND the first/next visit is far out
 *                         (missing, or > today + max(21, freq/2)) — can't auto-anchor; needs a manual date.
 *                         (New SAs whose first visit is imminent are intentionally NOT flagged.)
 *
 * EXTRAS: cycles_gap = (next_sa - anchor) / freq (severity — 2.0 = a whole cycle skipped).
 *   anchor_mismatch = the last GT-typed visit is missing or much older than the last ANY-type visit →
 *   the "old GT/CL typing" cause. Fix = re-anchor the next SA visit to (last any-type visit + freq),
 *   regardless of type, then ripple the chain.
 *
 *   node scripts/probes/sa_skipped_cycle.js
 */
const https = require('https');
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const PAT = process.env.SUPABASE_PAT, P = process.env.SUPABASE_PROJECT_ID;
function pg(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:`/v1/projects/${P}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>{let j;try{j=JSON.parse(d);}catch(e){return rej(new Error('pg parse: '+d.slice(0,200)));} if(!Array.isArray(j))return rej(new Error('pg error: '+JSON.stringify(j).slice(0,200))); res(j);});});r.on('error',rej);r.write(b);r.end();});}

const SQL = `
WITH tday AS (SELECT (now() at time zone 'America/New_York')::date d),
sa AS (SELECT j.id job_id, j.frequency_days freq, c.id client_id, c.client_code, c.name
  FROM jobs j JOIN clients c ON c.id=j.client_id
  WHERE j.job_status<>'archived' AND coalesce(j.frequency_days,0)>0 AND c.status IN ('ACTIVE','RECURRING')
    AND j.title NOT ILIKE '%warranty of drainage%'),
la  AS (SELECT client_id, max(visit_date) d FROM visits WHERE visit_status='completed' AND deleted_at IS NULL GROUP BY client_id),
lgt AS (SELECT client_id, max(visit_date) d FROM visits WHERE visit_status='completed' AND deleted_at IS NULL AND service_type='GT' GROUP BY client_id),
ns  AS (SELECT job_id, min(visit_date) d FROM visits, tday WHERE visit_status='scheduled' AND deleted_at IS NULL AND visit_date>=tday.d GROUP BY job_id),
x AS (SELECT sa.*, la.d last_any, lgt.d last_gt, ns.d next_sa,
    CASE WHEN ns.d IS NOT NULL AND la.d IS NOT NULL THEN (ns.d-la.d)-sa.freq END days_late,
    CASE WHEN ns.d IS NOT NULL AND la.d IS NOT NULL THEN round((ns.d-la.d)::numeric/sa.freq,1) END cycles_gap,
    ((SELECT d FROM tday)-la.d) overdue_days
  FROM sa LEFT JOIN la ON la.client_id=sa.client_id LEFT JOIN lgt ON lgt.client_id=sa.client_id LEFT JOIN ns ON ns.job_id=sa.job_id),
f AS (SELECT client_code, name, freq, last_any, next_sa, days_late, cycles_gap, overdue_days,
    CASE WHEN last_any IS NULL THEN 'no_history_far'
         WHEN next_sa IS NULL THEN 'overdue_no_upcoming' ELSE 'cycle_skipped' END reason,
    (last_any IS NOT NULL AND (last_gt IS NULL OR (last_any-last_gt)>freq)) anchor_mismatch
  FROM x, tday
  WHERE (last_any IS NULL AND (next_sa IS NULL OR next_sa > tday.d + GREATEST(21,freq/2)))
     OR (last_any IS NOT NULL AND next_sa IS NULL AND overdue_days>freq)
     OR (last_any IS NOT NULL AND next_sa IS NOT NULL AND days_late>=GREATEST(14,freq/4)))
SELECT * FROM f ORDER BY COALESCE(cycles_gap, 9) DESC, COALESCE(days_late, overdue_days, 999) DESC`;

(async () => {
  const rows = await pg(SQL);
  const cats = {}; for (const r of rows) cats[r.reason] = (cats[r.reason]||0)+1;
  console.log(`SA clients with a skipped/late cycle: ${rows.length}  |  ${JSON.stringify(cats)}  |  anchor-mismatch (old GT/CL typing): ${rows.filter(r=>r.anchor_mismatch).length}\n`);
  for (const r of rows) {
    const sev = r.cycles_gap>=1.8 ? 'SEVERE' : (r.cycles_gap>=1.4 || r.reason!=='cycle_skipped' ? 'HIGH  ' : 'MILD  ');
    console.log(`[${sev}] ${r.client_code} freq=${r.freq} | last=${r.last_any||'NONE'}${r.anchor_mismatch?' (oldGT-typed)':''} next=${r.next_sa||'NONE'} | ${r.cycles_gap!=null?r.cycles_gap+'x cycle gap, ':''}${r.days_late!=null?r.days_late+'d late, ':''}overdue ${r.overdue_days!=null?r.overdue_days+'d':'?'} [${r.reason}]`);
  }
  console.log(`\n--- audit complete --- {"probe":"sa_skipped_cycle","flagged":${rows.length}}`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
