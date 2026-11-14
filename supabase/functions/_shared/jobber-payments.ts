// ============================================================================
// _shared/jobber-payments.ts — what we read from Jobber for the payments copy (2026-11-14)
// ============================================================================
// Fred, 2026-11-14: "Build the copy now ... see if there is a way to have a good way to have that realtime,
// like with the webhook but if we need to have cronjob then decide the frequency of fetching that data".
// Plan: Building Apps/Ops Portal/docs/specs/2026-11-13-jobber-payments-and-people.md, section C.
//
// ONE selection, used by every reader of payments and payouts, so they can never disagree about what a payment
// is: webhook-jobber (handlePayment, handlePayout), sync-jobber-payments (the timed net) and
// scripts/sync/backfill_jobber_payments.mjs (Node imports this file with --experimental-strip-types).
// The mapping of these fields to our columns lives in ONE place too: public.sync_jobber_payments and
// public.sync_jobber_payouts take the raw nodes. Change a field here, change the mapping there, in one cycle.
//
// The selections, the id helpers and the write loop (writePayments, writePayouts). No Deno or Node API beyond
// atob/btoa: the callers pass in their own database call, Jobber read and import, so both runtimes load this file.
// ============================================================================

// The version the 2026-11-13 trial read every payment and payout at. Keep all three readers on it.
export const PAY_API_VERSION = '2026-09-09'

// A payment record. Card digits, name on card, expiry, bank name and transaction ids exist and are NOT read on
// purpose (plan section C). allocations: the only place a split payment lists its invoices (max seen 6); a reply
// whose list has more pages is refused by the writer, never stored cut.
export const PAYMENT_FIELDS = `__typename id adjustmentType paymentOrigin amount entryDate sentAt details
  client { id } invoice { id } quote { id }
  allocations(first: 25) { pageInfo { hasNextPage } nodes { amount
    ... on InvoicePaymentRecordAllocation { invoice { id } }
    ... on QuotePaymentRecordAllocation { quote { id } } } }
  ... on CheckPaymentRecord { checkNumber }
  ... on CreditCardPaymentRecord { ccTransactionNumber }
  ... on AchBankPaymentPaymentRecord { confirmationNumber }
  ... on BankTransferPaymentRecord { confirmationNumber }
  ... on CashAppPaymentRecord { confirmationNumber }
  ... on ETransferPaymentRecord { confirmationNumber }
  ... on OtherPaymentRecord { confirmationNumber }
  ... on PaypalPaymentRecord { confirmationNumber }
  ... on VenmoPaymentRecord { confirmationNumber }
  ... on ZellePaymentRecord { confirmationNumber }
  ... on JobberPaymentsCreditCardPaymentRecord { brand paymentMethodFunding feeAmount transactionStatus refundedAt }
  ... on JobberPaymentsACHPaymentRecord { feeAmount transactionStatus refundedAt negatedBalanceAdjustment { id } }
  ... on JobberPaymentsRefundPaymentRecord { feeAmount transactionStatus refundedAt refundedPaymentRecord { id } }
  ... on RefundPaymentRecord { refundedPaymentRecord { id } }`

// A bank payout and its lines (amounts in cents). Max lines seen on one payout: 38; more than 50 is refused.
export const PAYOUT_FIELDS = `id status payoutMethod netAmount arrivalDate created updatedAt failureReason
  balanceTransactions(first: 50) { pageInfo { hasNextPage } nodes { __typename type grossAmount feeAmount netAmount created
    ... on PaymentBalanceTransaction { paymentRecord { id } }
    ... on RefundBalanceTransaction { paymentRecord { id } }
    ... on DisputeBalanceTransaction { paymentRecord { id } } } }`

// The invoice and quote fields the plan adds (paid date, tax, discount, the tax rate's name, viewed, void; the real sent
// date, approved and converted dates, required deposit, the quote's lines). handleInvoice and handleQuote select them in
// the query they already make; the backfill selects them alone. Written by public.sync_jobber_invoice_extras (invoice,
// API 2026-09-09) and public.sync_jobber_quote_extras (quote, API 2026-04-16, handleQuote's version), which skip a node
// missing any of these keys. Priced 2026-11-14: +~9 points on an invoice re-read, +~25 on a quote with its lines.
export const INVOICE_EXTRA_FIELDS = `receivedDate dateViewedInClientHub taxRate { name } voidDetails { voidReasonCode voidedAt }
  amounts { subtotal taxAmount discountAmount }`
export const QUOTE_EXTRA_FIELDS = `sentAt clientHubViewedAt lastTransitioned { approvedAt convertedAt }
  amounts { subtotal taxAmount depositAmount }
  lineItems(first: 50) { pageInfo { hasNextPage } nodes { name description quantity unitPrice totalPrice taxable } }`

// The number behind any Jobber id. The same payment reads as OtherPaymentRecord/N in the ledger list and as
// PaymentRecord/N under an invoice: the number is the identity.
export function jobberNumber(gid: string | null | undefined): string | null {
  if (!gid) return null
  try {
    const m = atob(gid).match(/^gid:\/\/Jobber\/\w+\/(\d+)$/)
    return m ? m[1] : null
  } catch {
    return null
  }
}

// The id we store and send back to Jobber: paymentRecord(id:) and payoutRecord(id:) accept these forms.
export const paymentGid = (num: string) => btoa(`gid://Jobber/PaymentRecord/${num}`)
export const payoutGid = (num: string) => btoa(`gid://Jobber/PayoutRecord/${num}`)

