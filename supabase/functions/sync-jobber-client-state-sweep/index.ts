// ============================================================================
// sync-jobber-client-state-sweep : weekly, READ-ONLY, "do Jobber and we agree on who is a client?"
// ============================================================================
// Shipped 2026-09-18 with "archive is the delete" (audit: Building Apps/Client App/docs/
// 2026-09-18_client-delete-audit.md, graft 3). Once the Clients App hides INACTIVE rows, these
// divergences become silent unless something looks for them:
//
//   inactive_client_live_in_jobber    ours INACTIVE, Jobber isArchived=false. Jobber auto-unarchives a
//                                     client when new work is created there ("+ Create", or the client
//                                     submitting a request); our status_source='manual' pin keeps the
//                                     row INACTIVE, its new jobs and visits sync in and show on the
//                                     Calendar, and the Clients App hides the client.
//   linked_client_gone_in_jobber      ours ACTIVE / RECURRING / PAUSED, Jobber client(id) is null with
//                                     no errors key. A CLIENT_DESTROY that never arrived: that webhook
//                                     is ack-first, Jobber never retries it, and deliveries before
//                                     2026-08-21 were refused outright.
//   live_client_archived_in_jobber    ours ACTIVE / RECURRING / PAUSED, Jobber isArchived=true. A lost
//                                     CLIENT_UPDATE(isArchived) after the poll's window closed. The
//                                     fourth quadrant of the audit's matrix; without it the covers
//                                     text below would over-claim.
//
// 🛑 THIS FUNCTION WRITES NOTHING TO clients, visits OR entity_source_links, AND MUST NEVER.
//    A null read is an ABSENCE. This estate has soft-deleted 756 live visits from an absence once
//    (2026-08-14) and the judges of the audit found the same defect in a design that let a sweep
//    flip status from a null: the status flip fires trg_clients_cleanup_sa_visits_on_status, which
//    soft-deletes upcoming Service Agreement visits and queues Jobber visitDelete pushes, against a
//    client Jobber may still have. So the sweep REPORTS, into sync_log, and a person resolves each
//    item through the app (archive-client / unarchive-client / Edit client status).
//
// HOW A NULL IS ALLOWED TO MEAN "GONE" HERE (and only here, and only as a report): gql() throws on
// every shape that could mean "no answer" (non-JSON body, an errors array, a missing data key), so
// an alias that comes back null inside a well-formed data object is Jobber affirmatively saying it
// holds no such client. An alias absent from the reply entirely is UNKNOWN and is counted as such.
// Three more guards, added after the 2026-09-18 review:
//   - MASS NULL CEILING. If more than max(5, 10%) of the checked clients read null the run is an
//     error, the gone items are dropped and the reason names the shape (a token re-authorised
//     against another Jobber account, or a Jobber incident answering null for everything). A
//     systemic null must read as a broken sweep, never as hundreds of deleted clients.
//   - CARRY FORWARD. The health views read the LATEST row per source and mark an item resolved
//     the moment it stops appearing. So a run that could not ask Jobber about part of the fleet
//     (partial) or at all (error) re-emits the previous run's items for the clients it did not
//     check, flagged carried_forward, instead of silently resolving them and re-newing them a week
//     later.
//   - A FAILED RUN IS ITSELF AN ITEM (sweep_failed), because a once-a-week source can never trip
//     the health function's sync_failed arm (which needs 2 failures in 24 hours).
//
// COST, measured live 2026-09-17 (audit reader, rsweep): { id isArchived } for 471 clients in 19
// requests of 25 aliases cost about 1,409 points of the 10,000 bucket. Pace at 2 s between requests
// and stop below THROTTLE_FLOOR like the sibling drift functions. A failed batch is retried once
// after a backoff before it counts as unknown, and the breaker sleeps between attempts so a brief
// waiting room does not burn the whole weekly run in one second.
//
// SURFACES: sync_log row sync_source='jobber-client-state-sweep' (status ok / attention / partial /
// error, details.items one per flagged client with a stable `kind` key), read by ops.v_health_items
// and ops.v_health_status (registered in migration 2026-09-18_0100), escalated by health-escalate
// when an item is new or 3 days old. Scheduled by pg_cron 'jobber-client-state-sweep' Sunday 07:15
// UTC through public.fn_request_jobber_sync('client-state-sweep'). The health function's sync_stuck
// arm exempts this source (a weekly 'attention' is one run, not a streak).
//
// AUTH: verify_jwt=true at the gateway + role=service_role in the handler (the anon key also
// passes verify_jwt). Never deploy --no-verify-jwt.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";
const BATCH = 25;
const BATCH_PAUSE_MS = 2000;
const RETRY_BACKOFF_MS = [8000, 30000];
const MAX_CONSECUTIVE_BATCH_FAILURES = 3;
const THROTTLE_FLOOR = 3500;
const PAGE = 1000;                      // PostgREST max_rows; page rather than trust one select
const LIVE_STATUSES = new Set(["ACTIVE", "RECURRING", "PAUSED"]);
const SOURCE = "jobber-client-state-sweep";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function bearerRole(req: Request): string | null {
  const m = (req.headers.get("authorization") || "").match(/^Bearer (.+)$/);
  if (!m) return null;
  try { return JSON.parse(atob(m[1].split(".")[1])).role ?? null; } catch { return null; }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function jobberToken(): Promise<string> {
  const { data, error } = await db.from("webhook_tokens").select("access_token")
    .eq("source_system", "jobber").maybeSingle();
  if (error || !data?.access_token) throw new Error(`no jobber token: ${error?.message ?? "missing"}`);
  return data.access_token as string;
}

let throttleAvailable = Number.POSITIVE_INFINITY;

/** One GraphQL round trip. The three guards are the whole reason a null alias may be read as "gone". */
async function gql(token: string, query: string): Promise<Record<string, unknown>> {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION,
    },
    body: JSON.stringify({ query }),
  });
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    throw new Error(`jobber returned ${ctype || "no content-type"} at HTTP ${r.status} (waiting room?)`);
  }
  const j = await r.json();
  if (Array.isArray(j?.errors) && j.errors.length) {
    throw new Error(`jobber graphql error: ${JSON.stringify(j.errors[0]?.message ?? j.errors[0])}`);
  }
  if (!j || typeof j !== "object" || !("data" in j) || j.data == null) {
    throw new Error("jobber reply carried no data key");
  }
  const t = j?.extensions?.cost?.throttleStatus;
  if (t?.currentlyAvailable != null) throttleAvailable = Number(t.currentlyAvailable);
  return j.data as Record<string, unknown>;
}

