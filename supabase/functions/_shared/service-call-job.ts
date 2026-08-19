// The ONE definition of "a property gets a Service Call job". Every path that creates a property
// calls this. Do not assemble the rule a second time anywhere: two copies of one rule is how the
// 2026-08-18 custom-field sync defects were born.
//
// 🛑 THERE IS NO jobDelete AND NO jobArchive. The only teardown is jobClose(DESTROY_ALL), which also
//    destroys the job's scheduled visits. So every check runs BEFORE Jobber is touched, and every DB
//    read that gates the create FAILS CLOSED: a discarded supabase-js error returns data:null, which
//    reads as "no job exists" and would create a duplicate nobody can remove.
//
// 🛑 THIS DOES NOT BUILD THE JOB ITSELF. save-client-job already creates SC jobs and owns the
//    read-back verify plus the atomic row+link write via fn_record_client_job. Reimplementing any of
//    that here would be a second assembly of the same rule. This function decides WHETHER, and
//    delegates HOW.

export type EnsureReason =
  | "property_not_in_jobber" | "link_lookup_failed" | "job_lookup_failed"
  | "job_lookup_ambiguous"
  | "job_create_failed" | "job_create_unreadable" | "job_not_recorded";

// 🛑 CODES save-client-job CAN RETURN *AFTER* jobCreate ALREADY SUCCEEDED. Mapping any of these to
//    "failed" would be a lie with permanent consequences: `failed` means nothing was left behind, so
//    the caller records job_step='failed', v_client_create_attention stays empty, and the next retry
//    creates a SECOND undeletable job. Verified against save-client-job/index.ts:
//      db_write_failed   :1143  "The job WAS created in Jobber (#N) but saving it locally failed"
//      verify_failed     :1094, :1108, :1117, :1127, :1133  "Jobber created the job but ..."
//      jobber_no_answer  :1077  "It may or may not have created the job - check Jobber before retrying"
//    ⚠ ANYTHING UNRECOGNISED ALSO MAPS HERE, not to job_create_failed. The fail-safe answer to
//      "I do not know whether Jobber holds a job" is "assume it might", exactly as isLive() treats an
//      unknown status as live.
const CODES_MEANING_JOBBER_MAY_HOLD_IT = new Set(["db_write_failed", "verify_failed", "jobber_no_answer"]);

// Codes that provably precede the mutation, so nothing exists upstream and a retry is safe.
const CODES_MEANING_NOTHING_WAS_CREATED = new Set([
  "bad_request", "forbidden", "not_found", "method_not_allowed",
  "jobber_rejected", "jobber_unreachable", "jobber_unavailable", "jobber_busy",
]);

export type EnsureResult =
  | { ok: true;  created: boolean; job_id: number; detail: string }
  | { ok: false; reason: EnsureReason; detail: string };

// Measured on Prod 2026-08-19: the live job_status values are action_required, active, archived,
// late, requires_invoicing, today, upcoming. Only `archived` of the three terminal names actually
// occurs; `closed` and `destroyed` are kept because save-client-job and sync-jobber-job-drift both
// treat them as terminal and Jobber can still produce them.
const TERMINAL = new Set(["archived", "closed", "destroyed"]);

/** Live = not terminal. ⚠ A NULL status counts as LIVE, deliberately: see isLive's note below. */
function isLive(status: unknown): boolean {
  const s = String(status ?? "").trim().toLowerCase();
  // 🛑 FAIL SAFE ON NULL. Measured 2026-08-19: 0 jobs carry a NULL job_status, so this is latent
  //    rather than live. It matters anyway because of WHICH WAY it fails. Filtering in PostgREST
  //    with .not("job_status","in","(...)") would drop a NULL row entirely (SQL: NOT (NULL IN ...)
  //    is NULL, not TRUE), so an existing Service Call with a NULL status would be INVISIBLE to the
  //    idempotency check and we would mint a duplicate that no API can delete. Treating unknown as
  //    live means the worst case is refusing to create a job somebody can add by hand, instead of
  //    creating a permanent duplicate.
  if (s === "") return true;
  return !TERMINAL.has(s);
}

/**
 * A live Service Call job among these rows, or null.
 * ⚠ Compared in JS, TRIMMED and LOWERCASED, not in PostgREST. The DB predicate is
 * lower(btrim(title)) = 'service call', which PostgREST cannot express: .ilike() does not trim.
 * Measured 2026-08-19: 19 live jobs match case-insensitively but are not the exact string
 * 'Service Call', one of them with a trailing space.
 * ⚠ EQUALITY, never a prefix. ops.client_jobs classifies on a 'service call%' PREFIX and would call
 * 'Service Call - 341' a Service Call; this must not, or a differently-titled job would suppress the
 * one the property is owed.
 */
