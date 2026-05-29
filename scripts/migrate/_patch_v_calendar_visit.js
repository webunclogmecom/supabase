// Fetch the current ops.v_calendar_visit definition, append `WHERE v.deleted_at
// IS NULL` to the outer SELECT, and re-CREATE the view via Management API.
// Idempotent.

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  return { ok: r.ok, status: r.status, body: await r.text() };
}

(async () => {
  const get = await sql(`SELECT pg_get_viewdef('ops.v_calendar_visit'::regclass, true) AS def;`);
  if (!get.ok) { console.error(get.body); process.exit(1); }
  const oldDef = JSON.parse(get.body)[0].def;
  console.log('Original length:', oldDef.length);

  // The view has no WHERE at the outer SELECT — ends with a string of LEFT JOINs
  // and a final semicolon. We append a WHERE just before the trailing semicolon.
  let newDef = oldDef.trim();
  if (newDef.endsWith(';')) newDef = newDef.slice(0, -1);
  newDef += `\n  WHERE v.deleted_at IS NULL;`;

  // Wrap in CREATE OR REPLACE
  const migration = `
BEGIN;
DROP VIEW IF EXISTS ops.v_calendar_visit;
CREATE VIEW ops.v_calendar_visit AS
${newDef}
GRANT SELECT ON ops.v_calendar_visit TO anon, authenticated;
COMMIT;
`;
  console.log('--- New SQL ---');
  console.log(migration);
  console.log('---');

  if (!process.argv.includes('--apply')) {
    console.log('(dry-run; pass --apply to execute)');
    return;
  }

  const apply = await sql(migration);
  console.log('Apply status:', apply.status, apply.body.slice(0, 200));
})();
