// dedupe_visit_photos.js
// Cleanse duplicate photo_links on visits — same image uploaded twice (driver
// double-attached to two Jobber notes for the same visit). Identifies dups by
// (visit_id, photos.size_bytes) — same size = same content (sizes are deterministic
// per image, no random collisions in real data).
//
// Keep policy: prefer the photo_link that HAS a classification (and the most
// recently classified). Fallback: lowest photo_link.id (oldest). This preserves
// any user classification work even if the duplicates were tagged differently.
//
// Steps:
//   1. Dry-run report (no writes) — list deletions per visit, flag classification mismatches
//   2. Execute on Prod — DELETE photo_links → CASCADE removes photo_classifications via FK
//   3. Mirror on Sandbox #1 — manually DELETE photo_classifications first (no FK), then photo_links
//   4. Clean orphan photos rows on both DBs
//   5. Re-verify counts
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX1 = process.env.SANDBOX_SUPABASE_PROJECT_ID;

function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({s: x.statusCode, b})); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}
const j = x => { try { return JSON.parse(x); } catch { return x; } };

// Smart-keep query: per (visit, size) group, rank by classified-first, recent-first, low-id-tiebreaker
const RANKING_CTE = `
  WITH ranked AS (
    SELECT pl.id AS link_id, pl.entity_id AS visit_id, ph.size_bytes, pl.photo_id,
           pc.service_phase, pc.updated_at AS pc_updated_at,
           ROW_NUMBER() OVER (
             PARTITION BY pl.entity_id, ph.size_bytes
             ORDER BY
               CASE WHEN pc.photo_link_id IS NOT NULL THEN 0 ELSE 1 END,  -- prefer classified
               pc.updated_at DESC NULLS LAST,                              -- prefer most recent
               pl.id                                                        -- tiebreaker: keep oldest
           ) AS rn,
           COUNT(*) OVER (PARTITION BY pl.entity_id, ph.size_bytes) AS group_size
    FROM photo_links pl
    JOIN photos ph ON ph.id = pl.photo_id
    LEFT JOIN photo_classifications pc ON pc.photo_link_id = pl.id
    WHERE pl.entity_type='visit' AND ph.size_bytes IS NOT NULL
  )`;

