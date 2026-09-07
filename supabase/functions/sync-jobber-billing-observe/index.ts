// ============================================================================================
// sync-jobber-billing-observe - phase A of billing two-way: THE EYES ONLY (2026-09-07)
// ============================================================================================
// Fred: "go ahead with the detect-only shadow lane for billing."
//
// Reads each job's invoicing settings from Jobber and records them in
// sync.jobber_billing_observed. It NEVER writes public.jobs, NEVER pushes to Jobber, and NEVER
// adopts. public.jobs.billing_type / invoice_frequency / invoice_rrule are "last confirmed by us"
// with no inbound reader, so a Jobber-side invoicing edit is otherwise invisible to us.
//
// 🛑 IT DOES NOT USE sync.source_field_shadow, DELIBERATELY. Two measured reasons, both reproduced
//    in rolled-back probes against the live bodies:
//      1. fn_record_shadow with p_adopted_to=NULL still re-baselines source_value on an ADOPT
//         verdict, so a finding vanishes after ONE pass and phase B is disarmed.
//      2. CONFLICT_FROZEN (P0001) raises forever once conflict_at is set, so a single conflicting
//         job would abort the whole daily run.
//    The shadow answers "did the SOURCE move", which only matters when a source value is ambiguous.
//    Jobber's billingType and billingFrequency are non-null enums. Attribution comes instead from
//    changed_at/prev_norm_* (the recorder writes CHANGE-ONLY) and from audit.logs for our side.
//
// 🛑 ALL MAPPING HAPPENS IN SQL. This function ships RAW Jobber values to
//    sync.fn_record_billing_observations. Normalising here would be a third implementation
//    alongside save-client-job and the SQL normaliser, and a detector that drifts from the writer
//    reports phantom findings forever.
//
// 🛑 AN ABSENT NODE IS NO OBSERVATION, NOT AN EMPTY ONE. A job Jobber does not return is omitted
//    from the batch entirely and counted in unresolvable_gids. Coercing a missing answer into a
//    value is the defect that armed a mass archive in sync-jobber-job-drift, and the recorder
//    cannot tell the difference, so the responsibility is here.
//
// COST, measured 2026-09-07: a billing-only page is 5.2 points/node, so ~486 jobs is ~2,900 points
// against a 10,000 bucket at first:100 in 5 requests. first:25 is measurably WORSE per node (6.0).
//
// AUTH: verify_jwt=true at the gateway + role=service_role in the handler (the anon key also passes
// verify_jwt). Never deploy --no-verify-jwt.
// ============================================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GRAPHQL_VERSION = '2026-04-16'
// Same budget discipline as sync-jobber-poll v26. This runs alone at 02:00 ET so contention is
// near zero, but the floor costs nothing and a shared bucket has bitten this estate before.
const THROTTLE_FLOOR = 3500
const THROTTLE_RESTORE_PER_S = 500
let throttleAvailable = Number.POSITIVE_INFINITY   // unknown until Jobber first tells us
const PAGE = 100

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// ⚠ THERE IS DELIBERATELY NO EXCLUSION LIST HERE. An earlier version of this file carried a
//    hardcoded EXCLUDED_JOB_IDS = [1720, 576] "so they are not permanent findings". Measured
//    2026-09-07, BOTH exclusions were unnecessary and the list was pure stale-list hazard:
//      1720 (000-DH Homestead Dump)  ours fixed/once_closed      <-> Jobber FIXED_PRICE/ON_COMPLETION
//      1662 (000-DP DUMP Pompano)    ours visit_based/as_needed  <-> Jobber VISIT_BASED/NEVER
//    Both AGREE with Jobber so neither produces a finding, and 576 has since been archived in
//    Jobber and leaves the candidate set on its own.
//    It was also ASYMMETRIC: it excluded Homestead's job and not Pompano's, for no reason beyond
//    which one came up in conversation. A hand-maintained list of ids is exactly what this estate
//    keeps paying for; this detector reports what it observes and lets the comparison decide.
//    🛑 If a dump-site job ever DOES drift, that is a real finding and must not be hidden here.

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-app-source": "jobber-billing-observe" } } },
);

function bearerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer (.+)$/);
  if (!m) return null;
  try { return JSON.parse(atob(m[1].split(".")[1])).role ?? null; } catch { return null; }
}

async function getReadToken(): Promise<string> {
  const { data } = await db.from("webhook_tokens").select("access_token")
    .eq("source_system", "jobber").single();
  if (!data?.access_token) throw new Error("no jobber read token");
  return data.access_token;
}

