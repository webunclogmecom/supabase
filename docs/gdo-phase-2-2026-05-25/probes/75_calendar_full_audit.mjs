// 75_calendar_full_audit.mjs
// Comprehensive integrity audit of visits surfaced in the Calendar App.
// Goal: find extras, missing visits, orphans, duplicates, invalid status,
// and cancelled-leak.
//
// Covers May 2026 (live month) + ±2 month buffer for context.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('A. COUNT INTEGRITY — visits vs v_calendar_visit, by month');
console.log(await pg(`
  WITH months AS (
    SELECT generate_series(
      date_trunc('month', CURRENT_DATE - INTERVAL '2 month'),
      date_trunc('month', CURRENT_DATE + INTERVAL '2 month'),
      INTERVAL '1 month'
    )::date AS m
  )
  SELECT to_char(m, 'YYYY-MM') AS month,
    (SELECT COUNT(*)::int FROM public.visits v
     WHERE v.visit_date >= m AND v.visit_date < m + INTERVAL '1 month') AS visits_table,
    (SELECT COUNT(*)::int FROM ops.v_calendar_visit v
     WHERE v.visit_date >= m AND v.visit_date < m + INTERVAL '1 month') AS view_total,
    (SELECT COUNT(*)::int FROM public.visits v
     WHERE v.visit_date >= m AND v.visit_date < m + INTERVAL '1 month'
       AND v.visit_status = 'cancelled') AS cancelled_count
  FROM months
  ORDER BY m;
`));

banner('B. CANCELLED LEAK — any cancelled visits showing in v_calendar_visit?');
console.log(await pg(`
  SELECT id, visit_date, client_name, visit_status
  FROM ops.v_calendar_visit
  WHERE visit_status = 'cancelled'
  LIMIT 20;
`));

banner('C. SOURCE BREAKDOWN — May 2026 visits by source');
console.log(await pg(`
  SELECT source AS visit_source, COUNT(*)::int AS n
  FROM public.visits
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01'
  GROUP BY source ORDER BY n DESC;
`));

banner('D. ORPHAN visits — client missing or INACTIVE');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.visit_status, v.client_id, c.name, c.status
  FROM public.visits v
  LEFT JOIN public.clients c ON c.id = v.client_id
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
    AND (c.id IS NULL OR c.status = 'INACTIVE')
  ORDER BY v.visit_date
  LIMIT 30;
`));

banner('E. DUPLICATE candidates — same client+date+service_type');
console.log(await pg(`
  SELECT client_id, visit_date, service_type, COUNT(*)::int AS n,
         array_agg(id ORDER BY id) AS ids,
         array_agg(visit_status ORDER BY id) AS statuses
  FROM public.visits
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01'
  GROUP BY client_id, visit_date, service_type
  HAVING COUNT(*) > 1
  ORDER BY n DESC, visit_date
  LIMIT 30;
`));

banner('F. INVALID STATUS — any unexpected visit_status values?');
console.log(await pg(`
  SELECT visit_status, COUNT(*)::int AS n
  FROM public.visits
  WHERE visit_date >= '2026-01-01'
  GROUP BY visit_status ORDER BY n DESC;
`));

banner('G. STATUS↔completed_at consistency check (May 2026)');
console.log(await pg(`
  SELECT
    COUNT(*) FILTER (WHERE visit_status = 'completed' AND completed_at IS NULL)::int AS completed_but_no_timestamp,
    COUNT(*) FILTER (WHERE visit_status <> 'completed' AND completed_at IS NOT NULL)::int AS not_completed_but_has_timestamp,
    COUNT(*) FILTER (WHERE visit_status = 'completed' AND completed_at IS NOT NULL)::int AS completed_with_timestamp,
    COUNT(*) FILTER (WHERE visit_status = 'scheduled' AND completed_at IS NULL)::int AS scheduled_clean
  FROM public.visits
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01';
`));

banner('H. NULL/INVALID dates');
console.log(await pg(`
  SELECT id, visit_date, client_id, visit_status, source
  FROM public.visits
  WHERE visit_date IS NULL
     OR visit_date < '2024-01-01'
     OR visit_date > '2027-12-31'
  LIMIT 20;
`));

banner('I. NO ADDRESS reachable — visits where view returns null address');
console.log(await pg(`
  SELECT id, visit_date, client_name, client_code
  FROM ops.v_calendar_visit
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01'
    AND (address IS NULL OR address = '')
  LIMIT 20;
