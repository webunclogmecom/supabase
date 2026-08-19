// push-visit-to-jobber — "Keep Calendar's schedule" for a single visit: Jobber adopts OUR data.
//
// THE MIRROR TWIN OF adopt-visit-from-jobber. That function is the staff door for
// Jobber -> Calendar; this one is the staff door for Calendar -> Jobber. Fred, 2026-08-19:
// "can you add another button, one from Sync from jobber and one for Sync to jobber, so jobber
// adopts the data from the calendar instead."
//
// WHY IT IS THIS SHAPE AND NOT SOMETHING SIMPLER
//   * The write machinery already exists and is proven: public.fn_request_jobber_push(visit_id,'upsert')
//     enqueues the pg_net call to jobber-push-visit (service_role gateway), which owns the Jobber
//     write saga, the no-link create branch, the scope check (fn_visit_in_jobber_scope) and the
//     visit_sync_flags bookkeeping. It is EXACTLY what the drift reconciler's HEAL branch calls.
//     This door adds only: a staff gate, a read-verify, and a fresh drift snapshot.
//   * fn_request_jobber_push is service_role-only (Phase 3 revoked lifecycle RPCs from
//     authenticated) — hence an edge-fn door, same pattern as adopt-visit-from-jobber.
//   * The VERIFY here uses the READ token (same path as adopt / the drift reconciler). The WRITE
//     token lives inside jobber-push-visit and must stay there.
//
// ⚠ THE DRIFT CARD IS A SNAPSHOT, NOT A LIVE COMPARISON (see 2026-08-17_1500's DEFECT 1). After a
//   successful push our DB value is unchanged, so ops.v_calendar_push_health's re-validation
//   (v.start_at = entry.jobber_start_at, against the SNAPSHOT's jobber value) still shows the card.
//   Without the fn_request_jobber_sync('drift') call below, a correct push would leave an alarming
//   stale warning for up to 30 minutes — the exact defect Fred reported for the adopt direction on
//   2026-08-17. The UI additionally hides the card optimistically on ok.
//
// AUTH: in-handler, NOT gateway verify_jwt — this project signs session tokens with ES256 and the
//   gateway rejects them outright (401 UNAUTHORIZED_ASYMMETRIC_JWT), so verify_jwt=false in
//   config.toml is deliberate. Same pattern as adopt-visit-from-jobber / save-client-job.

import { createClient } from "npm:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// ET parts of an instant — the operating-date rule is the ET CLOCK date of start_at
// (Fred 2026-07-02; the 06:00 "operating night" cutoff was REMOVED, do not reintroduce it).
function etParts(d: Date): { date: string; time: string } {
  const p = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  }).formatToParts(d).reduce((a, x) => (a[x.type] = x.value, a), {} as Record<string, string>);
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour === "24" ? "00" : p.hour}:${p.minute}:${p.second}` };
}

// Same token path as adopt-visit-from-jobber / sync-jobber-visit-drift: webhook_tokens row +
// refresh when near expiry. READ-only use here (we only fetch the visit's schedule to VERIFY the
// push landed) — the WRITE OAuth lives inside jobber-push-visit and must not be duplicated here.
async function getJobberToken(db: ReturnType<typeof createClient>): Promise<string> {
  const { data: row } = await db.from("webhook_tokens")
    .select("access_token, refresh_token, client_id, client_secret, expires_at")
    .eq("source_system", "jobber").single();
  if (!row) throw new Error("no jobber row in webhook_tokens");
  if (new Date(row.expires_at).getTime() > Date.now() + 60_000) return row.access_token as string;

  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}` +
    `&client_id=${encodeURIComponent(row.client_id)}&client_secret=${encodeURIComponent(row.client_secret)}`;
  const tr = await fetch("https://api.getjobber.com/api/oauth/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
  });
  if (!tr.ok) {
    // another worker may have just refreshed it — re-read before failing
    const { data: row2 } = await db.from("webhook_tokens")
      .select("access_token, expires_at").eq("source_system", "jobber").single();
    if (row2 && new Date(row2.expires_at).getTime() > Date.now() + 60_000) return row2.access_token as string;
    throw new Error(`jobber token refresh failed ${tr.status}`);
  }
  const t = await tr.json();
  const newExp = JSON.parse(atob(t.access_token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).exp * 1000;
  await db.from("webhook_tokens").update({
    access_token: t.access_token, refresh_token: t.refresh_token || row.refresh_token,
    expires_at: new Date(newExp).toISOString(), updated_at: new Date().toISOString(),
  }).eq("source_system", "jobber");
  return t.access_token as string;
}

