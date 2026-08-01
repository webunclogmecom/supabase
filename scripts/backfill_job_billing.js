// backfill_job_billing.js — record each live job's ACTUAL billing from Jobber.
//
// WHY: public.jobs gained billing_type / invoice_frequency / invoice_rrule on
// 2026-08-01 (migration _1120), but only save-client-job writes them, so every
// pre-existing job reads NULL. The Client App treats NULL as "never confirmed"
// and asks the user to choose — correct, but it means ~443 live jobs would each
// need a manual answer. Jobber already knows the truth, so read it.
//
// Reads Jobber, writes only these three columns via fn_record_client_job (which
// is key-presence-aware, so nothing else on the row is touched).
//
// Usage: node scripts/backfill_job_billing.js            (DRY RUN, writes nothing)
//        node scripts/backfill_job_billing.js --execute
//
// ⚠ PERIODIC schedules: Jobber's Job.invoiceSchedule exposes billingFrequency and
// a human scheduleSummary, never the underlying RRULE. A PERIODIC job is therefore
// recorded as 'monthly_last_day' ONLY when the summary unambiguously says so;
// anything else PERIODIC is left NULL rather than guessed, because writing the
// wrong half of the billing pair is exactly the failure this column exists to stop.
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

for (const line of fs.readFileSync(path.resolve(__dirname, '../.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!m) continue;
  let v = m[2].trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (!(m[1] in process.env)) process.env[m[1]] = v;
}
const EXECUTE = process.argv.includes('--execute');
const JT = execSync('./jobber-token.sh', {
  cwd: path.resolve(__dirname, '../../Slack'),
  shell: 'C:/Program Files/Git/bin/bash.exe',
}).toString().trim();

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error('SQL ' + r.status + ': ' + JSON.stringify(j));
  return j;
}
async function gql(query, variables) {
  for (let attempt = 0; attempt < 4; attempt++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + JT, 'Content-Type': 'application/json',
                 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
      body: JSON.stringify({ query, variables }),
    });
    const j = await r.json();
    if (j.errors && /throttle/i.test(JSON.stringify(j.errors))) {
      await new Promise(s => setTimeout(s, 2000 * (attempt + 1)));
      continue;
    }
    return j;
  }
  throw new Error('throttled after retries');
}

const FREQ_MAP = { PER_VISIT: 'per_visit', ON_COMPLETION: 'once_closed', NEVER: 'as_needed' };

(async () => {
  const rows = await sql(`
    select j.id, l.source_id as gid, j.job_number, j.title
      from public.jobs j
      join public.entity_source_links l
        on l.entity_type='job' and l.source_system='jobber' and l.entity_id=j.id
     where j.job_status <> 'archived'
       and j.billing_type is null
     order by j.id`);
  console.log(`candidates (live, billing not yet recorded): ${rows.length}`);

  const out = [];
  const summary = { recorded: 0, periodic_ambiguous: 0, no_job_in_jobber: 0, errors: 0 };

  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    const res = await gql(
      `query($id: EncodedId!){ job(id:$id){ id billingType invoiceSchedule{ billingFrequency scheduleSummary } } }`,
      { id: r.gid });
    const job = res?.data?.job;
    if (!job) { summary.no_job_in_jobber++; out.push({ ...r, skip: 'not in Jobber' }); continue; }

    const btype = job.billingType === 'FIXED_PRICE' ? 'fixed'
                : job.billingType === 'VISIT_BASED' ? 'visit_based' : null;
    const bf = job.invoiceSchedule?.billingFrequency;
    const summaryTxt = String(job.invoiceSchedule?.scheduleSummary ?? '');
    let bfreq = FREQ_MAP[bf] ?? null;
    let rrule = null;
    if (bf === 'PERIODIC') {
      if (/last day/i.test(summaryTxt) && /month/i.test(summaryTxt)) {
        bfreq = 'monthly_last_day';
        rrule = 'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1';
      } else {
        summary.periodic_ambiguous++;
        out.push({ ...r, skip: 'PERIODIC, summary not unambiguous: ' + summaryTxt });
        continue;
      }
    }
    if (!btype || !bfreq) { out.push({ ...r, skip: `unmapped ${job.billingType}/${bf}` }); continue; }

    out.push({ ...r, billing_type: btype, invoice_frequency: bfreq, invoice_rrule: rrule, summary: summaryTxt });
    if (EXECUTE) {
      const payload = JSON.stringify({ gid: job.id, billing_type: btype,
        invoice_frequency: bfreq, invoice_rrule: rrule ?? '' }).replace(/'/g, "''");
      await sql(`select public.fn_record_client_job('${payload}'::jsonb)`);
    }
    summary.recorded++;
    if ((i + 1) % 25 === 0) console.log(`  ${i + 1}/${rows.length}…`);
  }

  fs.writeFileSync(process.argv.find(a => a.endsWith('.json')) ?? 'billing_backfill.json',
    JSON.stringify({ execute: EXECUTE, summary, rows: out }, null, 2));
  console.log(JSON.stringify(summary));
  console.log(EXECUTE ? '--- backfill complete ---' : '--- DRY RUN complete (nothing written) ---');
})();
