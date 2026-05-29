// scripts/probes/_phase4_post_cleanup_audit.js
//
// Phase 4 of the 2026-05-29 cleanup directive: re-audit DB integrity after
// the hard-deletes (Phases 1 + 3) and full reconcile (Phase 2). Looks for:
//
//   - Visit counts by status / source
//   - Orphan ESL rows pointing to non-existent visits
//   - Visits with NULL client_id
//   - visit_assignments referencing non-existent visit or employee
//   - public.visits_with_status and ops.v_calendar_visit counts vs base table
//   - Audit log spot-check for today's app_source='sql' writes
//   - Date-drift quick scan via existing audit_visits_vs_jobber_drift probe
//
// Read-only.

const path = require('path');
const https = require('https');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;

function request({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({ hostname: host, path, method, headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } }, (res) => {
      let d = ''; res.on('data', c => (d += c));
      res.on('end', () => resolve({ status: res.statusCode, body: d }));
    });
    req.on('error', reject);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function pg(sql) {
  const r = await request({
    host: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 400)}`);
  return JSON.parse(r.body);
}

(async () => {
  console.log('\n=== PHASE 4: post-cleanup DB integrity audit ===\n');

  // 1. Visit counts
  console.log('--- 1. Visit counts ---');
  const counts = await pg(`
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE visit_status = 'completed')::int AS completed,
      COUNT(*) FILTER (WHERE visit_status = 'scheduled')::int AS scheduled,
      COUNT(*) FILTER (WHERE deleted_at IS NOT NULL)::int AS soft_deleted,
      COUNT(*) FILTER (WHERE source = 'jobber')::int AS source_jobber,
      COUNT(*) FILTER (WHERE source = 'airtable')::int AS source_airtable,
      COUNT(*) FILTER (WHERE source = 'supabase_cron')::int AS source_cron,
      COUNT(*) FILTER (WHERE source = 'manual')::int AS source_manual,
      COUNT(*) FILTER (WHERE source = 'visit-calendar')::int AS source_calendar,
      MIN(visit_date) AS min_date,
      MAX(visit_date) AS max_date
    FROM public.visits;
  `);
  console.log(JSON.stringify(counts[0], null, 2));

  // 2. NULL client_id (the 81 gap noted in Phase 1 sweep)
  console.log('\n--- 2. Visits with NULL client_id ---');
  const nullClient = await pg(`SELECT COUNT(*)::int AS n FROM public.visits WHERE client_id IS NULL;`);
  console.log(`  ${nullClient[0].n} visits with NULL client_id`);

  // 3. Orphan ESL rows
  console.log('\n--- 3. Orphan ESL rows pointing to non-existent visits ---');
  const orphanEsl = await pg(`
    SELECT esl.id, esl.entity_id, esl.source_system, esl.source_id
    FROM public.entity_source_links esl
    LEFT JOIN public.visits v ON v.id = esl.entity_id
    WHERE esl.entity_type = 'visit' AND v.id IS NULL
    ORDER BY esl.id;
  `);
  console.log(`  ${orphanEsl.length} orphan ESL rows (entity_type=visit, no matching visits row)`);
  if (orphanEsl.length > 0 && orphanEsl.length <= 20) for (const e of orphanEsl) console.log(`    esl_id=${e.id} entity_id=${e.entity_id} ${e.source_system}:${(e.source_id || '').slice(-12)}`);

  // 4. visit_assignments referencing non-existent visits / employees
  console.log('\n--- 4. visit_assignments FK integrity ---');
  const orphanAsgn = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.visit_assignments va LEFT JOIN public.visits v ON v.id = va.visit_id WHERE v.id IS NULL) AS orphan_visit,
      (SELECT COUNT(*)::int FROM public.visit_assignments va LEFT JOIN public.employees e ON e.id = va.employee_id WHERE e.id IS NULL) AS orphan_employee;
  `);
  console.log(`  Orphan visit_id: ${orphanAsgn[0].orphan_visit}`);
  console.log(`  Orphan employee_id: ${orphanAsgn[0].orphan_employee}`);

  // 5. Views vs base table
  console.log('\n--- 5. Views vs base table (deleted_at honored?) ---');
  const viewCounts = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.visits WHERE deleted_at IS NULL) AS base_active,
      (SELECT COUNT(*)::int FROM public.visits_with_status) AS visits_with_status,
      (SELECT COUNT(*)::int FROM ops.v_calendar_visit) AS v_calendar_visit;
  `);
  console.log(JSON.stringify(viewCounts[0], null, 2));
  const ok1 = viewCounts[0].base_active === viewCounts[0].visits_with_status;
  const ok2 = viewCounts[0].base_active === viewCounts[0].v_calendar_visit;
  console.log(`  Views consistent with base table (deleted_at filter respected): ${ok1 && ok2 ? '✅' : '❌'}`);

  // 6. Audit log spot-check for today's sql writes
  console.log('\n--- 6. Audit log app_source distribution for today ---');
  const auditLog = await pg(`
    SELECT app_source, operation, COUNT(*)::int AS n
    FROM audit.logs
    WHERE changed_at >= CURRENT_DATE
      AND table_name = 'visits'
    GROUP BY 1, 2
    ORDER BY 1, 2;
  `);
  console.log(JSON.stringify(auditLog, null, 2));

  // 7. Jobber-linked counts
  console.log('\n--- 7. Jobber-linked counts ---');
  const jobber = await pg(`
    SELECT
      (SELECT COUNT(*)::int FROM public.entity_source_links WHERE entity_type='visit' AND source_system='jobber') AS visit_jobber_links,
      (SELECT COUNT(*)::int FROM public.entity_source_links WHERE entity_type='employee' AND source_system='jobber') AS employee_jobber_links,
      (SELECT COUNT(*)::int FROM public.entity_source_links WHERE entity_type='visit' AND source_system='airtable') AS visit_at_links;
  `);
  console.log(JSON.stringify(jobber[0], null, 2));

  // 8. Future visits (should be 0 scheduled, since Phase 3 cleared >= 2026-06-01)
  console.log('\n--- 8. Future visit gating ---');
  const fut = await pg(`
    SELECT
      COUNT(*) FILTER (WHERE visit_date >= '2026-06-01' AND visit_status='scheduled')::int AS future_scheduled,
      COUNT(*) FILTER (WHERE visit_date >= '2026-06-01')::int AS any_future,
      COUNT(*) FILTER (WHERE visit_date BETWEEN '2026-05-30' AND '2026-05-31' AND visit_status='scheduled')::int AS sat_sun_531_scheduled
    FROM public.visits;
  `);
  console.log(JSON.stringify(fut[0], null, 2));
  console.log(`  Phase 3 gate respected (future_scheduled=0, any_future=0): ${fut[0].future_scheduled === 0 && fut[0].any_future === 0 ? '✅' : '❌'}`);

  console.log('\n--- audit complete --- {"probe":"phase4_post_cleanup_audit"}');
})().catch(e => { console.error(e); process.exit(1); });
