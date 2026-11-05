// Standing check of history-rows.ts, the filters and sorts on the Monthly Report's history table. Made-up data, no browser, no network.
//   node --no-warnings scripts/lwt-monthly/app/history-rows.check.mjs
// It ends by breaking the module one rule at a time, and each break must make the suite fail.
import { stripTypeScriptTypes } from 'node:module'
import { readFileSync } from 'node:fs'

const source = stripTypeScriptTypes(readFileSync(new URL('./history-rows.ts', import.meta.url), 'utf8'))
const load = (code) => import(`data:text/javascript,${encodeURIComponent(code)}#${Math.random()}`)

const row = (ym, period, inv, n, g, fee, status, who, when, extra = {}) => ({ ym, period, invoice_id: inv, ticket_count: n, gallons: g, fee, status_text: status, who, when, filed: status === 'Filed', discarded: status === 'Discarded' ? '2026-11-03' : null, ...extra })
const ROWS = [
  row('2026-10', 'October 2026', 'SP00000500', 16, '48,937', '$205.04', 'Draft', 'Dana', '2026-11-18'),
  row('2026-09', 'September 2026', 'SP00000400', 15, '53,400', '$223.74', 'Filed', 'Avery', '2026-11-03'),
  row('2026-09', 'September 2026', null, 16, '53,465', '$224.01', 'Discarded', 'Avery', '2026-11-03'),
  row('2026-08', 'August 2026', 'SP00000300', 12, '9,000', '$37.71', 'Filed', 'Blake', '2026-10-13'),
  row('2025-12', 'December 2025', 'SP00000100', 3, '120,000', '$1,005.60', 'Filed', null, null),
]
const ids = (rows) => rows.map(r => `${r.ym}${r.discarded ? 'x' : ''}`).join(' ')

function suite(m) {
  const failed = []
  const ok = (c, n) => { if (!c) failed.push(n) }
  const v = (o = {}) => ({ ...m.DEFAULT_VIEW, ...o })
  const r = (o) => ids(m.historyRows(ROWS, v(o)))
  ok(r({}) === '2026-10 2026-09 2026-08 2025-12', 'arrives on filed and drafts, newest first')
  ok(r({ show: 'filed' }) === '2026-09 2026-08 2025-12', 'Filed')
  ok(r({ show: 'draft' }) === '2026-10', 'Drafts')
  ok(r({ show: 'discarded' }) === '2026-09x', 'Discarded')
  ok(r({ who: 'Avery' }) === '2026-09', 'handled by one person, discarded rows stay hidden')
  ok(r({ who: 'Avery', show: 'discarded' }) === '2026-09x', 'filters combine')
  ok(r({ year: '2025' }) === '2025-12', 'a year')
  ok(r({ q: 'sp00000300' }) === '2026-08', 'search: an invoice, either case')
  ok(r({ q: 'september' }) === '2026-09', 'search: a month')
  ok(r({ q: 'blake' }) === '2026-08', 'search: a name')
  ok(r({ q: '  august   blake ' }) === '2026-08', 'search: every word must match')
  ok(r({ q: 'august avery' }) === '', 'search: nothing matches')
  ok(r({ sort: 'period', dir: 'asc' }) === '2025-12 2026-08 2026-09 2026-10', 'oldest first')
  ok(r({ sort: 'gallons', dir: 'desc' }) === '2025-12 2026-09 2026-10 2026-08', 'gallons sort as numbers (9,000 is the least)')
  ok(r({ sort: 'fee', dir: 'desc' }) === '2025-12 2026-09 2026-10 2026-08', 'a fee over a thousand sorts as a number')
  ok(r({ sort: 'fee', dir: 'asc' }) === '2026-08 2026-10 2026-09 2025-12', 'and lowest first')
  ok(r({ sort: 'tickets', dir: 'desc' }) === '2026-10 2026-09 2026-08 2025-12', 'tickets')
  ok(r({ sort: 'who', dir: 'asc' }) === '2026-09 2026-08 2026-10 2025-12', 'a name A to Z, no name last')
  ok(r({ sort: 'who', dir: 'desc' }) === '2026-10 2026-08 2026-09 2025-12', 'Z to A, no name still last')
  ok(r({ sort: 'handled', dir: 'desc' }) === '2026-10 2026-09 2026-08 2025-12', 'recently handled, no date last')
  ok(r({ sort: 'invoice', dir: 'asc', show: 'discarded' }) === '2026-09x', 'a row with no invoice still shows')
  const ties = ids(m.historyRows([row('2026-07', 'July', 'A', 5, '1', '$1', 'Filed', 'Avery', '2026-08-01'), row('2026-09', 'Sep', 'B', 5, '1', '$1', 'Filed', 'Avery', '2026-10-01')], v({ sort: 'tickets', dir: 'desc' })))
  ok(ties === '2026-09 2026-07', 'equal rows read newest month first')
  ok(ids(m.historyRows([row('2026-12', 'Dec', 'Z', 1, '1', '$1', 'Filed', null, null), row('2026-01', 'Jan', 'A', 1, '1', '$1', 'Filed', 'Avery', '2026-02-01')], v({ sort: 'who', dir: 'asc' }))) === '2026-01 2026-12', 'no name sorts last even on the newest month')
  const before = JSON.stringify(ROWS)
  m.historyRows(ROWS, v({ sort: 'fee', dir: 'asc' }))
  ok(JSON.stringify(ROWS) === before, 'the original list is left alone')
  ok(m.firstDir('fee') === 'desc' && m.firstDir('period') === 'desc' && m.firstDir('who') === 'asc' && m.firstDir('invoice') === 'asc', 'first click: most or newest, words A to Z')
  ok(m.filterCount(v()) === 0 && m.filterCount(v({ show: 'filed', who: 'x', year: '2026' })) === 3 && m.filterCount(v({ q: 'x' })) === 0, 'the count is the filters, not the search')
  ok(m.numberOf('$1,005.60') === 1005.6 && m.numberOf(null) === 0, 'numberOf')
  return failed
}

