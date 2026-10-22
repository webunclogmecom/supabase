// Remove the [TEST] intakes the collector tests made (requested_by '[TEST] collector page check%'):
// storage objects via the Storage API first, then photos (links cascade) and the intakes (uploads cascade),
// then COUNT every table written to, not just the ones expected to be clean.
//   node cleanup.mjs [intake id ...]   with ids: only those (each must carry the label); without: every labelled one
// 🛑 It NEVER removes an intake whose photos a site file version uses (public.property_pages content): on 2026-10-22 an
// unscoped run deleted test intake 167 (submitted 2026-09-25) and its gate photo 27404, which [TEST] 1164's site file
// versions 1 to 5 still showed. The storage delete cannot be undone (no storage backup), so such intakes are kept and listed.
import fs from 'node:fs'
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const ids = process.argv.slice(2).map(Number)
if (ids.some((n) => !Number.isInteger(n) || n <= 0)) throw new Error('intake ids must be positive whole numbers')
const USED = `select l.entity_id from public.photo_links l
  join (select distinct (ph ->> 'photo_id')::bigint as photo_id from public.property_pages pg, jsonb_array_elements(pg.content -> 'photos') ph) u on u.photo_id = l.photo_id
 where l.entity_type = 'property_intake'`
const T = `select id from public.property_intakes where requested_by like '[TEST] collector page check%'${ids.length ? ` and id in (${ids.join(',')})` : ''} and id not in (${USED})`
const kept = await sql(`select id from public.property_intakes where requested_by like '[TEST] collector page check%'${ids.length ? ` and id in (${ids.join(',')})` : ''} and id in (${USED})`)
if (kept.length) console.log('kept (a site file uses their photos):', kept.map((r) => r.id).join(', '))
const doomed = await sql(T)
console.log('removing intakes:', doomed.map((r) => r.id).join(', ') || 'none')
if (!doomed.length) process.exit(0)
const objs = await sql(`select name from storage.objects where bucket_id='intake-photos' and split_part(name,'/',1) in (select id::text from (${T}) t)`)
if (objs.length) {
  const r = await fetch('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/intake-photos', { method: 'DELETE', headers: { Authorization: 'Bearer ' + env.SUPABASE_SERVICE_ROLE_KEY, apikey: env.SUPABASE_SERVICE_ROLE_KEY, 'content-type': 'application/json' }, body: JSON.stringify({ prefixes: objs.map((o) => o.name) }) })
  console.log('storage delete', r.status, (await r.json()).length, 'objects')
}
console.log(await sql(`begin;
  delete from public.photos where id in (select l.photo_id from public.photo_links l where l.entity_type='property_intake' and l.entity_id in (${T}));
  delete from public.property_intakes where id in (${T});
  commit;`))
console.log(await sql(`select (select count(*) from public.property_intakes where requested_by like '[TEST] collector page check%') intakes,
  (select count(*) from public.property_intake_uploads u where not exists (select 1 from public.property_intakes i where i.id=u.intake_id)) orphan_uploads,
  (select count(*) from public.photo_links where entity_type='property_intake' and entity_id not in (select id from public.property_intakes)) orphan_links,
  (select count(*) from public.photos where storage_path like 'intake-photos/%' and id not in (select photo_id from public.photo_links)) orphan_photos,
  (select count(*) from storage.objects where bucket_id='intake-photos' and split_part(name,'/',1) not in (select id::text from public.property_intakes)) orphan_objects,
  (select count(*) from public.property_intakes) intakes_left`))
