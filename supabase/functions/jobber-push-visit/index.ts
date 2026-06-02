// ============================================================================
// jobber-push-visit — Calendar → Jobber write-back (Phase 2)
// ----------------------------------------------------------------------------
// Mirrors create / move-date / title / delete of `source='calendar'` visits
// into Jobber. The Calendar app is the MASTER; Jobber follows.
//
// Invoked by a DB trigger (pg_net) with JSON body { op, visit_id } and an
// Authorization: Bearer <service_role_key> header. Deployed --no-verify-jwt
// (like the webhook receivers); auth is the service-key bearer check below.
//
//   op = 'upsert'  -> create (if no Jobber link) or edit schedule/title (if linked)
//   op = 'delete'  -> visitDelete in Jobber (soft-delete: visits.deleted_at set)
//
// Reads + refreshes the jobber_write token from public.webhook_tokens. Resolves
// the target Jobber job from OUR DB (visits.job_id -> entity_source_links, else
// the client's single active job). No match -> skip + write public.visit_sync_flags.
// Links the created Jobber visit GID back via entity_source_links so the read-sync
// dedups it (no loop).
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GQL_VERSION = "2026-04-16";
const TZ = "America/New_York";
const db = createClient(SUPABASE_URL, SERVICE_KEY);

// ---- Jobber write token: read + refresh from webhook_tokens('jobber_write') ----
async function getJobberToken(): Promise<string> {
  const { data, error } = await db.from("webhook_tokens")
    .select("access_token,refresh_token,client_id,client_secret,expires_at")
    .eq("source_system", "jobber_write").single();
  if (error || !data) throw new Error("no jobber_write token row");
  if (new Date(data.expires_at).getTime() > Date.now() + 120_000) return data.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(data.refresh_token)}` +
    `&client_id=${encodeURIComponent(data.client_id)}&client_secret=${encodeURIComponent(data.client_secret)}`;
  const r = await fetch("https://api.getjobber.com/api/oauth/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
  if (!r.ok) throw new Error(`token refresh failed ${r.status}: ${(await r.text()).slice(0, 150)}`);
  const t = await r.json();
  const exp = JSON.parse(atob(t.access_token.split(".")[1])).exp * 1000;
  await db.from("webhook_tokens").update({
    access_token: t.access_token, refresh_token: t.refresh_token || data.refresh_token,
    expires_at: new Date(exp).toISOString(), updated_at: new Date().toISOString(),
  }).eq("source_system", "jobber_write");
  return t.access_token;
}

async function gql(token: string, query: string, variables?: unknown) {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION },
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json();
  if (j.errors) throw new Error(`GraphQL: ${JSON.stringify(j.errors).slice(0, 300)}`);
  return j.data;
}

// our entity -> Jobber GID via the bridge table
async function jobberGid(entityType: string, entityId: number): Promise<string | null> {
  const { data } = await db.from("entity_source_links")
    .select("source_id").eq("entity_type", entityType).eq("entity_id", entityId)
    .eq("source_system", "jobber").maybeSingle();
  return data?.source_id ?? null;
}

async function linkVisit(visitId: number, gid: string) {
  await db.from("entity_source_links").upsert(
    { entity_type: "visit", entity_id: visitId, source_system: "jobber", source_id: gid },
    { onConflict: "entity_type,source_system,source_id" },
  );
}

async function flag(visitId: number, reason: string, detail: string) {
  await db.from("visit_sync_flags").upsert(
    { visit_id: visitId, reason, detail, resolved_at: null },
    { onConflict: "visit_id" },
  );
  console.log(`[push] FLAG visit ${visitId}: ${reason} — ${detail}`);
}
async function clearFlag(visitId: number) {
  await db.from("visit_sync_flags").update({ resolved_at: new Date().toISOString() }).eq("visit_id", visitId).is("resolved_at", null);
}

// resolve the target Jobber job GID for a visit
async function resolveJobGid(visit: any): Promise<{ gid: string } | { error: string }> {
  if (visit.job_id) {
    const g = await jobberGid("job", visit.job_id);
    return g ? { gid: g } : { error: `job_id=${visit.job_id} has no jobber link` };
  }
  const { data: jobs } = await db.from("jobs").select("id,job_status").eq("client_id", visit.client_id);
  const active = (jobs || []).filter((j: any) => j.job_status !== "archived");
  if (active.length === 1) {
    const g = await jobberGid("job", active[0].id);
    return g ? { gid: g } : { error: "single active job has no jobber link" };
  }
  return { error: active.length === 0 ? "client has no active job" : `ambiguous: ${active.length} active jobs — set visits.job_id` };
}

// UTC timestamp -> { date:'YYYY-MM-DD', time:'HH:MM:SS', timezone } in ET wall-clock
function etParts(d: Date) {
  const f = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  });
  const p: Record<string, string> = {};
  for (const part of f.formatToParts(d)) p[part.type] = part.value;
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}:${p.second}`, timezone: TZ };
}
function visitSchedule(visit: any) {
  // No specific time -> "Anytime" / all-day in Jobber: send the date with NO time
  // component and Jobber sets allDay=true spanning the full ET day.
  if (!visit.start_at) {
    const d = { date: visit.visit_date, timezone: TZ };
    return { startAt: d, endAt: d };
  }
  // Timed visit -> include the ET wall-clock time.
  const start = new Date(visit.start_at);
  const end = visit.end_at ? new Date(visit.end_at) : new Date(start.getTime() + 60 * 60 * 1000);
  return { startAt: etParts(start), endAt: etParts(end) };
}

