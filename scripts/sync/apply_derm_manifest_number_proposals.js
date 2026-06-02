// ============================================================================
// apply_derm_manifest_number_proposals.js — bulk-apply high-confidence
// OCR proposals from public.derm_manifest_number_proposals.
//
// Safety gates (won't overwrite anything):
//   - Only acts on review_status='pending' proposals
//   - Only acts on confidence='high' proposals (configurable via --confidence)
//   - SKIPS any manifest where white_manifest_number is already set
//     (the proposal moves to 'superseded' state instead — never overwrites)
//   - Dry-run by default; --execute required to write
//   - Per-row transaction (a bad row doesn't block the batch)
//
// Audit trail: every UPDATE on derm_manifests + derm_manifest_number_proposals
// is captured by their audit triggers (audit_derm_manifests +
// audit_derm_manifest_number_proposals) — both opted in to audit.logs.
//
// CLI:
//   node scripts/sync/apply_derm_manifest_number_proposals.js                    # dry-run
//   node scripts/sync/apply_derm_manifest_number_proposals.js --execute          # do it
//   node scripts/sync/apply_derm_manifest_number_proposals.js --execute --confidence=medium
// ============================================================================

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

const EXECUTE = process.argv.includes('--execute');
const conf = (process.argv.find(a => a.startsWith('--confidence=')) || '--confidence=high').split('=')[1];
const ALLOWED_CONF = conf.split(',').map(s => s.trim()); // e.g. ['high'] or ['high','medium']

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query',
      method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function esc(s) { return s == null ? 'NULL' : "'" + String(s).replace(/'/g, "''") + "'"; }

(async () => {
  console.log(`# apply_derm_manifest_number_proposals — ${new Date().toISOString()} ${EXECUTE ? 'EXECUTE' : '(dry-run)'}`);
  console.log(`Confidence accepted: ${ALLOWED_CONF.join(', ')}`);

  // Pull pending proposals matching the confidence filter
  const confList = ALLOWED_CONF.map(c => esc(c)).join(',');
  const proposals = await pg(`
    SELECT
      p.id AS proposal_id,
      p.manifest_id,
      p.proposed_number,
      p.confidence,
      dm.white_manifest_number AS current_value,
      c.name AS client_name,
      dm.service_date::text
    FROM public.derm_manifest_number_proposals p
    JOIN public.derm_manifests dm ON dm.id = p.manifest_id
    LEFT JOIN public.clients c ON c.id = dm.client_id
    WHERE p.review_status = 'pending'
      AND p.confidence IN (${confList})
      AND p.proposed_number IS NOT NULL
    ORDER BY p.id`);

  console.log(`Pending proposals to consider: ${proposals.length}`);

  let willApply = 0, willSkip = 0;
  const skipReasons = {};

  // First pass — classify (no writes yet)
  const actions = proposals.map(p => {
    if (p.current_value !== null && p.current_value !== p.proposed_number) {
      skipReasons['current_value_differs'] = (skipReasons['current_value_differs'] || 0) + 1;
      return { ...p, action: 'skip', reason: `current=${p.current_value}, refusing to overwrite` };
    }
    if (p.current_value === p.proposed_number) {
      skipReasons['already_matches'] = (skipReasons['already_matches'] || 0) + 1;
      return { ...p, action: 'mark_superseded', reason: 'value already set to proposed value' };
    }
    return { ...p, action: 'apply' };
  });

  willApply = actions.filter(a => a.action === 'apply').length;
  willSkip = actions.filter(a => a.action !== 'apply').length;

  console.log(`  → Will apply: ${willApply}`);
  console.log(`  → Will skip: ${willSkip}  (${JSON.stringify(skipReasons)})`);

  if (!EXECUTE) {
    console.log('\nSample of what will apply (first 10):');
    actions.filter(a => a.action === 'apply').slice(0, 10).forEach(a =>
      console.log(`  manifest ${a.manifest_id} (${a.client_name || '—'}, ${a.service_date}) → white # "${a.proposed_number}"`));
    console.log('\n(DRY-RUN) Re-run with --execute to apply.');
    return;
  }

  // Apply — one per-row transaction each
  let applied = 0, errors = 0;
  for (const a of actions) {
    if (a.action === 'skip') continue;
    try {
      if (a.action === 'apply') {
        // Two writes in one statement (CTE) — atomic both-or-neither at the row level
        await pg(`
          WITH manifest_upd AS (
            UPDATE public.derm_manifests
               SET white_manifest_number = ${esc(a.proposed_number)}
             WHERE id = ${a.manifest_id} AND white_manifest_number IS NULL
            RETURNING id
          )
          UPDATE public.derm_manifest_number_proposals
             SET review_status = 'approved',
                 reviewed_at = now(),
                 notes = COALESCE(notes, '') || 'auto-approved by bulk-apply script'
           WHERE id = ${a.proposal_id}
             AND EXISTS (SELECT 1 FROM manifest_upd);
        `);
        applied++;
        if (applied % 10 === 0) console.log(`  ...applied ${applied}/${willApply}`);
      } else if (a.action === 'mark_superseded') {
        await pg(`
          UPDATE public.derm_manifest_number_proposals
             SET review_status = 'superseded',
                 reviewed_at = now(),
                 notes = COALESCE(notes, '') || 'already set to proposed value'
           WHERE id = ${a.proposal_id}`);
      }
    } catch (e) {
      console.error(`  ! error on manifest ${a.manifest_id}: ${e.message.slice(0, 200)}`);
      errors++;
    }
  }

  console.log(`\nApplied: ${applied}  Errors: ${errors}`);

  // Post-check
  const post = await pg(`
    SELECT
      COUNT(*) FILTER (WHERE review_status='approved')::int AS approved,
      COUNT(*) FILTER (WHERE review_status='pending')::int AS pending,
      COUNT(*) FILTER (WHERE review_status='superseded')::int AS superseded,
      COUNT(*) FILTER (WHERE review_status='rejected')::int AS rejected
    FROM public.derm_manifest_number_proposals`);
  console.log('\nPost-state of proposals queue:');
  console.log(' ', post[0]);

  const healthAfter = await pg(`
    SELECT health_state, COUNT(*)::int AS n
    FROM derm.manifest_health
    GROUP BY health_state ORDER BY n DESC`);
  console.log('\nPost-state of manifest_health distribution:');
  healthAfter.forEach(h => console.log(' ', h.health_state, '→', h.n));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
