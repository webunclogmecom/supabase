// node --experimental-strip-types --no-warnings run.mjs
// Runs harness.mjs's scenarios against the canonical session-storage.ts. Exit 1 on any failure.
import { scenarios } from './harness.mjs'
const canon = await import('./session-storage.ts')
const rows = scenarios(() => ({ storage: canon.sharedSessionStorage, user: canon.sharedUserStorage, setRemember: canon.setRememberMe, load: canon.sweepStaleCopies }))
console.log(`canonical session-storage.ts: ${rows.filter((r) => r.ok).length}/${rows.length}`)
for (const r of rows) console.log(`  ${r.ok ? 'PASS' : 'FAIL'} ${r.name}${r.ok ? '' : '  -> ' + r.got}`)
process.exit(rows.every((r) => r.ok) ? 0 : 1)
