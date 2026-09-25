// node build.mjs : build intake.html, the public collector page Picture Planner serves at /intake.html.
//
// It is supabase/functions/intake-submit/form-page.ts (the reviewed form) with exactly these changes,
// each anchored once, so there is ONE form and a diff of it is this list:
//   1. the canonical analytics token guard as the FIRST script (Lovable hosting injects /~flock.js,
//      which posts location.href, fragment included, to its analytics; the guard scrubs `code=`);
//   2. <meta name="referrer" content="no-referrer"> and robots noindex (the URL is a capability);
//   3. the endpoint is the intake-submit URL (the page no longer lives on it);
//   4. the token is read from the FRAGMENT `#code=<token>`: a fragment never reaches a server log or a
//      Referer, and `code` is a key the guard already redacts, so the guard stays byte-identical in all
//      eight apps.
// Then Picture Planner downloads this file, byte for byte, into public/intake.html.
import fs from 'node:fs'
const R = new URL('../../', import.meta.url)
const src = fs.readFileSync(new URL('supabase/functions/intake-submit/form-page.ts', R), 'utf8')
const guard = fs.readFileSync(new URL('scripts/shared-session/analytics-token-guard.inline.js', R), 'utf8').trim()
const a = src.indexOf('String.raw`'), b = src.lastIndexOf('`')
if (a < 0 || b <= a) throw new Error('FORM_HTML not found')
let html = src.slice(a + 'String.raw`'.length, b)
if (html.includes('${')) throw new Error('interpolation inside FORM_HTML')
const once = (from, to) => { const n = html.split(from).length - 1; if (n !== 1) throw new Error(`anchor x${n}: ${from.slice(0, 60)}`); html = html.replace(from, () => to) }
once('<meta charset="utf-8">\n',
  '<meta charset="utf-8">\n<script>' + guard + '</script>\n<meta name="referrer" content="no-referrer">\n<meta name="robots" content="noindex,nofollow">\n')
once("var EP=location.pathname, TOKEN=new URLSearchParams(location.search).get('t')||'';",
  "var EP='https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-submit', TOKEN=new URLSearchParams(location.hash.slice(1)).get('code')||'';")
for (const bad of ['apikey', 'supabase.co/rest', 'supabase.co/auth', 'eyJ']) if (html.includes(bad)) throw new Error('forbidden: ' + bad)
if (html.includes('\r')) throw new Error('CR')
fs.writeFileSync(new URL('intake.html', import.meta.url), html)
console.log('intake.html', Buffer.byteLength(html), 'bytes')
