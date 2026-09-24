// node analytics-token-guard.test.mjs            run the checks on the ONE-LINE artifact that ships
// node analytics-token-guard.test.mjs --print    print that one line (paste it into each app's <head>)
//
// The shipped artifact is analytics-token-guard.js with its comments removed and its lines joined; the
// checks run THAT string, not the readable file, so what is tested is what ships. Exit 1 on any failure.
import fs from 'node:fs'
const src = fs.readFileSync(new URL('./analytics-token-guard.js', import.meta.url), 'utf8')
export const GUARD = src.slice(src.indexOf('(function () {')).split('\n').map((l) => l.trim()).filter(Boolean).join(' ')
if (process.argv.includes('--print')) { process.stdout.write(GUARD + '\n'); process.exit(0) }

function env() {
  const sent = []
  class XHR { open(m, u) { this.u = u } send(b) { sent.push({ via: 'xhr', url: this.u, body: b }) } }
  class Resp { constructor(b, i) { this.status = i && i.status } }
  const window = { XMLHttpRequest: XHR, fetch: (u, i) => { sent.push({ via: 'fetch', url: u, body: i && i.body }); return Promise.resolve(new Resp(null, { status: 200 })) } }
  const navigator = { sendBeacon: (u, d) => { sent.push({ via: 'beacon', url: u, body: d }); return true } }
  window.navigator = navigator
  const run = () => new Function('window', 'navigator', 'Response', GUARD)(window, navigator, Resp)
  return { window, navigator, sent, run }
}
const HREF = 'https://planner.unclogme.app/reset-password#access_token=AAA.bbb.ccc&expires_at=1&expires_in=3600&refresh_token=BBBrefresh&provider_token=CCCgoogle&token_type=bearer&type=recovery'
const BODY = JSON.stringify({ timestamp: 't', action: 'page_hit', payload: JSON.stringify({ pathname: '/reset-password', href: HREF }) })
const SECRETS = ['AAA.bbb.ccc', 'BBBrefresh', 'CCCgoogle']
let fails = 0
const check = (ok, msg) => { console.log((ok ? '  PASS ' : '  FAIL ') + msg); if (!ok) fails++ }

{ // control: without the guard the tracker body carries the tokens (the instrument can see a leak)
  const e = env(); const x = new e.window.XMLHttpRequest(); x.open('POST', '/~api/analytics'); x.send(BODY)
  check(SECRETS.every((s) => e.sent[0].body.includes(s)), 'control: with no guard the tracker body carries all three tokens')
}
{
  const e = env(); e.run()
  const x = new e.window.XMLHttpRequest(); x.open('POST', '/~api/analytics'); x.send(BODY)
  const b = e.sent[0].body
  check(!SECRETS.some((s) => b.includes(s)), 'XHR to /~api/analytics: no token value leaves the page (double-encoded JSON payload)')
  check(b.includes('access_token=redacted') && b.includes('type=recovery') && b.includes('/reset-password') && b.includes('page_hit'), 'the page view itself is kept: path, action and non-secret parameters survive')
  const y = new e.window.XMLHttpRequest(); y.open('POST', 'https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/token?grant_type=refresh_token'); y.send('{"refresh_token":"BBBrefresh"}')
  check(e.sent[1].body.includes('BBBrefresh'), 'every other request is untouched (auth-js still sends its own refresh token)')
  const z = new e.window.XMLHttpRequest(); z.open('POST', '/~api/analytics'); z.send({ blob: HREF })
  check(e.sent.length === 2, 'a tracker body that is not text is dropped, not sent')
}
{
  const e = env(); e.run()
  await e.window.fetch('/~api/analytics', { method: 'POST', body: BODY })
  check(!SECRETS.some((s) => e.sent[0].body.includes(s)), 'fetch to the tracker: tokens redacted')
  await e.window.fetch('https://example.com/x', { method: 'POST', body: BODY })
  check(SECRETS.every((s) => e.sent[1].body.includes(s)), 'fetch elsewhere: untouched')
  const r = await e.window.fetch({ url: 'https://hub.unclogme.app/~api/analytics' })
  check(e.sent.length === 2 && r.status === 204, 'fetch to the tracker with no readable body: not sent')
  e.navigator.sendBeacon('/~api/analytics', BODY)
  check(!SECRETS.some((s) => e.sent[2].body.includes(s)), 'sendBeacon to the tracker: tokens redacted')
  check(e.navigator.sendBeacon('/~api/analytics', { blob: 1 }) === true && e.sent.length === 3, 'sendBeacon with a non-text body: dropped')
}
{
  const e = env(); e.run()
  const x = new e.window.XMLHttpRequest(); x.open('POST', '/~api/analytics')
  x.send('{"href":"https://hr.unclogme.app/employees?code=PKCEcode123&state=s&zipcode=33141#token_hash=THASH"}')
  const b = e.sent[0].body
  check(!b.includes('PKCEcode123') && !b.includes('THASH') && b.includes('zipcode=33141'), 'a PKCE ?code= and a token_hash are redacted; zipcode= is not a match')
}
{
  const e = env(); e.run(); e.run()
  const x = new e.window.XMLHttpRequest(); x.open('POST', '/~api/analytics'); x.send(BODY)
  check(e.sent.length === 1, 'installing the guard twice is harmless (one send, not two)')
}
{ // the file each app downloads must be exactly the tested artifact (plus the newline --print adds)
  const shipped = fs.readFileSync(new URL('./analytics-token-guard.inline.js', import.meta.url), 'utf8')
  check(shipped === GUARD + '\n', 'analytics-token-guard.inline.js is byte-identical to the tested one-line artifact')
}
console.log(`\nguard: ${GUARD.length} characters, one line`)
if (fails) { console.log(`${fails} FAILED`); process.exit(1) } else console.log('all passed')
