// ============================================================================
// save-calendar-visit — VERIFIED-THEN-COMMITTED Calendar write (Fred, 2026-07-29)
// ============================================================================
// Fred: "when we make changes in the Calendar App that get pushed to Jobber, and if there is any
// issue that doesn't let us, then to show the error toast/popup about it, and to NOT save that in
// our db, it can be kept on the Drawer as dirty data, so the user can click save again."
//
// TODAY'S PATH CANNOT DO THAT, structurally. The app calls edit_calendar_visit, a trigger fires
// fn_push_visit_to_jobber, and that pushes via net.http_post — pg_net QUEUES and returns, so the
// transaction commits before Jobber has said anything. There is no patch to the trigger that makes
// it verified. Hence this function: the app awaits it, and our DB is written only after Jobber has
// confirmed.
//
// ORDER (the whole point):
//   1. partition the patch into pushable vs local-only
//   2. PRE-FLIGHT validate every pushable group           <- before ANY mutation
//   3. push the changed groups to Jobber
//   4. RE-READ Jobber and verify                          <- "200" is not acceptance
//   5. only then write our DB, with the push trigger suppressed
//
// ⚠ WHY PRE-FLIGHT MATTERS, with a real example. Jobber has no multi-mutation transaction, so a
// save touching schedule AND crew can leave Jobber half-updated. The existing push MANUFACTURES that
// state: it calls assertTeamMapped() INSIDE the crew branch, i.e. after visitEditSchedule has
// already landed. Validating everything first converts the commonest failure (an unmapped employee)
// from a half-applied push into a clean refusal with nothing written on either side.
// Compensating rollback was considered and REJECTED: undoing the schedule is another call that can
// itself fail, leaving three states and no way to tell which.
//
// ⚠ RESIDUAL, AND IT IS REPORTED HONESTLY, NOT HIDDEN. A transient failure between mutation 1 and 2
// (network drop, 5xx) can still half-apply. That returns code 'partial_push' WITH `applied[]` and
// `failed`, so the UI can say "the date was saved in Jobber but the crew was not" instead of a bare
// "failed", which would be a lie about a reachable state.
//
// ⚠ SCOPE OF v1 — LINE ITEMS ARE NOT VERIFIED. syncVisitLineItems() in jobber-push-visit reads
// `line_items` from the DB by visit_id, so pushing a line-item change before writing our DB is
// impossible without reworking it. A patch containing line-item keys therefore returns
// 'lineitems_unsupported' and writes NOTHING; the caller should use the existing (unverified) path
// for those until phase 2. Shipping a partial guarantee silently would be worse than refusing.
//
// LOCAL-ONLY FIELDS: vehicle_id (truck) and driver_id. Neither is a Jobber field, and neither bumps
// a watched column, so the trigger never pushes them. A patch containing ONLY these must take the
// plain local write and NEVER contact Jobber — an early draft treated that as 'nothing_to_push' and
// refused the save, which would have silently discarded every truck reassignment. (Caught by
// @Building Apps in review, 2026-07-29.)
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

// ⚠ x-app-source IS REQUIRED, and its absence was a real regression (found by @Building Apps).
// audit.log_change() derives app_source from the request Origin, and this function is server-to-server
// with NO browser Origin, so every verified save fell through the CASE to app_source='sql' -- i.e.
// indistinguishable from an engineer running SQL by hand. Before the verified path, the Calendar wrote
// via PostgREST from the browser and attributed correctly ('visit-calendar', 2,064 rows). ADR 016 makes
// the explicit header an override that wins over Origin, which is exactly what a headless writer needs.
// Same idiom as dump-visit-create ('dump-schedule') and rpa-derm-queue ('gdo-report-bot').
//
// ⚠ THIS RESTORES THE APP, NOT THE PERSON. jwt_claims still comes from the service_role token, so
// jwt_claims->>'email' remains NULL and get_record_history cannot name which dispatcher made the
// change. Per-user attribution needs the human's identity carried explicitly (the pattern
// send-derm-email uses with sent_by_email/sent_by_user_id, 2026-07-21h) because
// edit_calendar_visit_verified is deliberately service_role-only and so cannot be called with the
// caller's own JWT. `visits` has no such column today. Tracked as an open item, NOT fixed here.
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-app-source": "visit-calendar" } } },
);
const GQL_VERSION = "2026-04-16";