function findServiceCall(jobs: Array<{ id: number; title: string | null; job_status: string | null }> | null) {
  return (jobs ?? []).find((j) =>
    isLive(j.job_status) && String(j.title ?? "").trim().toLowerCase() === "service call") ?? null;
}

export async function ensureServiceCallJob(opts: {
  db: any;              // supabase-js client, service_role
  authHeader: string;   // the CALLER's Authorization header, forwarded so the write is attributed
  clientId: number;
  propertyId: number;
}): Promise<EnsureResult> {
  const { db, authHeader, clientId, propertyId } = opts;

  // ---- 1. resolve the property's REAL Jobber GID ---------------------------------------------
  // 🛑 A '<gid>_billing' link is NOT a property id: it decodes to gid://Jobber/Client/<n> with the
  //    literal ASCII '_billing' appended, so jobCreate rejects it.
  // ⚠ WHAT THAT LINK ACTUALLY IS, measured 2026-08-19 and NOT what an earlier draft assumed: Jobber
  //    mints ONE property for a clientCreate and no billing property at all. The billing twin is OUR
  //    row, inserted by handleClient from billingAddress (webhook-jobber:628), which is exactly why
  //    its link is synthetic. So a property row carries ONE link, real OR synthetic, never both:
  //    0 of 901 properties have two. The find() below is therefore a classifier, not a chooser, and
  //    it stays written this way so an unexpected second link cannot pick the wrong one.
  // ⚠ Filtered in JS because a LIKE pattern of '%\_billing' puts an escape into the wire format and
  //    '_' is itself a LIKE wildcard.
  const { data: links, error: linkErr } = await db
    .from("entity_source_links")
    .select("source_id")
    .eq("entity_type", "property")
    .eq("entity_id", propertyId)
    .eq("source_system", "jobber");
  if (linkErr) {
    return { ok: false, reason: "link_lookup_failed",
      detail: `Could not read the property's Jobber link: ${linkErr.message}` };
  }
  const realGid = (links ?? [])
    .map((l: any) => String(l.source_id ?? ""))
    .find((s: string) => s !== "" && !s.endsWith("_billing"));
  if (!realGid) {
    return { ok: false, reason: "property_not_in_jobber",
      detail: "This property has no real Jobber property link (only a billing twin, or none at all), so no job can be created on it." };
  }

  // ---- 2. idempotency, BEFORE Jobber ---------------------------------------------------------
  // ⚠ No job_status filter in the query on purpose: terminal rows are removed by isLive() in JS so
  //    a NULL status cannot vanish from the result set. See isLive.
  const { data: before, error: jobErr } = await db
    .from("jobs")
    .select("id,title,job_status")
    .eq("property_id", propertyId);
  if (jobErr) {
    return { ok: false, reason: "job_lookup_failed",
      detail: `Could not check for an existing Service Call: ${jobErr.message}` };
  }
  const existing = findServiceCall(before);
  if (existing) {
    return { ok: true, created: false, job_id: Number(existing.id),
      detail: "This property already has a Service Call job." };
  }

  // ---- 2b. THE MIRROR COLUMN CAN LIE, SO REFUSE WHEN IT MIGHT ---------------------------------
  // 🛑 `jobs.property_id` is a BEST-EFFORT mirror, not the truth. webhook-jobber only sets it when
  //    the property is already linked at import time (`if (propertyId) jobRow.property_id = ...`),
  //    and the jobs cursor is `createdAt`, so a job imported before its property was linked keeps a
  //    NULL forever - nothing backfills it. Measured on Prod 2026-08-19: 57 of 1811 jobs carry a
  //    NULL property_id, and TWO of them are LIVE Service Calls (#99901056 on our property 1069,
  //    #99901058 on 1075). For those, step 2 above returns zero rows while Jobber plainly holds a
  //    Service Call on that very property. Delegating there mints a SECOND, permanently undeletable
  //    job. Confirmed by reading Jobber directly, not inferred.
  // ⇒ If this client has ANY live Service Call whose property we cannot place, we do not know
  //   whether it belongs to this property. Refuse, loudly. A refusal costs a job somebody adds by
  //   hand; the alternative costs a duplicate nobody can ever remove.
  const { data: unplaced, error: unplacedErr } = await db
    .from("jobs")
    .select("id,title,job_status,property_id")
    .eq("client_id", clientId)
    .is("property_id", null);
  if (unplacedErr) {
    return { ok: false, reason: "job_lookup_failed",
      detail: `Could not check this client's unplaced jobs: ${unplacedErr.message}` };
  }
  const ambiguous = findServiceCall(unplaced);
  if (ambiguous) {
    return { ok: false, reason: "job_lookup_ambiguous",
      detail: `This client has a live Service Call job (id ${ambiguous.id}) that is not linked to any property here, so we cannot tell whether it already covers this one. Link that job to its property first, then retry.` };
  }

  // ---- 3. delegate ---------------------------------------------------------------------------
  // Send NOTHING else. services and fees are hard-refused for SC (Fred, 2026-08-06: an SC job
  // carries no line items at all), and start_date / frequency_days are silently ignored.
  // ---- 4. ask our own DB what is on the property NOW -------------------------------------------
  // Used on EVERY exit from the delegate, not only the happy one. A remote object created while the
  // local write failed is worse than a failed push (jobber-push-task, 2026-08-06), and the moment
  // that is most in doubt is precisely the one where we could not read the reply.
  const reread = async (): Promise<{ id: number } | null | "error"> => {
    const { data: after, error: afterErr } = await db
      .from("jobs").select("id,title,job_status").eq("property_id", propertyId);
    if (afterErr) return "error";
    const landed = findServiceCall(after);
    return landed ? { id: Number(landed.id) } : null;
  };

  let r: Response;
  try {
    r = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/save-client-job`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: authHeader },
      body: JSON.stringify({
        action: "create",
        client_id: clientId,
        patch: { kind: "SC", property_id: propertyId, billing_type: "visit_based", invoice_frequency: "per_visit" },
      }),
    });
  } catch (e) {
    // 🛑 A LOST REPLY IS NOT A LOST WRITE. The request may well have completed. Look before
    //    concluding: if the job is there, it worked and we simply did not hear back.
    const landed = await reread();
    if (landed && landed !== "error") {
      return { ok: true, created: true, job_id: landed.id,
        detail: "Service Call job created (the reply was lost, but the job is recorded)." };
    }
    return { ok: false, reason: "job_not_recorded",
      detail: `Could not reach save-client-job (${e instanceof Error ? e.message : String(e)}) and no Service Call job is recorded. Jobber may still hold one: check before retrying.` };
  }

  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    const landed = await reread();
    if (landed && landed !== "error") {
      return { ok: true, created: true, job_id: landed.id,
        detail: "Service Call job created (the reply was unreadable, but the job is recorded)." };
    }
    return { ok: false, reason: "job_not_recorded",
      detail: `save-client-job returned ${ctype || "an unknown content type"} at HTTP ${r.status} and no Service Call job is recorded. Jobber may still hold one: check before retrying.` };
  }

  let j: any = {};
  try { j = await r.json(); } catch { j = {}; }
  // ⚠ save-client-job answers HTTP 200 for BOTH outcomes: fail() returns {ok:false,...} at status
  //    200. So r.ok is not the discriminator; the body's ok flag is. Checking only r.ok would read
  //    every refusal as a success.
  if (!r.ok || j?.ok !== true) {
    const code = String(j?.code ?? "");
    const msg = String(j?.message ?? `save-client-job returned HTTP ${r.status} with no ok flag`);
    // A refusal that provably precedes the mutation is safe to call a failure. Everything else,
    // INCLUDING an unrecognised code, may have left a job in Jobber.
    if (CODES_MEANING_NOTHING_WAS_CREATED.has(code)) {
      return { ok: false, reason: "job_create_failed", detail: msg };
    }
    if (CODES_MEANING_JOBBER_MAY_HOLD_IT.has(code) || code === "") {
      const landed = await reread();
      if (landed && landed !== "error") {
        return { ok: true, created: true, job_id: landed.id,
          detail: `save-client-job reported "${code || "an error"}" but the job is recorded: ${msg}` };
      }
      return { ok: false, reason: "job_not_recorded",
        detail: `${msg} (code ${code || "none"}). Jobber may hold a Service Call job we never recorded: check before retrying.` };
    }
    // Unrecognised: fail SAFE, not convenient.
    return { ok: false, reason: "job_not_recorded",
      detail: `${msg} (unrecognised code ${code}). Treating it as "Jobber may hold a job" because we cannot prove otherwise.` };
  }

  // ---- 5. verify what LANDED, re-read, never echoed --------------------------------------------
  const landed = await reread();
  if (landed === "error") {
    return { ok: false, reason: "job_not_recorded",
      detail: "save-client-job reported success but we could not verify it. Check before retrying." };
  }
  if (!landed) {
    return { ok: false, reason: "job_not_recorded",
      detail: "save-client-job reported success but no Service Call job is on this property. Jobber may hold a job we never recorded." };
  }
  return { ok: true, created: true, job_id: landed.id, detail: "Service Call job created." };
}
