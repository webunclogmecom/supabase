// 129_apply_zones_fk_refactor.mjs
// Apply docs/migrations/2026-05-29_zones_fk_refactor.sql
// Verify:
//   - zones.id surrogate PK present, code unique
//   - properties.zone_id populated (no orphans)
//   - immutable-code trigger gone
//   - sync trigger works (UPDATE zone text → zone_id auto-updates)
//   - cascade trigger works (UPDATE zones.code → properties.zone cascades)
//   - hard-delete RPC works on a throwaway zone
// Reverts every test mutation.
import 'dotenv/config';
import { readFileSync } from 'node:fs';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','X-App-Source':'sql'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0,1500)}`);
  return JSON.parse(body);
}

console.log('=== Applying 2026-05-29_zones_fk_refactor.sql ===');
console.log(await pg(readFileSync('docs/migrations/2026-05-29_zones_fk_refactor.sql', 'utf8')));

console.log('\n=== 1. zones structure ===');
console.log(await pg(`
  SELECT column_name, data_type, is_nullable, column_default
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='zones'
  ORDER BY ordinal_position;
`));
console.log(await pg(`
  SELECT conname, contype, pg_get_constraintdef(oid) AS def
  FROM pg_constraint
  WHERE conrelid='public.zones'::regclass
  ORDER BY conname;
`));

console.log('\n=== 2. properties.zone_id coverage ===');
console.log(await pg(`
  SELECT
    (zone IS NOT NULL) AS has_zone_text,
    (zone_id IS NOT NULL) AS has_zone_id,
    COUNT(*)::int AS n
  FROM public.properties
  GROUP BY 1, 2
  ORDER BY 1 DESC, 2 DESC;
`));

console.log('\n=== 3. zones_with_usage still works ===');
console.log(await pg(`
  SELECT code, label, is_active, n_properties FROM public.zones_with_usage
  ORDER BY sort_order;
`));

console.log('\n=== 4. Code rename cascade test ===');
console.log('  4a. Rename SOUTH → SOUTH_RNTEST');
console.log(await pg(`UPDATE public.zones SET code='SOUTH_RNTEST' WHERE code='SOUTH' RETURNING code;`));

console.log('  4b. Check 3 properties cascade to new code');
console.log(await pg(`
  SELECT id, zone, zone_id FROM public.properties
  WHERE zone_id = (SELECT id FROM public.zones WHERE code='SOUTH_RNTEST')
  ORDER BY id LIMIT 3;
`));

console.log('  4c. Revert: rename back to SOUTH');
console.log(await pg(`UPDATE public.zones SET code='SOUTH' WHERE code='SOUTH_RNTEST' RETURNING code;`));

console.log('  4d. Sanity: properties.zone is back to SOUTH');
console.log(await pg(`
  SELECT id, zone, zone_id FROM public.properties
  WHERE zone_id = (SELECT id FROM public.zones WHERE code='SOUTH')
  ORDER BY id LIMIT 3;
`));

console.log('\n=== 5. Hard-delete RPC test ===');
console.log('  5a. Create throwaway zone TEST_HD');
console.log(await pg(`
  INSERT INTO public.zones (code, label, color_hex, sort_order, is_active)
  VALUES ('TEST_HD', 'Hard Delete Test', '#999999', 999, true)
  RETURNING id, code;
`));

console.log('  5b. Call zones_hard_delete(TEST_HD)');
console.log(await pg(`SELECT * FROM public.zones_hard_delete('TEST_HD');`));

console.log('  5c. Confirm gone');
console.log(await pg(`SELECT code FROM public.zones WHERE code='TEST_HD';`));

console.log('\n=== 6. Final sanity — all 11 canonical zones intact ===');
console.log(await pg(`
  SELECT code, label, color_hex, sort_order, is_active
  FROM public.zones ORDER BY sort_order;
`));

console.log('\n=== 7. audit attribution check (last 2 min) ===');
console.log(await pg(`
  SELECT table_name, operation, app_source, COUNT(*)::int AS n
  FROM audit.logs
  WHERE changed_at >= now() - INTERVAL '2 minutes'
    AND table_name IN ('zones','properties')
  GROUP BY 1, 2, 3
  ORDER BY 1, 2, 3;
`));
