// fp-gdo-evidence — hand the CUSTOMER portal a short-lived signed URL for ONE permit's
// GDO filing image.
//
// WHY (Fred, 2026-08-24, on https://fp.unclogme.app/043-mil/visit/qpUrslVPtH = visit 6617):
//      "I don't see the evidence of the GDO Online Report ... the evidence should be displayed on
//      the FP App, and also it should be separated by their GDO, so we know."
//
// 🛑 THE FIELD PORTAL RUNS AS **anon**, AND rpa-evidence IS PRIVATE.
//    Its only SELECT policy is `rpa_evidence_staff_read` for {authenticated}. So the portal cannot
//    read the object at all, and `customer.get_work_order` deliberately returns only the boolean
//    `has_report_image` — never a path. This function is the ONLY bridge, and it exists so the
//    bucket can stay private.
//
// 🛑 THE PATH IS NEVER TAKEN FROM THE CALLER. It is derived server-side from (public_id, gdo_id).
//    Accepting a client-supplied path would turn a shareable report link into a read primitive over
//    the entire private bucket. There is no parameter here that can name another object.
//
// ⚠ THE VISIT SLUG IS THE CAPABILITY, and that is a deliberate, unchanged trust boundary: whoever
//    holds `public_id` already sees the whole service report at that URL. This adds that visit's own
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

// ---- CORS (echo the requested headers — the save-calendar-visit lesson) ----
const ALLOW_FALLBACK = "authorization, x-client-info, apikey, content-type, x-supabase-api-version";
function corsPreflight(req: Request) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": req.headers.get("access-control-request-headers") ?? ALLOW_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
}
function hdrs() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": ALLOW_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
  };
}
function fail(code: string, message: string, extra: Record<string, unknown> = {}) {
  return new Response(JSON.stringify({ ok: false, code, message, ...extra }), { status: 200, headers: hdrs() });
}
function done(body: Record<string, unknown>) {
  return new Response(JSON.stringify({ ok: true, ...body }), { status: 200, headers: hdrs() });
}

// ============================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPreflight(req) });
  if (req.method !== "POST") return fail("method_not_allowed", "POST only.");

  const body = await req.json().catch(() => null);
  const publicId = String(body?.public_id ?? "").trim();
  const gdoId = body?.gdo_id == null ? null : Number(body.gdo_id);

  if (!publicId) return fail("bad_request", "public_id is required.");
  if (gdoId == null || !Number.isFinite(gdoId)) return fail("bad_request", "gdo_id is required.");

  // 🛑 THE SLUG IS THE CAPABILITY, AND THE PATH IS NEVER TAKEN FROM THE CALLER.
  //    Everything below is derived server-side from (public_id, gdo_id). A caller cannot ask for an
  //    arbitrary object: if it is not the screenshot belonging to THIS visit and THIS permit, there
  //    is no way to name it. Accepting a path here would turn a report link into a read primitive
  //    over the whole private bucket.
  const { data: visit, error: vErr } = await db
    .from("visits").select("id, public_id, deleted_at")
    .eq("public_id", publicId).is("deleted_at", null).maybeSingle();
  // 🛑 DESTRUCTURE THE ERROR. A discarded error yields data:null and the guard fails OPEN.
  if (vErr) return fail("lookup_failed", "Could not load that report.");
  if (!visit) return fail("not_found", "That report link is not valid.");

  // The submission for THIS visit and THIS permit. SUCCESS only: a failed attempt's screenshot is a
  // login-error page, which is not evidence and is not the customer's business.
  const { data: sub, error: sErr } = await db
    .from("derm_portal_submissions")
    .select("screenshot_path, status, dry_run, gdo_id, visit_id")
    .eq("visit_id", visit.id).eq("gdo_id", gdoId).eq("dry_run", false)
    .eq("status", "SUCCESS").not("screenshot_path", "is", null)
    .order("attempted_at", { ascending: false }).limit(1).maybeSingle();
  if (sErr) return fail("lookup_failed", "Could not load that report.");
  if (!sub?.screenshot_path) {
    return fail("no_evidence", "There is no filing image for that permit on this visit.");
  }

  // ⚠ BELT AND BRACES: re-assert the row we got back really belongs to the visit and permit we
  //    resolved. The filters above should make this impossible to violate; that is exactly why it is
  //    cheap to check, and why a violation would mean something is badly wrong.
  if (Number(sub.visit_id) !== Number(visit.id) || Number(sub.gdo_id) !== gdoId) {
    return fail("mismatch", "That filing image does not belong to this report.");
  }

  // Short TTL. The image is re-signed on each view; nothing durable is handed out.
  const { data: signed, error: signErr } = await db.storage
    .from("rpa-evidence").createSignedUrl(sub.screenshot_path, 300);
  if (signErr || !signed?.signedUrl) {
    return fail("sign_failed", "Could not open that filing image. Try again.");
  }

  return done({ url: signed.signedUrl, expires_in: 300 });
});
