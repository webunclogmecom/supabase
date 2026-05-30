// audit_visit_dups.js
// One-shot duplicate detector for the Jobber transition month.
//
// Finds supabase_cron scheduled placeholders that coexist with a jobber visit
// for the SAME client + service_type within ±7 days — i.e. a pair the
// webhook-jobber promotion path should have collapsed into one row but didn't.
// While the office manually creates visits in Jobber (and push-to-Jobber is
// still blocked on the admin OAuth scope, task #80), this catches dups before
// they accumulate silently.
//
// DETECT-ONLY by default. The ±7d window can legitimately catch two adjacent
// visits for high-frequency clients (e.g. weekly food trucks), so each pair is
// annotated with the client's frequency_days — review before acting.
//
//   node scripts/probes/audit_visit_dups.js          # report (writes JSON)
//
// Output: reports/visit_dups_<date>.json + a one-line stdout summary.

const fs = require('fs');
const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });
const PAT = process.env.SUPABASE_PAT, PROJECT = process.env.SUPABASE_PROJECT_ID;
function pg(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q});const r=https.request({hostname:'api.supabase.com',path:'/v1/projects/'+PROJECT+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},(rs)=>{let d='';rs.on('data',c=>d+=c);rs.on('end',()=>res(d));});r.on('error',rej);r.write(b);r.end();});}

(async () => {
  const rows = JSON.parse(await pg(`
    SELECT cron.id AS cron_id, c.client_code, c.name AS client_name, cron.service_type,
           cron.visit_date::text AS cron_date, j.id AS jobber_id, j.visit_date::text AS jobber_date,
           j.visit_status AS jobber_status, ABS(j.visit_date - cron.visit_date) AS gap_days,
           sc.frequency_days,
           (ABS(j.visit_date - cron.visit_date) < COALESCE(sc.frequency_days, 9999)) AS likely_real_dup
    FROM public.visits cron
    JOIN public.clients c ON c.id = cron.client_id
    JOIN public.visits j ON j.client_id = cron.client_id AND j.service_type = cron.service_type
      AND j.source = 'jobber' AND j.deleted_at IS NULL
      AND ABS(j.visit_date - cron.visit_date) <= 7
    LEFT JOIN public.service_configs sc ON sc.client_id = cron.client_id AND sc.service_type = cron.service_type
    WHERE cron.source = 'supabase_cron' AND cron.visit_status = 'scheduled' AND cron.deleted_at IS NULL
    ORDER BY likely_real_dup DESC, c.client_code;
  `));
  if (rows.message) throw new Error(rows.message);

  const likely = rows.filter(r => r.likely_real_dup);
  const maybe = rows.filter(r => !r.likely_real_dup);
  const dateStr = new Date().toISOString().slice(0, 10);
  const out = {
    ran_at: new Date().toISOString(),
    total_pairs: rows.length,
    likely_real_dups: likely.length,    // gap < client frequency → almost certainly the same visit
    maybe_adjacent: maybe.length,        // gap >= frequency → could be two legitimate close visits
    pairs: rows,
  };
  const p = path.resolve(__dirname, `../../reports/visit_dups_${dateStr}.json`);
  fs.writeFileSync(p, JSON.stringify(out, null, 2));
  process.stdout.write(`DUP_AUDIT total=${rows.length} likely_real=${likely.length} maybe_adjacent=${maybe.length} -> ${p}\n`);
})().catch(e => { process.stdout.write('ERR:' + e.message + '\n'); process.exit(1); });
