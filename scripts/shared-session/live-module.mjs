// live-module.mjs: which session module does each app ACTUALLY serve? Reads the published bundles.
//
//   node live-module.mjs [app ...] [--wait N]     default: all eight; --wait polls N x 20 s for the canonical
//
// Walks each app from several routes to closure (/assets/x.js AND ./x.js imports, which is how lazy
// route chunks are imported). PASS = the canonical module's own strings are there, none of the six old
// variants' strings are, and "unclogme-remember-me" appears in exactly one chunk (the module).
// A string check cannot prove byte identity (the bundle is minified); live-restart.mjs and
// live-login-flag.mjs prove the behaviour.
const APPS = { hub: 'hub.unclogme.app', admin: 'admin.unclogme.app', clients: 'clients.unclogme.app', stamp: 'stamp.unclogme.app',
  derm: 'derm.unclogme.app', calendar: 'calendar.unclogme.app', hr: 'hr.unclogme.app', planner: 'planner.unclogme.app' }
const CANON = ['-byte cookie limit: it cannot be stored, so this browser is signed out', 'unclogme-remember-me', '-code-verifier']
const OLD = ['falling back to localStorage', 'storing in localStorage only', 'refusing to write cookie', 'refusing to write oversized cookie',
  'derm-stamp-studio-auth', 'skipping cookie write', 'Cookies overflow silently']
const args = process.argv.slice(2)
const wi = args.indexOf('--wait'); const tries = wi >= 0 ? Number(args[wi + 1]) : 1
const apps = args.filter((a, i) => APPS[a] && (wi < 0 || i !== wi + 1))
async function walk(host) {
  const seen = new Set(), q = [], rows = []
  const add = (s) => { for (const m of s.matchAll(/(?:\/assets\/|\.\/)([A-Za-z0-9_.$\-]+\.js)/g)) { const p = '/assets/' + m[1]; if (!seen.has(p)) { seen.add(p); q.push(p) } } }
  for (const r of ['/', '/login', '/forms', '/employees', '/manifests', '/reset-password']) { try { add(await (await fetch(`https://${host}${r}?cb=${Date.now()}`)).text()) } catch {} }
  while (q.length) { const u = q.shift(); try { const r = await fetch(`https://${host}${u}`); if (r.ok) { const t = await r.text(); add(t); rows.push({ u, t }) } } catch {} }
  return rows
}
let bad = 0
for (const app of apps.length ? apps : Object.keys(APPS)) {
  let line = ''
  for (let n = 0; n < tries; n++) {
    const rows = await walk(APPS[app]); const all = rows.map((r) => r.t).join('\n')
    const flagChunks = rows.filter((r) => r.t.includes('unclogme-remember-me')).map((r) => r.u.replace('/assets/', ''))
    const miss = CANON.filter((s) => !all.includes(s)), old = OLD.filter((s) => all.includes(s))
    const ok = !miss.length && !old.length && flagChunks.length === 1
    line = `${app.padEnd(9)} ${ok ? 'CANONICAL' : 'NOT canonical'}  chunks=${rows.length} flag-in=${flagChunks.join(',') || 'none'}${miss.length ? ' missing=' + JSON.stringify(miss) : ''}${old.length ? ' old=' + JSON.stringify(old) : ''}`
    if (ok) break
    if (n + 1 < tries) await new Promise((r) => setTimeout(r, 20000))
    else bad++
  }
  console.log(line)
}
process.exit(bad ? 1 : 0)