// ── gql() below is COPIED VERBATIM from sync-jobber-poll (v26), never retyped. It carries the
//    content-type guard for Jobber's HTML waiting room at HTTP 200, the throttle retry, and the
//    bucket pacing. Keep them in step; do not fork a fourth implementation.
async function gql(token: string, query: string, variables: Record<string, unknown> = {}, attempt = 0): Promise<any> {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': GRAPHQL_VERSION },
    body: JSON.stringify({ query, variables }),
  })

  // 🛑 Jobber sheds load with an HTML "Waiting Room" page at HTTP 200. Without this guard
  // `r.json()` throws and the caller reads the failure as "this entity has no rows". CLAUDE.md lists
  // this function among the 10 that lacked the check.
  const ctype = r.headers.get('content-type') ?? ''
  if (!ctype.includes('json')) throw new Error(`Jobber returned ${ctype || 'no content-type'} at HTTP ${r.status} (busy/waiting room)`)

  const j = await r.json()

  // Record the live balance BEFORE any throw, so a throttled failure still teaches us the state.
  const th = j?.extensions?.cost?.throttleStatus
  if (th && typeof th.currentlyAvailable === 'number') throttleAvailable = th.currentlyAvailable

  if (j.errors?.length) {
    const throttled = j.errors.some((e: any) =>
      e?.extensions?.code === 'THROTTLED' || /throttl|rate limit/i.test(String(e?.message ?? '')))
    if (throttled && attempt < 3) {
      await sleep(2000 * (attempt + 1))
      throttleAvailable = Number.POSITIVE_INFINITY   // force a fresh read from the retry's response
      return gql(token, query, variables, attempt + 1)
    }
    throw new Error(`GraphQL: ${JSON.stringify(j.errors[0]).slice(0, 200)}`)
  }

  // Below the floor, wait for the bucket to refill. The NEXT response corrects this estimate, so a
  // wrong guess here self-heals rather than compounding.
  if (throttleAvailable < THROTTLE_FLOOR) {
    const waitMs = Math.min(20000, Math.ceil(((THROTTLE_FLOOR - throttleAvailable) / THROTTLE_RESTORE_PER_S) * 1000))
    await sleep(waitMs)
    throttleAvailable += (waitMs / 1000) * THROTTLE_RESTORE_PER_S
  }

  return j.data
}

