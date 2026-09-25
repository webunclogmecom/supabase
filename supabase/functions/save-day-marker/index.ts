// ============================================================================================
// save-day-marker — the Visit Calendar's ONLY door for changing a day marker (2026-09-24)
// --------------------------------------------------------------------------------------------
// Fred: "I was thinking that we do like with the visits, that it first confirms the data was changed
// in jobber being reflected in the app/db".
// Design: Building Apps/Visit Calendar/docs/specs/2026-09-24-jobber-first-day-markers-design.md
// Migration: docs/migrations/2026-09-24_2100_jobber_first_day_markers.sql
//
//     claim the marker -> push to Jobber -> READ THE TASK BACK -> only then commit (row + link, one txn)
//     on ANY failure: the marker is left as it was, and the app shows the typed error
//
// The saga itself is ../_shared/day-marker-task.ts saveMarker(), shared with heal-day-starts; this file
// is the browser door: auth, the request shape, the response.
//
// REQUEST (POST, JSON):
//   { op: "create", marker: {marker_type, marker_date, minutes, employee_id?, vehicle_id?, dump_site?,
//                            source_visit_id?, eta_minutes?, eta_computed_at?}, replace_marker_id? }
//   { op: "update", marker_id, patch: {marker_date?, minutes?, employee_id?, source_visit_id?,
//                                      eta_minutes?, eta_computed_at?}, replace_marker_id? }
//   { op: "delete", marker_id }
// replace_marker_id is the marker that already holds the slot (409 already_exists names it):
//   create  -> that marker takes the new values IN PLACE (same row, same Jobber Task)
//   update  -> (a move onto an occupied slot) that marker takes this one's values, then this one goes
//
// RESPONSE: 200 {ok:true, op, outcome, marker_id, marker, jobber_task, ...}; otherwise a real HTTP status
// with {ok:false, code, message, ...} in the body. `message` is a plain sentence the app shows as is.
// supabase-js functions.invoke() resolves a non-2xx as a FunctionsHttpError with data:null: read the body
// with `await error.context.json()` (the same as save-calendar-task).
//   400 invalid_input · 401 unauthorized · 403 forbidden · 404 not_found
//   409 already_exists (blocking_marker_id, blocking) · 409 changed_elsewhere · 409 busy
//   502 jobber_rejected / jobber_unavailable / jobber_unverified · 503 lookup_failed
//   500 db_error / partly_moved / unexpected / commit_unknown · 503 too_slow
// A failure that may have left the Jobber Task different from the row carries a message saying so (Jobber
// is corrected automatically within minutes by start-push-retry, from the claim the save leaves behind).
//
// AUTH — verify_jwt = false, DELIBERATE, the same as save-calendar-task (read its header): this project
// signs session tokens with ES256 and the gateway rejects them on newer deployments. The control is
// IN-HANDLER auth.getUser() + the @ayache.com / @unclogme.com gate. A service-role key carries no email
// and is refused 403: the healer calls the shared saga directly, never this door.
// ============================================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { saveMarker, CREATE_KEYS } from "../_shared/day-marker-task.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (status: number, code: string, message: string) => json({ ok: false, code, message }, status);

const UPDATE_KEYS = ["marker_date", "minutes", "employee_id", "source_visit_id", "eta_minutes", "eta_computed_at"];
const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);
const isPosInt = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v > 0;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail(405, "method_not_allowed", "POST only.");

  // ---- AUTH: a real, staff-domain human. Never service_role-by-default. --------------------
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return fail(401, "unauthorized", "Sign in again.");
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const email = (userData?.user?.email ?? "").toLowerCase();
  if (userErr || !email || (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return fail(403, "forbidden", "Not a staff account.");
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail(400, "bad_request", "Malformed JSON."); }
  if (!isObj(body)) return fail(400, "bad_request", "Body must be a JSON object.");

  const op = body.op;
  if (op !== "create" && op !== "update" && op !== "delete") {
    return fail(400, "bad_request", "op must be create, update or delete.");
  }
  const replace = body.replace_marker_id ?? null;
  if (replace !== null && !isPosInt(replace)) return fail(400, "bad_request", "replace_marker_id must be a marker id.");
  if (op !== "create" && !isPosInt(body.marker_id)) return fail(400, "bad_request", "marker_id is required.");
  if (replace !== null && replace === body.marker_id) return fail(400, "bad_request", "A marker cannot replace itself.");

  // The shape, before anything reaches Jobber. The shared saga validates the resulting row.
  let values: Record<string, unknown> | undefined;
  let patch: Record<string, unknown> | undefined;
  if (op === "create") {
    if (!isObj(body.marker)) return fail(400, "bad_request", "marker must be an object.");
    const extra = Object.keys(body.marker).filter((k) => !CREATE_KEYS.includes(k));
    if (extra.length) return fail(400, "invalid_input", `These marker fields cannot be set: ${extra.join(", ")}.`);
    values = body.marker;
  } else if (op === "update") {
    if (!isObj(body.patch) || Object.keys(body.patch).length === 0) return fail(400, "bad_request", "patch must name what changes.");
    const extra = Object.keys(body.patch).filter((k) => !UPDATE_KEYS.includes(k));
    if (extra.length) return fail(400, "invalid_input", `These marker fields cannot be changed: ${extra.join(", ")}.`);
    patch = body.patch;
  } else if (replace !== null) {
    return fail(400, "bad_request", "A delete does not replace anything.");
  }

  const t0 = Date.now();
  const r = await saveMarker({
    op, markerId: (body.marker_id as number | undefined) ?? null, values, patch,
    replaceMarkerId: replace as number | null, heal: null, holder: "save-day-marker",
  });
  // Attribution: ops.calendar_day_markers is audit opt-out (dispatch state), so the edge log is the record.
  console.log(`[save-day-marker] ${email} ${op} marker=${body.marker_id ?? "new"}${replace ? ` replace=${replace}` : ""} -> ` +
    `${r.ok ? `${r.outcome} id=${r.marker_id} task=${r.jobber_task}` : `${r.code}${r.dirty ? " (claim left for the retry)" : ""}`} ${Date.now() - t0}ms`);

  if (r.ok) return json(r);
  const { status, dirty: _dirty, ok: _ok, ...rest } = r;
  return json({ ok: false, ...rest }, status);
});
