// node --experimental-strip-types scripts/sync/backfill_jobber_payments.mjs [--from 2024-01-01] [--only payments,payouts,invoices,quotes] [--check-only]
//
// --check-only is the STANDING CHECK: it reads Jobber and our copy and writes nothing anywhere (no payment, payout,
// invoice or quote; no import). It compares every money record by kind (count, amount), by month (Eastern), method and
// kind (amount), and every payout (count, net). Exit 1 on any difference. The method is worked out here from the record
// type on its own, so the check does not lean on the SQL writer's mapping.
//
// The payments copy's backfill (2026-11-14). Re-runnable: everything goes through the same writers as the webhook
// handlers and the timed net (public.sync_jobber_payments, sync_jobber_payouts, sync_jobber_invoice_extras,
// sync_jobber_quote_extras), which upsert on the Jobber id's link and compare before they write, so a second run
// changes nothing. Plan: Building Apps/Ops Portal/docs/specs/2026-11-13-jobber-payments-and-people.md, section C.
//
// JOBBER IS READ ONLY HERE. Reads run on the WRITE app's token (webhook_tokens 'jobber_write'): its points bucket is
// separate from the read app's, so the 5-minute poll is not starved. The token is never refreshed here (the
// calendar task poll keeps it fresh) and never printed. An invoice or quote a payment needs that is not in our
// database is imported by a signed replay through webhook-jobber (x-sync-wait), as the poll does.
//
// At the end: a count check against Jobber's own totals, read in this same run: every money record (payment, deposit,
// refund, failed payment, bad debt) by kind, count and amount, and every payout, count and net. Then the held
// payments of the window Jobber no longer returns are re-read by id and marked removed when Jobber says null.
// Writes a summary (counts only, no client data) to stdout.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { createHmac } from 'node:crypto'

const here = dirname(fileURLToPath(import.meta.url))
const env = Object.fromEntries(readFileSync(join(here, '../../.env'), 'utf8').split(/\r?\n/)
  .filter((l) => /^[A-Z_]+=/.test(l)).map((l) => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1).replace(/^["']|["']$/g, '').trim()] }))
// Node reads a .ts file in this repo as CommonJS, so load a .mts copy of the exact shared source.
const copy = join(mkdtempSync(join(tmpdir(), 'jp-')), 'jobber-payments.mts')
writeFileSync(copy, readFileSync(join(here, '../../supabase/functions/_shared/jobber-payments.ts'), 'utf8'))
const J = await import(pathToFileURL(copy).href)

const args = process.argv.slice(2)
const opt = (name, dflt) => { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : dflt }
const FROM = opt('from', '2024-01-01')
const CHECK_ONLY = args.includes('--check-only')
const ONLY = new Set(opt('only', CHECK_ONLY ? 'payments,payouts' : 'payments,payouts,invoices,quotes').split(','))
if (!/^\d{4}-\d{2}-\d{2}$/.test(FROM)) throw new Error('--from must be YYYY-MM-DD')
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// ---- database: plain SELECTs through the Management API; writes through PostgREST RPC (service key), so a failing
// call never carries its payload into the server log as statement text.
async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'Content-Type': 'application/json' }, body: JSON.stringify({ query }) })
  const j = await r.json().catch(() => null)
  if (!Array.isArray(j)) throw new Error('DB read failed: ' + JSON.stringify(j).slice(0, 300))
  return j
}
const rpc = async (fn, body) => {
  const r = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: 'Bearer ' + env.SUPABASE_SERVICE_ROLE_KEY, 'Content-Type': 'application/json', 'x-app-source': 'jobber' },
    body: JSON.stringify(body),
  })
  const text = await r.text()
  let j = null
  try { j = JSON.parse(text) } catch { /* not JSON */ }
  if (!r.ok) return { data: null, error: { message: `HTTP ${r.status} ${(j?.message ?? text).slice(0, 300)}` } }
  return { data: j, error: null }
}

