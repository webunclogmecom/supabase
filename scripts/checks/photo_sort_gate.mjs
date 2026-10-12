// photo_sort_gate.mjs - "are this visit's photos sorted?" has ONE definition: public.v_visit_photo_counts. The Admin
// Review queue chip, its "Send email to City" pre-check, fn_admin_review_pending (the 11 AM Slack post) and the DERM
// Tracker dialog (v_derm_manifest_email_readiness) read it, and so must the send-visit-photos-email gate.
//   node scripts/checks/photo_sort_gate.mjs
//   PHOTO_FN_SRC=<path to a copy of index.ts> node scripts/checks/photo_sort_gate.mjs   (to test a copy or a mutant)
// Why (2026-10-12 notification audit): Admin Review's Confirm saves service_phase 'unknown' for a photo left
// untagged. The view and the gate each counted "any classification row" as sorted, so 62 untagged photos on 32
// visits passed as sorted while the review page showed them untagged. The fix changed the view (migration
// 2026-10-12_1335) and made the gate read it; a copy of the phase list in the gate is how the two drift apart again.
import fs from 'node:fs';
import assert from 'node:assert';

const src = fs.readFileSync(process.env.PHOTO_FN_SRC ?? new URL('../../supabase/functions/send-visit-photos-email/index.ts', import.meta.url), 'utf8');
const from = src.indexOf('// -- the gate: EVERY image on this visit must be classified');
const to = src.indexOf("return json({ error: 'not_classified'");
assert.ok(from > 0 && to > from, 'the not_classified gate was found in send-visit-photos-email');
const gate = src.slice(from, to);
assert.match(gate, /\.from\('v_visit_photo_counts'\)\s*\.select\('total_images, classified_images'\)\s*\.eq\('visit_id', visitId\)/,
  'the gate reads this visit\'s row of v_visit_photo_counts');
assert.match(gate, /if \(pcErr\) throw new Error/, 'a failed read of the view throws, never reads as "all sorted"');
assert.match(gate, /const unclassified = imageTotal - \(pc \? Number\(pc\.classified_images\) : 0\)/, 'unclassified comes from the view');
assert.match(gate, /const imageTotal = pc \? Number\(pc\.total_images\) : images\.length/, 'no row for a visit with photos counts every photo as not sorted');
assert.doesNotMatch(gate, /phaseBy\.size|SORTED_PHASES|\[\s*'before',\s*'after'/, 'the gate keeps no copy of the sorted rule');

// The view side: the newest migration that replaces v_visit_photo_counts counts only the 4 phases a reviewer can pick.
const dir = new URL('../../docs/migrations/', import.meta.url);
const migs = fs.readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()
  .filter((f) => /CREATE OR REPLACE VIEW public\.v_visit_photo_counts/i.test(fs.readFileSync(new URL(f, dir), 'utf8')));
assert.ok(migs.length > 0, 'a migration defines v_visit_photo_counts');
const last = fs.readFileSync(new URL(migs[migs.length - 1], dir), 'utf8');
const body = last.slice(last.toUpperCase().lastIndexOf('CREATE OR REPLACE VIEW PUBLIC.V_VISIT_PHOTO_COUNTS'));
assert.match(body, /COALESCE\(\(c\.service_phase = ANY \(ARRAY\['before'::text, 'after'::text, 'internal'::text, 'extra'::text\]\)\), false\) AS is_classified/,
  `the newest view body (${migs[migs.length - 1]}) counts only the 4 phases as sorted`);

console.log(`ok: the gate reads v_visit_photo_counts; newest view body ${migs[migs.length - 1]} counts only the 4 phases`);
