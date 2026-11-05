// Standing check: no staff app may render its signed-in pages in the browser's system font (Building Apps CLAUDE.md rule 1).
//   node scripts/checks/app-fonts.mjs
// Found 2026-11-05: the DERM Tracker and Picture Planner had shipped since their first builds with Tailwind's default font token,
// so only their login screens were Manrope. A login check cannot see that, because the login sets its own font.
// Needs no session and holds no client data. It reads the stylesheets a signed-out browser gets, which are the same files.
// An app passes when its --font-sans names Manrope, or an html, :root or body rule does, or it sets no default token at all
// (the Client App sets its font another way; measured Manrope with a session on 2026-11-05).
// Non-zero exit on any failure. A stylesheet it could not read is a failure, never a pass.
const APPS = ['derm', 'planner', 'stamp', 'calendar', 'clients', 'admin', 'hr', 'hub', 'ops']
const DEFAULT = /--font-sans:\s*ui-sans-serif/

export function verdict(css) {
  // @theme inline compiles the token away and leaves only --default-font-family (the DERM Tracker since 2026-11-05).
  const token = [...css.matchAll(/--(?:font-sans|default-font-family):[^;}]*/g)].map((m) => m[0]).join(' ')
  if (/manrope/i.test(token)) return { ok: true, why: 'token' }
  // The whole selector must be the page itself: `body.svcrep-body` (the DERM Service Report) is one screen, and it fooled the first version.
  if (/(?:^|\})\s*(?:html|:root|:host|body)\s*(?:,\s*(?:html|:root|:host|body)\s*)*\{[^{}]*font-family:[^;}]*manrope/i.test(css)) return { ok: true, why: 'base rule' }
  if (DEFAULT.test(css)) return { ok: false, why: 'the font token is still the Tailwind default' }
  return { ok: true, why: 'no default token' }
}

let bad = 0
const say = (ok, label, extra = '') => { console.log(`${ok ? 'ok  ' : 'FAIL'}  ${label}${extra ? `: ${extra}` : ''}`); if (!ok) bad++ }

// Controls: the two shapes that must fail and pass, or a clean run proves nothing.
say(!verdict('.a{}:root{--font-sans:ui-sans-serif, system-ui, sans-serif}').ok, 'control: the Tailwind default fails')
say(verdict(':root{--font-sans:"Manrope", ui-sans-serif}').ok, 'control: a Manrope token passes')
say(verdict(':root{--font-sans:ui-sans-serif}body{font-family:Manrope,sans-serif}').ok, 'control: Manrope on body passes')
say(!verdict(':root{--font-sans:ui-sans-serif}.svcrep,body.svcrep-body{font-family:Manrope,sans-serif}').ok, 'control: Manrope on one screen fails')

for (const app of APPS) {
  const origin = `https://${app}.unclogme.app`
  try {
    const html = await (await fetch(`${origin}/?x=${Date.now()}`)).text()
    const files = [...new Set([...html.matchAll(/\/assets\/[A-Za-z0-9_.-]+\.css/g)].map((m) => m[0]))]
    if (!files.length) { say(false, app, 'no stylesheet found on the page'); continue }
    const css = (await Promise.all(files.map(async (f) => (await fetch(origin + f)).text()))).join('\n')
    const v = verdict(css)
    say(v.ok, app, v.why)
  } catch (e) { say(false, app, `could not read it: ${e.message}`) }
}
console.log(bad ? `\n${bad} FAILED` : '\nall good')
process.exit(bad ? 1 : 0)
