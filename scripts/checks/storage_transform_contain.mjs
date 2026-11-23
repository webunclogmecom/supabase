#!/usr/bin/env node
// storage_transform_contain.mjs: no caller asks Supabase Storage for a WIDTH-ONLY image transform without resize=contain.
//
//   node scripts/checks/storage_transform_contain.mjs        (reads SUPABASE_PAT from the env or Supabase/.env)
//
// WHY (measured 2026-11-23, Trello #244 and its follow-up 2026-11-23_1610): the render endpoint asked for a width only,
// with no resize or with resize=cover, returns WIDTH x ORIGINAL HEIGHT, the middle columns of the photo. A 4000x3000 phone
// photo asked "width 800" comes back 800x3000 (the middle fifth), an 810x1080 visit photo asked width=400 comes back
// 400x1080. resize=contain returns the whole photo. width + height + cover is a crop on purpose (the box is known): allowed.
//
// shortcut: a transform object held in a variable (driver-page's FULL / THUMB) is seen only through the URL it builds;
// read such a caller by hand if the URL pattern ever stops matching it.
// It reads three places: the database (function and view bodies), this repo's edge functions, and the live JS of every app.
// Exit 1 lists each offender. On 2026-11-23 the known ones are #244's (Planner Page Builder, the portal's PageBuilder and
// PageBuilderList, driver-page); the check goes green when #244 ships.
import fs from 'node:fs'
import { crawl } from '../client-app/base.mjs'

const APPS = ['calendar', 'clients', 'derm', 'admin', 'fp', 'stamp', 'dump', 'hub', 'planner', 'ops', 'hr', 'reviews']
// a supabase-js transform object that has a width; it is fine with resize contain, or with a height (a known box)
const OBJ = /transform\s*:\s*\{[^{}]*\bwidth\s*:[^{}]*\}/g
const objOk = (s) => /resize\s*:\s*["'`]contain["'`]/.test(s) || /\bheight\s*:/.test(s)
// a hand-built render address in app code (the library's own "render/image" has no /public/, /sign/ or /authenticated/)
const URL_ = /render\/image\/(public|sign|authenticated)\/[^"'`]{0,240}/g
const urlOk = (s) => /resize=contain/.test(s) || (/height=/.test(s) && /resize=cover/.test(s))
// positive controls: each pattern finds its fixture and judges it, or a clean run means nothing
for (const [re, ok, bad, good] of [
  [OBJ, objOk, 'createSignedUrl(p,3600,{transform:{width:800}})', "getPublicUrl(p,{transform:{width:800,resize:'contain'}})"],
  [URL_, urlOk, '`${SB}/storage/v1/render/image/public/b/${p}?width=${w}&quality=${q}`', '"/storage/v1/render/image/public/b/x.jpg?width=400&resize=contain"'],
]) {
  const hit = (s) => [...s.matchAll(new RegExp(re.source, 'g'))].map((m) => m[0])
  if (hit(bad).length !== 1 || ok(hit(bad)[0]) || hit(good).length !== 1 || !ok(hit(good)[0])) throw new Error('control failed: ' + re.source)
}

const fail = []
// 1. the database
const env = fs.existsSync(new URL('../../.env', import.meta.url)) ? fs.readFileSync(new URL('../../.env', import.meta.url), 'utf8') : ''
const PAT = process.env.SUPABASE_PAT || (env.match(/^SUPABASE_PAT=["']?([^"'\r\n]+)/m) || [])[1]
if (!PAT) { console.error('FAIL: SUPABASE_PAT not set and not in Supabase/.env'); process.exit(2) }
const q = `select n.nspname||'.'||p.proname as name, p.prosrc as body from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where p.prosrc ~ 'render/image' and n.nspname not in ('pg_catalog','information_schema','storage','extensions')
           union all select schemaname||'.'||viewname, definition from pg_views where definition ~ 'render/image'`
const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: q }) })
const rows = await r.json()
if (!Array.isArray(rows)) { console.error('FAIL: query', JSON.stringify(rows).slice(0, 200)); process.exit(2) }
if (!rows.some((x) => x.name === 'customer.thumbnail_url')) { console.error('FAIL: control, customer.thumbnail_url not found by the sweep'); process.exit(2) }
for (const x of rows) if (!/resize=contain/.test(x.body)) fail.push(`db  ${x.name}: builds a render URL without resize=contain`)
console.log(`db: ${rows.length} bodies build a render URL`)

// 2. this repo's edge functions
const fnDir = new URL('../../supabase/functions/', import.meta.url)
let files = 0
for (const f of fs.readdirSync(fnDir, { recursive: true })) {
  if (!/\.(ts|js|mjs)$/.test(f)) continue
  const t = fs.readFileSync(new URL(f.replaceAll('\\', '/'), fnDir), 'utf8'); files++
  for (const m of t.matchAll(OBJ)) if (!objOk(m[0])) fail.push(`edge ${f}: ${m[0]}`)
  for (const m of t.matchAll(URL_)) if (!urlOk(m[0])) fail.push(`edge ${f}: ${m[0].slice(0, 120)}`)
}
console.log(`edge: ${files} files read`)

// 3. the live apps
for (const a of APPS) {
  const chunks = await crawl(['/'], { base: `https://${a}.unclogme.app`, html: /\/assets\/[A-Za-z0-9._-]+\.js/g, chunk: /(["'`])(?:\.\/|\/assets\/)([A-Za-z0-9._-]+\.js)\1/g })
  if (!chunks.size) { fail.push(`app ${a}: the walk found no JS (broken check, not a clean app)`); continue }
  for (const [p, t] of chunks) {
    for (const m of t.matchAll(OBJ)) if (!objOk(m[0])) fail.push(`app ${a} ${p}: ${m[0]}`)
    for (const m of t.matchAll(URL_)) if (!urlOk(m[0])) fail.push(`app ${a} ${p}: ${m[0].slice(0, 120)}`)
  }
  console.log(`app ${a}: ${chunks.size} chunks`)
}

if (fail.length) { console.log(`\nFAIL: ${fail.length} width-only transform(s) without resize=contain:\n  ` + fail.join('\n  ')); process.exit(1) }
console.log('\nPASS: every transformed image request asks for resize=contain (or a known box)')