// ---- Jobber: the write app's token, waited for (never refreshed) when it has under 3 minutes left; re-read every minute
const cached = {}
async function token(kind) {
  if (cached[kind] && Date.now() - cached[kind].at < 60000) return cached[kind].row
  for (let i = 0; i < 40; i++) {
    const rows = await sql(`select access_token, client_secret, extract(epoch from (expires_at - now()))::int as left_s from public.webhook_tokens where source_system = '${kind}'`)
    if (rows.length !== 1) throw new Error('no token row for ' + kind)
    if (rows[0].left_s > 180) { cached[kind] = { row: rows[0], at: Date.now() }; return rows[0] }
    console.log(`[token] ${kind} has ${rows[0].left_s}s left; waiting for the system to refresh it`)
    await sleep(30000)
  }
  throw new Error(`the ${kind} token was not refreshed; stop`)
}
let available = null
const FLOOR = 6000
async function gql(query, variables, version, retry = 0) {
  if (available != null && available < FLOOR) await sleep(Math.min(20000, Math.ceil(((FLOOR - available) / 500) * 1000)))
  const tk = (await token('jobber_write')).access_token
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST', headers: { Authorization: 'Bearer ' + tk, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': version },
    body: JSON.stringify({ query, variables }) })
  const ctype = r.headers.get('content-type') ?? ''
  if (!ctype.includes('json')) {
    if (retry < 5) { await sleep(Math.min(30000, 1000 * 2 ** retry)); return gql(query, variables, version, retry + 1) }
    throw new Error(`Jobber returned ${ctype || 'no content-type'} at HTTP ${r.status}`)
  }
  const j = await r.json().catch(() => null)
  const t = j?.extensions?.cost?.throttleStatus
  if (typeof t?.currentlyAvailable === 'number') available = t.currentlyAvailable
  const throttled = r.status === 429 || (Array.isArray(j?.errors) && j.errors.some((e) => e?.extensions?.code === 'THROTTLED' || /throttl/i.test(e?.message || '')))
  if (throttled && retry < 6) { await sleep(Math.min(30000, 2000 * 2 ** retry)); return gql(query, variables, version, retry + 1) }
  if (j?.errors || j?.error) throw new Error('GraphQL: ' + JSON.stringify(j.errors ?? j.error).slice(0, 300))
  if (!j || typeof j !== 'object' || !('data' in j) || j.data == null) throw new Error(`Jobber returned no data key at HTTP ${r.status}`)
  return j.data
}
async function listAll(field, args, vars, fields, size, version, onPage) {
  let after = null, n = 0
  for (let page = 0; ; page++) {
    if (page > 1000) throw new Error(field + ': more than 1000 pages; stop')
    const data = await gql(`query($after: String${args ? ', ' + args : ''}) { ${field}(first: ${size}, after: $after${vars.f ? ', filter: $f' : ''}${vars.s ? ', sort: $s' : ''}) { totalCount pageInfo { hasNextPage endCursor } nodes { ${fields} } } }`, { after, ...vars }, version)
    const c = data[field]
    if (!c || !Array.isArray(c.nodes) || !c.pageInfo) throw new Error(`no ${field} nodes/pageInfo`)
    n += c.nodes.length
    await onPage(c.nodes, c.totalCount)
    if (!c.pageInfo.hasNextPage) return n
    after = c.pageInfo.endCursor
  }
}

const readSecret = (await token('jobber')).client_secret
const readPayment = async (gid) => (await gql(`query($id: EncodedId!) { paymentRecord(id: $id) { ${J.PAYMENT_FIELDS} } }`, { id: gid }, J.PAY_API_VERSION)).paymentRecord ?? null
const imported = []
const importDep = async (kind, gid) => {
  const payload = JSON.stringify({ topic: kind === 'invoice' ? 'INVOICE_UPDATE' : 'QUOTE_UPDATE', webHookEvent: { itemId: gid, occurredAt: new Date().toISOString() } })
  const sig = createHmac('sha256', readSecret).update(payload).digest('base64')
  const r = await fetch(`${env.SUPABASE_URL}/functions/v1/webhook-jobber`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig, 'x-sync-wait': '1' }, body: payload })
  if (!r.ok) throw new Error(`import of ${kind} ${J.jobberNumber(gid)} failed: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`)
  imported.push(kind + ' ' + J.jobberNumber(gid))
}

