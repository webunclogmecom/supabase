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

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const GQL_VERSION = "2026-04-16";

// ---- patch partition -------------------------------------------------------
const PUSHABLE = ["visit_date", "start_at", "end_at", "title", "notes", "team_ids"];
const LOCAL_ONLY = ["vehicle_id", "driver_id"];
const LINEITEM_KEYS = ["service_line_item_ids", "line_items", "line_item_prices", "line_item_descriptions"];

function fail(code: string, message: string, extra: Record<string, unknown> = {}) {
  return new Response(JSON.stringify({ ok: false, code, message, ...extra }), {
    status: 200, headers: { "Content-Type": "application/json" },
  });
}
function done(body: Record<string, unknown>) {
  return new Response(JSON.stringify({ ok: true, ...body }), {
    status: 200, headers: { "Content-Type": "application/json" },
  });
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
function bearerRole(req: Request): string | null {
  const h = req.headers.get("Authorization") || "";
  const t = h.startsWith("Bearer ") ? h.slice(7) : "";
  const p = t.split(".")[1];
  if (!p) return null;
  try { return JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/"))).role ?? null; } catch { return null; }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const role = bearerRole(req);
  if (role !== "authenticated" && role !== "service_role") {
    return new Response(JSON.stringify({ ok: false, code: "forbidden", message: "Not permitted." }), {
      status: 403, headers: { "Content-Type": "application/json" },
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
  if (!pushable.length) {
    const { error } = await db.rpc("edit_calendar_visit", { p_visit_id: visitId, p_patch: patch });
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
  if (applied.includes("title") && target.title && jv?.title !== target.title) mismatches.push("title");
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
  const { error: werr } = await db.rpc("edit_calendar_visit_verified", { p_visit_id: visitId, p_patch: patch });
  if (werr) {
    return fail("db_write_failed",
      `Jobber was updated but saving here failed: ${werr.message}. The two are now out of step — check the visit in Jobber.`,
      { applied, failed: "db" });
  }
  return done({ code: "saved", message: "Saved.", applied });
});
