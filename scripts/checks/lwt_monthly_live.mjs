// Standing check for the DERM Tracker's Monthly Report page (Trello EOnFKqSK). Read-only, needs no key, holds no client data.
//   node --experimental-strip-types scripts/checks/lwt_monthly_live.mjs
// Three things that can drift with nothing on screen saying so:
//   1. the bot's vocabulary (/monthly/config.js) against the tables in monthly-rules.ts;
//   2. the rules and the page the live app ships, against this repo (an app copy is a byte-identical download, never edited);
//   3. the door: the function refuses a call with no session, and answers only the two staff origins.
// Non-zero exit on any failure. A check that could not run is a failure, never a pass.
import { readFileSync } from 'node:fs'
import { configDrift, RULE_INFO } from '../lwt-monthly/monthly-rules.ts'

const BOT = 'https://unclogmerpabot-production.up.railway.app'
const APP = process.env.LWT_APP_ORIGIN || 'https://derm.unclogme.app'
const FN = 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/lwt-monthly'
let bad = 0
const ok = (cond, label, extra = '') => { console.log(`${cond ? 'ok  ' : 'FAIL'}  ${label}${extra ? `: ${extra}` : ''}`); if (!cond) bad++ }

// 1 ---------------------------------------------------------------------------------------------------------------------------
ok(configDrift('this is not the config').length > 0, 'control: text it cannot read is a drift')
const cfg = await fetch(`${BOT}/monthly/config.js`)
ok(cfg.ok, 'the bot serves its vocabulary', `HTTP ${cfg.status}`)
if (cfg.ok) {
  const drift = configDrift(await cfg.text())
  ok(drift.length === 0, 'vocabulary matches monthly-rules.ts', drift.slice(0, 5).join(' | '))
}

// 2 ---------------------------------------------------------------------------------------------------------------------------
const html = await (await fetch(`${APP}/monthly?x=${Date.now()}`)).text()
const seen = new Set([...html.matchAll(/\/assets\/[A-Za-z0-9_.-]+\.js/g)].map((m) => m[0]))
const queue = [...seen]
const chunks = new Map()
while (queue.length) {
  const a = queue.shift()
  const t = await (await fetch(APP + a)).text()
  chunks.set(a, t)
  for (const m of t.matchAll(/assets\/([A-Za-z0-9_.-]+\.js)/g)) {
    const n = `/assets/${m[1]}`
    if (!seen.has(n)) { seen.add(n); queue.push(n) }
  }
}
// A byte-for-byte test is impossible after minifying, so every sentence of the rules' vocabulary and of the page must be present.
const all = [...chunks.values()].join('\n')
const unescape = (s) => s.replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16))).replace(/\\'/g, "'").replace(/\\"/g, '"')
const present = (s) => all.includes(s) || all.includes(s.replace(/'/g, "\\'")) || all.includes(JSON.stringify(s).slice(1, -1))
ok(!present('a sentence no build should ever carry 7f3a'), 'control: a made-up sentence is absent')
ok(chunks.size > 5, 'walked the live chunks', String(chunks.size))
ok(all.includes('to:"/monthly"'), 'the menu links to the page')
ok(all.includes('This report file could not be read'), 'the live build carries the report viewer')
const titles = Object.values(RULE_INFO).map((v) => v[0])
const missing = titles.filter((t) => !present(t))
ok(missing.length === 0, `the live build carries the rules' ${titles.length} titles`, missing.slice(0, 3).join(' | '))
const page = readFileSync(new URL('../lwt-monthly/app/MonthlyReportPage.tsx', import.meta.url), 'utf8')
// Quoted strings and the text between JSX tags. Quoted alone could not tell two builds apart when a change touched only JSX text.
const quoted = [...page.matchAll(/'((?:[^'\\\n]|\\.){28,})'/g)].map((m) => unescape(m[1])).filter((s) => !/[{}$<>=/]/.test(s) && /^[A-Z]/.test(s))
const jsx = [...page.matchAll(/>([A-Z][^<>{}\n&]{27,})</g)].map((m) => m[1].trim())
const words = [...new Set([...quoted, ...jsx])]
const lost = words.filter((s) => !present(s))
ok(words.length > 15, 'the page has sentences to look for', String(words.length))
ok(lost.length === 0, 'the live build carries this repo’s page', lost.slice(0, 3).join(' | '))
ok(all.includes('.lw-fhead') || [...html.matchAll(/\/assets\/[A-Za-z0-9_.-]+\.css/g)].length > 0, 'the page’s styles can load')

// 3 ---------------------------------------------------------------------------------------------------------------------------
const none = await fetch(FN, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'overview' }) })
ok(none.status === 401, 'no session is refused', `HTTP ${none.status}`)
const pre = await fetch(FN, { method: 'OPTIONS', headers: { Origin: 'https://evil.example', 'Access-Control-Request-Method': 'POST' } })
ok(pre.headers.get('access-control-allow-origin') !== 'https://evil.example', 'another origin is not allowed')

console.log(bad ? `\n${bad} FAILED` : '\nall good')
process.exit(bad ? 1 : 0)
