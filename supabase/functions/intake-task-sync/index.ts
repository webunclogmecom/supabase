// ============================================================================================
// intake-task-sync: a site survey form's Jobber task closes itself (Fred, 2026-10-13)
// --------------------------------------------------------------------------------------------
// The Client App's Schedule intake makes a Jobber + Calendar task for the person sent to fill the form
// (save-calendar-task, property_intakes.calendar_task_id). Until now nothing closed it. Fred's decisions:
//   submitted form (any, even Incomplete)  -> tick the task done
//   cancelled form                          -> delete the task
//   expired form                            -> NOT handled yet (Fred asked whether forms expire; open)
// Plan: docs/superpowers/specs/2026-10-13-intake-task-close-on-submit-and-cancel-plan.md
// Migration: docs/migrations/2026-10-13_1235_intake_task_close.sql
//
// WHAT IT READS: public.v_intake_task_actions, the ONE definition of "this form's task needs closing".
//   It lists only OPEN tasks, and a form the sweeper already closed (public.intake_task_closures.done_at)
//   never comes back, so a task a person reopens by hand STAYS reopened.
//
// HOW IT WRITES: Jobber first, read back, then our copy, exactly like save-calendar-task:
//   complete  appointmentEditCompleteness -> task(id){isComplete} must be true -> ops.fn_record_calendar_task
//             with expected_is_complete:false (someone ticking it meanwhile is ZZ002, read as "already done")
//   delete    deleteAndVerify (taskDelete + read back until proven absent) -> ops.fn_delete_calendar_task
//   Nothing local changes unless Jobber confirmed. A failure is written to the ledger and retried next run.
//   The Jobber helpers are the verified ones in _shared/day-marker-task.ts (byte-identical to
//   save-calendar-task's; scripts/probes/calendar_task_helpers_verbatim.mjs).
//
// AUTH: verify_jwt = true (config.toml) AND role = service_role asserted here. Called by pg_cron
//   (public.fn_request_intake_task_sync, cron intake-task-sync, every 5 minutes). The anon key is a validly
//   signed JWT, so the gateway alone is half a gate on a function holding the Jobber write token.
//
// OBSERVABILITY: every run (dry runs excepted) writes one public.sync_log row, sync_source 'intake_task_sync',
//   status success / partial / error (success is the clean word). log_jobber_sync_health watches it with a
//   25-minute staleness window, so a sweeper that stops, or a form that fails every run, reaches Fred's
//   health email.
//
// Body: {} for a normal run, {dry_run:true} to list what it would do without touching Jobber or the DB.
// ============================================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { answered, deleteAndVerify, errsOf, getJobberToken, gql } from "../_shared/day-marker-task.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SOURCE = "intake_task_sync";
const BATCH = 20;

// x-app-source labels the audit rows of the task writes. A machine: NO x-actor-name, which
// get_record_history prints as a person's name.
const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
  global: { headers: { "x-app-source": "intake-task-sync" } },
});

const M_COMPLETE = `mutation($id: EncodedId!, $c: Boolean!){
  appointmentEditCompleteness(appointmentId: $id, input: { completed: $c }){
    appointment{ id } userErrors{ message } } }`;
const Q_DONE = `query($id: EncodedId!){ task(id: $id){ id isComplete } }`;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type Row = {
  intake_id: number; action: "complete" | "delete"; task_id: number; jobber_gid: string | null;
  since: string; attempts: number | null;
};
type Outcome = { done: true; outcome: string } | { done: false; error: string };

async function complete(token: string, r: Row): Promise<Outcome> {
  const gid = r.jobber_gid!;
  const res = await gql(token, M_COMPLETE, { id: gid, c: true });
  const errs = errsOf(res, "appointmentEditCompleteness");
  const check = await gql(token, Q_DONE, { id: gid });
  if (!answered(check)) {
    return { done: false, error: `Jobber did not answer the read-back${errs.length ? ` (the change said: ${errs.join("; ")})` : ""}` };
  }
  // Gone in Jobber: nothing to tick. The Calendar poll removes our copy after two sightings.
  if (!check.data.task) return { done: true, outcome: "gone_in_jobber" };
  if (check.data.task.isComplete !== true) {
    return { done: false, error: `Jobber still shows the task open${errs.length ? `: ${errs.join("; ")}` : ""}` };
  }
  const { error } = await db.schema("ops").rpc("fn_record_calendar_task", {
    p: {
      jobber_gid: gid, is_complete: true, expected_is_complete: false,
      completed_source: "intake", completed_at: new Date().toISOString(),
    },
    p_actor_email: null,   // machine actor, as poll-calendar-tasks
  });
  if (error?.code === "ZZ002") return { done: true, outcome: "completed_elsewhere" };
  if (error) return { done: false, error: `Jobber has it done but our copy could not be updated: ${error.message}` };
  return { done: true, outcome: "completed" };
}

