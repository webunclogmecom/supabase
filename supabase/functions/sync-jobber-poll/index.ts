// ============================================================================
// sync-jobber-poll — Edge Function (Supabase-native Jobber delta poll)
// ============================================================================
// Deno port of scripts/sync/cron_jobber.js's INCREMENTAL run. Pulls Jobber deltas
// (clients/jobs/visits/invoices/quotes since the sync_cursors cursor), stages them in
// raw.jobber_pull_* (needs_populate=TRUE), then replays the flagged rows through
// webhook-jobber (HMAC-signed) so they land in public.* — exactly as the GitHub poll does.
//
// WHY: GitHub Actions throttles the */2 jobber-poll.yml schedule to ~2-3h gaps. Driven by
// pg_cron (*/5) via pg_net this runs INSIDE the database, immune to GitHub's scheduler —
// invoices/clients/jobs land within ~5 min. Same pattern as sync-jobber-upcoming-visits.
//
// Runs as a background task (EdgeRuntime.waitUntil) — the full cycle exceeds pg_net's ~5s
// timeout, so the caller gets an immediate 202 and the result lands in public.sync_log.
// `x-sync-wait: 1` runs synchronously and returns the result (manual testing).
//
// Auth (CHANGED 2026-07-29): `Authorization: Bearer <service_role JWT>`, FAIL-CLOSED. Deploy WITH
// verify_jwt=true (pinned in supabase/config.toml) — the gateway verifies the signature and this
// handler additionally requires role=service_role, because bearerRole only DECODES the token and
// the PUBLIC anon key would otherwise satisfy the gateway on its own. Same model as
// jobber-push-visit. Caller is public.fn_request_jobber_sync('poll') via pg_cron.
// ⚠ The old `x-sync-key: <SYNC_TRIGGER_KEY>` shared secret is RETIRED. Its gate was
// `if (TRIGGER_KEY && ...)`, which skipped auth entirely whenever SYNC_TRIGGER_KEY was empty, on a
// verify_jwt=false function. Do not reintroduce that idiom. A manual run now needs the bearer, e.g.
//   curl -H "Authorization: Bearer $SERVICE_ROLE" -H 'x-sync-wait: 1' <url>
// Public tables (webhook_tokens, sync_cursors) via service-role supabase-js; raw.* (not
// PostgREST-exposed) via a DIRECT Postgres connection (SUPABASE_DB_URL — already a function
// secret, normal DB privileges, NO admin PAT in the function). queryObject(string) uses the
// simple-query protocol → safe with the transaction pooler (no prepared statements).
// Faithful 1:1 port of the incremental run — the cutover changes only the scheduler.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { Client } from 'https://deno.land/x/postgres@v0.19.3/mod.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const DB_URL = Deno.env.get('SUPABASE_DB_URL')!
const GRAPHQL_VERSION = '2026-04-16'
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

// Decode-only. The GATEWAY verifies the signature (verify_jwt=true in config.toml); this just reads
// the role claim so the public anon key cannot invoke the function. Identical to jobber-push-visit.
function bearerRole(req: Request): string | null {
  const m = (req.headers.get('authorization') || '').match(/^Bearer (.+)$/)
  if (!m) return null
  try { return JSON.parse(atob(m[1].split('.')[1])).role ?? null } catch { return null }
}

type Exec = (q: string) => Promise<any[]>

