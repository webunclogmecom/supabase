import { readFileSync } from 'fs'
import { pathToFileURL } from 'url'
const env = Object.fromEntries(readFileSync('.env','utf8').split(/\r?\n/)
  .filter(l => l.includes('=')).map(l => { const i = l.indexOf('='); return [l.slice(0,i).trim(), l.slice(i+1).trim()] }))

export async function sql(query) {
  const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + env.SUPABASE_PAT },
    body: JSON.stringify({ query }) })
  const j = await r.json()
  if (!Array.isArray(j)) throw new Error('query failed: ' + JSON.stringify(j).slice(0, 300))
  return j
}

// NOTE: the main-module guard MUST use pathToFileURL. On Windows import.meta.url is
// `file:///C:/...` (three slashes) while `file://` + a backslash-replaced argv[1] yields
// `file://C:/...` (two) -- so the hand-built form NEVER matches and this whole block is
// silently skipped, exiting 0 with no output. A probe that prints nothing is not a passing
// probe; it is a broken instrument. Verified on this machine 2026-08-26.
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  // POSITIVE CONTROL: an already-allowed value must insert cleanly.
  const control = await sql(`
    begin;
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
    values ('visit', -999, 'jobber', 'PROBE-CONTROL');
    select 'control-inserted' as r;
    rollback;`)
  // TARGET: the new value.
  let targetOk = true, targetErr = ''
  try {
    await sql(`
      begin;
      insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
      values ('calendar_task', -999, 'jobber', 'PROBE-TARGET');
      rollback;`)
  } catch (e) { targetOk = false; targetErr = e.message.slice(0, 120) }

  console.log('control (must pass): ' + JSON.stringify(control).slice(0, 60))
  console.log('target  calendar_task allowed: ' + targetOk + (targetOk ? '' : '  <- ' + targetErr))
  console.log('--- audit complete --- ' + JSON.stringify({ probe: 'calendar_task_esl', target_ok: targetOk }))
}