async function payThrottle() {
  if (!Number.isFinite(throttleAvailable) || throttleAvailable >= THROTTLE_FLOOR) return;
  const need = THROTTLE_FLOOR - throttleAvailable;
  await sleep(Math.min(10_000, Math.ceil((need / 500) * 1000)));
}

/** One batch, with one retry after a backoff. Throws only after both attempts failed. */
async function gqlWithRetry(token: string, query: string): Promise<Record<string, unknown>> {
  let lastErr: unknown;
  for (let attempt = 0; attempt <= RETRY_BACKOFF_MS.length; attempt++) {
    try {
      await payThrottle();
      return await gql(token, query);
    } catch (e) {
      lastErr = e;
      if (attempt < RETRY_BACKOFF_MS.length) await sleep(RETRY_BACKOFF_MS[attempt]);
    }
  }
  throw lastErr;
}

type Issue = "inactive_client_live_in_jobber" | "linked_client_gone_in_jobber" | "live_client_archived_in_jobber" | "sweep_failed";
type Item = {
  kind: string; issue: Issue; reason: string;
  client_id: number | null; client_code: string | null; name: string;
  our_status: string | null; status_source: string | null; jobber_state: "live" | "archived" | "gone" | "unknown";
  carried_forward?: boolean;
};

type ClientRow = { id: number; client_code: string | null; name: string | null; status: string | null; status_source: string | null };

/** Every client, paged, because a single select silently stops at PostgREST's max_rows. */
async function allClients(): Promise<ClientRow[]> {
  const out: ClientRow[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await db.from("clients")
      .select("id, client_code, name, status, status_source")
      .order("id", { ascending: true })
      .range(from, from + PAGE - 1);
    if (error) throw new Error(`clients query failed: ${error.message}`);
    out.push(...((data ?? []) as ClientRow[]));
    if (!data || data.length < PAGE) break;
  }
  return out;
}

async function allClientLinks(): Promise<Map<number, string>> {
  const gidOf = new Map<number, string>();
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await db.from("entity_source_links")
      .select("entity_id, source_id")
      .eq("entity_type", "client").eq("source_system", "jobber")
      .order("id", { ascending: true })
      .range(from, from + PAGE - 1);
    if (error) throw new Error(`link query failed: ${error.message}`);
    for (const l of data ?? []) gidOf.set(Number(l.entity_id), String(l.source_id));
    if (!data || data.length < PAGE) break;
  }
  return gidOf;
}

