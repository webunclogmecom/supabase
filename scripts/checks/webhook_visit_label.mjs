// node scripts/checks/webhook_visit_label.mjs [control-ref]
// A visit made in Jobber takes its service_type from the catalogue (public.service_line_items), by the same rule as
// ops.v_calendar_visit.service_label: of its coded lines, schedulable first, the lowest code with a label.
// Fred, 2026-11-06, Trello #177: "Have a catalogue for this", "All lines now".
// Runs the REAL label block of webhook-jobber (working tree AND the body before the fix, cut out by its anchors, never
// retyped) against named line shapes and against every live visit with coded lines. READ ONLY: one SELECT on Prod, no
// webhook is called, nothing is written. The control must fail the named cases, or this check proves nothing.
import fs from 'node:fs'
import { execSync } from 'node:child_process'
import { stripTypeScriptTypes } from 'node:module'

const PATH = 'supabase/functions/webhook-jobber/index.ts'
const control = process.argv[2] || '6c6dbf2f'
const ENV = [new URL('../../.env', import.meta.url), 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env'].find((p) => fs.existsSync(p))
const env = Object.fromEntries(fs.readFileSync(ENV, 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const sql = async (query) => {
  const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', { method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' }, body: JSON.stringify({ query }) })
  const j = await r.json(); if (!Array.isArray(j)) throw new Error(JSON.stringify(j).slice(0, 300)); return j
}

function block(src, label) {
  const a = src.indexOf('const inferServiceType = '), endMark = "const serviceType = serviceTypeConcrete ?? 'Pumping'", b = src.indexOf(endMark)
  if (a < 0 || b < 0) throw new Error(`${label}: anchors not found, update this check`)
  const js = stripTypeScriptTypes(`async function __label(v, supabase) {\n${src.slice(a, b + endMark.length)}\nreturn { concrete: serviceTypeConcrete, label: serviceType }\n}`)
  return new Function(`${js}; return __label`)()
}

const catalogue = await sql('select code, service_type, schedulable from public.service_line_items')
const stub = (result) => ({ from: () => ({ select: async () => result }) })
const okDb = stub({ data: catalogue, error: null })
const visit = (lines, title = 'Some client - job') => ({ title, lineItems: { nodes: lines.map((name) => ({ name })) } })
const SC = '112-YA Yan\'s Restaurant - Service Call'

// name, line names, title, the label wanted, must the pre-fix body get it wrong
const CASES = [
  ['21 alone (test visit 9101)', ['21 - Service Call - Assessment'], "Yan's Restaurant - 112-YA - [TEST] Viktor sync check 2", 'Assessment', true],
  ['21 alone, titled Service Call (6830)', ['21 - Service Call - Assessment'], SC, 'Assessment', true],
  ['21 listed first with 01 Pumping stays Pumping (223-CHA, visit 5125)', ['21 - Service Call - Assessment', '01 - Service Agreement - Pumping - Grease Trap', '13 - Service Call - Cleaning - Aux Cleaning', '19 - Service Call - Camera Inspection'], 'El Chaman - For service rendered', 'Pumping', false],
  ['18 Unclogging', ['18 - Service Call - Unclogging - Commercial - Hydrojet'], SC, 'Unclogging', true],
  ['22 Labor', ['22 - Service Call - Labor'], SC, 'Labor', true],
  ['23 Parts', ['23 - Service Call - Parts'], SC, 'Parts', true],
  ['24 Labor BUS', ['24 - Service Call - Labor BUS'], SC, 'Labor BUS', true],
  ['19 Camera Inspection', ['19 - Service Call - Camera Inspection'], SC, 'Camera Inspection', true],
  ['20 Dye Test', ['20 - Service Call - Dye Test'], SC, 'Dye Test', true],
  ['28 Dump', ['28 - Service Call - Dump'], 'x', 'Dump Offload', true],
  ['04 Lift Station reads Pumping, not Cleaning', ['04 - Service Agreement - Pumping - Lift Station & Tank Cleaning'], 'x', 'Pumping', true],
  ['11 Lift Station call reads Pumping', ['11 - Service Call - Pumping - Lift Station & Tank Cleaning'], 'x', 'Pumping', true],
  ['Lowest code wins whatever Jobber lists first', ['13 - Service Call - Cleaning - Auxiliary Line Cleaning', '01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning'], 'x', 'Pumping', true],
  ['A fee line never decides', ['25 - Credit card fee (3.53%)', '18 - Service Call - Unclogging - Commercial - Hydrojet'], SC, 'Unclogging', true],
  ['One digit code', ['1 - Service Agreement - Pumping - Grease Trap'], 'x', 'Pumping', false],
  ['01 unchanged', ['01 - Service Agreement - Pumping - Grease Trap & Tank Cleaning'], 'x', 'Pumping', false],
  ['08 unchanged', ['08 - Service Agreement - Warranty of Drainage'], 'x', 'Warranty of Drainage', false],
  ['Free text still reads by its words', ['Grease Trap Pumping'], 'x', 'Pumping', false],
  ['Free text cleaning', ['Main line cleaning'], 'x', 'Cleaning', false],
  ['Fee only falls to the title', ['25 - Credit card fee (3.53%)'], SC, 'Cleaning', false],
  ['A code the catalogue does not hold falls to its words', ['99 - Main line cleaning'], 'x', 'Cleaning', false],
]

