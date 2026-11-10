// The Site file set: one source, two copies (Ops Portal move plan for Picture Planner, decision 5).
// src/ here is the source. The Ops Portal holds a copy in src/modules/planner/site-file/ (its staff preview) and the Picture
// Planner holds one in src/components + src/lib (the public page drivers open, planner.unclogme.app/driver). The three must be
// byte-identical apart from import paths, or the preview stops showing what drivers see.
//
//   node scripts/site-file/check.mjs --portal "<Ops Portal app dir>" [--planner "<Picture Planner repo dir>"]
//
// Exit 0 when every given copy matches, 1 on a difference. It first proves it can see a difference (a planted change).
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SET = ['DriverPage.tsx', 'MarkedImage.tsx', 'access-pdf-types.ts', 'format.ts', 'google-maps.ts', 'site-map-pins.ts', 'site-map-pins.test.ts']
const PLANNER_PATH = { 'DriverPage.tsx': 'src/components', 'MarkedImage.tsx': 'src/components' }

// Import paths are the only allowed difference: each copy names the set's files from its own folders.
// Line endings are not content: this repo's checkout may turn LF into CRLF.
const normal = (text) =>
  text
    .replace(/\r\n/g, '\n')
    .replace(/"@\/modules\/planner\/site-file\/([\w-]+)"/g, '"<$1>"')
    .replace(/"@\/(?:lib|components)\/([\w-]+)"/g, '"<$1>"')
    .replace(/"\.\/([\w-]+)"/g, '"<$1>"')

function firstDiff(a, b) {
  const x = a.split('\n'), y = b.split('\n')
  for (let i = 0; i < Math.max(x.length, y.length); i++) if (x[i] !== y[i]) return `line ${i + 1}: ${JSON.stringify((y[i] ?? '<missing>').slice(0, 120))}`
  return null
}

const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : null }
const copies = []
if (arg('--portal')) copies.push(['portal', (f) => path.join(arg('--portal'), 'src/modules/planner/site-file', f)])
if (arg('--planner')) copies.push(['planner', (f) => path.join(arg('--planner'), PLANNER_PATH[f] ?? 'src/lib', f)])
if (!copies.length) throw new Error('give --portal and/or --planner')

// Control: a one-character change must be found, or a clean run proves nothing.
const src0 = normal(fs.readFileSync(path.join(HERE, 'src', SET[0]), 'utf8'))
if (!firstDiff(src0, src0.replace('Directions', 'Directionz'))) throw new Error('control failed: a planted change was not seen')

let bad = 0
for (const [name, at] of copies) {
  for (const f of SET) {
    const source = normal(fs.readFileSync(path.join(HERE, 'src', f), 'utf8'))
    const p = at(f)
    if (!fs.existsSync(p)) { console.log(`${name}  MISSING  ${f}`); bad++; continue }
    const d = firstDiff(source, normal(fs.readFileSync(p, 'utf8')))
    console.log(`${name}  ${d ? 'DIFFERS' : 'same   '}  ${f}${d ? '  ' + d : ''}`)
    if (d) bad++
  }
}
console.log(bad ? `${bad} difference(s)` : 'all copies match the source')
process.exit(bad ? 1 : 0)
