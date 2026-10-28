// edge_vm_source.mjs - turns an edge function's TypeScript into a script node:vm can run, for the stub checks that
// run a REAL supabase/functions/<fn>/index.ts. A vm script cannot import (aab4ac0, 2026-10-23, broke eight checks).
//   vm.runInNewContext(edgeVmSource(src), ctx)      node scripts/checks/edge_vm_source.mjs   (self-check)
// Types are stripped by Node 22 (an `import type` vanishes with them). Each import { a, b as c } from "../_shared/<f>.ts"
// becomes that REAL helper, read from this repo once per build, "export " removed, run in its own closure BEFORE the
// function, which then runs in a strict block. So, as in Deno: the function sees only the names it imported, importing
// a name the helper does not export is a SyntaxError, and a helper sees none of the function's names nor another
// helper's. The one harness name both can see is __edgeVmShared.
// Any other import (npm:, jsr:, https:, or one inside a helper) is left in place, so vm fails loudly.
// The function's own top-level names stay inside its block, so a check that calls one (askVision, parseRows) appends
// the expression to the source before building: vm.runInNewContext(edgeVmSource(src + '\n;({ parseRows })'), ctx).
// ponytail: importing an `export let/var` throws (a copy is not a live binding); a helper holding `export { a as b }`
// or `export default` fails to parse, and `export const a = 1, b = 2` reads `b` as not exported (all loud); a
// top-level `var` in the function would still reach the helpers. None of the 8 checked functions needs any of these.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { pathToFileURL } from 'node:url';
import { stripTypeScriptTypes } from 'node:module';

const SHARED_IMPORT = /^[ \t]*import\s*\{([^}]*)\}\s*from\s*(["'])\.\.\/_shared\/([\w-]+)\.ts\2[ \t]*;?/gm;
const EXPORT_DECL = /^export\s+(?:async\s+)?(?:function\b\s*\*?|const\b|let\b|var\b|class\b)\s*([\w$]+)/gm;
const EXPORT_LIST = /^export\s*\{([^}]*)\}/gm;
const readShared = (f) => fs.readFileSync(new URL(`../../supabase/functions/_shared/${f}.ts`, import.meta.url), 'utf8');

function exportsOf(js) {
  const names = new Set([...js.matchAll(EXPORT_DECL)].map((m) => m[1]));
  const live = new Set([...js.matchAll(EXPORT_DECL)].filter((m) => /^export\s+(let|var)\b/.test(m[0])).map((m) => m[1]));
  for (const [, list] of js.matchAll(EXPORT_LIST))
    for (const spec of list.split(',').map((s) => s.trim())) if (/^[\w$]+$/.test(spec)) names.add(spec);
  return { names, live };
}

export function edgeVmSource(ts, read = readShared) {
  const helpers = new Map();  // helper file -> { names imported from it, bindings as the function named them }
  const body = stripTypeScriptTypes(ts).replace(SHARED_IMPORT, (_, list, _q, f) => {
    const h = helpers.get(f) ?? helpers.set(f, { names: new Set(), binds: [] }).get(f);
    for (const spec of list.split(',').map((s) => s.trim()).filter(Boolean)) {
      const [name, as = name] = spec.split(/\s+as\s+/);
      h.names.add(name); h.binds.push(as === name ? name : `${name}: ${as}`);
    }
    return '';
  });
  const files = [...helpers];
  const shared = files.map(([f, h]) => {
    const js = stripTypeScriptTypes(read(f)), exported = exportsOf(js);
    for (const n of h.names) {
      if (!exported.names.has(n))
        throw new SyntaxError(`The requested module '../_shared/${f}.ts' does not provide an export named '${n}'`);
      if (exported.live.has(n))
        throw new Error(`'${n}' is an export let/var in ../_shared/${f}.ts: this harness would copy it once, not bind it live`);
    }
    return `(() => {\n${js.replace(/^export /gm, '')}\nreturn { ${[...h.names].join(', ')} };\n})()`;
  });
  return `"use strict";\nconst __edgeVmShared = [${shared.join(',\n')}];\n{\n`
    + files.map(([, h], i) => `const { ${h.binds.join(', ')} } = __edgeVmShared[${i}];\n`).join('')
    + `${body}\n}`;
}

// self-check, on inline fixtures (h: a helper with a private name; n: imports; p: uses a name it never declares;
// s: uses `a` without importing it; l: an export list)
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const H = { h: 'const PRIVATE: number = 2;\nexport function a(x: number) { return x * PRIVATE; }\nexport const b = 5;\n'
                + 'export async function later() { return 9; }\nexport let n = 0;',
              n: 'import { z } from "npm:z";\nexport const c = 1;',
              p: 'export function tag(x: string) { return PREFIX + x; }',
              s: 'export function viaA() { return a(5); }',
              l: 'const k = 7;\nexport { k };' };
  let reads = 0;
  const run = (ts) => vm.runInNewContext(edgeVmSource(ts, (f) => (reads++, H[f])), {});
  // multi-line braces, CRLF, single quotes, an alias, a type-only import, an inline type, two lines from one helper
  assert.strictEqual(run('import type { T } from "../_shared/h.ts";\r\nimport {\r\n  a,\r\n  b as bee,\r\n} from \'../_shared/h.ts\'\r\n'
    + 'import { type T2, a as twice } from "../_shared/h.ts";\nconst n: number = 1;\n[a(n), bee, twice(3)].join()'), '2,5,6');
  assert.strictEqual(reads, 1, 'a helper imported on several lines is read once');
  assert.strictEqual(run('import { k } from "../_shared/l.ts";\nk'), 7);
  assert.strictEqual(typeof run('import { later } from "../_shared/h.ts";\nlater'), 'function');  // export async function
  // a function's own top-level name is reachable only through the source's completion value
  assert.strictEqual(run('import { a } from "../_shared/h.ts";\nfunction own() { return a(2); }\n;({ own })').own(), 4);
  // an export let/var would be a frozen copy here and a live binding in Deno: refused
  assert.throws(() => run('import { n } from "../_shared/h.ts";\nn'), { message: /export let\/var/ });
  // a private name, or an exported one the function never imported, is not visible; importing a private one fails
  assert.throws(() => run('import { a } from "../_shared/h.ts";\nPRIVATE'), { name: 'ReferenceError' });
  assert.throws(() => run('import { a } from "../_shared/h.ts";\nb'), { name: 'ReferenceError' });
  assert.throws(() => run('import { PRIVATE } from "../_shared/h.ts";\nPRIVATE'),
    { name: 'SyntaxError', message: /does not provide an export named 'PRIVATE'/ });
  // a helper sees none of the function's names (const, or a function declaration) nor another helper's imports
  assert.throws(() => run('import { tag } from "../_shared/p.ts";\nconst PREFIX = "P-";\ntag("x")'), { name: 'ReferenceError' });
  assert.throws(() => run('import { tag } from "../_shared/p.ts";\nfunction PREFIX() {}\ntag("x")'), { name: 'ReferenceError' });
  assert.throws(() => run('import { a } from "../_shared/h.ts";\nimport { viaA } from "../_shared/s.ts";\nviaA()'),
    { name: 'ReferenceError' });
  // any other import, in the function or inside a helper, still fails
  const NO_IMPORT = { name: 'SyntaxError', message: /Cannot use import statement outside a module/ };
  assert.throws(() => run('import { a } from "../_shared/h.ts";\nimport x from "npm:x";\na(1)'), NO_IMPORT);
  assert.throws(() => run('import { c } from "../_shared/n.ts";\nc'), NO_IMPORT);
  console.log('edge_vm_source: self-check passed');
}
