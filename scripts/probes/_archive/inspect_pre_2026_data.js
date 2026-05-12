// Identify scope of pre-2026 deletion safely.
// Photos can be linked to MULTIPLE entities via photo_links. We must only
// delete photos whose ALL links point to pre-2026 notes (or pre-2026 visits,
// or pre-2026 manifests). If a photo is linked to even one 2026 entity, KEEP.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const r = (sql) => new Promise((res, rej) => {
  const req = https.request({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
  req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
});

(async () => {
  const CUT = '2026-01-01';

  // 1. Pre-2026 notes
  const preNotes = await r(`SELECT COUNT(*) AS n FROM notes WHERE note_date < '${CUT}'`);
  console.log(`Pre-2026 notes:                              ${preNotes[0].n}`);

  // 2. photo_links pointing at pre-2026 notes
  const preNoteLinks = await r(`
    SELECT COUNT(*) AS n FROM photo_links pl
    JOIN notes n ON n.id = pl.entity_id
    WHERE pl.entity_type='note' AND n.note_date < '${CUT}'
  `);
  console.log(`photo_links → pre-2026 notes:                ${preNoteLinks[0].n}`);

  // 3. Are any of those photos ALSO linked to 2026 entities? (would survive deletion)
  // i.e., a photo with at least one link to entity_type='note' (pre-2026)
  // AND another link to a 2026 visit/manifest.
  const sharedPhotos = await r(`
    WITH pre_note_photos AS (
      SELECT DISTINCT pl.photo_id
      FROM photo_links pl
      JOIN notes n ON n.id = pl.entity_id
      WHERE pl.entity_type='note' AND n.note_date < '${CUT}'
    ),
    photo_other_links AS (
      SELECT DISTINCT p.photo_id
      FROM pre_note_photos p
      JOIN photo_links pl2 ON pl2.photo_id = p.photo_id
      WHERE
        -- linked to a 2026+ visit
        (pl2.entity_type='visit' AND EXISTS (SELECT 1 FROM visits v WHERE v.id = pl2.entity_id AND v.visit_date >= '${CUT}'))
        OR
        -- linked to a 2026+ manifest (use shipped_at or created_at as the date)
        (pl2.entity_type='derm_manifest' AND EXISTS (
           SELECT 1 FROM derm_manifests m WHERE m.id = pl2.entity_id
             AND COALESCE(m.service_date, m.created_at::date) >= '${CUT}'
        ))
        OR
        -- linked to a 2026+ note (different note that survives)
        (pl2.entity_type='note' AND EXISTS (
           SELECT 1 FROM notes n2 WHERE n2.id = pl2.entity_id AND n2.note_date >= '${CUT}'
        ))
    )
    SELECT COUNT(*) AS n FROM photo_other_links;
  `);
  console.log(`...of those, photos ALSO linked to 2026+:    ${sharedPhotos[0].n}  (these stay)`);

  // 4. Photos to fully delete (only pre-2026 links)
  const photosToDelete = await r(`
    WITH pre_note_photos AS (
      SELECT DISTINCT pl.photo_id
      FROM photo_links pl
      JOIN notes n ON n.id = pl.entity_id
      WHERE pl.entity_type='note' AND n.note_date < '${CUT}'
    )
    SELECT COUNT(*) AS n, SUM(p.size_bytes)::bigint AS total_bytes
    FROM photos p
    WHERE p.id IN (SELECT photo_id FROM pre_note_photos)
      AND NOT EXISTS (
        SELECT 1 FROM photo_links pl2 WHERE pl2.photo_id = p.id
        AND (
          (pl2.entity_type='visit' AND EXISTS (SELECT 1 FROM visits v WHERE v.id = pl2.entity_id AND v.visit_date >= '${CUT}'))
          OR (pl2.entity_type='derm_manifest' AND EXISTS (SELECT 1 FROM derm_manifests m WHERE m.id = pl2.entity_id AND COALESCE(m.service_date, m.created_at::date) >= '${CUT}'))
          OR (pl2.entity_type='note' AND EXISTS (SELECT 1 FROM notes n2 WHERE n2.id = pl2.entity_id AND n2.note_date >= '${CUT}'))
        )
      );
  `);
  const mb = (Number(photosToDelete[0].total_bytes || 0) / 1024 / 1024).toFixed(0);
  console.log(`Photos to FULLY delete (DB + storage):       ${photosToDelete[0].n}  (~${mb} MB)`);

  // 5. Are there pre-2026 photos linked DIRECTLY to visits or manifests (not via notes)?
  const directVisitPhotos = await r(`
    SELECT COUNT(*) AS n FROM photo_links pl
    JOIN visits v ON v.id = pl.entity_id
    WHERE pl.entity_type='visit' AND v.visit_date < '${CUT}'
  `);
  console.log(`photo_links → pre-2026 visits (direct):       ${directVisitPhotos[0].n}`);

  const directManifestPhotos = await r(`
    SELECT COUNT(*) AS n FROM photo_links pl
    JOIN derm_manifests m ON m.id = pl.entity_id
    WHERE pl.entity_type='derm_manifest' AND COALESCE(m.service_date, m.created_at::date) < '${CUT}'
  `);
  console.log(`photo_links → pre-2026 manifests (direct):    ${directManifestPhotos[0].n}`);

  // 6. Visits/manifests pre-2026 — are we keeping them or also deleting?
  const preVisits = await r(`SELECT COUNT(*) AS n FROM visits WHERE visit_date < '${CUT}'`);
  const preManifests = await r(`SELECT COUNT(*) AS n FROM derm_manifests WHERE COALESCE(service_date, created_at::date) < '${CUT}'`);
  console.log(`\nFor reference:`);
  console.log(`  visits pre-2026:     ${preVisits[0].n}`);
  console.log(`  manifests pre-2026:  ${preManifests[0].n}`);
})().catch(e => { console.error(e.message); process.exit(2); });
