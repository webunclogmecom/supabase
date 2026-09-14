// Node front-end for the shared run-length detector (supabase/functions/_shared/printed_rule_detector.mjs).
// USE: node scripts/probes/rev/detect_node.mjs <jpeg-path> [topPct] [botPct]
// ALWAYS run it against a page whose truth you already know before believing it on a page you do
// not: a detector with no positive control is an untested instrument.
import fs from 'node:fs';
import nodePath from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { detectRules } from '../../../supabase/functions/_shared/printed_rule_detector.mjs';

const require = createRequire(import.meta.url);
const jpeg = require('jpeg-js');

export function detectFile(path, topPct = null, botPct = null) {
  const raw = jpeg.decode(fs.readFileSync(path), { useTArray: true });
  return detectRules(raw, topPct, botPct);
}

// run the CLI only when this file is the entry point (it is also imported by the Phase 0 script)
if (process.argv[1] && nodePath.resolve(process.argv[1]).toLowerCase() === fileURLToPath(import.meta.url).toLowerCase()) {
  const [, , path, top, bot] = process.argv;
  if (!path) { console.error('usage: node detect_node.mjs <jpeg-path> [topPct] [botPct]'); process.exit(2); }
  const r = detectFile(path, top ? +top : null, bot ? +bot : null);
  console.log(`${path}  ${r.W}x${r.H}  skew ${r.skew}`);
  for (const x of r.rules) console.log(`  ${String(x.pct).padStart(7)}  run ${x.run.toFixed(3)}  ${x.kind}`);
}
