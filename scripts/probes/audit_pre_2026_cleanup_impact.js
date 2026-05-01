// Audit: what would get deleted if we drop all visits with visit_date < 2026-01-01.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== FK tables referencing visits.id and their cascade behavior ===');
  console.table(await q(`
    SELECT
      tc.table_name AS child_table,
      kcu.column_name AS child_column,
      rc.delete_rule
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu USING (constraint_name, table_schema)
    JOIN information_schema.referential_constraints rc USING (constraint_name)
    JOIN information_schema.constraint_column_usage ccu USING (constraint_name)
    WHERE tc.constraint_type='FOREIGN KEY'
      AND ccu.table_name='visits' AND ccu.column_name='id'
      AND tc.table_schema='public'
    ORDER BY tc.table_name;
  `));

  console.log('\n=== Visits to delete (visit_date < 2026-01-01) — by year & status ===');
  console.table(await q(`
    SELECT EXTRACT(YEAR FROM visit_date)::int AS year, visit_status, COUNT(*) AS n
    FROM visits
    WHERE visit_date < '2026-01-01' OR visit_date IS NULL
    GROUP BY year, visit_status ORDER BY year, visit_status;
  `));

  console.log('\n=== Total visits to delete vs survive ===');
  console.table(await q(`
    SELECT
      COUNT(*) FILTER (WHERE visit_date < '2026-01-01' OR visit_date IS NULL) AS to_delete,
      COUNT(*) FILTER (WHERE visit_date >= '2026-01-01') AS will_survive,
      COUNT(*) AS total
    FROM visits;
  `));

  console.log('\n=== Cascade impact on each FK table ===');
  console.table(await q(`
    WITH del AS (SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL)
    SELECT 'visit_assignments' AS table_name,
           (SELECT COUNT(*) FROM visit_assignments WHERE visit_id IN (SELECT id FROM del)) AS rows_affected
    UNION ALL
    SELECT 'photo_links (entity_type=visit)',
           (SELECT COUNT(*) FROM photo_links WHERE entity_type='visit' AND entity_id IN (SELECT id FROM del))
    UNION ALL
    SELECT 'notes (visit_id)',
           (SELECT COUNT(*) FROM notes WHERE visit_id IN (SELECT id FROM del))
    UNION ALL
    SELECT 'manifest_visits',
           (SELECT COUNT(*) FROM manifest_visits WHERE visit_id IN (SELECT id FROM del))
    UNION ALL
    SELECT 'inspections (visit_id)',
           (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='inspections' AND column_name='visit_id')
    UNION ALL
    SELECT 'entity_source_links (visit)',
           (SELECT COUNT(*) FROM entity_source_links WHERE entity_type='visit' AND entity_id IN (SELECT id FROM del));
  `));

  console.log('\n=== Photos that would become orphaned (linked ONLY to deleted visits) ===');
  console.table(await q(`
    WITH del_visits AS (SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL),
    photos_in_del AS (
      SELECT DISTINCT pl.photo_id
      FROM photo_links pl
      WHERE pl.entity_type='visit' AND pl.entity_id IN (SELECT id FROM del_visits)
    ),
    photos_with_other_links AS (
      SELECT DISTINCT pl.photo_id
      FROM photo_links pl
      WHERE pl.photo_id IN (SELECT photo_id FROM photos_in_del)
        AND NOT (pl.entity_type='visit' AND pl.entity_id IN (SELECT id FROM del_visits))
    )
    SELECT
      (SELECT COUNT(*) FROM photos_in_del) AS photos_referenced_by_deleted_visits,
      (SELECT COUNT(*) FROM photos_with_other_links) AS would_keep_via_other_link,
      (SELECT COUNT(*) FROM photos_in_del) - (SELECT COUNT(*) FROM photos_with_other_links) AS would_become_orphan;
  `));

  console.log('\n=== Notes attached to deleted visits — break down by source ===');
  console.table(await q(`
    WITH del_visits AS (SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL)
    SELECT
      n.source,
      COUNT(*) AS n_notes,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id)) AS notes_with_photos
    FROM notes n
    WHERE n.visit_id IN (SELECT id FROM del_visits)
    GROUP BY n.source ORDER BY n_notes DESC;
  `));

  console.log('\n=== inspections schema check (does it have visit_id?) ===');
  console.table(await q(`
    SELECT column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name='inspections'
      AND column_name LIKE '%visit%';
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
