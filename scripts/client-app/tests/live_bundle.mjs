// Walks the LIVE Client App bundle from real routes (rule 2i: a "/"-only walk reaches 3 of 7 chunks) and asserts the
// Schedule intake strings are served. Prints chunk names, counts and totals only.
//   node scripts/client-app/tests/live_bundle.mjs            -> PASS/FAIL lines, exit 1 on a FAIL
//   node scripts/client-app/tests/live_bundle.mjs --absent   -> the pre-publish control: every NEW needle ABSENT, every GONE needle still there
//   CLIENT_APP=http://localhost:8080/clients (or --base <url>) walks the portal's copy instead (scripts/client-app/base.mjs)
import { BASE, crawl } from '../base.mjs'
const ROUTES = ['/clients/381', '/dashboard', '/schedule', '/']
const ABSENT = process.argv.includes('--absent')
const seen = await crawl(ROUTES)
const all = [...seen.values()].join('\n')
const bytes = [...seen.values()].reduce((n, t) => n + Buffer.byteLength(t), 0)
if (BASE !== 'https://clients.unclogme.app') console.log(BASE)
console.log(`${seen.size} chunks, ${bytes} bytes; intake dialog in ${[...seen].filter(([, t]) => t.includes('schedule_property_intake')).map(([u]) => u.replace(/^\/assets\//, '')).join(', ')}`)
let pass = 0, fail = 0
const ok = (c, name) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}`) }
// controls that must be present before AND after: the instrument can see the dialog, and what shipped before stays shipped
const ALWAYS = ['schedule_property_intake', 'intakeParentKey', 'v_intake_questions', 'Assign to', 'Nobody yet', 'We make a task for this person in Jobber and in the Calendar, and put their name on the form.', 'Technicians', 'save-calendar-task',
  '"client-app"', 'Open this link on site to fill in the site survey form:', 'cancel_intake', 'Task made for ',
  'It is in Jobber and in the Calendar, with this link in its notes.', "'s name is already on the form.", 'Could not confirm the task. Check the Calendar before sending the link.',
  'Check the Calendar', 'No task was made, so the link was cancelled.', 'No task was made, and the link could not be cancelled. Cancel it in the Picture Planner, under Forms.',
  'asked again next to the capacity plate photo.', "We couldn't load the staff list. Close this and try again.", 'rolled_back', 'jobber_task',
  // the definite-refusal list (design 2.3): a code on it, with no jobber_task, cancels the link
  'intake_closed', 'jobber_rejected', 'property_without_client',
  // kept on purpose by the 2026-11-05 change
  '0 on file, may be unknown', 'Everything starts ticked except what we already have on file.', 'It opens with no login, and it stops working once it has been submitted.']
for (const n of ALWAYS) ok(all.includes(n), `always live: ${n}`)
// the 2026-11-05 change (office training film): the Link ready sentence by task outcome, Manholes ticked at 0
const NEW = ["It's already in their task, so you don't need to send it.", 'If the task is not in the Calendar, send this to whoever is going on site.', 'We store 0 by default, so 0 and unknown look the same.']
const GONE = ['Send this to whoever is going on site.', 'Never pre-ticked']
for (const n of NEW) ok(ABSENT ? !all.includes(n) : all.includes(n), `${ABSENT ? 'absent before the build' : 'live'}: ${n}`)
for (const n of GONE) ok(ABSENT ? all.includes(n) : !all.includes(n), `${ABSENT ? 'still there before the build' : 'gone'}: ${n}`)
if (!ABSENT) ok(!new RegExp('[' + String.fromCharCode(0x2013, 0x2014) + ']').test(NEW.join(' ')), 'no en or em dash in the new strings')
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
