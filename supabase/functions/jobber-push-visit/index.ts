// ============================================================================
// jobber-push-visit — Calendar → Jobber write-back (Phase 2)
// ----------------------------------------------------------------------------
// Mirrors create / move-date / title / delete of `source='calendar'` visits
// into Jobber. The Calendar app is the MASTER; Jobber follows.
//
// Invoked by a DB trigger (pg_net) with JSON body { op, visit_id } and an
// Authorization: Bearer <service_role_key> header. Deployed WITH verify_jwt=true
// (pinned in supabase/config.toml): the gateway verifies the JWT signature and the
// handler additionally requires role=service_role (bearerRole below only DECODES the
// token, so the gateway MUST verify it — do NOT deploy this one --no-verify-jwt).
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

async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<any> {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION },
    body: JSON.stringify({ query, variables }),
  });
  const j = await r.json().catch(() => ({}));
  // Jobber's GraphQL API is a cost-based leaky bucket. Retry THROTTLED / HTTP 429 with
  // exponential backoff — WITHOUT this, a backfill burst silently loses visitCreate calls
  // (the push is fire-and-forget from pg_net; a throw here just 500s with no retry, leaving
  // an orphan calendar visit with no Jobber GID). Mirrors scripts/sync/lib/jobber.js.
  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) =>
      e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled && _retry < 5) {
    const waitMs = Math.min(30_000, 1_000 * Math.pow(2, _retry)) + _retry * 250;
    console.log(`[push] Jobber throttled — backoff ${waitMs}ms (retry ${_retry + 1}/5)`);
    await new Promise((s) => setTimeout(s, waitMs));
    return gql(token, query, variables, _retry + 1);
  }
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
const M_ASSIGN = `mutation($id: EncodedId!, $input: VisitEditAssignedUsersInput!){ visitEditAssignedUsers(visitId:$id, input:$input){ userErrors{ message path } } }`;
// Service-Call visits carry their own line items (the services done on that call);
// Service-Agreement visits do NOT — their priced line items live on the Jobber SA job.
const M_LI_CREATE = `mutation($id: EncodedId!, $input: VisitCreateLineItemInput!){ visitCreateLineItems(visitId:$id, input:$input){ userErrors{ message path } } }`;
const M_LI_DELETE = `mutation($id: EncodedId!, $input: VisitDeleteLineItemsInput!){ visitDeleteLineItems(visitId:$id, input:$input){ userErrors{ message path } } }`;
const Q_VISIT_LI  = `query($jobId: EncodedId!){ job(id:$jobId){ visits(first:50){ nodes{ id lineItems(first:50){ nodes{ id name } } } } } }`;
function ue(payload: any): string | null { const e = payload?.userErrors; return e && e.length ? JSON.stringify(e) : null; }