async function remove(token: string, r: Row): Promise<Outcome> {
  const del = await deleteAndVerify(token, r.jobber_gid!);
  if (!del.gone) return { done: false, error: del.reason ?? "Jobber did not confirm the delete" };
  const { error } = await db.schema("ops").rpc("fn_delete_calendar_task", { p_task_id: r.task_id, p_actor_email: null });
  if (error) return { done: false, error: `The Jobber task is gone but our copy could not be removed: ${error.message}` };
  return { done: true, outcome: del.alreadyGone ? "already_gone" : "deleted" };
}

Deno.serve(async (req) => {
  const t0 = new Date();
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  // Copied from poll-calendar-tasks: the gateway verified the signature, this asserts WHICH key.
  const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  let role: string | null = null;
  try {
    const p = tok.split(".");
    if (p.length === 3) {
      const pad = p[1].replace(/-/g, "+").replace(/_/g, "/");
      role = JSON.parse(atob(pad + "=".repeat((4 - (pad.length % 4)) % 4)))?.role ?? null;
    }
  } catch { role = null; }
  if (role !== "service_role") return json({ ok: false, error: "forbidden" }, 403);

  const body = await req.json().catch(() => ({}));
  const dryRun = body?.dry_run === true;

  const items: Record<string, unknown>[] = [];
  const counts = { completed: 0, deleted: 0, failed: 0 };
  const errors: string[] = [];

  const finish = async (status: string, httpStatus = 200) => {
    const out = { ok: status !== "error", status, dry_run: dryRun, ...counts, items, errors };
    if (dryRun) return json(out, httpStatus);
    const { error } = await db.from("sync_log").insert({
      sync_source: SOURCE, started_at: t0.toISOString(), finished_at: new Date().toISOString(),
      rows_updated: counts.completed + counts.deleted, rows_errored: counts.failed, status,
      duration_seconds: (Date.now() - t0.getTime()) / 1000,
      details: { ...counts, items },
      error_details: errors.length ? { errors } : null,
    });
    if (error) console.error(`[intake-task-sync] sync_log write failed: ${error.message}`);
    return json(out, httpStatus);
  };

  const { data, error } = await db.from("v_intake_task_actions")
    .select("intake_id, action, task_id, jobber_gid, since, attempts")
    .order("since", { ascending: true }).limit(BATCH);
  if (error) {
    errors.push(`could not read v_intake_task_actions: ${error.message}`);
    return finish("error", 500);
  }
  const rows = (data ?? []) as Row[];
  if (dryRun || !rows.length) {
    for (const r of rows) items.push({ intake_id: r.intake_id, task_id: r.task_id, action: r.action, would: true });
    return finish("success");
  }

  let token: string;
  try { token = await getJobberToken(); } catch (e) {
    counts.failed = rows.length;
    errors.push(`no Jobber token: ${(e as Error).message}`);
    return finish("error", 502);
  }

  for (const r of rows) {
    let o: Outcome;
    if (!r.jobber_gid) {
      o = { done: false, error: "the task has no Jobber link, so there is nothing to change in Jobber" };
    } else {
      try { o = r.action === "complete" ? await complete(token, r) : await remove(token, r); }
      catch (e) { o = { done: false, error: `unexpected: ${(e as Error).message}` }; }
    }
    if (o.done) counts[r.action === "complete" ? "completed" : "deleted"]++;
    else { counts.failed++; errors.push(`intake ${r.intake_id} task ${r.task_id}: ${o.error}`); }
    items.push({ intake_id: r.intake_id, task_id: r.task_id, action: r.action, ...(o.done ? { outcome: o.outcome } : { error: o.error }) });

    const now = new Date().toISOString();
    const { error: lErr } = await db.from("intake_task_closures").upsert({
      intake_id: r.intake_id, action: r.action, task_id: r.task_id, jobber_gid: r.jobber_gid,
      outcome: o.done ? o.outcome : null, done_at: o.done ? now : null,
      last_error: o.done ? null : o.error, attempts: (r.attempts ?? 0) + 1, last_attempt_at: now,
    }, { onConflict: "intake_id" });
    // The Jobber and task writes already happened; a lost ledger row only means the next run re-reads the
    // row, and the view no longer lists a task that is now complete or deleted.
    if (lErr) errors.push(`intake ${r.intake_id}: ledger write failed: ${lErr.message}`);
  }

  return finish(counts.failed || errors.length ? "partial" : "success");
});