// ⚠ CORS. The Calendar calls this from a BROWSER, which sends an OPTIONS preflight first (custom
// headers + JSON content-type). Without this the preflight got 405, the POST was never sent, and the
// feature was 100% unreachable from the only surface that matters — while every server-side test
// passed, because server-to-server calls do not preflight. Found by @Building Apps driving a real
// Save, not by any backend test, and it could not have been found by one.
// These headers must be on EVERY response, not just the OPTIONS reply: a POST answer without them is
// blocked by the browser after the fact, which looks identical to a network failure.
// ⚠ ECHO the requested headers; do NOT hardcode the list.
// First attempt hardcoded "authorization, x-client-info, apikey, content-type" and the preflight
// returned 200 — but supabase-js still failed, because current versions also send
// x-supabase-api-version. The browser silently kills the request when ANY requested header is
// unlisted, and the symptom is "Failed to send a request to the Edge Function" with NO console error
// and NO POST in the network log: there is nothing to debug from, because the request never exists.
// A bare fetch() with only Content-Type sailed through, which is what isolated it to the SDK.
// Echoing means an SDK upgrade that adds a header cannot break this again.
const ALLOW_FALLBACK = "authorization, x-client-info, apikey, content-type, x-supabase-api-version";
function cors(req: Request) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": req.headers.get("access-control-request-headers") ?? ALLOW_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
}

// ---- patch partition -------------------------------------------------------
const PUSHABLE = ["visit_date", "start_at", "end_at", "title", "notes", "team_ids"];
const LOCAL_ONLY = ["vehicle_id", "driver_id"];
const LINEITEM_KEYS = ["service_line_item_ids", "line_items", "line_item_prices", "line_item_descriptions"];

// NOTE: no per-request global here on purpose. An earlier draft stashed the Request in a
// module-level variable so these helpers could echo its headers, but Deno.serve handles requests
// concurrently, so two overlapping calls would read each other's. Echoing only matters on the
// PREFLIGHT (where the browser decides whether to send at all) and `req` is in scope there; on the
// actual response the browser ignores Allow-Headers, so the static list is correct and race-free.
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

async function getJobberToken(): Promise<string> {
  const { data } = await db.from("webhook_tokens").select("access_token").eq("source_system", "jobber").maybeSingle();
  const t = data?.access_token;
  if (!t) throw new Error("no jobber token");
  return t;
}

type GqlResult = { ok: true; data: any } | { ok: false; kind: "busy" | "unreachable" | "no_answer" | "rejected"; detail: string };

// Classifies the failure by the signal available at the moment it happens. The distinction matters
// because only 'unreachable' (nothing left our side) licenses an outright-safe retry.
async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<GqlResult> {
  let r: Response;
  try {
    r = await fetch("https://api.getjobber.com/api/graphql", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION },
      body: JSON.stringify({ query, variables }),
    });
  } catch (e) {
    // Threw before any response existed -> the request provably never arrived.
    return { ok: false, kind: "unreachable", detail: e instanceof Error ? e.message : String(e) };
  }
  let j: any = {};
  try { j = await r.json(); } catch { j = {}; }

  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) =>
      e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled) {
    if (_retry < 5) {
      await new Promise((res) => setTimeout(res, 400 * Math.pow(2, _retry)));
      return gql(token, query, variables, _retry + 1);
    }
    // Survived five backed-off attempts. Telling the user "the same values will get the same
    // answer" here would be FALSE; the correct advice is to wait and press Save unchanged.
    return { ok: false, kind: "busy", detail: "throttled after 5 retries" };
  }
  // 5xx or a timeout AFTER the request was sent: we cannot prove whether Jobber applied it.
  if (r.status >= 500) return { ok: false, kind: "no_answer", detail: `HTTP ${r.status}` };
  if (Array.isArray(j.errors) && j.errors.length) {
    return { ok: false, kind: "rejected", detail: j.errors.map((e: any) => e?.message).filter(Boolean).join("; ") };
  }
  return { ok: true, data: j.data };
}

function ue(payload: any): string | null {
  const e = payload?.userErrors;
  return e && e.length ? e.map((x: any) => x?.message).filter(Boolean).join("; ") : null;
}

// Jobber's message is rendered verbatim in a toast, so hand over something readable or nothing.
function tidy(msg: string | null | undefined): string | null {
  if (!msg) return null;
  const t = String(msg).trim().replace(/[.\s]+$/, "").trim();
  return t.length ? t : null;
}