const out = { from: FROM, check_only: CHECK_ONLY, started: new Date().toISOString() }
const grid = {}
const monthET = (iso) => new Date(iso).toLocaleDateString('en-CA', { timeZone: 'America/New_York' }).slice(0, 7)
// CheckPaymentRecord -> check, JobberPaymentsACHPaymentRecord -> jobber_payments_ach: the record type in snake case.
const methodOf = (t) => t.replace(/PaymentRecord$/, '').replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2').replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase()
const toWindow = new Date(Date.now() + 864e5).toISOString()
const fromWindow = new Date(`${FROM}T00:00:00-05:00`).toISOString()
const add = (a, b) => { for (const [k, v] of Object.entries(b)) if (typeof v === 'number') a[k] = (a[k] ?? 0) + v; if (b.held?.length) a.held = [...(a.held ?? []), ...b.held] }

if (ONLY.has('payments')) {
  const jobber = {}, seen = [], w = {}
  let buf = [], total = null
  const flush = async () => { if (buf.length && !CHECK_ONLY) add(w, await J.writePayments(rpc, buf, [], readPayment, importDep)); buf = [] }
  const n = await listAll('paymentRecords', '$f: PaymentRecordFilterAttributes, $s: PaymentRecordSortAttributes',
    { f: { entryDate: { after: fromWindow, before: toWindow } }, s: { key: 'ENTRY_DATE', direction: 'ASCENDING' } }, J.PAYMENT_FIELDS, 50, J.PAY_API_VERSION,
    async (nodes, tc) => {
      total = tc
      for (const p of nodes) {
        if (!J.MONEY_ADJUSTMENTS.includes(p.adjustmentType)) continue
        seen.push(p.id)
        const k = jobber[p.adjustmentType] ??= { count: 0, amount: 0 }
        k.count++; k.amount = Math.round((k.amount + p.amount) * 100) / 100
        const key = [monthET(p.entryDate), methodOf(p.__typename), p.adjustmentType].join('|')
        grid[key] = Math.round(((grid[key] ?? 0) + p.amount) * 100) / 100
      }
      buf.push(...nodes)
      if (buf.length >= 500) await flush()
      process.stdout.write(`\r[payments] ${seen.length} money records of ${tc} ledger records read`)
    })
  await flush()
  console.log('')
  if (n !== total) throw new Error(`read ${n} ledger records but Jobber counts ${total}; stop before any removal`)
  if (CHECK_ONLY) { out.payments = { ledger_records_read: n, jobber_total_count: total, jobber_money: jobber } } else {
  const { data: u, error } = await rpc('fn_jobber_payments_unseen', { p_from: fromWindow, p_to: toWindow, p_seen: seen })
  if (error) throw new Error('fn_jobber_payments_unseen refused: ' + error.message)
  const found = [], gone = []
  for (const gid of u.unseen) { const node = await readPayment(gid); if (node) found.push(node); else gone.push(gid) }
  for (let i = 0; i < Math.max(gone.length, found.length ? 1 : 0); i += 20) add(w, await J.writePayments(rpc, i === 0 ? found : [], gone.slice(i, i + 20), readPayment, importDep))
  out.payments = { ledger_records_read: n, jobber_total_count: total, jobber_money: jobber, written: w, unseen_reread: { unseen: u.unseen.length, moved: found.length, gone: gone.length } }
  }
}

if (ONLY.has('payouts')) {
  const jobber = { count: 0, net: 0 }, w = {}
  let buf = []
  const n = await listAll('payoutRecords', '$s: [PayoutSortInput!]', { s: [{ key: 'ARRIVAL_DATE', direction: 'ASCENDING' }] }, J.PAYOUT_FIELDS, 10, J.PAY_API_VERSION,
    async (nodes) => {
      for (const p of nodes) { jobber.count++; jobber.net += p.netAmount }
      buf.push(...nodes)
      process.stdout.write(`\r[payouts] ${jobber.count} read`)
    })
  console.log('')
  if (!CHECK_ONLY) add(w, await J.writePayouts(rpc, buf, [], readPayment, importDep))
  out.payouts = { read: n, jobber: { count: jobber.count, net: jobber.net / 100 }, written: w }
}