const first = suite(await load(source))
for (const f of first) console.log('FAIL', f)
if (first.length) { console.log(`${first.length} failed`); process.exit(1) }
console.log('ok   all 27 checks')

const MUTANTS = [
  ['discarded rows show by default', "if (x.discarded) return false;", ''],
  ['Filed and Drafts swapped', "(show === 'filed') === !!x.filed", "(show === 'filed') !== !!x.filed"],
  ['numbers sort as text', "case 'gallons': return numberOf(x.gallons);", "case 'gallons': return x.gallons;"],
  ['the fee keeps its comma', "/[^0-9.-]/g", "/[^0-9.]/"],
  ['who filter ignored', "(v.who && x.who !== v.who) || ", ''],
  ['year filter ignored', " || (v.year && yearOf(x) !== v.year)", ''],
  ['search matches any word', 'words.every(', 'words.some('],
  ['search is case-sensitive', "const text = [x.period, x.invoice_id, x.who].filter(Boolean).join(' ').toLowerCase();", "const text = [x.period, x.invoice_id, x.who].filter(Boolean).join(' ');"],
  ['direction ignored', "const sign = v.dir === 'asc' ? 1 : -1;", 'const sign = 1;'],
  ['blanks sort with the rest', "if (a.s !== b.s) return a.s === null ? 1 : -1;", ''],
  ['ties lose their order', 'return b.x.ym.localeCompare(a.x.ym) || a.i - b.i;', 'return a.i - b.i;'],
  ['the search counts as a filter', "(v.year ? 1 : 0);", "(v.year ? 1 : 0) + (v.q ? 1 : 0);"],
  ['arrives oldest first', "sort: 'period', dir: 'desc' }", "sort: 'period', dir: 'asc' }"],
]
let bad = 0
for (const [name, from, to] of MUTANTS) {
  if (!source.includes(from)) { console.log('FAIL mutant cannot apply:', name); bad++; continue }
  let failed
  try { failed = suite(await load(source.replace(from, to))) } catch (e) { failed = [e.message] }
  if (!failed.length) { console.log('FAIL mutant survived:', name); bad++ }
}
if (bad) { console.log(`${bad} of ${MUTANTS.length} mutants were not caught`); process.exit(1) }
console.log(`ok   ${MUTANTS.length} of ${MUTANTS.length} mutants caught`)
console.log('\nall good')
