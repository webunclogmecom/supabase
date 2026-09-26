// ============================================================================
// sync-jobber-job-drift — the 30-minute jobs reconcile (2026-07-30)
// ============================================================================
// Fred: "every 30 minutes we need to check we're sync … on the jobs."
// Design: docs/jobber-calendar-job-migration/2026-07-30_client-app-job-two-way-sync-design.md §3c
//
// Port of scripts/sync/reconcile_jobs.js with its three known holes fixed:
//  1. Runs on pg_cron (vault-bearer wrapper fn_request_jobber_sync('jobs-drift'),
//     schedule 15,45 * * * *) — NOT GitHub Actions, which throttled the */2 poll
//     to ~2-3h. The GH reconcile-jobs.yml schedule is retired in the same commit.
//  2. The candidate set INCLUDES jobs that went terminal in our DB within 14 days
//     (the 076-TCE/056-STM class: archived here, open in Jobber, previously
//     unable to self-heal because the old reconciler skipped DB-archived rows).
//  3. Batch reads — jobs(filter:{ids:[…50]}) — instead of one call per job.
//
// 🛑 THE ARCHIVED EXCLUSION IS DELIBERATE AND FRED-SETTLED (2026-08-03). DO NOT WIDEN IT.
//    The candidate query below filters `.not("job_status","in","(archived,closed,destroyed)")`.
//    Fred: "leave it, don't extend the reconciler to archived jobs."
//    Four archived jobs (10000171, 10000188, 2505, 10000196) hold stale line-item rows that will
//    NEVER converge, and that is the correct outcome: measured, they appear 0 times in
//    ops.client_service_options (which filters job_status <> 'archived'), so no app surface reads
//    them. Widening the sweep buys a Jobber API cost on every 30-minute run, forever, for records
//    nothing queries, charged against the leaky-bucket budget documented under BATCH/LINE_PAGE.
//    ⚠ 10000196 drifts in the OPPOSITE direction (4 job-scope rows ours, 5 in Jobber). It is
//    pre-existing, it is NOT evidence the exclusion is wrong, and it is inert under the same
//    decision. Note the exclusion is not absolute: hole #2's 14-day recent-terminal arm is the
//    sanctioned way a terminal-here / open-in-Jobber job still self-heals.
//    Workings: docs/audits/2026-08-03_qty0_orphan_cleanup_and_source_fix.md
//
// DIRECTION: Jobber → DB only. With the verified-synchronous writer
// (save-client-job), any DB-side divergence means something bypassed the saga;
// that is a FINDING (surfaced in the sync_log details), never an outbound push.
//
// No-clobber semantics preserved from handleJob: frequency_days only when the
// "Frequency" custom field is present-and-numeric; client/property never NULLed;
// line items wiped+reinserted ONLY on real diff, scoped to job-only rows
// (visit_id IS NULL AND invoice_id IS NULL), SA-titled jobs carry lines, others
// carry none.
//
// AUTH: verify_jwt=true at the gateway + role=service_role in the handler (the
// anon key also passes verify_jwt). Never deploy --no-verify-jwt.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";
// ⚠ COST MATH, measured the hard way (first deploy threw THROTTLED): Jobber's
// leaky bucket charges the REQUESTED page sizes, not the returned rows. 50 jobs
// x lineItems(first:100) requested ≈ 5k+ points per batch — three runs drained
// the 10k bucket. 25 x 25 keeps a full 449-job sweep near ~6k requested with
// 500 pts/s restoring during the run, and the inter-batch pause pays the rest.
const BATCH = 25;
const LINE_PAGE = 25;
const BATCH_PAUSE_MS = 400;
// Stop a sweep that cannot reach Jobber at all, rather than walking the whole fleet retrying.
const MAX_CONSECUTIVE_BATCH_FAILURES = 3;

// x-app-source 'jobber': these DB writes ADOPT Jobber's state (inbound direction),
// same attribution the visit drift adopt path uses (ADR 016).
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-app-source": "jobber" } } },
);

function bearerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer (.+)$/);
  if (!m) return null;
  try { return JSON.parse(atob(m[1].split(".")[1])).role ?? null; } catch { return null; }
}

// READ token (source_system='jobber') — this fn only reads Jobber.
async function getReadToken(): Promise<string> {
  const { data } = await db.from("webhook_tokens").select("access_token").eq("source_system", "jobber").single();
  if (!data?.access_token) throw new Error("no jobber read token");
  return data.access_token;
}

async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<any> {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION },
    body: JSON.stringify({ query, variables }),
  });

  // 🛑 Jobber sheds load with an HTML "Waiting Room" page at HTTP 200. The status code lies; the
  // content-type is what tells you. Without this, r.json() yields {} and this function returns
  // `undefined`, which the caller then dereferenced as `data.jobs` and killed the WHOLE sweep:
  // 30 dead runs in the 14 days to 2026-09-06, every one still logging checked=480 with
  // updated=0, sample "run failed: Cannot read properties of undefined (reading 'jobs')".
  // It is a transient load-shed, so retry it on the same ladder as a throttle, then give up loudly.
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    if (_retry < 5) {
      await new Promise((s) => setTimeout(s, Math.min(30_000, 1_000 * Math.pow(2, _retry))));
      return gql(token, query, variables, _retry + 1);
    }
    throw new Error(`Jobber returned ${ctype || "no content-type"} at HTTP ${r.status} (busy/waiting room)`);
  }

  const j = await r.json().catch(() => ({}));
  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) => e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled && _retry < 5) {
    await new Promise((s) => setTimeout(s, Math.min(30_000, 1_000 * Math.pow(2, _retry))));
    return gql(token, query, variables, _retry + 1);
  }
  if (j.errors) throw new Error(`GraphQL: ${JSON.stringify(j.errors).slice(0, 250)}`);

  // 🛑 A well-formed JSON reply carrying NO `data` key is a MISSING ANSWER, not an empty one.
  // Returning it lets the caller coerce it into "Jobber holds no such job", and the caller's
  // absence branch ARCHIVES the job. Never hand a missing answer to a comparison.
  if (j == null || typeof j !== "object" || !("data" in j) || j.data == null) {
    throw new Error(`Jobber returned no data key at HTTP ${r.status}`);
  }
  return j.data;
}

const Q_JOBS = `query($ids: [EncodedId!]) {
  jobs(first: ${BATCH}, filter: { ids: $ids }) {
    nodes {
      id jobNumber title jobStatus startAt endAt total instructions
      customFields { __typename ... on CustomFieldNumeric { label valueNumeric } }
      lineItems(first: ${LINE_PAGE}) { nodes { name quantity unitPrice totalPrice } }
    }
  }
}`;

const norm = (s: unknown) => String(s ?? "").trim();

