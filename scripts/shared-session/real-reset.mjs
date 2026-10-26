// node real-reset.mjs <app>: mint ONE recovery link for fred@ayache.com via the admin API (no email is
// sent), hand it straight to live-reset.mjs --real, never print it. The link is opened, never submitted.
// app "hub-invite" (2026-10-26): the same recovery link, redirected to /reset-password/invite and handed over as
// type=invite (the verify endpoint is called here, its redirect read and its type rewritten), so the invite page is
// tested with a real session without inviting anyone. Prints the landing path, never the tokens.
import fs from 'node:fs'
import { spawnSync } from 'node:child_process'
const env = Object.fromEntries(fs.readFileSync(new URL('../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const app = process.argv[2]
const PATH = { hub: '/reset-password', 'hub-invite': '/reset-password/invite', clients: '/reset-password', planner: '/reset-password', admin: '/', stamp: '/', derm: '/', calendar: '/' }
const host = app.split('-')[0]
const KEY = env.SUPABASE_SERVICE_ROLE_KEY || ''
// plan step 0.4: say which key this run spends, so a run during the legacy-keys watch is visible (never the value)
console.log('service key kind:', KEY.startsWith('sb_secret_') ? 'sb_secret_ (new)' : KEY.startsWith('eyJ') ? 'legacy JWT' : 'unknown')
const r = await fetch('https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/admin/generate_link', {
  method: 'POST',
  headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'content-type': 'application/json' },
  body: JSON.stringify({ type: 'recovery', email: 'fred@ayache.com', redirect_to: `https://${host}.unclogme.app${PATH[app]}` }),
})
const j = await r.json()
let link = j.action_link || j.properties?.action_link
if (!link) { console.log('generate_link failed', r.status, JSON.stringify(j).slice(0, 200)); process.exit(2) }
console.log('link minted (not printed); redirect host', new URL(new URL(link).searchParams.get('redirect_to')).host)
if (app.endsWith('-invite')) {
  const v = await fetch(link, { redirect: 'manual' })
  const to = v.headers.get('location') || ''
  if (!/[#&]type=recovery(&|$)/.test(to)) { console.log('verify gave no recovery redirect', v.status, new URL(to || 'https://x/').pathname); process.exit(2) }
  link = to.replace(/([#&])type=recovery(&|$)/, '$1type=invite$2')
  console.log('verify redirect path', new URL(link).pathname, '(type rewritten to invite)')
}
const out = spawnSync(process.execPath, [new URL('./live-reset.mjs', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1'), '--real', app, link], { encoding: 'utf8' })
process.stdout.write(out.stdout.replace(/access_token=[^&\s]+/g, 'access_token=<redacted>').replace(/refresh_token=[^&\s]+/g, 'refresh_token=<redacted>')); process.stderr.write(out.stderr)
process.exit(out.status)