/** The previous run's items, so a run that could not check a client does not silently resolve it. */
async function previousItems(): Promise<Item[]> {
  const { data, error } = await db.from("sync_log")
    .select("details")
    .eq("sync_source", SOURCE)
    .order("started_at", { ascending: false })
    .limit(1);
  if (error || !data || !data.length) return [];
  const items = (data[0] as { details?: { items?: unknown } }).details?.items;
  return Array.isArray(items) ? (items as Item[]).filter((i) => i && typeof i.kind === "string" && i.issue !== "sweep_failed") : [];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { status: 200 });
  if (bearerRole(req) !== "service_role") {
    return new Response(JSON.stringify({ error: "service_role required" }), { status: 401 });
  }

  const startedAt = new Date().toISOString();
  const t0 = Date.now();
  const stats = {
    linked: 0, checked: 0, unknown: 0, live: 0, archived: 0, gone: 0,
    flagged: 0, carried_forward: 0, batches_ok: 0, batches_failed: 0,
  };
  let items: Item[] = [];
  const errors: string[] = [];
  const uncheckedIds = new Set<number>();
  let fleetKnown = false;

  try {
    const token = await jobberToken();
    const rows = await allClients();
    const gidOf = await allClientLinks();
    const work = rows.filter((r) => gidOf.has(Number(r.id)));
    stats.linked = work.length;
    fleetKnown = true;
    for (const r of work) uncheckedIds.add(Number(r.id));

    let consecutiveFailures = 0;

    for (let i = 0; i < work.length; i += BATCH) {
      const slice = work.slice(i, i + BATCH);
      const query = `query { ${slice.map((r, n) =>
        `a${n}: client(id: "${gidOf.get(Number(r.id))}") { id isArchived }`
      ).join(" ")} }`;

      let data: Record<string, unknown>;
      try {
        data = await gqlWithRetry(token, query);
        consecutiveFailures = 0;
        stats.batches_ok++;
      } catch (e) {
        stats.batches_failed++;
        consecutiveFailures++;
        stats.unknown += slice.length;
        errors.push(`batch @${i}: ${String((e as Error).message).slice(0, 200)}`);
        if (consecutiveFailures >= MAX_CONSECUTIVE_BATCH_FAILURES) {
          errors.push(`circuit breaker: ${consecutiveFailures} consecutive batch failures, aborting`);
          stats.unknown += Math.max(0, work.length - (i + BATCH));   // everything not yet visited
          break;
        }
        await sleep(BATCH_PAUSE_MS);
        continue;
      }

      for (let n = 0; n < slice.length; n++) {
        const mine = slice[n];
        const theirs = data[`a${n}`] as { id: string; isArchived: boolean } | null | undefined;
        if (theirs === undefined) { stats.unknown++; errors.push(`client ${mine.id}: alias a${n} missing from the reply`); continue; }
        stats.checked++;
        uncheckedIds.delete(Number(mine.id));
        const ourStatus = String(mine.status ?? "");
        const flag = (issue: Issue, jobberState: Item["jobber_state"], reason: string) => {
          items.push({
            kind: `${issue}:${mine.id}`, issue, reason,
            client_id: Number(mine.id), client_code: mine.client_code ?? null, name: String(mine.name ?? ""),
            our_status: ourStatus, status_source: mine.status_source ?? null, jobber_state: jobberState,
          });
          stats.flagged++;
        };

        if (theirs === null) {
          stats.gone++;
          if (LIVE_STATUSES.has(ourStatus)) {
            flag("linked_client_gone_in_jobber", "gone",
              `${mine.client_code ?? mine.name} reads ${ourStatus} here but Jobber has no client at its linked id any more: it was deleted in Jobber and we were not told (or the CLIENT_DESTROY was lost). Nothing was changed. Open the client in the Clients App and use Archive client; it will be marked archived here and recorded as deleted in Jobber, and the record stays as history.`);
          }
          continue;
        }
        if (theirs.isArchived === true) {
          stats.archived++;
          if (LIVE_STATUSES.has(ourStatus)) {
            flag("live_client_archived_in_jobber", "archived",
              `${mine.client_code ?? mine.name} reads ${ourStatus} here but is archived in Jobber, so the two sides disagree about whether this is a customer. Nothing was changed. Either archive it in the Clients App (Archive client converges when Jobber already has it archived) or unarchive it in Jobber.`);
          }
          continue;
        }
        stats.live++;
        if (ourStatus === "INACTIVE") {
          const pinned = mine.status_source === "manual";
          flag("inactive_client_live_in_jobber", "live",
            `${mine.client_code ?? mine.name} is INACTIVE here${pinned ? " (pinned by a person)" : ""} but is a live, unarchived client in Jobber, so anything scheduled there syncs in and shows on the Calendar while the Clients App hides the client. Nothing was changed. Either reactivate it in the Clients App (Show archived, Reactivate) or archive it in Jobber.`);
        }
      }

      if (i + BATCH < work.length) await sleep(BATCH_PAUSE_MS);
    }
  } catch (e) {
    errors.push(`run failed: ${String((e as Error).message).slice(0, 300)}`);
  }

  // ---- mass-null ceiling: a systemic null is a broken sweep, never hundreds of deletions ---------
  const goneCeiling = Math.max(5, Math.ceil(0.10 * stats.checked));
  const massNull = stats.checked > 0 && stats.gone > goneCeiling;
  if (massNull) {
    const dropped = items.filter((i) => i.issue === "linked_client_gone_in_jobber").length;
    items = items.filter((i) => i.issue !== "linked_client_gone_in_jobber");
    stats.flagged -= dropped;
    errors.push(`systemic: ${stats.gone} of ${stats.checked} linked clients read null in Jobber (ceiling ${goneCeiling}); refusing to report them as deleted. Check the Jobber token and account before trusting this run.`);
  }

  // ---- status ---------------------------------------------------------------------------------
  // 'ok' and 'attention' are the clean words for a verdict row; 'partial' when Jobber could not be
  // asked about part of the fleet; 'error' when it could not be asked at all or the ceiling tripped.
  const status = stats.checked === 0 || massNull ? "error"
               : stats.unknown > 0 || errors.length ? "partial"
               : stats.flagged > 0 ? "attention"
               : "ok";

  // ---- carry forward: what the previous run flagged for clients this run did not check ----------
  if (status === "error" || status === "partial") {
    const prev = await previousItems();
    const carry = prev.filter((p) => {
      if (p.issue === "linked_client_gone_in_jobber" && massNull) return false;   // the ceiling voids that kind this run
      if (!fleetKnown) return true;                                                // no fleet read at all: keep everything
      return p.client_id != null && uncheckedIds.has(Number(p.client_id));
    });
    for (const p of carry) {
      if (items.some((i) => i.kind === p.kind)) continue;
      items.push({ ...p, carried_forward: true, reason: `${p.reason} (not re-checked this run; carried forward from the previous sweep)` });
      stats.carried_forward++;
    }
  }
  if (status === "error") {
    items.push({
      kind: "sweep_failed", issue: "sweep_failed",
      reason: `The weekly client state sweep could not check the fleet (${errors[errors.length - 1] ?? "unknown error"}). Jobber and the Clients App may disagree about who is a client and nobody would see it until the next run. Run it by hand: select public.fn_request_jobber_sync('client-state-sweep').`,
      client_id: null, client_code: null, name: "", our_status: null, status_source: null, jobber_state: "unknown",
    });
  }

  const details = {
    ...stats,
    duration_s: Math.round((Date.now() - t0) / 1000),
    throttle_left: Number.isFinite(throttleAvailable) ? throttleAvailable : null,
    mass_null: massNull,
    items,
    ...(errors.length ? { errors: errors.slice(0, 20) } : {}),
    covers: "Read-only. Compares clients.status with Jobber isArchived / existence for every Jobber-linked client, weekly: INACTIVE here but live in Jobber, live here but gone in Jobber, live here but archived in Jobber. It writes nothing; a person resolves each item in the Clients App. unknown > 0 means part of the fleet could not be asked this run and the previous run's items for those clients are carried forward.",
  };

  const { error: logErr } = await db.from("sync_log").insert({
    sync_source: SOURCE,
    status,
    started_at: startedAt,
    finished_at: new Date().toISOString(),
    rows_errored: stats.flagged,
    details,
  });
  if (logErr) {
    // The verdict row IS the observability; without it this run never happened as far as the
    // health views know. Say so on the wire so pg_net's response table carries the failure.
    console.error(`[${SOURCE}] sync_log insert failed: ${logErr.message}`);
    return new Response(JSON.stringify({ status: "error", log_error: logErr.message, ...stats }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ status, ...stats, items: items.slice(0, 20), errors: errors.slice(0, 5) }), {
    status: 200, headers: { "Content-Type": "application/json" },
  });
});