// Incremental entity set — matches cron_jobber's default run.
//
// 🛑 PROPERTIES ARE NOW IN THIS LIST, ON AN HOURLY GATE (added 2026-08-04, Fred approved after a
// dry run). The old comment here said properties "ride webhooks / a daily --full". BOTH halves were
// false and together they meant a Jobber-side edit to a SERVICE property address NEVER reached us:
//   * Jobber sends us no webhooks at all — this poll IS the webhook replacement (ADR 009).
//   * `--full` lives in scripts/sync/cron_jobber.js, whose schedule was retired 2026-06-09; no
//     workflow passes the flag, so it had not run since 2026-05-27.
// Measured before the change: PROPERTY_UPDATE had produced ZERO events ever, the `properties`
// sync_cursor still read 2020-01-01, and 342 rows sat in raw.jobber_pull_properties with
// needs_populate=TRUE, staged in May and never replayed. That is what left the DUMP Pompano address
// two months stale.
//
// Properties have no updatedAt filter, so this is a FULL sweep (468 rows, ~5 pages). Running that
// every 5 minutes would be pure waste, hence PROPERTY_SWEEP_MINUTE: pg_cron fires this function
// */5, so gating on minute < 5 means exactly one sweep per hour. Addresses do not change faster
// than that.
//
// Blast radius was measured first, not assumed — scripts/sync/dryrun_property_poll.js computes the
// exact row handleProperty would write for all 468 and diffs it: 23 properties change, 79 unlinked
// Jobber properties would be inserted. Re-run that script before widening this.
const PROPERTY_SWEEP_MINUTE = 5
const CURSOR_FIELD: Record<string, string> = { clients: 'updatedAt', jobs: 'createdAt', visits: 'completedAt', invoices: 'updatedAt', quotes: 'updatedAt' }
const NODE_TIME_FIELD: Record<string, string> = { clients: 'updatedAt', jobs: 'updatedAt', visits: 'completedAt', invoices: 'updatedAt', quotes: 'updatedAt' }
const FILTER_TYPE: Record<string, string> = { clients: 'Client', jobs: 'Job', visits: 'Visit', invoices: 'Invoice', quotes: 'Quote' }
// custom fields are selected on `properties` so that a Jobber-side edit to one CHANGES THE
// STAGED PAYLOAD and therefore flips needs_populate. Without them here the poll cannot see a
// custom-field-only edit at all: the address bytes are identical and the row is never
// restaged, so handleProperty is never replayed and the adoption never runs. The value is
// still re-read by handleProperty against Jobber; this selection exists purely for CHANGE
// DETECTION. See docs/migrations/2026-08-18_0210_sync_property_custom_field_rpc.sql.
//
// EXPECTED ON THE FIRST SWEEP AFTER DEPLOY: every one of the ~476 staged rows changes bytes
// at once, so all of them flip to needs_populate and drain at replayLimit=10 per 5-minute
// cycle, roughly 4 hours. That is a full-fleet replay, not a fault. Do NOT raise replayLimit
// to speed it up: at 40 the outer invocation was killed before writing its sync_log row, so
// work continued while observability vanished.
const ENTITIES = [
  { name: 'clients',  rawTable: 'jobber_pull_clients',  topic: 'CLIENT_UPDATE',  fields: 'id firstName lastName companyName isCompany isArchived emails { address primary description } phones { number primary description } billingAddress { street city province postalCode country } balance updatedAt' },
  { name: 'jobs',     rawTable: 'jobber_pull_jobs',     topic: 'JOB_UPDATE',     fields: 'id jobNumber title client { id } property { id } jobStatus startAt endAt total updatedAt' },
  { name: 'visits',   rawTable: 'jobber_pull_visits',   topic: 'VISIT_UPDATE',   fields: 'id title startAt endAt completedAt completedBy visitStatus client { id } job { id } invoice { id } assignedUsers { nodes { id } } createdAt', pageSize: 25 },
  { name: 'invoices', rawTable: 'jobber_pull_invoices', topic: 'INVOICE_UPDATE', fields: 'id invoiceNumber invoiceStatus issuedDate dueDate subject amounts { subtotal total invoiceBalance depositAmount } client { id } updatedAt' },
  { name: 'properties', rawTable: 'jobber_pull_properties', topic: 'PROPERTY_UPDATE', fields: 'id name address { street city province postalCode coordinates { latitude longitude } } customFields { __typename ... on CustomFieldNumeric { valueNumeric customFieldConfiguration { id } } ... on CustomFieldText { valueText customFieldConfiguration { id } } }', replayLimit: 10, pageSize: 25 },
  { name: 'quotes',   rawTable: 'jobber_pull_quotes',   topic: 'QUOTE_UPDATE',   fields: 'id quoteNumber quoteStatus amounts { subtotal total depositAmount } client { id } updatedAt' },
] as const