const M_EDIT_SCHED = `mutation($id: EncodedId!, $input: VisitEditScheduleInput!){ visitEditSchedule(id:$id, input:$input){ userErrors{ message } } }`;
const M_EDIT = `mutation($id: EncodedId!, $attributes: VisitEditAttributes!){ visitEdit(id:$id, attributes:$attributes){ userErrors{ message } } }`;
const M_ASSIGN = `mutation($id: EncodedId!, $input: VisitEditAssignedUsersInput!){ visitEditAssignedUsers(visitId:$id, input:$input){ userErrors{ message } } }`;
const Q_VERIFY = `query($id: EncodedId!){ visit(id:$id){ id title startAt endAt instructions assignedUsers(first:20){ nodes{ id } } } }`;

function etLocal(iso: string) {
  const d = new Date(iso);
  const p = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hour12: false,
  }).formatToParts(d).reduce((a: any, x) => (a[x.type] = x.value, a), {});
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour === "24" ? "00" : p.hour}:${p.minute}`, timezone: "America/New_York" };
}

// ⚠ verify_jwt=true only proves the caller holds a VALID project JWT — and the anon key is one.
// This function writes visits and pushes to Jobber, so the role must be checked explicitly.
// The 2026-07-12 harden made anon read-only on all business data; this must not reopen it.
function bearerClaims(req: Request): Record<string, unknown> | null {
  const h = req.headers.get("Authorization") || "";
  const t = h.startsWith("Bearer ") ? h.slice(7) : "";
  const p = t.split(".")[1];
  if (!p) return null;
  try { return JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/"))); } catch { return null; }
}

// ---- per-user attribution --------------------------------------------------
// ⚠ WHY A SEPARATE WRITE CLIENT. audit.log_change() captures `x-actor-name` into
// request_context.actor_name; that capture layer has existed since 2026-06-26 (P2b) and
// webhook-jobber already uses exactly this idiom. Without it, a verified save is logged as
// 'visit-calendar' but with NO person: jwt_claims comes from the service_role token, so
// jwt_claims->>'email' is NULL and get_record_history cannot name the dispatcher.
//
// ⚠ THE EMAIL, NOT A DISPLAY NAME. get_record_history maps the email to employees.full_name, which is
// how every other human branch renders. Sending a name would create a second naming path to keep in
// sync, and would not resolve to an employee row.
//
// ⚠ OMIT THE HEADER ENTIRELY when there is no email, rather than sending "". log_change uses
// NULLIF(...,'') and jsonb_strip_nulls, so an absent header is clean while an empty one is only
// equivalent by luck. A service_role caller (our own curl tests) legitimately has no email and MUST
// produce no actor claim rather than a blank one.
//
// ⚠ NEVER AN AUTHORIZATION INPUT. This is a caller-supplied header. We derive it from a JWT whose
// signature the gateway already verified (verify_jwt = true), but PostgREST accepts the header from
// anyone who can set one, so it is an attribution HINT only. Access control stays on the role check
// above and on the RPC's own grants.
function writeClient(actorEmail: string | null) {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { global: { headers: {
      "x-app-source": "visit-calendar",
      ...(actorEmail ? { "x-actor-name": actorEmail } : {}),
    } } },
  );
}

Deno.serve(async (req) => {
  // Preflight FIRST — before auth, before body parsing. A browser preflight carries no
  // Authorization header, so answering it after the role check would 403 every browser caller.
  if (req.method === "OPTIONS") return new Response("ok", { status: 200, headers: cors(req) });
  if (req.method !== "POST") return new Response("method not allowed", { status: 405, headers: cors(req) });

  // ONE decode: the role gate and the actor both come from the same verified token.
  const claims = bearerClaims(req);
  const role = (claims?.role as string) ?? null;
  // A service_role caller (scripts, our curl tests) has no email and must yield no actor.
  const actorEmail = typeof claims?.email === "string" && claims.email.trim() ? claims.email.trim() : null;
  if (role !== "authenticated" && role !== "service_role") {
    return new Response(JSON.stringify({ ok: false, code: "forbidden", message: "Not permitted." }), {
      status: 403, headers: hdrs(),
    });
  }

  let body: any;
  try { body = await req.json(); } catch { return fail("bad_request", "Malformed request."); }
  const visitId = Number(body?.visit_id);
  const patch = body?.patch ?? {};
  if (!visitId) return fail("bad_request", "Missing visit_id.");

  const keys = Object.keys(patch);
  if (!keys.length) return done({ code: "no_changes", message: "Nothing to save.", applied: [] });

  if (keys.some((k) => LINEITEM_KEYS.includes(k))) {
    return fail("lineitems_unsupported",
      "Service changes can't be saved through the verified path yet. Nothing was saved.",
      { applied: [] });
  }
  const unknown = keys.filter((k) => !PUSHABLE.includes(k) && !LOCAL_ONLY.includes(k));
  if (unknown.length) return fail("bad_request", `Unsupported field(s): ${unknown.join(", ")}`);

  const pushable = keys.filter((k) => PUSHABLE.includes(k));

  // ---- the visit ----------------------------------------------------------
  const { data: visit } = await db.from("visits")
    .select("id, client_id, job_id, visit_date, start_at, end_at, title, notes, deleted_at").eq("id", visitId).maybeSingle();
  if (!visit || visit.deleted_at) return fail("not_found", "This visit no longer exists.");

  // ---- LOCAL-ONLY FAST PATH: never contacts Jobber ------------------------
  // ⚠ writeClient HERE TOO. Caught by @Building Apps reading the source: my first version used the
  // module-level `db` and a comment claiming the verified call was "the only call that must carry the
  // actor". That was wrong. LOCAL_ONLY is `vehicle_id` + `driver_id`, so **assigning a truck or a
  // driver takes this path** -- and on the Calendar the truck is the primary assignment unit, so this
  // is a routine dispatcher action, not an edge case. It would have stayed anonymous in the Activity
  // history while schedule edits were correctly named, which is the worst shape for a bug like this:
  // attribution that works often enough to look finished.
  if (!pushable.length) {
    const { error } = await writeClient(actorEmail)
      .rpc("edit_calendar_visit", { p_visit_id: visitId, p_patch: patch });
    if (error) return fail("db_write_failed", `Couldn't save: ${error.message}`);
    return done({ code: "local_only", message: "Saved.", applied: [] });
  }

  const { data: link } = await db.from("entity_source_links")
    .select("source_id").eq("entity_type", "visit").eq("source_system", "jobber").eq("entity_id", visitId).maybeSingle();
  const gid = link?.source_id;
  if (!gid) return fail("not_in_jobber", "This visit isn't linked to Jobber yet, so the change can't be verified. Nothing was saved.");

  let token: string;
  try { token = await getJobberToken(); }
  catch { return fail("jobber_unreachable", "Couldn't reach Jobber. Nothing was saved."); }

  // =========================================================================
  // 2. PRE-FLIGHT — every group validated BEFORE the first mutation
  // =========================================================================
  let teamGids: string[] | null = null;
  if (pushable.includes("team_ids")) {
    const ids: number[] = Array.isArray(patch.team_ids) ? patch.team_ids.map(Number) : [];
    const { data: links } = await db.from("entity_source_links")
      .select("entity_id, source_id").eq("entity_type", "employee").eq("source_system", "jobber").in("entity_id", ids.length ? ids : [-1]);
    const map = new Map((links || []).map((l: any) => [Number(l.entity_id), l.source_id]));
    const missing = ids.filter((i) => !map.has(i));
    if (missing.length) {
      const { data: emp } = await db.from("employees").select("full_name").in("id", missing);
      const names = (emp || []).map((e: any) => e.full_name).join(", ") || missing.join(", ");
      // There is NO UI anywhere to create this mapping, so do not tell the user to go and fix it.
      return fail("unmapped_employee",
        `${names} isn't linked to Jobber, so this crew can't be saved. Nothing was saved. Remove them from the crew to save the rest, or ask for the link to be set up.`,
        { applied: [] });
    }
    teamGids = ids.map((i) => map.get(i)!);
  }

  // =========================================================================
  // 3. PUSH — ordered, each group recorded in `applied` as it lands
  // =========================================================================
  const applied: string[] = [];
  const target = { ...visit, ...patch };

  const push = async (group: string, run: () => Promise<GqlResult>, pick: (d: any) => any) => {
    const r = await run();
    if (!r.ok) {
      const code = applied.length ? "partial_push"
        : r.kind === "busy" ? "jobber_busy"
        : r.kind === "unreachable" ? "jobber_unreachable"
        : r.kind === "no_answer" ? "jobber_no_answer" : "jobber_rejected";
      const why = tidy(r.detail);
      throw { code, group, why };
    }
    const uerr = tidy(ue(pick(r.data)));
    if (uerr !== null) throw { code: applied.length ? "partial_push" : "jobber_rejected", group, why: uerr };
    applied.push(group);
  };

  try {
    if (pushable.some((k) => ["visit_date", "start_at", "end_at"].includes(k))) {
      const startIso = target.start_at ?? null;
      if (!startIso) throw { code: "bad_request", group: "schedule", why: "all-day visits can't be rescheduled here" };

      // ⚠ PRESERVE DURATION when the patch moves start_at but says nothing about end_at.
      // Without this, `target` keeps the OLD end_at, so moving a visit to a later date sends
      // startAt > endAt and Jobber refuses with "startAt needs to be before endAt" — every single
      // time. A plain date drag is the commonest edit there is, so this was a guaranteed failure on
      // the most ordinary action. Found by running the function, not by reading it: the test that
      // caught it was aiming at something else entirely.
      // Shifting the end by the same delta is what a calendar drag means: move the appointment,
      // keep its length. An explicit end_at in the patch always wins over this.
      if (!("end_at" in patch) && visit.start_at && visit.end_at) {
        const delta = new Date(String(target.start_at)).getTime() - new Date(String(visit.start_at)).getTime();
        if (Number.isFinite(delta) && delta !== 0) {
          target.end_at = new Date(new Date(String(visit.end_at)).getTime() + delta).toISOString();
          // ⚠ WRITE IT INTO `patch` TOO, or Jobber and our DB SILENTLY DIVERGE. This is the fix for a
          // regression this very block introduced (found by @Building Apps' adversarial audit).
          // The commit at the end sends `patch`, and edit_calendar_visit writes end_at only
          // `WHEN p_patch ? 'end_at'`. So the synthesised value went to Jobber and never to us:
          //     visit 09:00-10:00, user edits start to 08:00
          //     Jobber -> 08:00-09:00     our DB -> 08:00-10:00     toast said "Saved."
          // `{start_at}` with no end_at is the NORMAL product of editing the start field, since the
          // drawer builds the two independently, so this was the common path and not an edge case.
          // Nothing would have caught it later either: the verify step did not compare endAt, and
          // sync-jobber-visit-drift's isDrift() compares startAt only, so the */30 reconciler can
          // neither surface nor heal it. 985 live visits carry both timestamps.
          // Assigning to BOTH here is deliberate: one synthesis, one value, so the two sides cannot
          // disagree by construction. Do not "clean this up" into target-only.
          (patch as Record<string, unknown>).end_at = target.end_at;
        }
      }

      const input: any = { startAt: etLocal(startIso) };
      if (target.end_at) input.endAt = etLocal(target.end_at);
      await push("schedule", () => gql(token, M_EDIT_SCHED, { id: gid, input }), (d) => d?.visitEditSchedule);
    }
    const attrs: Record<string, unknown> = {};
    if (pushable.includes("title") && target.title) attrs.title = target.title;
    if (pushable.includes("notes")) attrs.instructions = target.notes ?? null;
    if (Object.keys(attrs).length) {
      await push(pushable.includes("title") ? "title" : "notes", () => gql(token, M_EDIT, { id: gid, attributes: attrs }), (d) => d?.visitEdit);
    }
    if (teamGids) {
      await push("crew", () => gql(token, M_ASSIGN, { id: gid, input: { assignedUserIds: teamGids } }), (d) => d?.visitEditAssignedUsers);
    }
  } catch (e: any) {
    const msgs: Record<string, string> = {
      jobber_busy: "Jobber is busy and couldn't take the change right now. Nothing was saved; your edit is still here. Wait a minute and press Save again — the values are fine, it's just timing.",
      jobber_unreachable: "Couldn't reach Jobber. Nothing was saved; your edit is still here. Press Save to try again.",
      jobber_no_answer: "Jobber didn't confirm the change, so nothing was saved here. Check the visit in Jobber before trying again.",
      jobber_rejected: "Jobber refused the change, so nothing was saved.",
      partial_push: "Only part of the change reached Jobber, and nothing was saved here.",
      bad_request: "That change can't be saved here.",
    };
    const base = msgs[e?.code] ?? "The change couldn't be saved.";
    const why = e?.why ? ` Jobber said: "${e.why}".` : "";
    return fail(e?.code ?? "jobber_rejected", base + why, { applied, failed: e?.group ?? null });
  }

  // =========================================================================
  // 4. VERIFY — re-read Jobber. A mutation reporting success is not acceptance.
  // =========================================================================
  const v = await gql(token, Q_VERIFY, { id: gid });
  if (!v.ok) {
    return fail("verify_failed",
      "The change was sent to Jobber but couldn't be confirmed, so nothing was saved here. Check the visit in Jobber.",
      { applied, failed: null });
  }
  const jv = v.data?.visit;
  const mismatches: string[] = [];
  if (applied.includes("schedule") && target.start_at) {
    const want = new Date(target.start_at).getTime();
    const got = jv?.startAt ? new Date(jv.startAt).getTime() : NaN;
    if (want !== got) mismatches.push("schedule");
  }
  // ⚠ endAt MUST be verified, not just startAt (gap found by @Building Apps). Sending start with no
  // end is the normal shape of a start-field edit, and the duration-preserving synthesis above now
  // writes that value to BOTH Jobber and our DB -- so if Jobber disagrees about the end, we would
  // commit a divergence while reporting success. Nothing downstream would catch it either:
  // sync-jobber-visit-drift's isDrift() compares startAt only.
  if (applied.includes("schedule") && target.end_at) {
    const wantEnd = new Date(String(target.end_at)).getTime();
    const gotEnd = jv?.endAt ? new Date(jv.endAt).getTime() : NaN;
    if (wantEnd !== gotEnd) mismatches.push("end time");
  }
  if (applied.includes("title") && target.title && jv?.title !== target.title) mismatches.push("title");
  // ⚠ notes was COMMITTED UNVERIFIED. Q_VERIFY already fetched `instructions` and nothing ever
  // compared it, so notes rode on a bare 200 with no userErrors -- precisely the acceptance criterion
  // this whole function exists to reject. Worse, the app never sets `title`, so of the groups the
  // drawer can actually route here, notes was the one with NO verification at all.
  // Gate on what was SENT (`pushable`), not on the label: the visitEdit mutation is labelled "title"
  // when title is present and "notes" otherwise, so a title+notes save appears in `applied` as
  // "title" only and a notes-label check would silently never fire.
  if (pushable.includes("notes") && (applied.includes("notes") || applied.includes("title"))) {
    const wantNotes = String(target.notes ?? "");
    const gotNotes = String(jv?.instructions ?? "");   // Jobber returns null for empty; treat as ""
    if (wantNotes !== gotNotes) mismatches.push("notes");
  }
  if (applied.includes("crew") && teamGids) {
    const got = new Set(((jv?.assignedUsers?.nodes) || []).map((n: any) => n.id));
    if (teamGids.length !== got.size || !teamGids.every((g) => got.has(g))) mismatches.push("crew");
  }
  if (mismatches.length) {
    return fail("verify_failed",
      `Jobber accepted the change but doesn't show it (${mismatches.join(", ")}), so nothing was saved here. Check the visit in Jobber.`,
      { applied, failed: mismatches[0] });
  }

  // =========================================================================
  // 5. COMMIT — only now. Suppressed so the trigger doesn't push a second time.
  //    Both partitions in ONE call: a save changing date AND truck writes both or neither.
  // =========================================================================
  // ⚠ writeClient, NOT the module-level `db`. Per-request because the actor differs per caller: a
  // module-level client cannot hold it, and a mutable module-level global would be unsafe anyway
  // since Deno.serve handles requests concurrently (the same trap caught and removed from this file
  // before it shipped).
  // ⚠ BOTH writes in this function use writeClient -- this one and the LOCAL-ONLY path above. An
  // earlier comment here claimed this was "the only call that must carry the actor"; that was wrong
  // and left truck/driver assignments anonymous. If a third write is ever added, it needs this too.
  // The reads (webhook_tokens, visits, entity_source_links, employees) deliberately use `db`: they
  // write nothing, so they have no attribution to carry.
  const { error: werr } = await writeClient(actorEmail)
    .rpc("edit_calendar_visit_verified", { p_visit_id: visitId, p_patch: patch });
  if (werr) {
    return fail("db_write_failed",
      `Jobber was updated but saving here failed: ${werr.message}. The two are now out of step — check the visit in Jobber.`,
      { applied, failed: "db" });
  }
  return done({ code: "saved", message: "Saved.", applied });
});
