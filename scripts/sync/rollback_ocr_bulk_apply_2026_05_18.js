// ============================================================================
// rollback_ocr_bulk_apply_2026_05_18.js — undo today's bulk OCR apply.
//
// Why: the OCR extracted the FOG eManifest form's PRINTED SERIAL (top-right,
// 3-digit, e.g. "265", "166") — which is NOT the same as the canonical
// "White Manifest #". The actual White Manifest # is a 6-digit identifier
// that exists ONLY for Miami-Dade records and lives on the Miami-Dade
// disposal facility receipt (not on the FOG eManifest form). Broward records
// have no White Manifest # at all — they use Yellow Ticket # instead.
//
// What we apply this script to: the 120 manifests whose white_manifest_number
// went from NULL → 3-digit value during today's bulk_apply run
// (2026-05-18 19:14 - 19:16 UTC). Per the audit log this is forensically
// pinpointed and idempotent.
//
// Two writes per row, both audited:
//   1. UPDATE public.derm_manifests SET white_manifest_number = NULL
//   2. UPDATE public.derm_manifest_number_proposals SET review_status='rejected'
//      WITH notes explaining the misextraction
//
// CLI:
//   node scripts/sync/rollback_ocr_bulk_apply_2026_05_18.js              # dry-run
//   node scripts/sync/rollback_ocr_bulk_apply_2026_05_18.js --execute    # do it
// ============================================================================

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const EXECUTE = process.argv.includes('--execute');

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log(`# OCR bulk-apply rollback — ${new Date().toISOString()} ${EXECUTE ? 'EXECUTE' : '(DRY-RUN)'}`);

  // Identify the manifests that today's bulk-apply touched.
  // Criteria: audit row where old_white IS NULL and new_white was a 3-digit
  // value, in the 19:14-19:16 UTC window.
  const targets = await pg(`
    SELECT DISTINCT (record_pk->>'id')::bigint AS manifest_id,
                    new_row->>'white_manifest_number' AS bad_value
    FROM audit.logs
    WHERE table_name='derm_manifests'
      AND operation='UPDATE'
      AND (old_row->>'white_manifest_number') IS NULL
      AND (new_row->>'white_manifest_number') IS NOT NULL
      AND LENGTH(new_row->>'white_manifest_number') = 3
      AND changed_at >= '2026-05-18 19:14:00+00'
      AND changed_at <= '2026-05-18 19:17:00+00'
    ORDER BY manifest_id`);

  console.log('Target manifest rows to revert:', targets.length);

  if (targets.length === 0) {
    console.log('Nothing to do.');
    return;
  }

  // Safety: re-verify each row still has the bad value before reverting (idempotent)
  let willRevert = 0, alreadyClean = 0, drifted = 0;
  for (const t of targets) {
    const cur = await pg(`SELECT white_manifest_number FROM public.derm_manifests WHERE id = ${t.manifest_id}`);
    if (cur.length === 0) { console.log(`  [skip] manifest ${t.manifest_id}: row no longer exists`); continue; }
    const cv = cur[0].white_manifest_number;
    if (cv === null) { alreadyClean++; continue; }
    if (cv !== t.bad_value) { drifted++; console.log(`  [skip] manifest ${t.manifest_id}: drifted to "${cv}" (expected "${t.bad_value}") — leave alone`); continue; }
    willRevert++;
  }

  console.log(`  Will revert: ${willRevert}`);
  console.log(`  Already clean (already NULL): ${alreadyClean}`);
  console.log(`  Drifted (value changed after our apply — manual review): ${drifted}`);

  if (!EXECUTE) { console.log('\n(DRY-RUN) Re-run with --execute to apply.'); return; }

  // Apply — per-row transaction
  let reverted = 0, proposalsRejected = 0, errors = 0;
  for (const t of targets) {
    try {
      // Revert white_manifest_number to NULL only if it still has the bad value
      const r1 = await pg(`
        UPDATE public.derm_manifests
           SET white_manifest_number = NULL
         WHERE id = ${t.manifest_id}
           AND white_manifest_number = '${t.bad_value.replace(/'/g, "''")}'
        RETURNING id`);
      if (r1.length === 1) reverted++;

      // Reject the corresponding proposal(s)
      const r2 = await pg(`
        UPDATE public.derm_manifest_number_proposals
           SET review_status = 'rejected',
               reviewed_at = now(),
               notes = COALESCE(NULLIF(notes, ''), '') ||
                       'rollback 2026-05-18: OCR extracted FOG form internal serial (top-right 3-digit), not the canonical White Manifest # (which is a 6-digit Miami-Dade identifier on the disposal facility receipt, not the FOG form). 119/121 of these were Broward records that correctly had no White Manifest # — they use Yellow Ticket # instead.'
         WHERE manifest_id = ${t.manifest_id}
           AND review_status = 'approved'
           AND proposed_number = '${t.bad_value.replace(/'/g, "''")}'
        RETURNING id`);
      proposalsRejected += r2.length;
    } catch (e) {
      console.error(`  ! error on manifest ${t.manifest_id}: ${e.message.slice(0, 200)}`);
      errors++;
    }
  }

  console.log(`\nReverted manifests: ${reverted}`);
  console.log(`Proposals rejected: ${proposalsRejected}`);
  console.log(`Errors: ${errors}`);

  // Post-check
  const after = await pg(`
    SELECT
      health_state, COUNT(*)::int AS n
    FROM derm.manifest_health
    GROUP BY health_state ORDER BY n DESC`);
  console.log('\nPost-rollback manifest_health distribution:');
  after.forEach(h => console.log(' ', h.health_state, '→', h.n));

  const propState = await pg(`
    SELECT review_status, COUNT(*)::int AS n
    FROM public.derm_manifest_number_proposals
    GROUP BY review_status ORDER BY review_status`);
  console.log('\nProposals queue state:');
  propState.forEach(p => console.log(' ', p.review_status, '→', p.n));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