// Push a visit's line items (with prices) onto its Jobber visit. For Service-Agreement
// visits this pushes the office's PER-VISIT overrides (set via the drawer) onto the Jobber
// visit, replacing the inherited job lines (SA billing is per-visit / VISIT_BASED, so the
// invoice reads the visit's lines). Un-edited SA visits carry NO visit-scoped line_items,
// so the empty-items guard below no-ops them — leaving the Jobber visit's inherited lines
// intact. Idempotent: deletes the visit's existing Jobber line items first, then re-creates.
async function syncVisitLineItems(token: string, visit: any, visitGid: string, isUpdate: boolean) {
  const { data: items } = await db.from("line_items").select("name,description,quantity,unit_price").eq("visit_id", visit.id);
  if (!items || !items.length) return;
  // ALWAYS reconcile (create + update): delete any line items already on the
  // Jobber visit first, then recreate from our DB. Idempotent — every push
  // converges Jobber to exactly our set, self-healing both duplicate line items
  // (from a racing 2nd push, e.g. the inbound poll re-touching a fresh visit)
  // and missing line items (from a prior push whose sync errored). isUpdate is
  // no longer used to gate the delete.
  {
    const jobGid = await jobberGid("job", visit.job_id);
    if (jobGid) {
      const jr = await gql(token, Q_VISIT_LI, { jobId: jobGid });
      const node = (jr.job?.visits?.nodes || []).find((n: any) => n.id === visitGid);
      const ids = (node?.lineItems?.nodes || []).map((x: any) => x.id);
      if (ids.length) {
        const d = await gql(token, M_LI_DELETE, { id: visitGid, input: { lineItemIds: ids } });
        const de = ue(d.visitDeleteLineItems); if (de) throw new Error(`visitDeleteLineItems: ${de}`);
      }
    }
  }
  const lineItems = items.map((it: any) => {
    const up = Number(it.unit_price) || 0, qty = Number(it.quantity) || 1;
    const desc = (it.description ?? "").trim();
    // Send the per-line-item description (Jobber's LineItem.description) when set (Fred 2026-07-02).
    return { name: it.name, unitPrice: up, quantity: qty, totalPrice: up * qty, saveToProductsAndServices: false, ...(desc ? { description: desc } : {}) };
  });
  const c = await gql(token, M_LI_CREATE, { id: visitGid, input: { lineItems } });
  const ce = ue(c.visitCreateLineItems); if (ce) throw new Error(`visitCreateLineItems: ${ce}`);
  // Final reconcile (concurrency self-heal): if a racing 2nd push (e.g. a rapid
  // re-save or the inbound poll) duplicated items, trim Jobber back to exactly our
  // DB set, per-name count. No-op when already in sync — costs one extra query.
  try {
    const jobGid2 = await jobberGid("job", visit.job_id);
    if (jobGid2) {
      const jr2 = await gql(token, Q_VISIT_LI, { jobId: jobGid2 });
      const node2 = (jr2.job?.visits?.nodes || []).find((n: any) => n.id === visitGid);
      const jb = (node2?.lineItems?.nodes || []) as Array<{ id: string; name: string }>;
      const want = new Map<string, number>();
      for (const it of items) want.set(it.name, (want.get(it.name) || 0) + 1);
      const seen = new Map<string, number>(); const extraIds: string[] = [];
      for (const ji of jb) { const n = (seen.get(ji.name) || 0) + 1; seen.set(ji.name, n); if (n > (want.get(ji.name) || 0)) extraIds.push(ji.id); }
      if (extraIds.length) {
        const dd = await gql(token, M_LI_DELETE, { id: visitGid, input: { lineItemIds: extraIds } });
        const dde = ue(dd.visitDeleteLineItems);
        console.log(dde ? `[push] dedupe warn: ${dde}` : `[push] deduped ${extraIds.length} racing duplicate line item(s) on ${visitGid}`);
      }
    }
  } catch (e) { console.log(`[push] dedupe skipped: ${e instanceof Error ? e.message : e}`); }
  console.log(`[push] synced ${lineItems.length} line item(s) to Jobber visit ${visitGid}`);
}

