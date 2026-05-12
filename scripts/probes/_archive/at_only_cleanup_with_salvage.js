// Phase 2: Clean remaining AT-only visits.
//   - For each AT-only visit, look for a matching Jobber-linked visit
//     (same client, ±2 days). If found: transfer the Airtable ESL onto the
//     Jobber row (preserve cross-system traceability). Then delete the
//     AT-only visit row.
//   - For AT-only visits with no match: hard delete.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const target = (process.argv.find(a => a.startsWith('--target=')) || '--target=main').split('=')[1];
const PROJECT = target === 'sandbox' ? process.env.SANDBOX_SUPABASE_PROJECT_ID : process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,800)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log(`Target: ${target} (${PROJECT})\n`);

  console.log('=== BEFORE ===');
  console.table(await q(`
    SELECT 'visits_total' AS metric, COUNT(*) AS n FROM visits
    UNION ALL SELECT 'at_only_remaining', COUNT(*) FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
        AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber');
  `));

  console.log('\n=== Cross-ref preview: salvage vs phantom in remaining AT-only ===');
  console.table(await q(`
    WITH at_only AS (
      SELECT v.id, v.client_id, v.visit_date FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
        AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    ),
    matches AS (
      SELECT
        at.id AS at_visit_id,
        (SELECT jv.id FROM visits jv
         WHERE jv.client_id = at.client_id
           AND ABS(jv.visit_date - at.visit_date) <= 2
           AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=jv.id AND source_system='jobber')
         ORDER BY ABS(jv.visit_date - at.visit_date), jv.id LIMIT 1) AS jobber_match_id
      FROM at_only at
    )
    SELECT
      COUNT(*) FILTER (WHERE jobber_match_id IS NOT NULL) AS salvage,
      COUNT(*) FILTER (WHERE jobber_match_id IS NULL) AS phantom
    FROM matches;
  `));

  console.log('\n=== Running cleanup transaction ===');
  const sql = `
    BEGIN;

    -- Step 0: Capture every AT-only visit ID UPFRONT. Once we move ESLs in
    -- step 2, "AT-only" criterion no longer matches the salvaged ones, so we
    -- need a static list to drive every subsequent step.
    CREATE TEMP TABLE to_delete AS
    SELECT v.id FROM visits v
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
      AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber');

    -- Step 1: Build the salvage list — AT-only visits that have a Jobber match
    -- within ±2d on the same client. We'll transfer their AT ESL to the matched
    -- Jobber visit row.
    -- IMPORTANT: dedup by jobber_visit_id and exclude jobber rows that already
    -- have an Airtable ESL (would conflict on UNIQUE (entity_type, entity_id,
    -- source_system)).
    CREATE TEMP TABLE salvage_map AS
    WITH at_only AS (
      SELECT v.id AS at_visit_id, v.client_id, v.visit_date,
             (SELECT esl.source_id FROM entity_source_links esl
               WHERE esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='airtable' LIMIT 1) AS at_record_id
      FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
        AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    ),
    raw_matches AS (
      SELECT
        at.at_visit_id,
        at.at_record_id,
        (SELECT jv.id FROM visits jv
         WHERE jv.client_id = at.client_id
           AND ABS(jv.visit_date - at.visit_date) <= 2
           AND EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=jv.id AND source_system='jobber')
           AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=jv.id AND source_system='airtable')
         ORDER BY ABS(jv.visit_date - at.visit_date), jv.id LIMIT 1) AS jobber_visit_id
      FROM at_only at
    )
    -- Keep one AT-only per jobber_visit_id (the lowest at_visit_id wins)
    SELECT DISTINCT ON (jobber_visit_id) at_visit_id, at_record_id, jobber_visit_id
    FROM raw_matches
    WHERE jobber_visit_id IS NOT NULL
    ORDER BY jobber_visit_id, at_visit_id;

    -- Step 2: Transfer Airtable ESL from AT-only visit → Jobber visit.
    -- salvage_map is already deduped (one AT per Jobber, Jobber doesn't have
    -- an existing AT ESL), so this UPDATE is collision-free.
    UPDATE entity_source_links esl
    SET entity_id = sm.jobber_visit_id
    FROM salvage_map sm
    WHERE esl.entity_type='visit' AND esl.source_system='airtable'
      AND esl.entity_id = sm.at_visit_id;

    -- Step 3: Delete dependents of all to_delete visits (drive everything
    -- off the static to_delete list, NOT the AT-only criterion which has
    -- changed after Step 2).
    UPDATE jobber_oversized_attachments SET visit_id = NULL
    WHERE visit_id IN (SELECT id FROM to_delete);

    WITH del_notes AS (SELECT id FROM notes WHERE visit_id IN (SELECT id FROM to_delete))
    DELETE FROM photo_links WHERE entity_type='note' AND entity_id IN (SELECT id FROM del_notes);

    WITH del_notes AS (SELECT id FROM notes WHERE visit_id IN (SELECT id FROM to_delete))
    DELETE FROM entity_source_links WHERE entity_type='note' AND entity_id IN (SELECT id FROM del_notes);

    DELETE FROM notes WHERE visit_id IN (SELECT id FROM to_delete);

    DELETE FROM photo_links WHERE entity_type='visit' AND entity_id IN (SELECT id FROM to_delete);

    -- Any leftover ESL pointing at to_delete IDs (should be empty for the
    -- salvaged ones since their AT ESL was moved in Step 2; only the
    -- non-salvage to_delete IDs still have AT ESLs to clean up).
    DELETE FROM entity_source_links WHERE entity_type='visit' AND entity_id IN (SELECT id FROM to_delete);

    -- Step 4: Delete every visit in to_delete (visit_assignments and
    -- manifest_visits cascade automatically).
    DELETE FROM visits WHERE id IN (SELECT id FROM to_delete);

    -- Step 5: Orphan photos cleanup
    DELETE FROM entity_source_links
    WHERE entity_type='photo' AND entity_id IN (
      SELECT p.id FROM photos p WHERE NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.photo_id=p.id)
    );
    DELETE FROM photos WHERE NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.photo_id=photos.id);

    DROP TABLE salvage_map;
    DROP TABLE to_delete;

    COMMIT;
  `;

  await q(sql);
  console.log('  ✓ committed');

  console.log('\n=== AFTER ===');
  console.table(await q(`
    SELECT 'visits_total' AS metric, COUNT(*) AS n FROM visits
    UNION ALL SELECT 'at_only_remaining', COUNT(*) FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
        AND NOT EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    UNION ALL SELECT 'visits_jobber_linked', COUNT(*) FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')
    UNION ALL SELECT 'visits_with_at_link', COUNT(*) FROM visits v
      WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')
    UNION ALL SELECT 'photos_total', COUNT(*) FROM photos
    UNION ALL SELECT 'photo_links_total', COUNT(*) FROM photo_links;
  `));

  console.log('\n=== Final visit breakdown by year + source ===');
  console.table(await q(`
    SELECT EXTRACT(YEAR FROM visit_date)::int AS year,
      CASE
        WHEN at_links.cnt > 0 AND jb_links.cnt > 0 THEN 'BOTH'
        WHEN jb_links.cnt > 0                      THEN 'jobber'
        ELSE                                            'other'
      END AS src,
      COUNT(*) AS n
    FROM visits v
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber') jb_links ON true
    LEFT JOIN LATERAL (SELECT COUNT(*) AS cnt FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable') at_links ON true
    GROUP BY year, src ORDER BY year, src;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
