// The Client App's address for its live checks, and the one bundle walk they all use (step 7 of the move into the Ops Portal).
//
//   CLIENT_APP=<url>  (or --base <url>)   default https://clients.unclogme.app, the old host (live production, the control)
//   CLIENT_APP=http://localhost:8080/clients   the portal's copy on its local dev server
//
// The LIST is at the base (old app: /, portal: /clients). A CLIENT PAGE is <origin>/clients/<id> on both hosts.
//
// crawl() returns Map(path -> code) for either host:
//   - a production build: the /assets/*.js chunks reached from the script's own seed routes, as every check walked them before;
//   - a Vite dev server (TanStack Start): it serves source as ES modules under /src/**, its HTML references none of them, and
//     route components are split behind dynamic import("..."). So the walk starts at the route files of the base's first path
//     segment (from /src/routeTree.gen.ts) and follows static, side-effect and dynamic imports on the same origin, keeping
//     /src/ and /@id/ and skipping /node_modules/ and /@fs/. Each module is squeezed (comments out, whitespace out between
//     tokens) so the checks' patterns, written for minified chunks, read it the same way. Keys drop Vite's ?t= and ?v= stamps.
const at = process.argv.indexOf('--base')
export const BASE = (at > 0 ? process.argv[at + 1] : process.env.CLIENT_APP || 'https://clients.unclogme.app').replace(/\/+$/, '')
// process.argv without `--base <url>`, for the scripts that read positional arguments
export const ARGS = process.argv.slice(2).filter((a, i, all) => a !== '--base' && all[i - 1] !== '--base')
export const ORIGIN = new URL(BASE).origin
const PATH = new URL(BASE).pathname.replace(/\/+$/, '')        // '' on the old host, '/clients' on the portal
export const PORTAL = PATH !== ''                              // the portal's pages (redesigned), not the old app's
export const OLD_HOST = ORIGIN === 'https://clients.unclogme.app'
export const listUrl = (q = '') => ORIGIN + (PATH || '/') + q
export const clientUrl = (id, q = '') => `${ORIGIN}/clients/${id}${q}`
// The .unclogme.app session cookie the Playwright tests plant reaches the old host and ops.unclogme.app, never localhost.
export const COOKIE_SIGN_IN = /(^|\.)unclogme\.app$/.test(new URL(BASE).hostname)

const get = async (u) => { try { const r = await fetch(u); return r.ok ? await r.text() : '' } catch { return '' } }

// seeds are the old app's routes; '/' means the list. `base` is BASE unless a script points the walk at another app.
// `html` and `chunk` are the patterns a script has always followed on a production build (each script keeps its own, so
// its reach on the old host does not move); a match's last capture group (or the match) ends with the chunk's file name.
export async function crawl(seeds = ['/'], { base = BASE, html = /\/assets\/[\w.$-]+\.js/g, chunk = /(?:\/assets\/|\.\/)([\w.$-]+\.js)/g } = {}) {
  const origin = new URL(base).origin, path = new URL(base).pathname.replace(/\/+$/, '')
  const url = (s) => (s === '/' ? origin + (path || '/') : origin + s)
  const first = await get(url(seeds[0]))
  return /\/@(vite\/client|id\/)/.test(first) ? devCrawl(origin, path) : prodCrawl(seeds.map(url), origin, html, chunk)
}

async function prodCrawl(urls, origin, html, chunk) {
  const files = new Map(), queue = []
  const add = (m) => { const p = '/assets/' + [...m].reverse().find(Boolean).split('/').pop(); if (!files.has(p) && !queue.includes(p)) queue.push(p) }
  for (const u of urls) for (const m of (await get(u)).matchAll(html)) add(m)
  while (queue.length) {
    const p = queue.shift(), t = await get(origin + p)
    files.set(p, t)
    for (const m of t.matchAll(chunk)) add(m)
  }
  return files
}

const key = (spec) => { const [p, q = ''] = spec.split('?'), s = new URLSearchParams(q); s.delete('t'); s.delete('v'); return s.size ? p + '?' + s : p }
async function devCrawl(ORIGIN, PATH) {
  const seg = PATH.split('/')[1] || ''
  const tree = await get(ORIGIN + '/src/routeTree.gen.ts')
  const routes = [...new Set([...tree.matchAll(/from\s*"(\/src\/routes\/[^"?]+)/g)].map((m) => m[1]))]
  const queue = routes.filter((p) => !seg || p.split('/').pop().split('.').includes(seg))
  if (!queue.length) throw new Error(`no route file for "${seg}" in ${ORIGIN}/src/routeTree.gen.ts: the walk cannot start`)
  const files = new Map()
  files.dev = true   // the scripts' patterns that depend on minification read this
  while (queue.length) {
    const p = queue.shift()
    if (files.has(p)) continue
    const raw = await get(ORIGIN + p)
    files.set(p, squeeze(raw))
    for (const m of raw.matchAll(/(?:\bfrom\s*|\bimport\s*\(?\s*)"(\/[^"]+)"/g)) {
      const k = key(m[1]), path = k.split('?')[0]
      if (!/^\/(src|@id)\//.test(k) || /\/node_modules\//.test(k) || !/(\.(m?js|jsx?|tsx?))$/.test(path) && !k.startsWith('/@id/')) continue
      if (!files.has(k) && !queue.includes(k)) queue.push(k)
    }
  }
  return files
}