async function handle(op: string, visitId: number, payloadGid?: string, changed?: string[]) {
  const token = await getJobberToken();
  const { data: visit } = await db.from("visits").select("*").eq("id", visitId).maybeSingle();

  // ---- DELETE (deleted_at set, Calendar cancel = visit_status'cancelled', skip = 'skipped', or explicit op) ----
  if (op === "delete" || (visit && (visit.deleted_at || visit.visit_status === "cancelled" || visit.visit_status === "skipped"))) {
    const gid = payloadGid || (visit ? await jobberGid("visit", visitId) : null);
    if (!gid) { console.log(`[push] delete: visit ${visitId} has no jobber link — nothing to delete`); return { ok: true, note: "no link" }; }
    // IDEMPOTENT delete. Jobber's poll-replay can double-deliver, so a 2nd delete
    // hits an already-gone visit. Jobber surfaces "already gone" two different ways:
    //   (a) a TOP-LEVEL GraphQL error ("Visit does not exist") — gql() THROWS this
    //       (the path actually observed in Prod 2026-06-29, visit 6606), and
    //   (b) a visitDelete userErrors entry (defensive — Jobber is inconsistent).
    // Both mean the visit is gone, which is the desired end-state — treat as SUCCESS:
    // skip the throw, still unlink, let the handler mark sync_state='confirmed'.
    // Only a GENUINE error (anything not matching ALREADY_GONE) aborts.
    const ALREADY_GONE = /not found|could not be found|does not exist/i;
    try {
      const d = await gql(token, M_DELETE, { ids: [gid] });
      const err = ue(d.visitDelete);
      if (err && !ALREADY_GONE.test(err)) { await flag(visitId, "delete_error", err); throw new Error(`visitDelete: ${err}`); }
      if (err) console.log(`[push] delete: Jobber visit ${gid} already gone (userError: ${err}) — treating as deleted (visit ${visitId})`);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // A genuine (non-already-gone) delete failure leaves the visit still booked in Jobber — flag it
      // so ops.v_calendar_push_health surfaces it (esp. a skip whose removal did not land).
      if (!ALREADY_GONE.test(msg)) { await flag(visitId, "delete_error", msg); throw e; }
      console.log(`[push] delete: Jobber visit ${gid} already gone (${msg}) — treating as deleted (visit ${visitId})`);
    }
    // unlink so a later un-cancel (upsert) cleanly re-creates instead of editing a dead GID
    await db.from("entity_source_links").delete()
      .eq("entity_type", "visit").eq("entity_id", visitId).eq("source_system", "jobber");
    console.log(`[push] deleted Jobber visit ${gid} + unlinked (our visit ${visitId})`);
    return { ok: true, deleted: gid };
  }

  if (!visit) return { ok: true, note: "visit gone, not a delete" };
  if (visit.source !== "visit-calendar" && visit.source !== "supabase_cron") { console.log(`[push] visit ${visitId} source=${visit.source} — ignoring (not visit-calendar)`); return { ok: true, note: "not visit-calendar" }; }

  const existingGid = await jobberGid("visit", visitId);
  const sched = visitSchedule(visit);
  // Planned crew (public.visit_team; fall back to the legacy single
  // assigned_driver_id) -> Jobber user GIDs. Jobber assigns a TEAM
  // (teamMemberIdsToAssign on create, visitEditAssignedUsers on update). An empty
  // team clears the assignment. (VisitEditScheduleInput carries only start/end,
  // so assignment is always a separate mutation on update.)
  const teamGids: string[] = [];
  {
    const { data: teamRows } = await db.from("visit_team").select("employee_id").eq("visit_id", visit.id);
    const empIds = (teamRows && teamRows.length)
      ? teamRows.map((r: any) => r.employee_id)
      : (visit.assigned_driver_id ? [visit.assigned_driver_id] : []);
    for (const eid of empIds) { const g = await jobberGid("employee", eid); if (g) teamGids.push(g); }
  }

  // ---- UPDATE (already linked) ----
  // "On-purpose" push: edit ONLY the field-groups the office actually changed in the
  // Calendar (the trigger passes them as `changed`). CREW is pushed ONLY when the team
  // was edited on purpose ('crew' in changed) — so a time move / truck change / status
  // flip never clobbers Jobber's driver (the bug). A null `changed` (legacy caller)
  // falls back to the full push; an empty `changed` is a no-op.
  if (existingGid) {
    const groups: string[] | null = Array.isArray(changed) ? changed : (changed === undefined ? null : []);
    const wants = (g: string) => groups === null || groups.includes(g);
    // crew + instructions are EMPTY-CLOBBER-prone (our value is usually empty/null): push them ONLY
    // when the office EXPLICITLY edited that field — never on a legacy/unscoped null `changed` (e.g. a
    // drift-reconciler HEAL re-assert). Defense-in-depth against re-introducing the driver/instructions clobber.
    const wantsStrict = (g: string) => Array.isArray(groups) && groups.includes(g);
    const did: string[] = [];
    if (wants("schedule")) {
      const s = await gql(token, M_EDIT_SCHED, { id: existingGid, input: sched });
      const se = ue(s.visitEditSchedule); if (se) throw new Error(`visitEditSchedule: ${se}`);
      did.push("schedule");
    }
    {
      // title and instructions are INDEPENDENT: push title ONLY when title changed, instructions
      // ONLY when notes changed — so a title-only edit never wipes a Jobber visit instruction
      // (all cron visits have notes=NULL). 2026-06-27 audit fix.
      const attrs: Record<string, unknown> = {};
      if (wants("title") && visit.title) attrs.title = visit.title;
      if (wantsStrict("notes")) attrs.instructions = visit.notes ?? null;
      if (Object.keys(attrs).length) {
        const e = await gql(token, M_EDIT, { id: existingGid, attributes: attrs });
        const ee = ue(e.visitEdit); if (ee) throw new Error(`visitEdit: ${ee}`);
        did.push(Object.keys(attrs).join("+"));
      }
    }
    if (wantsStrict("crew")) {
      // Only on a deliberate team edit (explicit 'crew' group). Pushes the office's team (incl. empty = cleared on purpose).
      const a = await gql(token, M_ASSIGN, { id: existingGid, input: { assignedUserIds: teamGids } });
      const ae = ue(a.visitEditAssignedUsers); if (ae) throw new Error(`visitEditAssignedUsers: ${ae}`);
      did.push(`crew:${teamGids.length}`);
    }
    if (wants("lineitems")) {
      await syncVisitLineItems(token, visit, existingGid, true);
      did.push("lineitems");
    }
    console.log(`[push] updated Jobber visit ${existingGid} [${did.join(",") || "noop"}] (our visit ${visitId})`);
    return { ok: true, updated: existingGid, did };
  }

  // ---- CREATE (not linked) ----
  // Only auto-create Jobber visits for 'scheduled' rows — a status flip on an
  // old unlinked visit (e.g. marked completed in Calendar) must not spawn a
  // brand-new Jobber visit.
  if (visit.visit_status !== "scheduled") { console.log(`[push] visit ${visitId} status=${visit.visit_status}, unlinked — not creating in Jobber`); return { ok: true, note: "non-scheduled, not created" }; }
  // Task 3 (2026-06-27): Jobber horizon = next 60 days + the single next visit per job.
  // A cron SA visit beyond that window stays DB-ONLY (the Calendar shows 6 months); the
  // generator's daily promote step creates it in Jobber once it rolls into the 60-day window.
  {
    const { data: inScope } = await db.rpc("fn_visit_in_jobber_scope", { p_visit_id: visitId });
    if (inScope === false) {
      console.log(`[push] visit ${visitId} (${visit.visit_date}, ${visit.source}) beyond Jobber 60d horizon — DB-only, not created`);
      return { ok: true, note: "beyond-jobber-horizon" };
    }
  }
  const job = await resolveJobGid(visit);
  if ("error" in job) { await flag(visitId, "no_job_match", job.error); return { ok: true, flagged: job.error }; }
  // RACE GUARD (2026-07-03): two overlapping pushes (e.g. a skip gap-fill + the resolve-stale
  // re-driver) can both reach this CREATE branch and double-create the visit in Jobber. Re-check
  // the link immediately before creating, and after creating verify we're still the winner — if
  // another push linked a different GID meanwhile, compensate by deleting our duplicate.
  {
    const raceGid = await jobberGid("visit", visitId);
    if (raceGid) { console.log(`[push] visit ${visitId} got linked (${raceGid}) while preparing create — skipping duplicate create`); return { ok: true, note: "already-linked-race" }; }
  }
  const input = { visits: [{ title: visit.title || null, instructions: visit.notes ?? null, schedule: { ...sched, notifyTeam: false, teamMemberIdsToAssign: teamGids } }] };
  const c = await gql(token, M_CREATE, { jobId: job.gid, input });
  const ce = ue(c.visitCreate); if (ce) { await flag(visitId, "create_error", ce); throw new Error(`visitCreate: ${ce}`); }
  const newGid = c.visitCreate.createdVisits?.[0]?.id;
  if (!newGid) throw new Error("visitCreate returned no visit id");
  {
    const winner = await jobberGid("visit", visitId);
    if (winner && winner !== newGid) {
      console.log(`[push] create race lost for visit ${visitId}: ${winner} already linked — deleting our duplicate ${newGid}`);
      try { await gql(token, M_DELETE, { ids: [newGid] }); }
      catch (e) { const msg = e instanceof Error ? e.message : String(e); console.error(`[push] duplicate cleanup failed for ${newGid}: ${msg}`); await flag(visitId, "dup_create_cleanup_failed", `${newGid}: ${msg}`); }
      return { ok: true, note: "create-race-lost, duplicate removed" };
    }
  }
  await linkVisit(visitId, newGid);
  await clearFlag(visitId);
  await syncVisitLineItems(token, visit, newGid, false);
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
    const res = await handle(op, visitId, body.jobber_gid, Array.isArray(body.changed) ? body.changed : undefined);
    // sync_state confirmation (Calendar↔Jobber "no success unless Jobber confirms"): mark 'confirmed'
    // when the visit reached its settled state — pushed/updated/created, OR legitimately nothing-to-do
    // (beyond-horizon DB-only / no link to delete). Mark 'failed' when we could NOT settle it
    // (no job match / create error / a thrown error). A sync_state-only UPDATE does not re-fire the
    // push trigger (its WHEN watches visit_date/start_at/title/..., never sync_state) so no loop.
    const settled = res?.ok === true && !res?.flagged;
    await db.from("visits").update({ sync_state: settled ? "confirmed" : "failed" }).eq("id", visitId);
    return new Response(JSON.stringify(res), { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error(`[push] FATAL visit ${visitId}:`, e instanceof Error ? e.message : String(e));
    await db.from("visits").update({ sync_state: "failed" }).eq("id", visitId);
    return new Response(JSON.stringify({ ok: false, error: e instanceof Error ? e.message : String(e) }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
