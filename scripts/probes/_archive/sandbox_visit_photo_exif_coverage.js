// How usable is photos.exif_taken_at as a "before/after service" classifier signal?
// For every visit with ≥2 linked photos: what % of those photos have EXIF timestamps?
// Also reports uploaded_at coverage (fallback signal).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql, projectId) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({status: x.statusCode, body: b})); });
    req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
  });
}

(async () => {
  console.log('=== Visit-photo EXIF coverage (Sandbox) ===\n');

  // Overall photo-level coverage on photos linked to visits
  const overall = JSON.parse((await pg(`
    SELECT
      COUNT(DISTINCT pl.id) AS visit_link_rows,
      COUNT(DISTINCT pl.photo_id) AS distinct_photos,
      COUNT(DISTINCT pl.entity_id) AS distinct_visits,
      ROUND(100.0 * COUNT(DISTINCT pl.photo_id) FILTER (WHERE ph.exif_taken_at IS NOT NULL)
        / NULLIF(COUNT(DISTINCT pl.photo_id), 0), 1) AS pct_with_exif,
      ROUND(100.0 * COUNT(DISTINCT pl.photo_id) FILTER (WHERE ph.uploaded_at IS NOT NULL)
        / NULLIF(COUNT(DISTINCT pl.photo_id), 0), 1) AS pct_with_uploaded_at
    FROM photo_links pl JOIN photos ph ON ph.id = pl.photo_id
    WHERE pl.entity_type = 'visit';`, SBX)).body);
  console.log('Overall photos linked to visits:');
  console.log(JSON.stringify(overall[0], null, 2));

  // Per-visit: how many visits have enough EXIF coverage to do a temporal split?
  const perVisit = JSON.parse((await pg(`
    WITH visit_photo AS (
      SELECT pl.entity_id AS visit_id, ph.exif_taken_at, ph.uploaded_at
      FROM photo_links pl JOIN photos ph ON ph.id = pl.photo_id
      WHERE pl.entity_type = 'visit'
    ), per_visit AS (
      SELECT visit_id, COUNT(*) AS n_photos,
        COUNT(*) FILTER (WHERE exif_taken_at IS NOT NULL) AS n_with_exif,
        COUNT(*) FILTER (WHERE uploaded_at IS NOT NULL) AS n_with_uploaded_at
      FROM visit_photo GROUP BY visit_id
    )
    SELECT
      COUNT(*) AS total_visits_with_photos,
      COUNT(*) FILTER (WHERE n_photos >= 2) AS visits_with_2plus_photos,
      COUNT(*) FILTER (WHERE n_photos >= 2 AND n_with_exif = n_photos) AS visits_full_exif,
      COUNT(*) FILTER (WHERE n_photos >= 2 AND n_with_exif >= n_photos/2.0) AS visits_50pct_exif,
      COUNT(*) FILTER (WHERE n_photos >= 2 AND n_with_exif = 0) AS visits_zero_exif,
      COUNT(*) FILTER (WHERE n_photos >= 2 AND n_with_uploaded_at = n_photos) AS visits_full_uploaded_at
    FROM per_visit;`, SBX)).body);
  console.log('\nPer-visit breakdown:');
  console.log(JSON.stringify(perVisit[0], null, 2));

  // Sample 5 recent completed 2026 visits and show their per-photo signals
  console.log('\nSample: 5 recent completed 2026 visits, per-photo signals');
  const sample = JSON.parse((await pg(`
    SELECT v.id AS visit_id, v.visit_date::text, c.client_code,
      ph.id AS photo_id, ph.exif_taken_at, ph.uploaded_at,
      pl.role, ph.exif_device
    FROM visits v
    JOIN photo_links pl ON pl.entity_type='visit' AND pl.entity_id = v.id
    JOIN photos ph ON ph.id = pl.photo_id
    LEFT JOIN clients c ON c.id = v.client_id
    WHERE v.visit_date >= '2026-04-01' AND v.visit_status='completed'
    ORDER BY v.visit_date DESC, v.id, ph.exif_taken_at NULLS LAST
    LIMIT 30;`, SBX)).body);
  console.log(JSON.stringify(sample, null, 2));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