// ---- the Playwright tests on the portal ----
const SB = 'https://wbasvhvvismukaqdnouk.supabase.co'
// The portal reads the access answer as a list of apps (the old app's object form throws there: `apps.find`).
export const PORTAL_ACCESS = { employee_id: 1, group: 'admin', me: { full_name: 'Visual Check', color_hex: '#334155', photo_path: null }, apps: [{ app: 'client_app', name: 'Client App', parent: null, mode: 'on', level: 'edit' }] }

// Where the .unclogme.app cookie does not reach (localhost), the portal signs in through its own form. The token, user
// and key answers are canned and never leave the browser; realtime is closed. Call it after the test's own routes.
export async function formSignIn(page, session, user) {
  const json = (x, b) => x.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(b) })
  await page.routeWebSocket(/supabase\.co/, (ws) => ws.close())
  await page.route(SB + '/auth/v1/token**', (x) => json(x, { ...session, user }))
  await page.route(SB + '/auth/v1/.well-known/**', (x) => json(x, { keys: [] }))
  await page.goto(ORIGIN + '/')
  await page.waitForSelector('input[type=email]', { timeout: 60000 })
  await page.locator('input[type=email]').fill(user.email)
  await page.locator('input[type=password]').fill('canned-not-a-password')
  await page.getByRole('button', { name: /^sign in$/i }).click()
  await page.waitForSelector('nav[aria-label="Main menu"] a[data-menu]', { timeout: 60000, state: 'attached' })
}

