// Check whether a specific PRE-POST inspection has photos linked to it,
// and whether those photos exist in storage.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const r = (project, sql) => new Promise((res, rej) => {
  const req = https.request({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
  req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
});

const PROD = process.env.SUPABASE_PROJECT_ID;
const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const SHIFT_DATE = '2026-04-29';

(async () => {
  for (const [label, proj] of [['PROD', PROD], ['SANDBOX', SB]]) {
    console.log(`\n=== ${label} — Steven's shift on ${SHIFT_DATE} ===`);

    // Inspections for that shift
    const insp = await r(proj, `
      SELECT i.id, i.inspection_type, i.submitted_at::text AS submitted, i.shift_date::text AS shift,
             i.employee_id, e.full_name AS employee, i.vehicle_id, v.name AS vehicle,
             i.sludge_gallons, i.water_gallons, i.has_issue
      FROM inspections i
      LEFT JOIN employees e ON e.id = i.employee_id
      LEFT JOIN vehicles v ON v.id = i.vehicle_id
      WHERE i.shift_date = '${SHIFT_DATE}'
      ORDER BY i.inspection_type, i.submitted_at;
    `);
    console.log(`  Inspections on ${SHIFT_DATE}: ${insp.length}`);
    for (const i of insp) console.log(`    #${i.id}  ${i.inspection_type}  submitted=${i.submitted}  emp=${i.employee} (${i.employee_id})  veh=${i.vehicle}  has_issue=${i.has_issue}`);

    if (!insp.length) continue;

    // Photo links pointing at these inspections
    const ids = insp.map(i => i.id).join(',');
    const links = await r(proj, `
      SELECT pl.id AS link_id, pl.entity_type, pl.entity_id, pl.role,
             p.id AS photo_id, p.storage_path, p.file_name, p.size_bytes,
             p.created_at::text AS uploaded
      FROM photo_links pl
      JOIN photos p ON p.id = pl.photo_id
      WHERE pl.entity_type = 'inspection' AND pl.entity_id IN (${ids})
      ORDER BY pl.entity_id, pl.role;
    `);
    console.log(`  photo_links → these inspections: ${links.length}`);
    for (const l of links) console.log(`    inspection #${l.entity_id}  role=${l.role}  ${l.storage_path}  (${l.size_bytes} B, uploaded ${l.uploaded})`);

    // Also check if there are photos linked to NOTES from that same shift_date that might belong
    // Fred / drivers may have uploaded inspection photos as note attachments (older flow)
    const noteLinks = await r(proj, `
      SELECT n.id AS note_id, n.note_date::text AS note_date, n.body,
             COUNT(pl.id) AS photo_count
      FROM notes n
      LEFT JOIN photo_links pl ON pl.entity_type='note' AND pl.entity_id = n.id
      WHERE n.note_date::date BETWEEN '${SHIFT_DATE}'::date AND ('${SHIFT_DATE}'::date + INTERVAL '1 day')::date
      GROUP BY n.id, n.note_date, n.body
      HAVING COUNT(pl.id) > 0
      ORDER BY n.note_date
      LIMIT 5;
    `);
    if (noteLinks.length) {
      console.log(`  notes with photos around that date (might be inspection-related):`);
      for (const n of noteLinks) console.log(`    note #${n.note_id} ${n.note_date}  ${n.photo_count} photos  body="${(n.body || '').slice(0, 60)}"`);
    }
  }

  // What entity_types do photo_links actually use?
  console.log(`\n=== photo_links entity_type distribution (Sandbox) ===`);
  const ets = await r(SB, `SELECT entity_type, COUNT(*) AS n FROM photo_links GROUP BY entity_type ORDER BY n DESC`);
  for (const e of ets) console.log(`  ${e.entity_type}: ${e.n}`);
})().catch(e => { console.error(e.message); process.exit(2); });