const numEq = (a: unknown, b: unknown) => Math.abs(Number(a ?? 0) - Number(b ?? 0)) < 0.005;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok");
  if (bearerRole(req) !== "service_role") {
    return new Response(JSON.stringify({ error: "service_role required" }), { status: 403 });
  }

  const started = new Date().toISOString();
  const stats = { candidates: 0, checked: 0, updated: 0, gone_archived: 0, line_syncs: 0, errors: 0, write_errors: 0, aborted_after_consecutive_failures: 0, db_only_drift: [] as string[], error_samples: [] as string[] };

  // 🛑 A REFUSED WRITE IS NOT A WRITE (2026-09-26). Until today the three writes below discarded their
  //    `error`, so a write PostgREST refused was counted as `updated` / `gone_archived` / `line_syncs`
  //    and its title/status/date/frequency changes were lost with no trace. Proven live on 112-YA: a
  //    patch refused by jobs_active_job_number_uniq (23505) logged `updated: 1`, status 'success',
  //    while the row never changed. Now every write checks its error: a failure is counted in
  //    `errors` (so sync_log reads 'partial' and log_jobber_sync_health can see it) and in
  //    `write_errors`, with the code in the sample, and the row carries on to its next step: one
  //    failing row never aborts the batch.
  const writeFailed = (msg: string, err: { code?: string; message?: string }) => {
    stats.errors++;
    stats.write_errors++;
    const m = `${msg} (${err.code ?? "no code"}): ${err.message ?? "unknown error"}`;
    if (stats.error_samples.length < 3) stats.error_samples.push(m);
    console.error(`[jobs-drift] ${m}`);
  };

  try {
    const token = await getReadToken();

    // Candidate set: linked jobs that are live in our DB, PLUS ones that went
    // terminal here in the last 14 days (fix #2 in the header).
    // 🛑 These reads THROW on error (2026-09-26). They used to discard it, so a failed read became
    //    "0 candidates" and the run logged 'success' having compared nothing: a missing answer read
    //    as an empty one, the exact shape the header forbids. Now the run lands as 'partial'.
    const { data: live, error: liveErr } = await db.from("jobs")
      .select("id, title, job_status, start_at, end_at, frequency_days, updated_at")
      .not("job_status", "in", "(archived,closed,destroyed)");
    if (liveErr) throw new Error(`live jobs read failed: ${liveErr.message}`);
    const cutoff = new Date(Date.now() - 14 * 86_400_000).toISOString();
    const { data: recentTerminal, error: termErr } = await db.from("jobs")
      .select("id, title, job_status, start_at, end_at, frequency_days, updated_at")
      .in("job_status", ["archived", "closed", "destroyed"])
      .gte("updated_at", cutoff);
    if (termErr) throw new Error(`recent-terminal jobs read failed: ${termErr.message}`);
    const rows = [...(live ?? []), ...(recentTerminal ?? [])];

    const ids = rows.map((r) => r.id);
    const { data: links, error: linkErr } = await db.from("entity_source_links")
      .select("entity_id, source_id")
      .eq("entity_type", "job").eq("source_system", "jobber")
      .in("entity_id", ids.length ? ids : [-1]);
    if (linkErr) throw new Error(`job links read failed: ${linkErr.message}`);
    const gidByJob = new Map((links ?? []).map((l: any) => [l.entity_id, l.source_id]));
    const linked = rows.filter((r) => gidByJob.has(r.id));
    // ⚠ `candidates` is how many rows we INTENDED to check. `checked` counts the ones actually
    //   compared against a real Jobber answer, and is incremented per row below. These used to be
    //   the same assignment made BEFORE the loop, so a run that compared nothing still reported
    //   checked=480 in sync_log, which is how 30 dead runs looked healthy to every reader.
    stats.candidates = linked.length;

    let consecutiveBatchFailures = 0;

    for (let i = 0; i < linked.length; i += BATCH) {
      const slice = linked.slice(i, i + BATCH);
      const gids = slice.map((r) => gidByJob.get(r.id)!);
      if (i > 0) await new Promise((s) => setTimeout(s, BATCH_PAUSE_MS));
      let byGid: Map<string, any>;
      try {
        const data = await gql(token, Q_JOBS, { ids: gids });
        // 🛑 REQUIRE THE READ TO HAVE HAPPENED before anything is compared against it.
        //    This deref used to sit OUTSIDE this catch and read `data.jobs?.nodes ?? []`, which
        //    is two defects in one line. (a) An undefined `data` threw here and killed the whole
        //    sweep rather than one batch. (b) Worse and still latent: a reply shaped `{}` would
        //    have coerced to an empty array, every job in the slice would have missed the lookup
        //    below, and the "gone on Jobber's side" branch would have ARCHIVED all 25. Measured
        //    2026-09-06: gone_archived has only ever been 1, twice, so (b) never fired, and the
        //    crash in (a) is the only reason. Fixing (a) alone would have armed (b).
        const nodes = data?.jobs?.nodes;
        if (!Array.isArray(nodes)) throw new Error("malformed jobs payload (no nodes array)");
        byGid = new Map(nodes.map((n: any) => [n.id, n]));
        consecutiveBatchFailures = 0;
      } catch (e) {
        // A failed batch skips ITS jobs only — never the rest of the sweep.
        stats.errors++;
        const msg = `batch @${i}: ${e instanceof Error ? e.message : e}`;
        if (stats.error_samples.length < 3) stats.error_samples.push(msg);
        console.error(`[jobs-drift] ${msg}`);
        // ⚠ CIRCUIT BREAKER. Each gql() call now retries a busy Jobber up to 5 times with backoff
        //   to 30s, so a real outage would otherwise spend ~60s per batch across ~20 batches and
        //   push a 26s job toward the wall-clock ceiling, where the invocation dies before writing
        //   its sync_log row. Stop early and report instead.
        if (++consecutiveBatchFailures >= MAX_CONSECUTIVE_BATCH_FAILURES) {
          stats.aborted_after_consecutive_failures = consecutiveBatchFailures;
          console.error(`[jobs-drift] aborting sweep after ${consecutiveBatchFailures} consecutive batch failures`);
          break;
        }
        continue;
      }

      for (const row of slice) {
        try {
          const j: any = byGid.get(gidByJob.get(row.id)!);
          // Counted here and not before the loop: reaching this line means a real Jobber answer
          // for this batch was received and validated, so this row was genuinely compared.
          stats.checked++;
          if (!j) {
            // Not returned for an explicit id filter = gone on Jobber's side
            // (destroyed from their UI; the API itself cannot delete jobs).
            if (row.job_status !== "archived") {
              const { error: goneErr } = await db.from("jobs").update({ job_status: "archived" }).eq("id", row.id);
              if (goneErr) writeFailed(`job ${row.id}: gone-arm archive refused`, goneErr);
              else stats.gone_archived++;
            }
            continue;
          }
          const patch: Record<string, unknown> = {};
          if (norm(j.title) && norm(j.title) !== norm(row.title)) patch.title = j.title;
          const st = String(j.jobStatus ?? "").toLowerCase();
          if (st && st !== row.job_status) patch.job_status = st;
          if (j.startAt && new Date(j.startAt).getTime() !== new Date(row.start_at ?? 0).getTime()) patch.start_at = j.startAt;
          if (j.endAt && new Date(j.endAt).getTime() !== new Date(row.end_at ?? 0).getTime()) patch.end_at = j.endAt;
          const cf = (j.customFields ?? []).find((c: any) => c.label === "Frequency");
          if (cf && cf.valueNumeric != null && Number.isFinite(Number(cf.valueNumeric)) &&
              Number(cf.valueNumeric) !== Number(row.frequency_days ?? -1)) {
            patch.frequency_days = Number(cf.valueNumeric);
          }
          if (Object.keys(patch).length) {
            const { error: patchErr } = await db.from("jobs").update(patch).eq("id", row.id);
            if (patchErr) writeFailed(`job ${row.id}: update of ${Object.keys(patch).join(",")} refused`, patchErr);
            else stats.updated++;
          }

          // Line items: an SA job carries the set, EVERY OTHER KIND CARRIES NONE.
          //
          // 🛑 THIS IS THE RULE, NOT AN IMPLEMENTATION DETAIL. Fred, 2026-08-06:
          // "the SC shouldn't have any kind of Line Item … SC can only have line items at the
          // moment of creating a visit. Because it's for the visit."
          // Jobber INHERITS a job's line items onto every visit it creates, so anything left on
          // a Service Call JOB silently becomes the default on every future call.
          //
          // ⚠ ON 2026-08-06 I WIDENED THIS TWICE AND BOTH WERE WRONG, so do not re-derive it:
          //   - first to `nodes` for every kind, to support fee lines on SC jobs;
          //   - then to "non-SA mirrors fee lines only", still wrong for the same reason.
          // A fee on an SC JOB "works" and is still wrong: it defaults onto every future visit.
          // The fee belongs on the VISIT, which is exactly why it bills once per call.
          //
          // ⚠ AND A SEPARATE CORRECTION worth keeping: while widened, I reported that it had
          // imported 627 rows onto 452 non-SA jobs and called it damage. IT HAD NOT. Those rows
          // date from 2026-04-29 to 2026-06-23 and sit almost entirely on legacy free-text-titled
          // jobs ("Grease Trap Pumping" is a job TITLE, not a Service Call). I had compared
          // "jobs not titled Service Agreement%" against a remembered figure about SERVICE CALL
          // jobs — two different populations — and read months-old data as my own doing.
          //
          // ⚠ Writer 3 of THREE that must agree: jobToRecord's `includeLines` in
          // save-client-job, webhook-jobber ~1137, and this. They are one change, not three.
          const isSA = norm(j.title || row.title).toLowerCase().startsWith("service agreement");
          const want = isSA
            ? (j.lineItems?.nodes ?? []).map((n: any) => ({
                name: norm(n.name), quantity: Number(n.quantity ?? 1),
                unit_price: Number(n.unitPrice ?? 0), total_price: n.totalPrice != null ? Number(n.totalPrice) : null,
              }))
            : [];
          const { data: have, error: haveErr } = await db.from("line_items")
            .select("name, quantity, unit_price")
            .eq("job_id", row.id).is("visit_id", null).is("invoice_id", null);
          // A failed read of OUR lines is not "we hold none": skip this row's line sync (the catch
          // below counts it) rather than rewrite on a comparison with nothing.
          if (haveErr) throw new Error(`line_items read failed: ${haveErr.message}`);
          // ⚠ MULTISET compare, not find-by-name. Jobs legitimately carry 2-3 lines
          // with the SAME name at different prices (split pricing — measured live:
          // 10+ jobs). A find-by-name diff always matched the first duplicate,
          // declared "differs", and wiped/reinserted those jobs' lines EVERY 30-min
          // run forever (caught by the phase-2 audit: rows_updated ~11 per run,
          // never converging). Key each line as name|qty|price and compare counts.
          const bag = (rows2: any[]) => {
            const m = new Map<string, number>();
            for (const x of rows2) {
              const k = `${norm(x.name)}|${Number(x.quantity ?? 1).toFixed(2)}|${Number(x.unit_price ?? 0).toFixed(2)}`;
              m.set(k, (m.get(k) ?? 0) + 1);
            }
            return m;
          };
          const hb = bag(have ?? []), wb = bag(want);
          const differs = hb.size !== wb.size || [...wb].some(([k, n]) => hb.get(k) !== n);
          if (differs) {
            // Atomic, per-job-serialized rewrite via public.rewrite_job_line_items — ends the
            // concurrent delete-then-insert duplication race (a reopen makes this and the */5 poll
            // overlap on the same job). `want` is the desired set; [] deletes and inserts nothing.
            const { error: rwErr } = await db.rpc("rewrite_job_line_items", { p_job_id: row.id, p_lines: want });
            if (rwErr) writeFailed(`job ${row.id}: line_items rewrite refused`, rwErr);
            else stats.line_syncs++;
          }
        } catch (e) {
          stats.errors++;
          const msg = `job ${row.id}: ${e instanceof Error ? e.message : e}`;
          if (stats.error_samples.length < 3) stats.error_samples.push(msg);
          console.error(`[jobs-drift] ${msg}`);
        }
      }
    }
  } catch (e) {
    stats.errors++;
    const msg = `run failed: ${e instanceof Error ? e.message : e}`;
    if (stats.error_samples.length < 3) stats.error_samples.push(msg);
    console.error(`[jobs-drift] ${msg}`);
  }

  const { error: logErr } = await db.from("sync_log").insert({
    sync_source: "jobber_job_drift",
    started_at: started,
    finished_at: new Date().toISOString(),
    rows_updated: stats.updated + stats.line_syncs + stats.gone_archived,
    rows_errored: stats.errors,
    status: stats.errors ? "partial" : "success",
    details: stats,
  });
  // The run's only record is that row; if it cannot be written, say so in the edge log and the reply.
  if (logErr) console.error(`[jobs-drift] sync_log insert failed: ${logErr.message}`);

  return new Response(JSON.stringify({ ok: true, sync_log_error: logErr?.message ?? null, ...stats }), { headers: { "Content-Type": "application/json" } });
});
