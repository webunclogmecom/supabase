// 82_smoke_test_apps.mjs
// Smoke test the three live Lovable apps:
//   - calendar.unclogme.app (Visit Calendar)
//   - derm.unclogme.app    (DERM Tracker)
//   - fp.unclogme.app      (Field Portal)
//
// Per-app: HTTP fetch the entry HTML, verify status + minimal markers.
// Then verify the data layer each app reads is sane via DB queries.

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

async function probe(url, timeoutMs = 15000) {
  const ctl = AbortSignal.timeout(timeoutMs);
  const t0 = Date.now();
  try {
    const r = await fetch(url, { signal: ctl, redirect: 'follow' });
    const text = await r.text();
    return {
      url,
      status: r.status,
      ok: r.ok,
      final_url: r.url,
      ms: Date.now() - t0,
      bytes: text.length,
      has_root_div: /<div id="root">|<div id="app">|<div id="__next">/.test(text),
      has_react: /react/i.test(text),
      has_vite: /\/assets\/.*\.js/.test(text),
      title: (text.match(/<title>([^<]*)<\/title>/) || [])[1] || '',
    };
  } catch (e) {
    return { url, error: String(e.message || e), ms: Date.now() - t0 };
  }
}

const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('1. HTTP smoke — entry HTML for each app');
const apps = [
  'https://calendar.unclogme.app/',
  'https://derm.unclogme.app/',
  'https://fp.unclogme.app/',
];
for (const u of apps) {
  const r = await probe(u);
  console.log(JSON.stringify(r, null, 2));
}

banner('2. CALENDAR data layer — ops.v_calendar_visit health');
console.log(await pg(`
  SELECT
    (SELECT COUNT(*)::int FROM ops.v_calendar_visit
     WHERE visit_date >= date_trunc('month', CURRENT_DATE)
       AND visit_date <  date_trunc('month', CURRENT_DATE) + INTERVAL '1 month') AS visits_this_month,
    (SELECT COUNT(*)::int FROM ops.v_calendar_visit
     WHERE visit_date >= CURRENT_DATE
       AND visit_date <  CURRENT_DATE + INTERVAL '14 days') AS visits_next_14d,
    (SELECT COUNT(*)::int FROM ops.v_calendar_visit
     WHERE visit_date >= CURRENT_DATE - INTERVAL '14 days'
       AND visit_date <  CURRENT_DATE
       AND visit_status = 'scheduled') AS overdue_count,
    (SELECT MAX(visit_updated_at) FROM ops.v_calendar_visit) AS last_calendar_write;
`));

banner('3. DERM data layer — manifests + linkages');
console.log(await pg(`
  SELECT
    (SELECT COUNT(*)::int FROM public.derm_manifests) AS total_manifests,
    (SELECT COUNT(*)::int FROM public.derm_manifests
     WHERE service_date >= CURRENT_DATE - INTERVAL '30 days') AS manifests_last_30d,
    (SELECT COUNT(*)::int FROM public.manifest_visits) AS total_manifest_visit_links,
    (SELECT COUNT(*)::int FROM public.derm_manifests
     WHERE derm_manifest_url IS NULL) AS manifests_missing_url,
    (SELECT MAX(updated_at) FROM public.derm_manifests) AS last_manifest_write;
`));

banner('4. DERM 2-week rule — completed visits older than 2 weeks needing DERM, missing link');
console.log(await pg(`
  WITH needing AS (
    SELECT v.id, v.visit_date, v.client_id, v.service_type, v.derm_required
    FROM public.visits v
    WHERE v.visit_status = 'completed'
      AND v.visit_date <= CURRENT_DATE - INTERVAL '14 days'
      AND v.visit_date >= CURRENT_DATE - INTERVAL '90 days'
      AND v.service_type = 'GT'
      AND (v.derm_required IS NULL OR v.derm_required = true)
  )
  SELECT
    (SELECT COUNT(*)::int FROM needing) AS gt_visits_needing_derm,
    (SELECT COUNT(*)::int FROM needing n
     WHERE NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = n.id)) AS missing_manifest_link;
`));

banner('5. FIELD PORTAL data layer — clients + properties');
console.log(await pg(`
  SELECT
    (SELECT COUNT(*)::int FROM public.clients WHERE status IN ('ACTIVE','RECURRING')) AS active_clients,
    (SELECT COUNT(*)::int FROM public.properties) AS total_properties,
    (SELECT COUNT(*)::int FROM public.properties WHERE latitude IS NULL OR longitude IS NULL) AS properties_missing_latlon,
    (SELECT COUNT(*)::int FROM public.gdos WHERE status='ACTIVE') AS active_gdos,
    (SELECT MAX(updated_at) FROM public.clients) AS last_client_write;
`));

banner('6. WEBHOOK health — last events seen (24h)');
// Discover columns first since schema varies.
const cols = await pg(`
  SELECT column_name FROM information_schema.columns
  WHERE table_schema='public' AND table_name='webhook_events_log'
  ORDER BY ordinal_position;
`);
const colNames = cols.map(c => c.column_name);
console.log('  columns:', colNames.join(', '));
const sourceCol = ['source','source_system','webhook_source','entity','provider'].find(c => colNames.includes(c)) || 'NULL';
const tsCol = ['received_at','created_at','ingested_at','occurred_at'].find(c => colNames.includes(c)) || 'NULL';
console.log(await pg(`
  SELECT ${sourceCol} AS source, COUNT(*)::int AS events_24h,
         MAX(${tsCol}) AS last_event
  FROM public.webhook_events_log
  WHERE ${tsCol} >= NOW() - INTERVAL '24 hours'
  GROUP BY ${sourceCol} ORDER BY events_24h DESC;
`));

banner('7. EDGE FUNCTION availability — HTTP probe deployed functions');
const SB_URL = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_ANON_KEY;
const fns = ['webhook-jobber', 'webhook-airtable', 'webhook-samsara', 'generate-derm-address-preview'];
for (const fn of fns) {
  // OPTIONS request to verify the function endpoint responds (CORS preflight)
  const t0 = Date.now();
  try {
    const r = await fetch(`${SB_URL}/functions/v1/${fn}`, {
      method: 'OPTIONS',
      headers: { 'Access-Control-Request-Method': 'POST', Origin: 'https://derm.unclogme.app' },
      signal: AbortSignal.timeout(8000),
    });
    console.log(`  ${fn}: ${r.status} (${Date.now() - t0}ms)`);
  } catch (e) {
    console.log(`  ${fn}: ERROR ${e.message}`);
  }
}

banner('8. AUDIT-trail freshness — last 5 audit rows');
console.log(await pg(`
  SELECT id, table_name, app_source, operation, changed_at
  FROM audit.logs
  ORDER BY changed_at DESC LIMIT 5;
`));