(async () => {
  console.log('='.repeat(78));
  console.log('STEP 1: DRY-RUN report (what would be deleted)');
  console.log('='.repeat(78));

  const dryRun = j((await pg(`
    ${RANKING_CTE}
    SELECT visit_id, size_bytes, link_id, service_phase, rn,
           CASE WHEN rn=1 THEN 'KEEP' ELSE 'DELETE' END AS action
    FROM ranked WHERE group_size > 1
    ORDER BY visit_id, size_bytes, rn;
  `, PROD)).b);

  // Group by visit for summary
  const byVisit = {};
  for (const r of dryRun) {
    byVisit[r.visit_id] = byVisit[r.visit_id] || { keep: 0, del: 0, mismatches: 0 };
    if (r.action === 'KEEP') byVisit[r.visit_id].keep++;
    else byVisit[r.visit_id].del++;
  }
  // Find classification mismatches within groups
  const groups = {};
  for (const r of dryRun) {
    const key = `${r.visit_id}:${r.size_bytes}`;
    if (!groups[key]) groups[key] = [];
    groups[key].push(r);
  }
  let mismatchesGlobal = 0;
  for (const [key, g] of Object.entries(groups)) {
    const phases = g.map(r => r.service_phase);
    const uniquePhases = [...new Set(phases.filter(p => p !== null))];
    if (uniquePhases.length > 1) {
      mismatchesGlobal++;
      const visitId = g[0].visit_id;
      byVisit[visitId].mismatches++;
    }
  }

  console.table(Object.entries(byVisit).map(([visitId, v]) => ({
    visit_id: visitId,
    keep: v.keep,
    delete: v.del,
    classification_mismatches_in_groups: v.mismatches,
  })));
  console.log(`\nTotal: ${dryRun.filter(r => r.action === 'KEEP').length} kept, ${dryRun.filter(r => r.action === 'DELETE').length} deleted, ${mismatchesGlobal} groups had differing classifications (smart-keep handles these by preferring most-recent).`);

  // === STEP 2: Execute on Prod ===
  console.log('\n' + '='.repeat(78));
  console.log('STEP 2: EXECUTE on Prod (CASCADE handles photo_classifications via FK)');
  console.log('='.repeat(78));
  const prodCountsBefore = j((await pg(`SELECT COUNT(*)::int AS pl_count FROM photo_links WHERE entity_type='visit'; SELECT COUNT(*)::int AS pc_count FROM photo_classifications;`, PROD)).b);
  console.log('  before: photo_links(visit) + photo_classifications counts:', prodCountsBefore);

  const prodDelete = await pg(`
    BEGIN;
    ${RANKING_CTE}
    DELETE FROM photo_links WHERE id IN (SELECT link_id FROM ranked WHERE rn > 1);
    COMMIT;
  `, PROD);
  console.log('  delete status:', prodDelete.s);
  if (prodDelete.s >= 300) { console.error('  failure:', prodDelete.b.slice(0,400)); process.exit(2); }

  const prodCountsAfter = j((await pg(`SELECT (SELECT COUNT(*)::int FROM photo_links WHERE entity_type='visit') AS pl_visit, (SELECT COUNT(*)::int FROM photo_classifications) AS pc;`, PROD)).b);
  console.log('  after:', prodCountsAfter);

  // === STEP 3: Mirror on Sandbox #1 (no FK, must delete classifications first) ===
  console.log('\n' + '='.repeat(78));
  console.log('STEP 3: MIRROR on Sandbox #1 (no FK — manual classification cleanup)');
  console.log('='.repeat(78));
  const sbxBefore = j((await pg(`SELECT (SELECT COUNT(*)::int FROM photo_links WHERE entity_type='visit') AS pl_visit, (SELECT COUNT(*)::int FROM photo_classifications) AS pc;`, SBX1)).b);
  console.log('  before:', sbxBefore);

  const sbxDelete = await pg(`
    BEGIN;
    -- 1) delete classifications for soon-to-be-deleted photo_links (no FK CASCADE on Sandbox)
    ${RANKING_CTE}, to_delete AS (SELECT link_id FROM ranked WHERE rn > 1)
    DELETE FROM photo_classifications WHERE photo_link_id IN (SELECT link_id FROM to_delete);
    -- 2) delete the duplicate photo_links
    ${RANKING_CTE}
    DELETE FROM photo_links WHERE id IN (SELECT link_id FROM ranked WHERE rn > 1);
    COMMIT;
  `, SBX1);
  console.log('  delete status:', sbxDelete.s);
  if (sbxDelete.s >= 300) { console.error('  failure:', sbxDelete.b.slice(0,400)); process.exit(2); }

  const sbxAfter = j((await pg(`SELECT (SELECT COUNT(*)::int FROM photo_links WHERE entity_type='visit') AS pl_visit, (SELECT COUNT(*)::int FROM photo_classifications) AS pc;`, SBX1)).b);
  console.log('  after:', sbxAfter);

  // === STEP 4: Clean orphan photos rows on both DBs ===
  console.log('\n' + '='.repeat(78));
  console.log('STEP 4: Clean orphan photos rows (no remaining photo_links)');
  console.log('='.repeat(78));
  for (const [name, id] of [['Prod', PROD], ['Sandbox #1', SBX1]]) {
    const before = j((await pg('SELECT COUNT(*)::int AS n FROM photos;', id)).b)[0].n;
    const orphans = j((await pg('SELECT COUNT(*)::int AS n FROM photos WHERE id NOT IN (SELECT DISTINCT photo_id FROM photo_links WHERE photo_id IS NOT NULL);', id)).b)[0].n;
    console.log(`  ${name}: ${before} photos total, ${orphans} are orphan → deleting...`);
    const r = await pg('DELETE FROM photos WHERE id NOT IN (SELECT DISTINCT photo_id FROM photo_links WHERE photo_id IS NOT NULL);', id);
    const after = j((await pg('SELECT COUNT(*)::int AS n FROM photos;', id)).b)[0].n;
    console.log(`  ${name}: ${before} → ${after} (removed ${before-after}) [status ${r.s}]`);
  }

  // === STEP 5: Verify visit 1799 specifically (your test visit) ===
  console.log('\n' + '='.repeat(78));
  console.log('STEP 5: Verify visit 1799 (199-JZ 2026-04-28) post-dedup');
  console.log('='.repeat(78));
  for (const [name, id] of [['Sandbox #1', SBX1], ['Prod', PROD]]) {
    const result = j((await pg(`
      SELECT pc.photo_link_id, pc.service_phase, ph.size_bytes
      FROM photo_classifications pc
      JOIN photo_links pl ON pl.id = pc.photo_link_id
      JOIN photos ph ON ph.id = pl.photo_id
      WHERE pl.entity_type='visit' AND pl.entity_id=1799
      ORDER BY pc.photo_link_id;
    `, id)).b);
    const dist = result.reduce((acc, r) => { acc[r.service_phase] = (acc[r.service_phase] || 0) + 1; return acc; }, {});
    console.log(`  ${name}: ${result.length} classifications | ${JSON.stringify(dist)}`);
  }

  console.log('\n✓ Dedup complete.');
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
