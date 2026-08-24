// Assembles supabase/functions/fp-gdo-evidence/index.ts.
// The CORS helpers are SPLICED byte-identically from save-client-property so every function in this
// repo answers preflight the same way. Run: node scripts/probes/build_fp_gdo_evidence.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const src = readFileSync('supabase/functions/save-client-property/index.ts', 'utf8');
const START = '// ---- CORS (echo the requested headers';
const END = '// ---- Jobber WRITE token';
const i = src.indexOf(START), j = src.indexOf(END);
if (i < 0 || j < 0 || j <= i) throw new Error('CORS splice anchors not found');
const CORS = src.slice(i, j).trimEnd() + '\n';
for (const must of ['corsPreflight', 'hdrs()', 'function fail(', 'function done(']) {
  if (!CORS.includes(must)) throw new Error(`spliced CORS block is missing ${must}`);
}
console.log(`spliced ${CORS.length} bytes of CORS helpers, 4/4 markers present`);

const HEAD = `// fp-gdo-evidence — hand the CUSTOMER portal a short-lived signed URL for ONE permit's
// GDO filing image.
//
// WHY (Fred, 2026-08-24, on https://fp.unclogme.app/043-mil/visit/qpUrslVPtH = visit 6617):
//      "I don't see the evidence of the GDO Online Report ... the evidence should be displayed on
//      the FP App, and also it should be separated by their GDO, so we know."
//
// 🛑 THE FIELD PORTAL RUNS AS **anon**, AND rpa-evidence IS PRIVATE.
//    Its only SELECT policy is \`rpa_evidence_staff_read\` for {authenticated}. So the portal cannot
//    read the object at all, and \`customer.get_work_order\` deliberately returns only the boolean
//    \`has_report_image\` — never a path. This function is the ONLY bridge, and it exists so the
//    bucket can stay private.
//
// 🛑 THE PATH IS NEVER TAKEN FROM THE CALLER. It is derived server-side from (public_id, gdo_id).
//    Accepting a client-supplied path would turn a shareable report link into a read primitive over
//    the entire private bucket. There is no parameter here that can name another object.
//
// ⚠ THE VISIT SLUG IS THE CAPABILITY, and that is a deliberate, unchanged trust boundary: whoever
//    holds \`public_id\` already sees the whole service report at that URL. This adds that visit's own
//    filing image to what they can already see, and nothing else.
//
// ⚠ SUCCESS ROWS ONLY. A failed attempt's screenshot is a portal login-error page. It is not
//    evidence, it is internal, and the customer has no business seeing it.
//
// ⚠ NOT IMPLEMENTED, AND KNOWN: there is no rate limiting. The slug is unguessable and already
//    gates the full report, so this does not widen the surface — but if report links are ever
//    published or indexed, revisit this before anything else.
//
// ⚠ ASSUMPTION RECORDED (Fred's explicit call, 2026-08-24): GDO evidence images are single-facility,
//    because a submission is per (visit, run, gdo_id) and the bot files one permit per run. He chose
//    to proceed on that reasoning rather than have the images opened first. It matters because the
//    DERM *Address sheet* IS shared across a dump run and does leak other clients, which is why the
//    city gets a blacked-out copy. If any GDO evidence image is found to show a second facility,
//    disable this function immediately.
import { createClient } from "jsr:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-app-source": "field-portal" } } },
);

`;

const BODY = readFileSync('scripts/probes/fp_gdo_evidence_body.ts.part', 'utf8');
mkdirSync('supabase/functions/fp-gdo-evidence', { recursive: true });
writeFileSync('supabase/functions/fp-gdo-evidence/index.ts', HEAD + CORS + BODY);

const out = readFileSync('supabase/functions/fp-gdo-evidence/index.ts', 'utf8');
if (!out.includes(CORS)) throw new Error('CORS block is not byte-identical in the output');
console.log('wrote supabase/functions/fp-gdo-evidence/index.ts, splice verified');