// ⚠ JOBBER BILLS EVERY QUERY AGAINST A LEAKY-BUCKET COST BUDGET, AND A FULL PROPERTY SWEEP NO
// LONGER FITS IN IT. Measured 2026-09-03: bucket 10,000, restore 500/s, and a property page costs
// ~23 PER NODE once `customFields` is selected (first:100 = 2,305, first:25 = 580; without custom
// fields the same page is 1,005). A ~468-property sweep therefore needs ~10,764, which EXCEEDS the
// whole bucket. `ca16cf9` added customFields on 2026-09-02 and from that hour the sweep failed most
// runs: properties went 23-24 successes/day to 5-10, with quotes failing alongside it because it
// runs next out of the same bucket. Nothing reported it (see the pull loop's catch).
//
// The fix is to READ the balance Jobber returns on every response and wait for the refill, rather
// than discovering the ceiling as an error. Pacing costs nothing when the budget is healthy.
const THROTTLE_FLOOR = 3500      // keep this much headroom for the entities that pull after us
const THROTTLE_RESTORE_PER_S = 500
let throttleAvailable = Number.POSITIVE_INFINITY   // unknown until Jobber first tells us

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

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

// Token + client_secret, with the rotation-race re-read (a sibling refresher — the */30
// keepalive or the other Jobber cron — may have just rotated the token).
async function getCreds(): Promise<{ token: string; clientSecret: string }> {
  const { data: row } = await supabase.from('webhook_tokens')
    .select('access_token, refresh_token, client_id, client_secret, expires_at').eq('source_system', 'jobber').single()
  if (!row) throw new Error('No jobber row in webhook_tokens')
  let token = row.access_token as string
  if (new Date(row.expires_at).getTime() <= Date.now() + 60_000) {
    const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(row.client_id)}&client_secret=${encodeURIComponent(row.client_secret)}`
    const tr = await fetch('https://api.getjobber.com/api/oauth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body })
    if (!tr.ok) {
      const { data: row2 } = await supabase.from('webhook_tokens').select('access_token, expires_at').eq('source_system', 'jobber').single()
      if (row2 && new Date(row2.expires_at).getTime() > Date.now() + 60_000) return { token: row2.access_token, clientSecret: row.client_secret }
      throw new Error(`Refresh failed ${tr.status}`)
    }
    const t = await tr.json()
    const payloadB64 = t.access_token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')
    const newExp = JSON.parse(atob(payloadB64)).exp * 1000
    await supabase.from('webhook_tokens').update({
      access_token: t.access_token, refresh_token: t.refresh_token || row.refresh_token,
      expires_at: new Date(newExp).toISOString(), updated_at: new Date().toISOString(),
    }).eq('source_system', 'jobber')
    token = t.access_token
  }
  return { token, clientSecret: row.client_secret }
}

async function hmacB64(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(payload))
  return btoa(String.fromCharCode(...new Uint8Array(sig)))
}

const sqlEsc = (v: unknown) => v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'"

async function pullDelta(token: string, entity: typeof ENTITIES[number], cursor: string | null): Promise<any[]> {
  const cursorField = CURSOR_FIELD[entity.name], nodeTimeField = NODE_TIME_FIELD[entity.name]
  const pageSize = (entity as any).pageSize || 100
  let fields = entity.fields as string
  if (nodeTimeField && !fields.includes(nodeTimeField)) fields += ` ${nodeTimeField}`
  const all: any[] = []
  let after: string | null = null, page = 0
  while (page++ < 200) {
    const useFilter = cursorField && cursor
    const q = `query Delta($after: String, $first: Int!${useFilter ? `, $filter: ${FILTER_TYPE[entity.name]}FilterAttributes` : ''}) {
      ${entity.name}(after: $after, first: $first${useFilter ? ', filter: $filter' : ''}) { pageInfo { hasNextPage endCursor } nodes { ${fields} } } }`
    const vars: Record<string, unknown> = { after, first: pageSize }
    if (useFilter) vars.filter = { [cursorField]: { after: new Date(cursor as string).toISOString() } }
    const data = await gql(token, q, vars)
    const conn = data[entity.name]
    if (!conn) break
    all.push(...conn.nodes)
    if (!conn.pageInfo.hasNextPage) break
    after = conn.pageInfo.endCursor
  }
  if (nodeTimeField) for (const n of all) if (!n._cursorTime) n._cursorTime = n[nodeTimeField]
  return all
}

// ⚠ ONLY FLAG needs_populate WHEN THE PAYLOAD ACTUALLY CHANGED (fixed 2026-08-12).
// This used to re-flag every row it re-staged. For the entities that pull by cursor that
// was harmless, because a cursor pull only returns rows that moved. For PROPERTIES it was
// not: properties have no updatedAt to page on, so the sweep restages ALL ~470 every hour,
// and every one came back needs_populate=TRUE. The replay clears 10 per 5-minute cycle,
// so 120/hour drained against 470/hour re-flagged. It could never catch up.
//
// The visible symptom was 43 Jobber properties that had NEVER been written to
// public.properties in the 8 days since the sweep was enabled, including all five of
// Wynd 28's units (Presidente, Pari Pari, CU4, Pasta, Nino Gordo) and 112-YA's
// 9401 Collins Avenue. The replay reported ok:10 fail:0 every single cycle, so nothing
// looked broken from the log: it was draining honestly, just slower than it refilled.
// The SELECT below also had no ORDER BY, so the same rows were revisited and the tail
// starved rather than the backlog rotating.
//
// 🛑 THE CONDITION IS DELIBERATELY ASYMMETRIC. A row is left FALSE only when it is
// byte-identical AND was already populated. A row still pending stays pending, so this
// can never clear a flag that has not been acted on. Getting that backwards would
// silently strand exactly the rows this is meant to rescue.
async function upsertRaw(exec: Exec, rawTable: string, nodes: any[]) {
  for (let i = 0; i < nodes.length; i += 50) {
    const batch = nodes.slice(i, i + 50)
    const ids = batch.map((n) => sqlEsc(n.id)).join(', ')
    const values = batch.map((n) => `(${sqlEsc(JSON.stringify(n))}::jsonb)`).join(',')
    // One statement: `settled` is evaluated against the PRE-DELETE snapshot, because every
    // CTE in a data-modifying statement sees the same snapshot.
    await exec(`
      WITH incoming(d) AS (VALUES ${values}),
           settled AS (
             SELECT i.d->>'id' AS gid
               FROM incoming i
               JOIN raw.${rawTable} r
                 ON r.data->>'id' = i.d->>'id'
                AND r.data = i.d
                AND r.needs_populate = FALSE
           ),
           del AS (DELETE FROM raw.${rawTable} WHERE data->>'id' IN (${ids}))
      INSERT INTO raw.${rawTable} (data, ingested_at, needs_populate)
      SELECT i.d, now(), (i.d->>'id') NOT IN (SELECT gid FROM settled)
        FROM incoming i`)
  }
}

async function getCursor(name: string): Promise<string | null> {
  const { data } = await supabase.from('sync_cursors').select('last_synced_at').eq('entity', name).maybeSingle()
  return (data?.last_synced_at as string) ?? null
}
async function setCursor(name: string, ts: string, rows: number) {
  await supabase.from('sync_cursors').update({
    last_synced_at: ts, last_run_finished: new Date().toISOString(), last_run_status: 'success', rows_pulled: rows, updated_at: new Date().toISOString(),
  }).eq('entity', name)
}

async function replayFlagged(exec: Exec, clientSecret: string) {
  const summary: { table: string; ok: number; fail: number }[] = []
  for (const e of ENTITIES) {
    // ⚠ CAP THE REPLAY. Each replayed row is a sequential HTTP round-trip to webhook-jobber, and
    // the properties backlog was 342 rows staged in May. Uncapped, the function exceeded its CPU
    // budget and the whole invocation died with a bare 500 -- after doing 25 rows of real work, so
    // it was neither a clean success nor a clean failure. Capped, every cycle finishes cleanly and
    // the backlog drains across cycles.
    //
    // ⚠ 40 WAS STILL TOO HIGH, AND THE FAILURE MODE WAS DECEPTIVE. pg_cron kept reporting
    // `succeeded` and properties kept draining (each replay is its own webhook-jobber request and
    // completes on its own), but the OUTER invocation was killed before reaching the sync_log
    // insert at the end of runSync. Measured: 3 consecutive cycles did real work while writing NO
    // sync_log row at all -- 267 -> 220 pending, 75 -> 122 PROPERTY_UPDATE events, zero log rows.
    // Work continuing while the observability silently disappears is worse than a clean failure,
    // because the next person reads "last successful sync 20:05" and concludes the poll is dead.
    // 10 keeps a cycle near its normal ~7s and still drains ~120/hour, far above the real change
    // rate once caught up. If you raise this, verify a sync_log row still appears every cycle.
    const cap = (e as any).replayLimit as number | undefined
    // ORDER BY id so the backlog ROTATES instead of starving its tail. Without it Postgres
    // returns whatever physical order it likes, and after a DELETE+INSERT sweep the reused
    // pages meant the same rows were replayed every cycle while 43 were never reached at all.
    const rows = await exec(`SELECT data->>'id' AS gid FROM raw.${e.rawTable} WHERE needs_populate=TRUE ORDER BY id${cap ? ` LIMIT ${cap}` : ''}`)
    if (!rows.length) continue
    let ok = 0, fail = 0
    for (const { gid } of rows) {
      const payload = JSON.stringify({ topic: e.topic, webHookEvent: { itemId: gid, occurredAt: new Date().toISOString() } })
      const sig = await hmacB64(clientSecret, payload)
      // 🛑 x-sync-wait IS LOAD-BEARING HERE, MORE THAN ANYWHERE ELSE. Since 2026-08-20
      //    webhook-jobber acknowledges real Jobber traffic immediately and processes in the
      //    background. Without this header wr.ok would be TRUE for every call, including ones whose
      //    processing later failed - and the very next line clears needs_populate on wr.ok. The
      //    queue would empty itself on acknowledgements and silently drop rows it never populated,
      //    which is exactly the "needs_populate=0 hiding rows it had given up on" failure this
      //    estate has already paid for once.
      const wr = await fetch(`${SUPABASE_URL}/functions/v1/webhook-jobber`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig, 'x-sync-wait': '1' }, body: payload })
      if (wr.ok) { ok++; await exec(`UPDATE raw.${e.rawTable} SET needs_populate=FALSE WHERE data->>'id'=${sqlEsc(gid)}`) } else fail++
    }
    summary.push({ table: e.rawTable, ok, fail })
  }
  return summary
}

async function runSync(): Promise<Record<string, unknown>> {
  const startedAt = new Date().toISOString(); const startMs = Date.now()
  const db = new Client(DB_URL)
  try {
    await db.connect()
    const exec: Exec = (q) => db.queryObject<Record<string, any>>(q).then((r) => r.rows as any[])
    const { token, clientSecret } = await getCreds()
    let totalPulled = 0
    const pulls: Record<string, number> = {}
    const pullErrors: Record<string, string> = {}
    const sweepProperties = new Date().getUTCMinutes() < PROPERTY_SWEEP_MINUTE
    for (const entity of ENTITIES) {
      // Full sweep, so only once an hour. Skipping the PULL still leaves replayFlagged free to
      // drain anything already staged, which is how the 342-row May backlog gets worked off.
      if (entity.name === 'properties' && !sweepProperties) { pulls[entity.name] = -2; continue }
      const cursor = await getCursor(entity.name)
      let nodes: any[]
      // 🛑 This used to be a bare `catch { ... = -1; continue }`. A two-day property-sync outage
      // was invisible because of it: pg_cron said succeeded and sync_log said status='success'.
      // Record WHAT failed; -1 alone cannot tell a throttle from a bad token from a schema change.
      try { nodes = await pullDelta(token, entity, cursor) }
      catch (e) { pulls[entity.name] = -1; pullErrors[entity.name] = String(e).slice(0, 300); continue }
      if (nodes.length) {
        await upsertRaw(exec, entity.rawTable, nodes)
        const newCursor = entity.name === 'properties'
          ? new Date().toISOString()
          : nodes.reduce((max, n) => { const ts = n._cursorTime || n.updatedAt || n.createdAt; return ts && ts > max ? ts : max }, cursor || '2020-01-01T00:00:00Z')
        await setCursor(entity.name, newCursor, nodes.length)
        totalPulled += nodes.length; pulls[entity.name] = nodes.length
      } else { await setCursor(entity.name, new Date().toISOString(), 0); pulls[entity.name] = 0 }
    }
    const replay = totalPulled > 0 ? await replayFlagged(exec, clientSecret) : []
    const fails = replay.reduce((s, r) => s + r.fail, 0)
    const dur = Math.round((Date.now() - startMs) / 1000)
    await supabase.from('sync_log').insert({
      sync_source: 'jobber_poll_pgcron', started_at: startedAt, finished_at: new Date().toISOString(),
      rows_inserted: totalPulled, rows_updated: 0,
      rows_errored: fails + Object.keys(pullErrors).length, duration_seconds: dur,
      // A failed PULL is now a partial run. Previously only replay failures moved this off 'success',
      // so an entity that never pulled at all still reported a clean sync.
      status: (fails === 0 && Object.keys(pullErrors).length === 0) ? 'success' : 'partial',
      details: { pulls, replay, ...(Object.keys(pullErrors).length ? { pull_errors: pullErrors } : {}) },
    })
    return { pulled: totalPulled, pulls, replay, duration_s: dur }
  } catch (e) {
    const dur = Math.round((Date.now() - startMs) / 1000)
    await supabase.from('sync_log').insert({ sync_source: 'jobber_poll_pgcron', started_at: startedAt, finished_at: new Date().toISOString(), rows_inserted: 0, rows_updated: 0, rows_errored: 0, duration_seconds: dur, status: 'error', details: { error: String(e).slice(0, 300) } }).catch(() => {})
    return { error: String(e).slice(0, 300) }
  } finally {
    await db.end().catch(() => {})
  }
}

Deno.serve(async (req) => {
  // FAIL-CLOSED: no bearer, unparseable bearer, or any role other than service_role is rejected.
  if (bearerRole(req) !== 'service_role') return new Response('forbidden', { status: 403 })
  if (req.headers.get('x-sync-wait') === '1') {
    const res = await runSync()
    return new Response(JSON.stringify(res), { status: res.error ? 500 : 200, headers: { 'Content-Type': 'application/json' } })
  }
  // @ts-ignore — EdgeRuntime provided by the Supabase Edge runtime.
  EdgeRuntime.waitUntil(runSync())
  return new Response(JSON.stringify({ accepted: true }), { status: 202, headers: { 'Content-Type': 'application/json' } })
})
