import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  return JSON.parse(await r.text());
}

console.log('=== Audit history for visit 4836 ===');
console.log(await pg(`
  SELECT id, app_source, operation, changed_at,
         old_row->>'visit_status' AS old_status, new_row->>'visit_status' AS new_status,
         old_row->>'completed_at' AS old_completed_at, new_row->>'completed_at' AS new_completed_at,
         old_row->>'visit_date' AS old_date, new_row->>'visit_date' AS new_date
  FROM audit.logs
  WHERE table_name='visits' AND ((new_row->>'id')::int = 4836 OR (old_row->>'id')::int = 4836)
  ORDER BY changed_at ASC;
`));

console.log('\n=== All raw.jobber_pull_visits rows for this visit GID ===');
console.log(await pg(`
  SELECT id, pulled_at, ingested_at,
         data->>'visitStatus' AS visit_status,
         data->>'completedAt' AS completed_at,
         data->>'_cursorTime' AS cursor_time
  FROM raw.jobber_pull_visits
  WHERE data->>'id' = 'Z2lkOi8vSm9iYmVyL1Zpc2l0LzIxODI3NTM0Mzk='
  ORDER BY pulled_at DESC;
`));

console.log('\n=== Manifest links for visit 4836 (DERM Tracker visibility) ===');
console.log(await pg(`
  SELECT mv.visit_id, mv.manifest_id, dm.white_manifest_number, dm.service_date
  FROM public.manifest_visits mv
  JOIN public.derm_manifests dm ON dm.id=mv.manifest_id
  WHERE mv.visit_id=4836;
`));

console.log('\n=== Sync cursor for visits (last successful pull) ===');
console.log(await pg(`
  SELECT entity, last_synced_at, rows_pulled, last_run_status, updated_at
  FROM public.sync_cursors WHERE entity='visits';
`));