async function jobberGql(token: string, query: string) {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION },
    body: JSON.stringify({ query }),
  });
  // ⚠ Jobber sheds load with an HTML "Waiting Room" at HTTP 200 (Supabase CLAUDE.md). Check the
  //   response content-type BEFORE parsing; a non-JSON answer is "Jobber is busy", never data.
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) throw new Error(`jobber_busy: non-JSON (${ctype}) at HTTP ${r.status}`);
  const j = await r.json();
  if (j.errors) throw new Error(JSON.stringify(j.errors).slice(0, 300));
  if (j.data === undefined) throw new Error("jobber_busy: JSON reply with no data key");
  return j.data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(url, svc, { auth: { persistSession: false } });

  // ---- AUTH: a real, staff-domain human. Never service_role-by-default. ----
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return json({ error: "unauthorized" }, 401);
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const email = (userData?.user?.email ?? "").toLowerCase();
  if (userErr || !email || (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return json({ error: "not a staff account" }, 403);
  }

  let body: { visit_id?: number };
  try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }
  const visitId = Number(body.visit_id);
  if (!Number.isFinite(visitId) || visitId <= 0) return json({ error: "visit_id required" }, 400);

  try {
    // ---- the visit as WE hold it: this is the value Jobber is being asked to adopt ----
    const { data: v, error: vErr } = await db
      .from("visits").select("id, visit_date, start_at, end_at, visit_status, deleted_at")
      .eq("id", visitId).single();
    if (vErr || !v) return json({ error: "visit not found" }, 404);
    if (v.deleted_at) return json({ error: "visit is deleted" }, 409);
    if (v.visit_status !== "scheduled") {
      // completed/skipped visits are dispatch history; re-pushing their schedule is never the fix
      return json({ error: `only a scheduled visit can be pushed (this one is ${v.visit_status})` }, 409);
    }

    // ---- enqueue the EXISTING push saga (the drift reconciler's own HEAL path).
    //      jobber-push-visit owns the write OAuth, the create-vs-edit branch, the scope check and
    //      visit_sync_flags. We deliberately reuse it rather than re-implementing a Jobber write. ----
    const { error: pushErr } = await db.rpc("fn_request_jobber_push", { p_visit_id: visitId, p_op: "upsert" });
    if (pushErr) return json({ error: `push request failed: ${pushErr.message}` }, 500);

    // same settle window the reconciler uses before verifying its heals
    await new Promise((s) => setTimeout(s, 8000));

    // ---- VERIFY with the read token: did Jobber actually adopt our schedule? ----
    // Re-read the link AFTER the push: the no-link branch creates the Jobber visit and links it.
    const { data: link } = await db
      .from("entity_source_links").select("source_id")
      .eq("entity_type", "visit").eq("entity_id", visitId).eq("source_system", "jobber").maybeSingle();

    let verified = false;
    let jobberNow: { startAt: string | null; endAt: string | null } | null = null;
    if (link?.source_id) {
      const token = await getJobberToken(db);
      const d = await jobberGql(token, `{ visit(id:"${link.source_id}"){ startAt endAt } }`);
      jobberNow = { startAt: d?.visit?.startAt ?? null, endAt: d?.visit?.endAt ?? null };
      if (jobberNow.startAt) {
        const jET = etParts(new Date(jobberNow.startAt));
        if (v.start_at) {
          // timed visit: Jobber must hold our ET clock date AND clock time (minute precision,
          // the same comparison the drift reconciler's heal-verify uses)
          const ourET = etParts(new Date(v.start_at));
          verified = jET.date === ourET.date && jET.time.slice(0, 5) === ourET.time.slice(0, 5);
        } else {
          // all-day visit: Jobber's ET midnight on our visit_date
          verified = jET.date === v.visit_date && jET.time === "00:00:00";
        }
      }
    }

    // if the push worker skipped or failed, it wrote a visit_sync_flags row — surface its reason
    let flagReason: string | null = null;
    if (!verified) {
      const { data: flag } = await db.from("visit_sync_flags")
        .select("reason, detail").eq("visit_id", visitId).is("resolved_at", null).maybeSingle();
      if (flag) flagReason = `${flag.reason}${flag.detail ? `: ${String(flag.detail).slice(0, 160)}` : ""}`;
    }

    // ---- the drift card is a SNAPSHOT; force a fresh one so a verified push clears it in ~a
    //      minute instead of lingering for up to 30 (fire-and-forget: a failure here only delays
    //      the card's disappearance, it does not affect the push). ----
    if (verified) {
      // signature verified against the live catalogue: fn_request_jobber_sync(p_target text)
      db.rpc("fn_request_jobber_sync", { p_target: "drift" }).then(() => {}, () => {});
    }

    return json({
      ok: verified,
      verified,
      visit_id: visitId,
      pushed: { visit_date: v.visit_date, start_at: v.start_at, end_at: v.end_at },
      jobber_now: jobberNow,
      linked: !!link?.source_id,
      flag: flagReason,
      by: email,
      ...(verified
        ? { note: "Jobber now holds the Calendar's schedule. The warning clears within about a minute." }
        : { error: flagReason ?? "The push did not verify. Jobber may be busy — check again in a minute before retrying." }),
    }, verified ? 200 : 502);
  } catch (err) {
    return json({ error: String(err).slice(0, 300) }, 500);
  }
});