// Billing-only selection. Nothing else is read, so the page stays cheap and this function can
// never accidentally act on a field it had no business fetching.
const Q_BILLING = `query($ids: [EncodedId!]) {
  jobs(first: ${PAGE}, filter: { ids: $ids }) {
    nodes {
      id
      billingType
      invoiceSchedule { billingFrequency recurrenceSchedule { calendarRule } }
    }
  }
}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok");
  if (bearerRole(req) !== "service_role") {
    return new Response(JSON.stringify({ error: "service_role required" }), { status: 403 });
  }

  const started = new Date().toISOString();
  const stats = {
    jobs_requested: 0, jobs_returned: 0, jobs_upserted: 0,
    unresolvable_gids: [] as unknown[], changed_ids: [] as number[],
    observed_job_ids: [] as number[], ok: false, error: null as string | null,
  };

  try {
    const token = await getReadToken();

    // Candidate set: every job we could show billing for. Live jobs, PLUS archived jobs that
    // carry a billing value, because client.jobs does NOT filter archived and the Client App can
    // still display them. Cost of the archived tail is ~72 points.
    const { data: live, error: liveErr } = await db.from("jobs")
      .select("id, job_status, billing_type")
      .not("job_status", "in", "(archived,closed,destroyed)");
    if (liveErr) throw new Error(`candidate read failed (live): ${liveErr.message}`);
    const { data: arch, error: archErr } = await db.from("jobs")
      .select("id, job_status, billing_type")
      .in("job_status", ["archived", "closed", "destroyed"])
      .not("billing_type", "is", null);
    if (archErr) throw new Error(`candidate read failed (archived): ${archErr.message}`);

    const candidateIds = [...(live ?? []), ...(arch ?? [])]
      .map((r: any) => r.id as number);

    // Only jobs we hold a Jobber link for can be read at all.
    const { data: links, error: linkErr } = await db.from("entity_source_links")
      .select("entity_id, source_id")
      .eq("entity_type", "job").eq("source_system", "jobber")
      .in("entity_id", candidateIds.length ? candidateIds : [-1]);
    if (linkErr) throw new Error(`link read failed: ${linkErr.message}`);

    const gidByJob = new Map<number, string>((links ?? []).map((l: any) => [l.entity_id, l.source_id]));
    const jobByGid = new Map<string, number>();
    for (const [jobId, gid] of gidByJob) jobByGid.set(gid, jobId);
    const targets = candidateIds.filter((id) => gidByJob.has(id));
    stats.jobs_requested = targets.length;

    for (let i = 0; i < targets.length; i += PAGE) {
      const slice = targets.slice(i, i + PAGE);
      const gids = slice.map((id) => gidByJob.get(id)!);

      // A batch failure is fatal here, unlike a reconciler: this function's whole output is a
      // coverage claim, and a silently short run is exactly the failure it exists to make visible.
      // The run row records what was achieved, and jobs_returned < jobs_requested is the signal.
      const data = await gql(token, Q_BILLING, { ids: gids });
      const nodes = data?.jobs?.nodes;
      if (!Array.isArray(nodes)) throw new Error(`malformed jobs payload at offset ${i}`);

      const byGid = new Map<string, any>(nodes.map((n: any) => [n.id, n]));
      const rows: Record<string, unknown>[] = [];
      for (const jobId of slice) {
        const gid = gidByJob.get(jobId)!;
        const n = byGid.get(gid);
        if (!n) {
          // NO OBSERVATION. Not an empty one. It is never sent to the recorder and never compared.
          stats.unresolvable_gids.push({ job_id: jobId, gid });
          continue;
        }
        rows.push({
          job_id: jobId,
          jobber_gid: gid,
          billing_type: n.billingType ?? null,
          billing_frequency: n.invoiceSchedule?.billingFrequency ?? null,
          // ⚠ invoiceSchedule, NOT visitSchedule. Taking the visit cadence here would write a visit
          //    schedule into a billing column, and phase B would then push it to Jobber.
          calendar_rule: n.invoiceSchedule?.recurrenceSchedule?.calendarRule ?? null,
        });
      }
      stats.jobs_returned += rows.length;

      if (rows.length) {
        const { data: rec, error: recErr } = await db.rpc("fn_record_billing_observations",
          { p_rows: rows });
        if (recErr) throw new Error(`recorder failed at offset ${i}: ${recErr.message}`);
        stats.jobs_upserted += Number((rec as any)?.changed ?? 0);
        stats.changed_ids.push(...(((rec as any)?.changed_ids ?? []) as number[]));
        stats.observed_job_ids.push(...(((rec as any)?.observed_ids ?? []) as number[]));
      }
    }

    stats.ok = true;
  } catch (e) {
    stats.error = e instanceof Error ? e.message : String(e);
    console.error(`[billing-observe] ${stats.error}`);
  }

  // The run row is written on EVERY path, success or failure. It is the only thing that can tell a
  // reader "this observation is fresh and covered N of M", and a run that dies without one is
  // indistinguishable from a run that never happened.
  // 🛑 VIA THE PUBLIC WRAPPER, NOT db.from(). supabase-js .from() resolves through PostgREST in the
  //    EXPOSED schemas, and `sync` is not one of them. The first live run used .from() here: it
  //    returned ok:true with 483 rows recorded and this write failed with PGRST205, so the ONE thing
  //    that silently broke was the freshness record. Confirmed with a control (public.jobs returns
  //    200 on the same client). Do not "simplify" this back to .from().
  const { error: runErr } = await db.rpc("fn_record_billing_observe_run", {
    p_started_at: started,
    p_jobs_requested: stats.jobs_requested,
    p_jobs_returned: stats.jobs_returned,
    p_jobs_upserted: stats.jobs_upserted,
    p_observed_job_ids: stats.observed_job_ids,
    p_unresolvable_gids: stats.unresolvable_gids,
    p_ok: stats.ok,
    p_error: stats.error,
  });
  // A missing run row makes every observation unverifiable, so it is reported to the caller rather
  // than only logged. The observations themselves are already durable at this point.
  if (runErr) {
    console.error(`[billing-observe] run row failed: ${runErr.message}`);
    stats.error = `${stats.error ? stats.error + "; " : ""}run row failed: ${runErr.message}`;
    stats.ok = false;
  }

  return new Response(JSON.stringify({
    ok: stats.ok,
    jobs_requested: stats.jobs_requested,
    jobs_returned: stats.jobs_returned,
    changed: stats.jobs_upserted,
    changed_ids: stats.changed_ids,
    unresolvable: stats.unresolvable_gids.length,
    error: stats.error,
  }), { headers: { "Content-Type": "application/json" } });
});