// The money kinds we store. Every other ledger line (an issued invoice, a void, a correction) is skipped by the writer.
export const MONEY_ADJUSTMENTS = ['PAYMENT', 'DEPOSIT', 'REFUND', 'FAILED_ACH_PAYMENT', 'BAD_DEBT']

// ---- the write loop, shared by the three callers ----------------------------------------------------------------
// rpc:         supabase-js .rpc (or the backfill's fetch shim): (fn, args) => { data, error }
// readPayment: one payment read by id. Returns the node, or null when Jobber answers null (gone). MUST THROW when the
//              reply is not an answer (not JSON, no data key, an errors array): a missing answer is never "gone".
// importDep:   makes an invoice or quote Jobber has exist in our database (webhook-jobber's own handler, or a signed
//              replay through it). Throws when it could not.
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: any; error: { message: string } | null }>
export type ReadPayment = (gid: string) => Promise<any | null>
export type ImportDep = (kind: 'invoice' | 'quote', gid: string) => Promise<void>

// Nodes per database call. A call of 184 payouts (with ~5 lines each, every row audited) hit the API's statement timeout
// on 2026-11-14; 200 payments passed. Smaller calls cost a few more round trips and stay far from it.
const CHUNK = 100
const PAYOUT_CHUNK = 20
const entry = (n: any) => String(n?.entryDate ?? '')

async function rpcOrThrow(rpc: Rpc, fn: string, args: Record<string, unknown>) {
  const { data, error } = await rpc(fn, args)
  if (error) throw new Error(`${fn} refused: ${error.message}`)
  if (!data || typeof data !== 'object') throw new Error(`${fn} returned no result`)
  return data
}

function addStats(total: Record<string, any>, r: Record<string, any>) {
  for (const k of ['received', 'not_money', 'inserted', 'updated', 'unchanged', 'allocations_rewritten', 'lines_rewritten', 'removed']) {
    if (typeof r[k] === 'number') total[k] = (total[k] ?? 0) + r[k]
  }
}

// Writes payment nodes (and gone ids, at most 20) through public.sync_jobber_payments. A payment held because what it
// pays or reverses is not here yet gets its dependencies imported or read, then is written again: up to 3 rounds.
// Returns the summed counts, what is still held, and what was imported or read.
export async function writePayments(rpc: Rpc, nodes: any[], gone: string[], readPayment: ReadPayment, importDep: ImportDep) {
  const total: Record<string, any> = { held: [], imported: [], read_by_id: 0 }
  let pending = [...nodes].sort((a, b) => entry(a).localeCompare(entry(b)))
  let goneLeft = gone
  for (let round = 0; round < 3 && (pending.length || goneLeft.length); round++) {
    const held: any[] = []
    const missing = { invoices: new Set<string>(), quotes: new Set<string>(), payments: new Set<string>() }
    for (let i = 0; i < Math.max(pending.length, 1); i += CHUNK) {
      const r = await rpcOrThrow(rpc, 'sync_jobber_payments', { p_nodes: pending.slice(i, i + CHUNK), p_gone: i === 0 ? goneLeft : [] })
      addStats(total, r)
      held.push(...(r.held ?? []))
      for (const g of r.missing?.invoices ?? []) missing.invoices.add(g)
      for (const g of r.missing?.quotes ?? []) missing.quotes.add(g)
      for (const g of r.missing?.payments ?? []) missing.payments.add(g)
    }
    goneLeft = []
    total.held = held
    if (!held.length) break
    let progressed = false
    for (const g of missing.invoices) { await importDep('invoice', g); total.imported.push(g); progressed = true }
    for (const g of missing.quotes) { await importDep('quote', g); total.imported.push(g); progressed = true }
    const extra: any[] = []
    for (const g of missing.payments) {
      const n = await readPayment(g)
      total.read_by_id++
      if (n) { extra.push(n); progressed = true }
    }
    if (!progressed) break
    const heldNums = new Set(held.map((h) => jobberNumber(h.gid)))
    pending = [...extra, ...pending.filter((n) => heldNums.has(jobberNumber(n.id)))].sort((a, b) => entry(a).localeCompare(entry(b)))
  }
  return total
}

// Writes payout nodes through public.sync_jobber_payouts. A payout held for a payment not here yet gets that payment
// read by id and written (with its own dependencies), then the payout is written again once.
export async function writePayouts(rpc: Rpc, nodes: any[], gone: string[], readPayment: ReadPayment, importDep: ImportDep) {
  const total: Record<string, any> = { held: [], payments_read: 0 }
  let pending = nodes
  let goneLeft = gone
  for (let round = 0; round < 2 && (pending.length || goneLeft.length); round++) {
    const held: any[] = []
    const missing = new Set<string>()
    for (let i = 0; i < Math.max(pending.length, 1); i += PAYOUT_CHUNK) {
      const r = await rpcOrThrow(rpc, 'sync_jobber_payouts', { p_nodes: pending.slice(i, i + PAYOUT_CHUNK), p_gone: i === 0 ? goneLeft : [] })
      addStats(total, r)
      held.push(...(r.held ?? []))
      for (const g of r.missing?.payments ?? []) missing.add(g)
    }
    goneLeft = []
    total.held = held
    if (!held.length || !missing.size) break
    const extra: any[] = []
    for (const g of missing) {
      const n = await readPayment(g)
      total.payments_read++
      if (n) extra.push(n)
    }
    if (!extra.length) break
    const w = await writePayments(rpc, extra, [], readPayment, importDep)
    if (w.held.length) total.payments_held = w.held
    const heldNums = new Set(held.map((h) => jobberNumber(h.gid)))
    pending = pending.filter((n) => heldNums.has(jobberNumber(n.id)))
  }
  return total
}
