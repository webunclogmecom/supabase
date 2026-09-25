// node mapkey.mjs [out.js] : which Google Maps key the live Planner bundle loads (prints only its ends)
import fs from 'node:fs'
const o = 'https://planner.unclogme.app', seen = new Set(), q = []
for (const s of ['/', '/access/la-cocina', '/property/la-cocina']) { const h = await (await fetch(o + s + '?cb=' + Date.now())).text(); for (const m of h.matchAll(/\/assets\/[A-Za-z0-9_.-]+\.js/g)) q.push(m[0]) }
let found = null
while (q.length) { const p = q.shift(); if (seen.has(p)) continue; seen.add(p); const t = await (await fetch(o + p)).text()
  if (/maps\.googleapis\.com\/maps\/api\/js\?key=/.test(t)) { found = p; fs.writeFileSync(process.argv[2] || 'map_chunk_live.js', t) }
  for (const m of t.matchAll(/(?:\/assets\/|\.\/|"|')([A-Za-z0-9_.-]+-[A-Za-z0-9_-]{6,}\.js)/g)) q.push('/assets/' + m[1]) }
const t = fs.readFileSync(process.argv[2] || 'map_chunk_live.js', 'utf8'), k = t.match(/maps\/api\/js\?key=([^&`"']+)/)
console.log(new Date().toISOString().slice(11, 19), seen.size, 'chunks; map chunk', found, '; key', k ? k[1].slice(0, 6) + '...' + k[1].slice(-4) : 'none')
