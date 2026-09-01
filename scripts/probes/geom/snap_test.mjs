// Extracts snapToRule from the SHIPPED source (never retyped) and exercises it.
// Same technique the estate uses for the base64 encoder: pull the real body out of the
// real file, so a drift between what is tested and what runs is impossible.
import { readFileSync } from 'node:fs';

// Point this at a fresh `Download codebase` of the DERM Stamp Studio. The whole point is to
// test the SHIPPED body, so never paste the function in here.
const SRC = process.argv[2] || './ss/src/routes/index.tsx';
const t = readFileSync(SRC, 'utf8');

// pull the body of the useCallback passed to snapToRule
const start = t.indexOf('const snapToRule = useCallback(');
if (start < 0) throw new Error('snapToRule not found in source');
const open = t.indexOf('(v: number)', start);
const bodyStart = t.indexOf('{', t.indexOf('=>', open));
let depth = 0, i = bodyStart, end = -1;
for (; i < t.length; i++) {
  if (t[i] === '{') depth++;
  else if (t[i] === '}') { depth--; if (depth === 0) { end = i; break; } }
}
// Strip ONLY the TypeScript annotations that appear in this body, one at a time, so a crude
// regex cannot silently delete a branch of the ternary (it did on the first attempt).
const body = t.slice(bodyStart, end + 1)
  .replace(/let best: number \| null = null;/, 'let best = null;')
  .replace(/: \{ value: number; rule: number \| null \}/g, '');
console.log('--- extracted body ---');
console.log(body.trim());
console.log('----------------------\n');

const make = (printedRules) => new Function('printedRules', 'v', 'return (function(v)' + body + ')(v);').bind(null, printedRules);

// The 14 real rules detected on ticket-834287 page 1 are unknown to this script, so use a
// realistic synthetic set at the measured ~5.4pp pitch plus mid-slot dividers.
const rules = [25.8, 28.5, 31.2, 33.9, 36.6, 39.3, 42.0, 44.7, 47.4, 50.1, 52.8, 55.5, 58.2, 64.4];
const snap = make(rules);

let pass = 0, fail = 0;
const t_ = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log((ok ? '  PASS  ' : '  FAIL  ') + name + '   got=' + JSON.stringify(got) + ' want=' + JSON.stringify(want));
  ok ? pass++ : fail++;
};

// 1. inside the radius -> snaps to the EXACT rule value, not a rounded one
t_('0.4pp away snaps exactly', snap(31.6), { value: 31.2, rule: 31.2 });
t_('1.19pp away still snaps', snap(33.9 + 1.19), { value: 33.9, rule: 33.9 });

// 2. outside the radius -> untouched, and reports no rule
t_('1.21pp away does NOT snap', snap(33.9 + 1.21), { value: 33.9 + 1.21, rule: null });
t_('far away does NOT snap', snap(20.0), { value: 20.0, rule: null });

// 3. picks the NEAREST, not the first within radius
// 29.4 is 0.9 from 28.5 and 1.8 from 31.2: both are candidates only if within 1.2, so the
// nearer one must win and the farther must be ignored.
t_('nearest wins (0.9 vs 1.8 away)', snap(29.4), { value: 28.5, rule: 28.5 });
// and the midpoint between two rules 2.7 apart is 1.35 from each: outside the radius, no snap.
t_('midpoint between rules does NOT snap', snap(29.85), { value: 29.85, rule: null });

// 4. THE CONTROL THAT MATTERS: an empty rule set must never snap and never invent a value.
//    This is the ticket-834433 case: a page with no detected rules.
const noRules = make([]);
t_('no rules -> no snap (834433 case)', noRules(31.6), { value: 31.6, rule: null });
t_('no rules -> value untouched', noRules(0), { value: 0, rule: null });

// 5. every snapped value must be within the server's 0.35pp tolerance of a real rule,
//    which is the whole point of the feature.
let worst = 0;
for (let v = 24; v <= 66; v += 0.017) {
  const s = snap(v);
  if (s.rule != null) {
    const d = Math.min(...rules.map((r) => Math.abs(r - s.value)));
    if (d > worst) worst = d;
  }
}
console.log('\n  worst distance from a real rule, over 2470 snapped positions: ' + worst.toFixed(6) + 'pp');
if (worst > 0) { console.log('  FAIL  a snapped value was not exactly on a rule'); fail++; } else { console.log('  PASS  every snapped value is EXACTLY a rule (server tolerance 0.35pp)'); pass++; }

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
