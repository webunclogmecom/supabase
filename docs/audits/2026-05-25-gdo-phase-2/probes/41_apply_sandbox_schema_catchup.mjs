// 41_apply_sandbox_schema_catchup.mjs
// In-scope fix from zero-runs iter 1 RED finding:
//   Apply visits.public_id + gdos.max_frequency_days migrations to Sandbox 1
//   so sandbox-refresh.yml can stop failing on column-not-found.

import 'dotenv/config';
import { readFile } from 'node:fs/promises';

const PAT = process.env.SUPABASE_PAT;
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
console.log(`Sandbox 1 project: ${SBX}`);

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${SBX}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('\n=== Pre-check: Sandbox missing columns ===');
const cols = await pg(`
  SELECT table_name, column_name FROM information_schema.columns
  WHERE table_schema='public' AND (
    (table_name='visits' AND column_name='public_id')
    OR (table_name='gdos' AND column_name='max_frequency_days')
  ) ORDER BY 1,2;
`);
console.log('  Found:', cols);

const need_public_id = !cols.some(c => c.table_name === 'visits' && c.column_name === 'public_id');
const need_max_freq = !cols.some(c => c.table_name === 'gdos' && c.column_name === 'max_frequency_days');
console.log(`  Need visits.public_id: ${need_public_id}`);
console.log(`  Need gdos.max_frequency_days: ${need_max_freq}`);

if (need_public_id) {
  console.log('\n=== Applying 2026-05-25e_visits_public_id.sql ===');
  const sql = await readFile('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/docs/migrations/2026-05-25e_visits_public_id.sql', 'utf8');
  const result = await pg(sql);
  console.log('  Result:', result);
}

if (need_max_freq) {
  console.log('\n=== Applying 2026-05-25i_gdos_max_frequency_days.sql ===');
  const sql = await readFile('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/docs/migrations/2026-05-25i_gdos_max_frequency_days.sql', 'utf8');
  const result = await pg(sql);
  console.log('  Result:', result);
}

console.log('\n=== Post-check ===');
console.log(await pg(`
  SELECT table_name, column_name FROM information_schema.columns
  WHERE table_schema='public' AND (
    (table_name='visits' AND column_name='public_id')
    OR (table_name='gdos' AND column_name='max_frequency_days')
  ) ORDER BY 1,2;
`));
