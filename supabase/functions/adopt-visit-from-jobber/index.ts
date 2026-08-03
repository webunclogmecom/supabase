// adopt-visit-from-jobber — "Sync from Jobber" for a single visit.
//
// WHY THIS IS AN EDGE FUNCTION AND NOT AN RPC
//   Adopting means taking Jobber's CURRENT schedule, so it needs a live Jobber read, which needs the
//   OAuth token. A plain SQL RPC cannot do that. public.adopt_visit_schedule_from_jobber already
//   exists and does the write correctly (push-suppressed, audited app_source='jobber', with an
//   optimistic-concurrency guard) but is service_role-only by design. This function is the staff-
//   authenticated door to it: verify the human, read Jobber, then call that RPC with service_role.
//
// WHY IT IS MANUAL AND NOT AUTOMATIC (measured 2026-08-03, do not "improve" this)
//   The obvious automation is last-writer-wins: if Jobber changed after our edit, adopt. It is NOT
//   implementable from the data we have.
//     * Jobber's Visit type has NO updatedAt. Introspected: completedAt, createdAt, createdBy,
//       endAt, startAt. There is no last-modified field to compare against our audit timestamp.
//     * webhook_events_log VISIT_UPDATE.occurredAt looks like the missing clock and is NOT. Measured
//       on the three visits surfaced that day: ~300 events each against ~6 real schedule changes, on
//       a perfectly regular 2.5-hour cadence (17:15, 14:45, 12:15, 09:45 ...) in batches of ~25
//       visits. It is a churn/poll signal, not a human edit. A rule of
//       "max(occurredAt) > our_edit + 5 min -> adopt" is true for essentially EVERY drifted visit and
//       would silently overwrite office edits with Jobber values — exactly the auto-revert the drift
//       reconciler refuses to do.
//   So a human decides, and this function is the one click that carries out the decision.
//   A real automatic rule needs a genuine "Jobber changed at" signal, which would mean recording when
//   the OBSERVED Jobber startAt actually changes, and would only work going forward.
//
// AUTH: in-handler, NOT gateway verify_jwt. This project signs session tokens with ES256 and the
//   gateway rejects them outright (401 UNAUTHORIZED_ASYMMETRIC_JWT), so verify_jwt=false in
//   config.toml is deliberate — same pattern as save-client-job.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

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

// Same token path as sync-jobber-visit-drift: webhook_tokens row + refresh when near expiry.
// READ-only use here (we only fetch the visit's schedule), so the read token is correct — this is
// NOT the write-OAuth path and must not be swapped for it.
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
  const j = await r.json();
  if (j.errors) throw new Error(JSON.stringify(j.errors).slice(0, 300));
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
    // ---- the visit + its Jobber GID ----
    const { data: v, error: vErr } = await db
      .from("visits").select("id, visit_date, start_at, visit_status, deleted_at").eq("id", visitId).single();
    if (vErr || !v) return json({ error: "visit not found" }, 404);
    if (v.deleted_at) return json({ error: "visit is deleted" }, 409);

    const { data: link } = await db
      .from("entity_source_links").select("source_id")
      .eq("entity_type", "visit").eq("entity_id", visitId).eq("source_system", "jobber").maybeSingle();
    if (!link?.source_id) return json({ error: "this visit is not linked to Jobber, nothing to adopt" }, 409);

    // ---- read Jobber LIVE (not the reconciler's snapshot — the user may be acting minutes later) ----
    const token = await getJobberToken(db);
    const d = await jobberGql(token, `{ visit(id:"${link.source_id}"){ startAt endAt } }`);
    const jStart: string | null = d?.visit?.startAt ?? null;
    if (!jStart) return json({ error: "Jobber returned no schedule for this visit" }, 502);

    // ---- Jobber schedule -> the row we adopt. Mirrors adoptTarget() in sync-jobber-visit-drift and
    //      the live BEFORE trigger: ET midnight means ALL-DAY (untimed), else keep the clock time. ----
    const e = etParts(new Date(jStart));
    const target = e.time === "00:00:00"
      ? { visit_date: e.date, start_at: null as string | null, end_at: null as string | null }
      : { visit_date: e.date, start_at: jStart, end_at: (d?.visit?.endAt ?? null) as string | null };

    // ---- write via the existing RPC. p_enforce_expected: refuse if the row moved since we read it
    //      (someone dragged it in the Calendar while this request was in flight) rather than clobber. ----
    const { data: ok, error: rpcErr } = await db.rpc("adopt_visit_schedule_from_jobber", {
      p_visit_id: visitId,
      p_visit_date: target.visit_date, p_start_at: target.start_at, p_end_at: target.end_at,
      p_expected_visit_date: v.visit_date, p_expected_start_at: v.start_at,
      p_enforce_expected: true,
    });
    if (rpcErr) return json({ error: `adopt failed: ${rpcErr.message}` }, 500);
    if (!ok) {
      return json({
        ok: false,
        error: "This visit changed while you were looking at it. Reopen it and try again.",
      }, 409);
    }

    return json({
      ok: true,
      visit_id: visitId,
      adopted: target,
      was: { visit_date: v.visit_date, start_at: v.start_at },
      all_day: target.start_at === null,
      by: email,
    });
  } catch (err) {
    return json({ error: String(err).slice(0, 300) }, 500);
  }
});