// The portal's pages read through POST /rpc/<fn> too (the shell's bell, the client page's reads). A POST to ONE STABLE or
// IMMUTABLE function is answered here through the Management API, in a READ ONLY transaction, as the first active admin
// with a confirmed sign-in (claims set inside the statement; nothing printed). Anything else returns false and stays the
// test's to refuse. Keys are read from Supabase/.env at run time.
let pat
const mgmt = async (q) => {
  pat ??= (await import('node:fs')).readFileSync(new URL('../../.env', import.meta.url), 'utf8').match(/^SUPABASE_PAT=['"]?([^'"\r\n]+)/m)[1]
  const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + pat, 'content-type': 'application/json' }, body: JSON.stringify({ query: 'set transaction read only; ' + q }) })
  const j = await r.json(); if (!Array.isArray(j)) throw new Error(JSON.stringify(j).slice(0, 300)); return j
}
const lit = (s) => "'" + String(s).replace(/'/g, "''") + "'"
const fnInfo = new Map()
export const reads = []   // every read answered this way, for a test that wants to list them
export async function answerRead(route) {
  const r = route.request(), m = new URL(r.url()).pathname.match(/\/rest\/v1\/rpc\/([a-z_][a-z0-9_]*)$/)
  const schema = r.headers()['content-profile'] || 'public'
  if (r.method() !== 'POST' || !m || !/^[a-z_]+$/.test(schema)) return false
  const fn = schema + '.' + m[1]
  if (!fnInfo.has(fn)) fnInfo.set(fn, mgmt(`select p.provolatile as v, p.proretset as set, array(select format_type(t, null) from unnest(p.proargtypes) t) as types, coalesce(p.proargnames, '{}') as names from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = ${lit(schema)} and p.proname = ${lit(m[1])}`))
  const rows = await fnInfo.get(fn)
  if (rows.length !== 1 || rows[0].v === 'v') return false
  const { types, names } = rows[0]
  let body
  try {
    const args = Object.entries(JSON.parse(r.postData() || '{}')).map(([n, v]) => {
      const t = types[names.indexOf(n)]
      if (!t || !/^[a-z_][a-z0-9_]*$/.test(n)) throw new Error('argument ' + n)
      const val = v === null ? 'null' : /^jsonb?$/.test(t) ? lit(JSON.stringify(v)) : Array.isArray(v) ? `array(select jsonb_array_elements_text(${lit(JSON.stringify(v))}::jsonb))` : lit(String(v))
      return `${n} => ${val}::${t}`
    }).join(', ')
    const head = "with p as (select u.id::text as sub, u.email from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email)) where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null order by e.id limit 1), c as (select set_config('request.jwt.claims', json_build_object('sub', p.sub, 'email', p.email, 'role', 'authenticated')::text, true) as s from p) "
    const out = await mgmt(head + (rows[0].set ? `select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) as j from c, lateral ${fn}(${args}) t` : `select (select to_jsonb(${fn}(${args})) from c) as j`))
    body = JSON.stringify(out[0].j)
    reads.push(fn)
  } catch (e) {
    reads.push(fn + ' failed: ' + String(e.message).slice(0, 120))
    await route.fulfill({ status: 400, contentType: 'application/json', body: JSON.stringify({ message: 'read failed in the test' }) })
    return true
  }
  await route.fulfill({ status: 200, contentType: 'application/json', body })
  return true
}

// Comments out, and whitespace out except one space between two word characters. Strings, template text and regex literals
// are copied as they are. A regex starts where an expression may start (after an operator, an opening bracket, a comma, a
// keyword like return); anywhere else a slash divides. Vite's served code always ends statements with a semicolon, so the
// newlines it drops never join two statements into one.
export function squeeze(src) {
  let out = '', i = 0, space = false, depth = 0
  const tpl = [], word = (c) => /[\w$]/.test(c || '')
  const emit = (s) => { if (space && word(out.slice(-1)) && word(s[0])) out += ' '; space = false; out += s }
  const regexHere = () => /(^|[(,=:[!&|?{};+\-*%<>~^])$/.test(out) || /(^|[^\w$.])(return|typeof|case|do|else|in|of|new|delete|void|throw|yield|await)$/.test(out)
  while (i < src.length) {
    const c = src[i], n = src[i + 1]
    if (c === '/' && n === '/') { while (i < src.length && src[i] !== '\n') i++; space = true; continue }
    if (c === '/' && n === '*') { const j = src.indexOf('*/', i + 2); i = j < 0 ? src.length : j + 2; space = true; continue }
    if (/\s/.test(c)) { space = true; i++; continue }
    if (c === '"' || c === "'") { let j = i + 1; while (j < src.length && src[j] !== c) j += src[j] === '\\' ? 2 : 1; emit(src.slice(i, j + 1)); i = j + 1; continue }
    if (c === '`' || (c === '}' && tpl.length && tpl[tpl.length - 1] === depth)) {
      if (c === '}') tpl.pop()
      let j = i + 1
      while (j < src.length && src[j] !== '`' && !(src[j] === '$' && src[j + 1] === '{')) j += src[j] === '\\' ? 2 : 1
      if (src[j] === '`') { emit(src.slice(i, j + 1)); i = j + 1 } else { emit(src.slice(i, j + 2)); tpl.push(depth); i = j + 2 }
      continue
    }
    if (c === '/' && regexHere()) {
      let j = i + 1, cls = false
      while (j < src.length && src[j] !== '\n' && (cls || src[j] !== '/')) { if (src[j] === '\\') j++; else if (src[j] === '[') cls = true; else if (src[j] === ']') cls = false; j++ }
      if (src[j] === '/') { j++; while (/[a-z]/.test(src[j] || '')) j++; emit(src.slice(i, j)); i = j; continue }
    }
    if (c === '{') depth++
    else if (c === '}') depth--
    emit(c); i++
  }
  return out
}

// The squeeze's one check: run `node scripts/client-app/base.mjs`.
if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replace(/\\/g, '/').split('/').pop())) {
  const fx = [
    'const a = "x // not a comment", b = \'don\\\'t\'; // a comment with a quote: don\'t',
    '/* block "quote */ const r = /["\'`]\\/\\//g, d = a / b / c;',
    'const t = `one ${ { k: "}" }.k } two ${ f(`in ${ x }`) } three`;',
    'function f(x) { return /[/]/.test(x) }',
    'export const supabase = moduleClient("client-app", { schema: "client" });',
  ].join('\n')
  const want = 'const a="x // not a comment",b=\'don\\\'t\';const r=/["\'`]\\/\\//g,d=a/b/c;const t=`one ${{k:"}"}.k} two ${f(`in ${x}`)} three`;function f(x){return/[/]/.test(x)}export const supabase=moduleClient("client-app",{schema:"client"});'
  const got = squeeze(fx)
  console.log(got === want ? 'PASS squeeze' : `FAIL squeeze\n got: ${got}\nwant: ${want}`)
  const k = key('/src/routes/a.tsx?t=1794650939830&tsr-split=component')
  console.log(k === '/src/routes/a.tsx?tsr-split=component' && key('/src/x.ts?t=1') === '/src/x.ts' && key('/src/x.ts?v=a&t=2') === '/src/x.ts' ? 'PASS key' : 'FAIL key ' + k)
  process.exit(got === want ? 0 : 1)
}
