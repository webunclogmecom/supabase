// measure-page-reference: measures the printed lines of ONE Stamp Studio page in the background, so the
// page has a machine reference before (and whatever) a person draws.
//
// Fred, 2026-10-05: "yes measure in the background". The Studio's in-app Re-measure was removed the same
// day; with it went the only independent check on where a person draws the bands. derm.save_page_bands
// refuses a drawn row that crosses a measured line between two clients, but only when the scan has a
// measurement graded OK. This function supplies that measurement for every page of every sheet that is
// not completed. It also pre-draws the lines when Draw the bands opens on a page nobody has drawn yet.
//
// THE SAME TWO STEPS THE APP RAN, server side:
//   detectRules  (_shared/printed_rule_detector.mjs, the pixel pass; also used by measure-generated-page)
//   classifyPage (_shared/printed_rule_classifier.mjs, the labelling pass, extracted by script from the
//                 app's reference copy)
// with the page's current Limit as the window when it has one, exactly as the app did, else none.
// Proven equal to the app's own measurements on 8 real scans: scripts/checks/page_reference_classifier.mjs.
//
// This function decides nothing and writes nothing itself: it hands the result to
// derm.fn_page_reference_measured, which records it through derm.record_page_rules as a runlen-v2 scan
// (below human-v1 and template-v1, so it never replaces lines a person or the generated-sheet finisher
// recorded). A failed fetch or decode is reported too, so the attempt ledger says why.
//
// INVOKED BY pg_cron (public.fn_request_page_reference_measure) with a service_role bearer, one page per
// call, body {dump_folder, page, image_url, top_pct?, bottom_pct?}. The cron records the attempt BEFORE
// asking, so a worker that dies here still consumes its budget (three per image).
// AUTH: verify_jwt=true (config.toml) PLUS the in-handler role gate.

import jpeg from "npm:jpeg-js@0.4.4";
import { detectRules } from "../_shared/printed_rule_detector.mjs";
import { classifyPage } from "../_shared/printed_rule_classifier.mjs";

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

async function report(body: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_page_reference_measured`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json", "Content-Profile": "derm",
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "x-app-source": "measure-page-reference",
    },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  let parsed: unknown = text;
  try { parsed = JSON.parse(text); } catch { /* keep the raw text */ }
  return { ok: r.ok, status: r.status, result: parsed };
}

const num = (v: unknown) => (v === null || v === undefined || v === "" || !isFinite(Number(v)) ? null : Number(v));

Deno.serve(async (req) => {
  if (bearerRole(req) !== "service_role") return json({ error: "service_role required" }, 403);
  // deno-lint-ignore no-explicit-any
  let body: any;
  try { body = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const dumpFolder = String(body?.dump_folder ?? "").trim();
  const page = Number(body?.page);
  const imageUrl = String(body?.image_url ?? "").trim();
  if (!/^[A-Za-z0-9/_-]{3,60}$/.test(dumpFolder)) return json({ error: "need a dump_folder" }, 400);
  if (!Number.isInteger(page) || page < 1 || page > 9) return json({ error: "need page 1..9" }, 400);
  // the two public buckets the Studio's scans live in (older sheets: "GT - Visits Images", 99 of 203)
  const allowed = ["manifests", "GT%20-%20Visits%20Images"].map((b) => `${SUPABASE_URL}/storage/v1/object/public/${b}/`);
  if (!allowed.some((a) => imageUrl.startsWith(a))) return json({ error: "image_url must be a public scan object" }, 400);
  const top = num(body?.top_pct), bot = num(body?.bottom_pct);
  const win = top !== null && bot !== null && top < bot ? { top, bot } : { top: null, bot: null };

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
    if (!(bytes[0] === 0xff && bytes[1] === 0xd8)) throw new Error(`not a JPEG (content-type ${ct || "?"}); only JPEG scans are measured`);
    raw = jpeg.decode(bytes, { useTArray: true, maxMemoryUsageInMB: 1024 });
  } catch (e) {
    const handoff = await report({ ...base, p_result: null, p_error: String(e).slice(0, 300) });
    return json({ ok: false, stage: "fetch", error: String(e).slice(0, 300), handoff });
  }
  const r = classifyPage({ ...detectRules(raw, win.top, win.bot), top: win.top, bot: win.bot });
  const result = {
    grade: r.grade, detail: r.detail, rules: r.rules ?? [],
    image_w: r.W, image_h: r.H, skew: r.skew, window: win, ms: Date.now() - t0,
  };
  const handoff = await report({ ...base, p_result: result, p_error: null });
  return json({ ok: handoff.ok, dump_folder: dumpFolder, page, grade: r.grade, lines: (r.rules ?? []).length, ms: result.ms, handoff });
});