`));

banner('J. COVERAGE — Recurring/Active clients with NO May 2026 visit (potential missing)');
// Heuristic: clients flagged ACTIVE or RECURRING with a service_config whose
// frequency_days is <= 31, but zero visits scheduled or completed in May 2026.
console.log(await pg(`
  SELECT c.id, c.client_code, c.name, c.status,
         array_agg(DISTINCT sc.service_type) AS service_types,
         array_agg(DISTINCT sc.frequency_days) AS freq_days,
         MAX(v.visit_date) AS last_visit_anywhere,
         (SELECT COUNT(*)::int FROM public.visits v2
          WHERE v2.client_id = c.id
            AND v2.visit_date >= '2026-05-01' AND v2.visit_date < '2026-06-01') AS may_count
  FROM public.clients c
  JOIN public.service_configs sc ON sc.client_id = c.id
  LEFT JOIN public.visits v ON v.client_id = c.id
  WHERE c.status IN ('ACTIVE','RECURRING')
    AND sc.frequency_days IS NOT NULL
    AND sc.frequency_days <= 31
    AND NOT EXISTS (
      SELECT 1 FROM public.visits v3
      WHERE v3.client_id = c.id
        AND v3.visit_date >= '2026-05-01' AND v3.visit_date < '2026-06-01'
    )
  GROUP BY c.id, c.client_code, c.name, c.status
  ORDER BY c.name
  LIMIT 30;
`));

banner('K. UNSCHEDULED count — visits with NULL date');
console.log(await pg(`
  SELECT COUNT(*)::int AS unscheduled_count, visit_status, source
  FROM public.visits
  WHERE visit_date IS NULL
  GROUP BY visit_status, source;
`));

banner('L. JOBBER LINKAGE — visits where source=jobber should have entity_source_links row');
console.log(await pg(`
  SELECT
    COUNT(*) FILTER (WHERE v.source = 'jobber')::int AS jobber_source_visits,
    COUNT(*) FILTER (WHERE v.source = 'jobber' AND esl.id IS NOT NULL)::int AS linked_to_jobber,
    COUNT(*) FILTER (WHERE v.source = 'jobber' AND esl.id IS NULL)::int AS missing_jobber_link
  FROM public.visits v
  LEFT JOIN public.entity_source_links esl
    ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01';
`));

banner('M. SUPABASE_CRON visits — should NOT have entity_source_links (locally generated)');
console.log(await pg(`
  SELECT
    COUNT(*) FILTER (WHERE v.source = 'supabase_cron')::int AS cron_visits,
    COUNT(*) FILTER (WHERE v.source = 'supabase_cron' AND esl.id IS NOT NULL)::int AS unexpectedly_linked
  FROM public.visits v
  LEFT JOIN public.entity_source_links esl
    ON esl.entity_type='visit' AND esl.entity_id=v.id
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01';
`));

banner('N. RECENT cron-generated visits — May 2026 sample');
console.log(await pg(`
  SELECT v.id, v.visit_date, c.name, c.client_code, v.service_type,
         v.visit_status, v.created_at
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  WHERE v.source = 'supabase_cron'
    AND v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
  ORDER BY v.visit_date
  LIMIT 10;
`));

banner('O. AIRTABLE source distribution (Active inspections + DERM still come from AT)');
console.log(await pg(`
  SELECT esl.source_system, COUNT(DISTINCT v.id)::int AS visit_count
  FROM public.visits v
  JOIN public.entity_source_links esl
    ON esl.entity_type='visit' AND esl.entity_id=v.id
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
  GROUP BY esl.source_system
  ORDER BY visit_count DESC;
`));

banner('P. SUMMARY');
console.log(await pg(`
  SELECT
    (SELECT COUNT(*)::int FROM public.visits
     WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01') AS total_may,
    (SELECT COUNT(*)::int FROM ops.v_calendar_visit
     WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01') AS view_may,
    (SELECT COUNT(*)::int FROM public.visits
     WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01' AND visit_status='completed') AS completed,
    (SELECT COUNT(*)::int FROM public.visits
     WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01' AND visit_status='scheduled') AS scheduled,
    (SELECT COUNT(*)::int FROM public.visits
     WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01' AND visit_status='cancelled') AS cancelled;
`));
