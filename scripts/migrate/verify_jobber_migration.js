// ============================================================================
// Jobber migration — post-run verification
// ============================================================================
// Run after jobber_notes_photos.js completes to produce a health report.
// Safe to run anytime (read-only queries).
//
// Usage: node scripts/migrate/verify_jobber_migration.js
// ============================================================================

require('dotenv').config();
const https = require('https');

function q(sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + process.env.SUPABASE_PAT,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => {
        if (res.statusCode >= 300) reject(new Error('HTTP ' + res.statusCode + ': ' + d.slice(0, 400)));
        else resolve(JSON.parse(d));
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

(async () => {
  console.log('='.repeat(72));
  console.log('Jobber notes + photos migration — verification report');
  console.log('='.repeat(72));

  // 1. Cursor state
  const cur = await q("SELECT * FROM sync_cursors WHERE entity='jobber_notes_migration'");
  if (cur.length) {
    const c = cur[0];
    console.log('\n[1] Checkpoint');
    console.log('  status             :', c.last_run_status);
    console.log('  last client_id     :', c.rows_pulled);
    console.log('  total notes        :', c.rows_populated);
    console.log('  last run started   :', c.last_run_started);
    console.log('  last run finished  :', c.last_run_finished || '(still running?)');
    if (c.last_error) console.log('  last_error         :', c.last_error.slice(0, 200));
  }

  // 2. Volume counts
  const totals = await q(`
    SELECT
      (SELECT COUNT(*)::int FROM notes WHERE source='jobber_migration') AS notes_total,
      (SELECT COUNT(*)::int FROM notes WHERE source='jobber_migration' AND visit_id IS NOT NULL) AS notes_visit_scoped,
      (SELECT COUNT(*)::int FROM notes WHERE source='jobber_migration' AND visit_id IS NULL) AS notes_non_visit,
      (SELECT COUNT(*)::int FROM photos WHERE source='jobber_migration') AS photos_total,
      (SELECT COUNT(*)::int FROM photo_links pl
         JOIN photos p ON p.id=pl.photo_id
         WHERE p.source='jobber_migration' AND pl.entity_type='visit') AS links_to_visits,
      (SELECT COUNT(*)::int FROM photo_links pl
         JOIN photos p ON p.id=pl.photo_id
         WHERE p.source='jobber_migration' AND pl.entity_type='note') AS links_to_notes,
      (SELECT COUNT(*)::int FROM jobber_oversized_attachments) AS oversized,
      (SELECT pg_size_pretty(SUM(size_bytes)) FROM photos WHERE source='jobber_migration') AS storage_used
  `);
  const t = totals[0];
  console.log('\n[2] Volume');
  console.log('  Notes total        :', t.notes_total);
  console.log('    visit-scoped     :', t.notes_visit_scoped, '(' + Math.round(t.notes_visit_scoped / (t.notes_total||1) * 100) + '%)');
  console.log('    non-visit        :', t.notes_non_visit, '(' + Math.round(t.notes_non_visit / (t.notes_total||1) * 100) + '%)');
  console.log('  Photos total       :', t.photos_total);
  console.log('    linked to visit  :', t.links_to_visits);
  console.log('    linked to note   :', t.links_to_notes);
  console.log('  Storage used       :', t.storage_used);
  console.log('  Oversized skipped  :', t.oversized);

  // 3. Client coverage
  const coverage = await q(`
    SELECT
      COUNT(DISTINCT client_id)::int AS clients_with_notes,
      (SELECT COUNT(*)::int FROM entity_source_links WHERE entity_type='client' AND source_system='jobber') AS total_jobber_clients
    FROM notes WHERE source='jobber_migration'
  `);
  const cv = coverage[0];
  console.log('\n[3] Coverage');
  console.log('  Clients with notes :', cv.clients_with_notes, '/', cv.total_jobber_clients, 'Jobber clients');

  // 4. Content type breakdown
  const byType = await q(`
    SELECT content_type, COUNT(*)::int AS cnt, pg_size_pretty(SUM(size_bytes)) AS size
    FROM photos WHERE source='jobber_migration'
    GROUP BY content_type ORDER BY cnt DESC
  `);
  console.log('\n[4] Content types');
  byType.forEach(r => console.log('  ' + r.content_type.padEnd(25), String(r.cnt).padStart(5), r.size));

  // 5. Oversized files breakdown
  if (t.oversized > 0) {
    const over = await q(`
      SELECT file_name, content_type, pg_size_pretty(size_bytes) AS size, classification_kind
      FROM jobber_oversized_attachments
      ORDER BY size_bytes DESC
      LIMIT 20
    `);
    console.log('\n[5] Oversized attachments (top 20)');
    over.forEach(r => console.log('  ' + String(r.size).padEnd(8), r.content_type.padEnd(20), r.classification_kind.padEnd(10), r.file_name.slice(0, 60)));
  }

  // 6. Integrity — every note with source='jobber_migration' has an entity_source_links row
  const integrity = await q(`
    SELECT
      (SELECT COUNT(*)::int FROM notes n WHERE n.source='jobber_migration'
        AND NOT EXISTS (SELECT 1 FROM entity_source_links esl
                        WHERE esl.entity_type='note' AND esl.entity_id=n.id AND esl.source_system='jobber')) AS notes_missing_esl,
      (SELECT COUNT(*)::int FROM photos p WHERE p.source='jobber_migration'
        AND NOT EXISTS (SELECT 1 FROM entity_source_links esl
                        WHERE esl.entity_type='photo' AND esl.entity_id=p.id AND esl.source_system='jobber')) AS photos_missing_esl,
      (SELECT COUNT(*)::int FROM photos p WHERE p.source='jobber_migration'
        AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.photo_id=p.id)) AS photos_without_link
  `);
  const i = integrity[0];
  console.log('\n[6] Integrity');
  console.log('  Notes missing entity_source_links  :', i.notes_missing_esl, i.notes_missing_esl === 0 ? 'OK' : 'FAIL');
  console.log('  Photos missing entity_source_links :', i.photos_missing_esl, i.photos_missing_esl === 0 ? 'OK' : 'FAIL');
  console.log('  Orphan photos (no photo_link)      :', i.photos_without_link, i.photos_without_link === 0 ? 'OK' : 'FAIL');

  // 7. Sample data for spot-checking
  const sample = await q(`
    SELECT n.id, c.name AS client, n.visit_id, n.author_name, n.note_date::text, LEFT(n.body, 80) AS body
    FROM notes n
    JOIN clients c ON c.id = n.client_id
    WHERE n.source='jobber_migration'
    ORDER BY n.id DESC
    LIMIT 5
  `);
  console.log('\n[7] Sample (5 most recent notes)');
  sample.forEach(s => console.log('  #' + s.id, '|', s.client.slice(0, 30).padEnd(30), '| visit', String(s.visit_id||'(non-visit)').padEnd(14), '|', s.author_name || '?', '|', (s.body || '').replace(/\n/g, ' ').slice(0, 80)));

  console.log('\n' + '='.repeat(72));
})().catch(e => { console.error('ERROR:', e.message); process.exit(1); });