// ---- Jobber mutations ----
const M_CREATE = `mutation($jobId: EncodedId!, $input: VisitCreateInput!){ visitCreate(jobId:$jobId, input:$input){ createdVisits{ id } userErrors{ message path } } }`;
const M_EDIT_SCHED = `mutation($id: EncodedId!, $input: VisitEditScheduleInput!){ visitEditSchedule(id:$id, input:$input){ userErrors{ message path } } }`;
const M_EDIT = `mutation($id: EncodedId!, $attributes: VisitEditAttributes!){ visitEdit(id:$id, attributes:$attributes){ userErrors{ message path } } }`;
const M_DELETE = `mutation($ids: [EncodedId!]!){ visitDelete(visitIds:$ids){ userErrors{ message path } } }`;
function ue(payload: any): string | null { const e = payload?.userErrors; return e && e.length ? JSON.stringify(e) : null; }

async function handle(op: string, visitId: number, payloadGid?: string) {
  const token = await getJobberToken();
  const { data: visit } = await db.from("visits").select("*").eq("id", visitId).maybeSingle();

  // ---- DELETE (soft-delete sets deleted_at; or explicit op=delete) ----
  if (op === "delete" || (visit && visit.deleted_at)) {
    const gid = payloadGid || (visit ? await jobberGid("visit", visitId) : null);
    if (!gid) { console.log(`[push] delete: visit ${visitId} has no jobber link — nothing to delete`); return { ok: true, note: "no link" }; }
    const d = await gql(token, M_DELETE, { ids: [gid] });
    const err = ue(d.visitDelete);
    if (err) throw new Error(`visitDelete: ${err}`);
    console.log(`[push] deleted Jobber visit ${gid} (our visit ${visitId})`);
    return { ok: true, deleted: gid };
  }

  if (!visit) return { ok: true, note: "visit gone, not a delete" };
  if (visit.source !== "visit-calendar") { console.log(`[push] visit ${visitId} source=${visit.source} — ignoring (not visit-calendar)`); return { ok: true, note: "not visit-calendar" }; }

  const existingGid = await jobberGid("visit", visitId);
  const sched = visitSchedule(visit);

  // ---- UPDATE (already linked) ----
  if (existingGid) {
    const s = await gql(token, M_EDIT_SCHED, { id: existingGid, input: sched });
    const se = ue(s.visitEditSchedule); if (se) throw new Error(`visitEditSchedule: ${se}`);
    if (visit.title) {
      const e = await gql(token, M_EDIT, { id: existingGid, attributes: { title: visit.title, instructions: visit.notes ?? null } });
      const ee = ue(e.visitEdit); if (ee) throw new Error(`visitEdit: ${ee}`);
    }
    console.log(`[push] updated Jobber visit ${existingGid} (our visit ${visitId})`);
    return { ok: true, updated: existingGid };
  }

  // ---- CREATE (not linked) ----
  const job = await resolveJobGid(visit);
  if ("error" in job) { await flag(visitId, "no_job_match", job.error); return { ok: true, flagged: job.error }; }
  const input = { visits: [{ title: visit.title || null, instructions: visit.notes ?? null, schedule: { ...sched, notifyTeam: false, teamMemberIdsToAssign: [] } }] };
  const c = await gql(token, M_CREATE, { jobId: job.gid, input });
  const ce = ue(c.visitCreate); if (ce) { await flag(visitId, "create_error", ce); throw new Error(`visitCreate: ${ce}`); }
  const newGid = c.visitCreate.createdVisits?.[0]?.id;
  if (!newGid) throw new Error("visitCreate returned no visit id");
  await linkVisit(visitId, newGid);
  await clearFlag(visitId);
  console.log(`[push] created Jobber visit ${newGid} on job ${job.gid} (our visit ${visitId})`);
  return { ok: true, created: newGid };
}

function bearerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer (.+)$/);
  if (!m) return null;
  try { return JSON.parse(atob(m[1].split(".")[1])).role ?? null; } catch { return null; }
}

Deno.serve(async (req) => {
  // auth: require a service_role JWT. Deployed with verify_jwt=true so the gateway
  // verifies the signature; we additionally require role=service_role so the public
  // anon key cannot invoke this. The DB trigger sends the service_role key.
  if (bearerRole(req) !== "service_role") return new Response("forbidden", { status: 403 });
  let body: any;
  try { body = await req.json(); } catch { return new Response("bad json", { status: 400 }); }
  const op = String(body.op || "upsert");
  const visitId = Number(body.visit_id);
  if (!visitId) return new Response("missing visit_id", { status: 400 });
  try {
    const res = await handle(op, visitId, body.jobber_gid);
    return new Response(JSON.stringify(res), { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error(`[push] FATAL visit ${visitId}:`, e instanceof Error ? e.message : String(e));
    return new Response(JSON.stringify({ ok: false, error: e instanceof Error ? e.message : String(e) }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
