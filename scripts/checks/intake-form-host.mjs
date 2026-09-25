// intake-form-host.mjs — the collector form on its real host, checked against the one source.
//
//   node scripts/checks/intake-form-host.mjs            source rules + live bytes + the redirect
//   node scripts/checks/intake-form-host.mjs --source   source rules only (before a publish)
//
// The form is ONE static file, scripts/intake-collector/intake.html (built from
// supabase/functions/intake-submit/form-page.ts by scripts/intake-collector/build.mjs), served verbatim by
// Picture Planner as https://planner.unclogme.app/intake.html (Lovable public/). The token rides in the
// FRAGMENT as #code=<token> (a key the analytics guard scrubs), so it never reaches a server log or a
// Referer. intake-submit's GET answers 302 to it. (Fixed 2026-09-25: this file still pointed at the
// abandoned apps/intake-form path and the old #t= fragment, so it could not run.)
// Why a static file and not a route: plan section D wants the collector to load no Supabase code and
// stay a few KB on one bar of signal; a file under public/ is served before the app's router, so it
// carries no React, no supabase-js and no session module at all.
//
// Exit 1 on any failure. Each live assertion has a positive control, so an unreachable host or a
// router 404 page reads as a failure, never as a pass.
import fs from 'node:fs'
import crypto from 'node:crypto'

const SRC = new URL('../intake-collector/intake.html', import.meta.url)
const HOST = 'https://planner.unclogme.app'
const PAGE = HOST + '/intake.html'
const EP = 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit'
let fails = 0
const check = (ok, msg) => { console.log((ok ? '  PASS ' : '  FAIL ') + msg); if (!ok) fails++ }
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex').slice(0, 16)

const src = fs.readFileSync(SRC)
const s = src.toString('utf8')
console.log(`source ${SRC.pathname.replace(/^\/([A-Z]:)/, '$1')}: ${src.length} bytes, sha ${sha(src)}`)

// --- source rules (plan D.2 / D.4) ---
check(/<title>Site survey<\/title>/.test(s), 'control: the source is the collector form')
check(/<meta name="referrer" content="no-referrer">/.test(s), 'no-referrer meta (the token must not leave in a Referer)')
check(/<meta name="robots" content="noindex,nofollow">/.test(s), 'noindex meta (a capability URL must never be indexed)')
const origins = [...new Set([...s.matchAll(/https?:\/\/[A-Za-z0-9.-]+/g)].map((m) => m[0]))]
check(origins.length === 1 && origins[0] === 'https://wbasvhvvismukaqdnouk.supabase.co', `exactly one origin, the function's (${origins.join(', ') || 'none'})`)
check(s.includes(`'${EP}'`), 'the endpoint is the absolute intake-submit URL')
for (const [bad, why] of [[/eyJ[A-Za-z0-9_-]{10,}/, 'a JWT (an anon key would stop the token being the only gate)'],
  [/apikey/i, 'an apikey header'], [/\/rest\/v1\//, 'a PostgREST path'], [/\/auth\/v1\//, 'an Auth path'],
  [/<script[^>]+src=/i, 'an external script'], [/<link[^>]+href=/i, 'an external stylesheet or font'],
  [/sb-[a-z]+-auth-token/, 'a Supabase session key']]) {
  check(!bad.test(s), `no ${why}`)
}
check(/location\.hash/.test(s), 'the token is read from the fragment')

if (!process.argv.includes('--source')) {
  // --- live bytes ---
  const r = await fetch(PAGE + '?cb=' + Date.now(), { redirect: 'manual', headers: { 'cache-control': 'no-cache' } })
  const live = Buffer.from(await r.arrayBuffer())
  const lt = live.toString('utf8')
  check(r.status === 200 && /<title>Site survey<\/title>/.test(lt), `control: ${PAGE} serves the form (${r.status}, ${(lt.match(/<title>[^<]*/) || ['no title'])[0]})`)
  check(Buffer.compare(live, src) === 0, `live bytes equal the source (live ${live.length} / sha ${sha(live)})`)
  console.log(`  info content-type ${r.headers.get('content-type')}, transferred ${live.length} bytes`)

  // --- the redirect every issued link goes through ---
  const g = await fetch(EP + '?t=check-not-a-token', { redirect: 'manual' })
  const loc = g.headers.get('location') || ''
  check(g.status === 302, `GET intake-submit answers 302 (${g.status})`)
  check(loc === PAGE + '#code=check-not-a-token', `Location is the form with the token in the fragment as code (${loc || 'none'})`)
}

if (fails) { console.log(`\n${fails} FAILED`); process.exit(1) } else console.log('\nall passed')
