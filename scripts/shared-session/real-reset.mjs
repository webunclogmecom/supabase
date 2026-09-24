// node real-reset.mjs <app>: mint ONE recovery link for fred@ayache.com via the admin API (no email is
// sent), hand it straight to live-reset.mjs --real, never print it. The link is opened, never submitted.
import fs from 'node:fs'
import { spawnSync } from 'node:child_process'
const env = Object.fromEntries(fs.readFileSync(new URL('../../.env', import.meta.url), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const app = process.argv[2]
const PATH = { hub: '/reset-password', clients: '/reset-password', planner: '/reset-password', admin: '/', stamp: '/', derm: '/', calendar: '/' }
const r = await fetch('https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/admin/generate_link', {
  method: 'POST',
  headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, 'content-type': 'application/json' },
  body: JSON.stringify({ type: 'recovery', email: 'fred@ayache.com', redirect_to: `https://${app}.unclogme.app${PATH[app]}` }),
})
const j = await r.json()
const link = j.action_link || j.properties?.action_link
if (!link) { console.log('generate_link failed', r.status, JSON.stringify(j).slice(0, 200)); process.exit(2) }
console.log('link minted (not printed); redirect host', new URL(new URL(link).searchParams.get('redirect_to')).host)
const out = spawnSync(process.execPath, [new URL('./live-reset.mjs', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1'), '--real', app, link], { encoding: 'utf8' })
process.stdout.write(out.stdout.replace(/access_token=[^&\s]+/g, 'access_token=<redacted>').replace(/refresh_token=[^&\s]+/g, 'refresh_token=<redacted>')); process.stderr.write(out.stderr)
process.exit(out.status)
