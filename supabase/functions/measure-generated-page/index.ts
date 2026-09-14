// measure-generated-page: runs the printed-rule detector on ONE page of a GENERATED DERM address
// sheet and hands the raw lines to derm.fn_generated_page_measured, which decides everything.
// This function classifies nothing and writes nothing itself.
//
// WHY IT IS THIS THIN. The decision (which lines are the six printed boundaries, whether the
// stamps sit inside them, whether anything may be written) lives in SQL, where it was replayed
// over the whole accepted corpus before it shipped (scripts/probes/generated_finisher/phase0_report.md)
// and is exercised by migration 2026-09-14_0615's VERIFY. The only work that needs a runtime with a
// JPEG decoder is fetching the scan and running the detector, and the detector is the SAME module
// the Node probe runs: supabase/functions/_shared/printed_rule_detector.mjs.
//
// INVOKED BY pg_cron (public.fn_request_generated_measure) with a service_role bearer, one page per
// call, body {dump_folder, ticket, page, image_url}. The cron records the attempt BEFORE asking, so
// a worker that dies here still consumes its budget (three per image).
//
// A FAILED FETCH OR DECODE IS STILL REPORTED: the RPC is called with p_lines null and meta.error,
// so the ledger reads "could not be read" instead of the page sitting at "requested" for ever.
//
// AUTH: verify_jwt=true (config.toml) PLUS the in-handler role gate. The anon key is a validly
// signed JWT, so the gateway check alone is half a gate.

import jpeg from "npm:jpeg-js@0.4.4";
import { detectRules } from "../_shared/printed_rule_detector.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MAX_IMAGE_BYTES = 12 * 1024 * 1024;

function json(p: unknown, status = 200): Response {
  return new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });
}
function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}
const dermHeaders = {
  "Content-Type": "application/json",
  "Content-Profile": "derm",
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
};

// The hand-off. Everything after this line is the database's decision.
async function report(body: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_generated_page_measured`, {
    method: "POST", headers: dermHeaders, body: JSON.stringify(body),
  });
  const text = await r.text();
  let parsed: unknown = text;
  try { parsed = JSON.parse(text); } catch { /* keep the raw text */ }
  return { ok: r.ok, status: r.status, result: parsed };
}

Deno.serve(async (req) => {
  if (bearerRole(req) !== "service_role") return json({ error: "service_role required" }, 403);
  let body: { dump_folder?: string; page?: number; image_url?: string; ticket?: string };
  try { body = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const dumpFolder = String(body?.dump_folder ?? "").trim();
  const page = Number(body?.page);
  const imageUrl = String(body?.image_url ?? "").trim();
  if (!/^ticket-\d{4,8}$/.test(dumpFolder)) return json({ error: "need dump_folder 'ticket-<digits>'" }, 400);
  if (!Number.isInteger(page) || page < 1 || page > 9) return json({ error: "need page 1..9" }, 400);
  // only our own public manifests bucket: anything else is not a scan of ours
  const allowed = `${SUPABASE_URL}/storage/v1/object/public/manifests/`;
  if (!imageUrl.startsWith(allowed)) return json({ error: "image_url must be a public manifests object" }, 400);

  const base = { p_dump_folder: dumpFolder, p_page: page, p_image_url: imageUrl };
  const t0 = Date.now();
  // deno-lint-ignore no-explicit-any
  let raw: any;
  try {
    const img = await fetch(imageUrl);
    if (!img.ok) throw new Error(`image HTTP ${img.status}`);
    const ct = (img.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
    const bytes = new Uint8Array(await img.arrayBuffer());
    if (bytes.length > MAX_IMAGE_BYTES) throw new Error(`image is ${bytes.length} bytes, over the ${MAX_IMAGE_BYTES} limit`);
    if (!(bytes[0] === 0xff && bytes[1] === 0xd8)) throw new Error(`not a JPEG (content-type ${ct || "?"}); only JPEG scans are measured automatically`);
    raw = jpeg.decode(bytes, { useTArray: true });
  } catch (e) {
    const handoff = await report({ ...base, p_lines: null, p_meta: { error: String(e).slice(0, 300), ms: Date.now() - t0 } });
    return json({ ok: false, stage: "fetch", error: String(e).slice(0, 300), handoff });
  }
  const r = detectRules(raw);
  const handoff = await report({
    ...base,
    p_lines: r.rules,
    p_meta: { image_w: r.W, image_h: r.H, skew: r.skew, detector: "printed_rule_detector.mjs", ms: Date.now() - t0 },
  });
  return json({ ok: handoff.ok, dump_folder: dumpFolder, page, lines: r.rules.length, ms: Date.now() - t0, handoff });
});
