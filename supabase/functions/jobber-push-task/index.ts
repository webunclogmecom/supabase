// ============================================================================
// jobber-push-task — Calendar day markers → Jobber TASKS: the NET (Fred, 2026-08-06; 2026-09-24)
// ----------------------------------------------------------------------------
// Mirrors ops.calendar_day_markers (the Day Start / End / Dump route markers) into Jobber as Tasks, so
// the crew sees the shape of the day on their own schedule. The Calendar is the MASTER; Jobber follows.
//
// 🛑 SINCE 2026-09-24 (migration 2026-09-24_2100) THIS IS THE NET, NOT THE MAIN PATH. A person's change
// goes through the edge fn save-day-marker and the Start healer's through heal-day-starts: both push to
// Jobber, read back and only then commit (Jobber first, like the visits). This function is still called
// for anything that writes the table in SQL:
//   * trg_push_marker_to_jobber -> public.fn_request_marker_push (pg_net), skipped for a saga's own commit;
//   * ops.retry_marker_pushes (cron start-push-retry): a failed delete, an edit that did not land, and a
//     claim left behind by an interrupted save.
//
//   op = 'upsert' -> make the Task match the row: edit it, or create it (no link yet, or deleted by hand
//                    in Jobber), read it back, commit the link through ops.save_day_marker('relink')
//   op = 'delete' -> the marker is gone: taskDelete, read back until proven gone, then drop the link
//
// Everything a marker's Task is (title, window, assignees, the read-back) and every Jobber and database
// step lives in ../_shared/day-marker-task.ts, the ONE definition, shared with save-day-marker and
// heal-day-starts. It CLAIMS the marker first (one writer per marker), so this can no longer overtake a
// save and leave Jobber a version behind. A marker another writer holds answers {ok:false, busy:true}:
// that writer's commit, or the next retry, covers it.
//
// 🛑 WHY TASKS AND NOT EVENTS — measured against the live API, and it CONTRADICTS Jobber AI, which
// recommended Events. The API exposes taskCreate / taskEdit / taskDelete but only **eventCreate**.
// Markers get dragged and removed constantly, so an Event-backed marker would strand an un-editable,
// un-deletable ghost on the crew's schedule on every move.
//
// AUTH: invoked by a DB trigger (pg_net) with a service_role bearer. Deployed verify_jwt=true, and the
// handler ALSO asserts role=service_role — the anon key is a validly signed JWT, so the gateway check
// alone is half a gate.
// ============================================================================
import { syncMarkerTask } from "../_shared/day-marker-task.ts";

function bearerRole(req: Request): string | null {
  const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const p = tok.split(".");
  if (p.length !== 3) return null;
  try {
    const pad = p[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(pad + "=".repeat((4 - (pad.length % 4)) % 4)))?.role ?? null;
  } catch { return null; }
}

function json(b: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });
  if (bearerRole(req) !== "service_role") return json({ ok: false, error: "forbidden" }, 403);

  let body: { op?: string; marker_id?: number };
  try { body = await req.json(); } catch { return json({ ok: false, error: "invalid json" }, 400); }
  const op = body.op, markerId = Number(body.marker_id);
  if (!Number.isInteger(markerId) || markerId <= 0 || (op !== "upsert" && op !== "delete")) {
    return json({ ok: false, error: "need { op: 'upsert'|'delete', marker_id }" }, 400);
  }
  // Always 200: pg_net only records the reply, and the body says what happened.
  return json(await syncMarkerTask(op, markerId));
});