const fixedSrc = fs.readFileSync(PATH, 'utf8')
const oldSrc = execSync(`git show ${control}:${PATH}`, { encoding: 'utf8' })
if (fixedSrc === oldSrc) { console.log('FAIL control is the working tree'); process.exit(1) }
const fixed = block(fixedSrc, 'working tree'), old = block(oldSrc, control)

let bad = 0
const say = (ok, line) => { if (!ok) bad++; console.log(`${ok ? 'PASS' : 'FAIL'} ${line}`) }
for (const [name, lines, title, want, controlWrong] of CASES) {
  const f = await fixed(visit(lines, title), okDb), o = await old(visit(lines, title), okDb)
  const oWrong = o.label !== want
  say(f.label === want && oWrong === controlWrong, `${name}: ${f.label}${controlWrong ? ` (pre-fix read ${o.label})` : ''}${oWrong !== controlWrong ? ` [control read ${o.label}, not as expected]` : ''}`)
}
const none = await fixed({ title: null, lineItems: { nodes: [] } }, okDb)
say(none.concrete === null && none.label === 'Pumping', 'No lines and no title: not concrete, so an update keeps the stored label; an insert defaults to Pumping')
let threw = ''
try { await fixed(visit(['01 - x']), stub({ data: null, error: { message: 'boom' } })) } catch (e) { threw = e.message }
say(/catalogue read failed/.test(threw), 'A failed catalogue read throws, it never guesses')
threw = ''
try { await fixed(visit(['01 - x']), stub({ data: [], error: null })) } catch (e) { threw = e.message }
say(/catalogue read failed/.test(threw), 'An empty catalogue reply throws, a missing answer is not an empty one')

// Mutants: the two shortcuts this rule could have been. Each must be caught by a named case.
const mutate = (from, to) => { if (!fixedSrc.includes(from)) throw new Error('mutant anchor missing: ' + from); return block(fixedSrc.replace(from, to), 'mutant') }
const firstListed = mutate('a.code.localeCompare(b.code))[0]', 'names.findIndex((n) => n?.includes(a.code + " ")) - names.findIndex((n) => n?.includes(b.code + " ")))[0]')
say((await firstListed(visit(CASES[2][1], CASES[2][2]), okDb)).label !== 'Pumping', 'mutant "first listed wins" is caught by the 21 + 01 case')
const noCatalogue = mutate('codes.has(c.code))', 'false)')
say((await noCatalogue(visit(CASES[0][1], CASES[0][2]), okDb)).label !== 'Assessment', 'mutant "no catalogue" is caught by the 21 case')

// Every live visit with coded lines: the webhook's rule against the Calendar's own label, computed by SQL.
const rows = await sql(`
  select v.id, v.source, v.title, v.service_type as stored,
         (select json_agg(li.name order by li.id) from public.line_items li where li.visit_id = v.id) as lines,
         (select (array_agg(s.service_type order by (not s.schedulable), s.code) filter (where s.service_type is not null))[1]
            from public.line_items li
            join public.service_line_items s on s.code = lpad(substring(btrim(li.name) from '^([0-9]+)'), 2, '0')
           where li.visit_id = v.id) as calendar_label
    from public.visits v
   where v.deleted_at is null
     and exists (select 1 from public.line_items li where li.visit_id = v.id and li.name ~ '^[[:space:]]*[0-9]{1,2}[[:space:]]*-')`)
let agree = 0, oldAgree = 0; const differ = []
for (const r of rows) {
  if (!r.calendar_label) continue
  const v = { title: r.title, lineItems: { nodes: r.lines.map((name) => ({ name })) } }
  const f = await fixed(v, okDb), o = await old(v, okDb)
  if (f.label === r.calendar_label) agree++; else differ.push({ id: r.id, source: r.source, webhook: f.label, calendar: r.calendar_label })
  if (o.label === r.calendar_label) oldAgree++
}
const total = agree + differ.length
console.log(`\nLive: ${total} visits with a labelled coded line. Webhook rule agrees with the Calendar's label on ${agree}; pre-fix body on ${oldAgree}.`)
if (differ.length) console.log(JSON.stringify(differ.slice(0, 10)))
say(total > 500, `the live read returned real rows (${total}), a positive control`)
say(differ.length === 0, 'the webhook and the Calendar read the same label on every live visit')
say(total - oldAgree > 50, `the pre-fix body disagreed on ${total - oldAgree}, so this comparison can fail`)
console.log(bad ? `\n${bad} WRONG` : '\nAll right.')
process.exit(bad ? 1 : 0)
