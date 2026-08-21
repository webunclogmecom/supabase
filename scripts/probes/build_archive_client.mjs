// Assembles supabase/functions/archive-client/index.ts.
//
// The CORS / token / gql / userErrors helpers are SPLICED BYTE-IDENTICALLY out of
// save-client-property, never retyped. That file's own header records why: a retyped body silently
// drops whatever you fail to reproduce, and in this case that would include the content-type guard
// against Jobber's HTML waiting room. The splice is asserted at assembly time and again after write.
//
// Run: node scripts/probes/build_archive_client.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const src = readFileSync('supabase/functions/save-client-property/index.ts', 'utf8');
const START = '// ---- CORS (echo the requested headers';
const END = 'function ue(payload: any): string | null {';
const i = src.indexOf(START), j = src.indexOf(END);
if (i < 0 || j < 0 || j <= i) throw new Error('splice anchors not found in save-client-property');
const tail = src.indexOf('\n}\n', j) + 3;
const HELPERS = src.slice(i, tail);
for (const must of ['corsPreflight', 'hdrs()', 'function fail(', 'function done(', 'getJobberToken',
                    'async function gql', 'content-type', 'THROTTLED', 'function ue(']) {
  if (!HELPERS.includes(must)) throw new Error(`spliced block is missing ${must} - refusing to write`);
}
console.log(`spliced ${HELPERS.length} bytes of helpers, all 9 markers present`);

const HEAD = readFileSync('scripts/probes/archive_client_head.ts.part', 'utf8');
const BODY = readFileSync('scripts/probes/archive_client_body.ts.part', 'utf8');

mkdirSync('supabase/functions/archive-client', { recursive: true });
writeFileSync('supabase/functions/archive-client/index.ts', HEAD + HELPERS + BODY);

const out = readFileSync('supabase/functions/archive-client/index.ts', 'utf8');
if (!out.includes(HELPERS)) throw new Error('the spliced helpers are not byte-identical in the output');
console.log('wrote supabase/functions/archive-client/index.ts, splice verified byte-identical');
