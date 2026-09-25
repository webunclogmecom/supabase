// Remove every [TEST] intake the collector tests made (requested_by '[TEST] collector page check%'):
// storage objects via the Storage API first, then photos (links cascade) and the intakes (uploads cascade),
// then COUNT every table written to, not just the ones expected to be clean.
import fs from 'node:fs'
const env = Object.fromEntries(fs.readFileSync(new URL('../../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (q) => (await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).json()
const T = "select id from public.property_intakes where requested_by like '[TEST] collector page check%'"
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