if (ONLY.has('invoices') && !CHECK_ONLY) {
  const w = {}
  const n = await listAll('invoices', '', {}, `id ${J.INVOICE_EXTRA_FIELDS}`, 50, '2026-09-09', async (nodes) => {
    const { data, error } = await rpc('sync_jobber_invoice_extras', { p_nodes: nodes })
    if (error) throw new Error('sync_jobber_invoice_extras refused: ' + error.message)
    add(w, data)
    w.not_linked_ids = [...(w.not_linked_ids ?? []), ...data.not_linked.map((g) => J.jobberNumber(g))]
    process.stdout.write(`\r[invoices] ${w.received} read`)
  })
  console.log('')
  out.invoices = { read: n, written: { ...w, not_linked_ids: undefined, not_linked: w.not_linked_ids.length } }
}

if (ONLY.has('quotes') && !CHECK_ONLY) {
  const w = {}
  const n = await listAll('quotes', '', {}, `id ${J.QUOTE_EXTRA_FIELDS}`, 10, '2026-04-16', async (nodes) => {
    const { data, error } = await rpc('sync_jobber_quote_extras', { p_nodes: nodes })
    if (error) throw new Error('sync_jobber_quote_extras refused: ' + error.message)
    add(w, data)
    w.not_linked_n = (w.not_linked_n ?? 0) + data.not_linked.length
    process.stdout.write(`\r[quotes] ${w.received} read`)
  })
  console.log('')
  out.quotes = { read: n, written: w }
}

// ---- the count check against Jobber's own totals, read in this run
const db = (await sql(`
  select (select coalesce(jsonb_object_agg(kind, jsonb_build_object('count', n, 'amount', amt)), '{}') from (
            select kind, count(*) n, sum(amount) amt from public.payments where deleted_at is null and entered_at >= '${fromWindow}' group by kind) k) as payments,
         (select jsonb_build_object('count', count(*), 'net', coalesce(sum(net_amount), 0)) from public.payouts where deleted_at is null) as payouts,
         (select count(*) from public.payments where deleted_at is not null) as payments_removed,
         (select count(*) from public.invoices where invoice_status = 'paid' and paid_at is null) as paid_invoices_without_paid_at,
         (select coalesce(jsonb_object_agg(k, amt), '{}') from (
            select to_char(entered_at at time zone 'America/New_York', 'YYYY-MM') || '|' || method || '|' ||
                   case kind when 'payment' then 'PAYMENT' when 'deposit' then 'DEPOSIT' when 'refund' then 'REFUND'
                             when 'failed_payment' then 'FAILED_ACH_PAYMENT' else 'BAD_DEBT' end as k, sum(amount) amt
              from public.payments where deleted_at is null and entered_at >= '${fromWindow}' group by 1) g) as grid`))[0]
const KIND = { PAYMENT: 'payment', DEPOSIT: 'deposit', REFUND: 'refund', FAILED_ACH_PAYMENT: 'failed_payment', BAD_DEBT: 'bad_debt' }
out.check = { db }
if (out.payments) {
  out.check.payments = Object.entries(out.payments.jobber_money).map(([adj, j]) => {
    const d = db.payments[KIND[adj]] ?? { count: 0, amount: 0 }
    return { kind: KIND[adj], jobber: j, ours: d, same: j.count === d.count && Math.abs(j.amount - Number(d.amount)) < 0.005 }
  })
}
if (out.payments) {
  const keys = new Set([...Object.keys(grid), ...Object.keys(db.grid)])
  out.check.month_method_kind = { cells: keys.size, differ: [...keys].filter((k) => Math.abs((grid[k] ?? 0) - Number(db.grid[k] ?? 0)) >= 0.005)
    .map((k) => ({ cell: k, jobber: grid[k] ?? 0, ours: Number(db.grid[k] ?? 0) })) }
}
delete db.grid
if (out.payouts) out.check.payouts = { jobber: out.payouts.jobber, ours: db.payouts, same: out.payouts.jobber.count === db.payouts.count && Math.abs(out.payouts.jobber.net - Number(db.payouts.net)) < 0.005 }
out.imported = imported.length
out.finished = new Date().toISOString()
console.log(JSON.stringify(out, null, 1))
const bad = (out.check.payments ?? []).some((x) => !x.same) || (out.check.payouts && !out.check.payouts.same) || (out.check.month_method_kind?.differ.length ?? 0) > 0
console.log(bad ? 'COUNT CHECK: DIFFERS (see above)' : 'COUNT CHECK: our copy holds exactly what Jobber returned')
process.exit(bad ? 1 : 0)
