import fs from 'node:fs'
const old = fs.readFileSync('old.ts', 'utf8')
const anchor = `  if (rpcErr) {
    // Same run_id = same object, so nothing else can reference it; remove it so no orphan image stays.
    await sb.storage.from('rpa-evidence').remove([path])
    if (rpcErr.code === '23505') {`
const count = old.split(anchor).length - 1
if (count !== 1) throw new Error('anchor count ' + count)
const plan = `  if (rpcErr) {
    // A concurrent duplicate of THIS run may have recorded first (bot retry after a client timeout). Then the image
    // at \`path\` is that record's evidence: keep it and answer like the dedupe above.
    const { data: won } = await sb.from('derm_portal_submissions')
      .select('id, visit_id, gdo_id, screenshot_path').eq('run_id', runId).limit(1)
    if (won && won.length > 0) {
      return json({ recorded: true, deduped: true, manual_entry: true, id: won[0].id, visit_id: won[0].visit_id,
        gdo_id: won[0].gdo_id, run_id: runId, screenshot_stored: won[0].screenshot_path !== null }, 200)
    }
    // No row for this run: the object is ours alone, remove it so no orphan image stays.
    await sb.storage.from('rpa-evidence').remove([path])
    if (rpcErr.code === '23505') {`
const mine = `  if (rpcErr) {
    // Re-read BEFORE removing anything. The image at \`path\` is a recorded row's evidence when a concurrent duplicate
    // of THIS run recorded first (the bot retries after its 30 s client timeout while this request still runs), or when
    // this RPC committed and only its answer was lost. Same read as the dedupe above.
    const { data: won, error: wonErr } = await sb
      .from('derm_portal_submissions')
      .select('id, visit_id, gdo_id, screenshot_path')
      .eq('run_id', runId)
      .limit(1)
    if (wonErr) {
      // Cannot tell whether a row points at the image: keep it. The bot retries; its retry dedupes or records.
      console.error('manual entry re-read after a record error failed:', wonErr.message, '| record error:', rpcErr.message)
      return json({ error: 'result_lookup_failed_retry' }, 500)
    }
    if (won && won.length > 0) {
      return json({ recorded: true, deduped: true, manual_entry: true, id: won[0].id, visit_id: won[0].visit_id,
        gdo_id: won[0].gdo_id, run_id: runId, screenshot_stored: won[0].screenshot_path !== null }, 200)
    }
    if (rpcErr.code === '23505' || rpcErr.code === '22023') {
      // A refusal, and no row carries this run_id (fn_record_manual_gdo_report pins every manual path to
      // <visit>/<run_id>.<ext>), so nothing references \`path\`: remove it so no orphan image stays. Any other error
      // keeps it: the bot retries and the retry rewrites the same path.
      await sb.storage.from('rpa-evidence').remove([path])
    }
    if (rpcErr.code === '23505') {`
for (const [name, rep] of [['plan', plan], ['mine', mine]]) {
  fs.writeFileSync(name + '.ts', old.replace(anchor, rep))
}
// strip the two imports for the node harness; esbuild keeps everything else verbatim
for (const name of ['old', 'plan', 'mine']) {
  let src = fs.readFileSync(name + '.ts', 'utf8')
  src = src.replace("import { createClient } from 'jsr:@supabase/supabase-js@2'", "import { createClient } from './stub.mjs'")
  src = src.replace("import { slackHeader, slackIdentity, slackSections } from '../_shared/slack-notify.ts'", "import { slackHeader, slackIdentity, slackSections } from './stub.mjs'")
  fs.writeFileSync(name + '.harness.ts', src)
}
console.log('ok')
