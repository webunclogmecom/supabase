// Walks the LIVE Client App bundle from real routes (rule 2i: a "/"-only walk reaches 3 of 7 chunks) and asserts the
// 2026-09-29 Schedule intake strings are served. Prints chunk names, counts and totals only.
//   node scripts/client-app/tests/live_bundle.mjs            -> PASS/FAIL lines, exit 1 on a FAIL
//   node scripts/client-app/tests/live_bundle.mjs --absent   -> the pre-publish control: every new needle must be ABSENT
const H = 'https://clients.unclogme.app'
const ROUTES = ['/clients/381', '/dashboard', '/schedule', '/']
const ABSENT = process.argv.includes('--absent')
const seen = new Map(), queue = []
for (const r of ROUTES) { const html = await (await fetch(H + r)).text(); for (const m of html.matchAll(/\/assets\/[A-Za-z0-9._$-]+\.js/g)) queue.push(m[0]) }
while (queue.length) {
  const u = queue.shift(); if (seen.has(u)) continue
  const t = await (await fetch(H + u)).text(); seen.set(u, t)
  for (const m of t.matchAll(/(?:\.\/|\/assets\/)([A-Za-z0-9._$-]+\.js)/g)) queue.push('/assets/' + m[1])
}
const all = [...seen.values()].join('\n')
const bytes = [...seen.values()].reduce((n, t) => n + Buffer.byteLength(t), 0)
console.log(`${seen.size} chunks, ${bytes} bytes; intake dialog in ${[...seen].filter(([, t]) => t.includes('schedule_property_intake')).map(([u]) => u.slice(8)).join(', ')}`)
let pass = 0, fail = 0
const ok = (c, name) => { c ? pass++ : fail++; console.log(`${c ? 'PASS' : 'FAIL'} ${name}`) }
// controls that must be present before AND after: the instrument can see the dialog
for (const n of ['schedule_property_intake', 'intakeParentKey', 'v_intake_questions']) ok(all.includes(n), `control present: ${n}`)
const NEW = ['Assign to', 'Nobody yet', 'We make a task for this person in Jobber and in the Calendar, and put their name on the form.', 'Technicians', 'save-calendar-task',
  '"client-app"', 'Open this link on site to fill in the site survey form:', 'cancel_intake', 'Task made for ',
  'It is in Jobber and in the Calendar, with this link in its notes.', "'s name is already on the form.", 'Could not confirm the task. Check the Calendar before sending the link.',
  'Check the Calendar', 'No task was made, so the link was cancelled.', 'No task was made, and the link could not be cancelled. Cancel it in the Picture Planner, under Forms.',
  'asked again next to the capacity plate photo.', "We couldn't load the staff list. Close this and try again.", 'rolled_back', 'jobber_task',
  // the definite-refusal list (design 2.3): a code on it, with no jobber_task, cancels the link
  'intake_closed', 'jobber_rejected', 'property_without_client']
for (const n of NEW) ok(ABSENT ? !all.includes(n) || ['Technicians', 'rolled_back', 'jobber_task', 'Check the Calendar', '"client-app"'].includes(n) : all.includes(n), `${ABSENT ? 'absent before the build' : 'live'}: ${n}`)
if (!ABSENT) ok(!new RegExp('[' + String.fromCharCode(0x2013, 0x2014) + ']').test(NEW.join(' ')), 'no en or em dash in the new strings')
console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
