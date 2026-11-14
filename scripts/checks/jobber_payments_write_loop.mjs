// node --experimental-strip-types scripts/checks/jobber_payments_write_loop.mjs
// Checks the payments copy's write loop (supabase/functions/_shared/jobber-payments.ts: writePayments, writePayouts)
// on stubs: a payment held for its invoice gets the invoice imported and is written in the next round; a refund held
// for its original gets the original read by id first; a read that is not an answer THROWS and is never "gone"; a
// payout held for its payment gets the payment read and written, then the payout; big batches are cut in chunks of
// 100 (payouts 20) with the gone ids in the first chunk only. Then a mutant that drops the import step must fail the first case,
// so the check is known to be able to fail. Nothing reaches Jobber or the database.
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

// Node reads a .ts file in this repo as CommonJS (no "type": "module"), so load a .mts copy of the exact source.
const srcPath = join(dirname(fileURLToPath(import.meta.url)), '../../supabase/functions/_shared/jobber-payments.ts')
const load = async (text) => {
  const copy = join(mkdtempSync(join(tmpdir(), 'jp-')), 'jobber-payments.mts')
  writeFileSync(copy, text)
  return import(pathToFileURL(copy).href)
}
const src = readFileSync(srcPath, 'utf8')

const gid = (type, n) => Buffer.from(`gid://Jobber/${type}/${n}`).toString('base64')
const num = (g) => { const m = Buffer.from(g, 'base64').toString().match(/\/(\d+)$/); return m ? m[1] : null }

// A stub of public.sync_jobber_payments / sync_jobber_payouts over an in-memory "database".
function stubDb({ invoices = [], payments = [] } = {}) {
  const db = { invoices: new Set(invoices), payments: new Set(payments), calls: [] }
  db.rpc = async (fn, args) => {
    db.calls.push({ fn, nodes: args.p_nodes.length, gone: args.p_gone.length })
    if (fn === 'sync_jobber_payments') {
      const held = [], missing = { invoices: [], quotes: [], payments: [] }
      let inserted = 0
      for (const n of [...args.p_nodes].sort((a, b) => String(a.entryDate).localeCompare(String(b.entryDate)))) {
        const inv = n.invoice?.id && num(n.invoice.id)
        const rev = n.refundedPaymentRecord?.id && num(n.refundedPaymentRecord.id)
        if (inv && !db.invoices.has(inv)) { missing.invoices.push(gid('Invoice', inv)); held.push({ gid: gid('PaymentRecord', num(n.id)) }); continue }
        if (rev && !db.payments.has(rev)) { missing.payments.push(gid('PaymentRecord', rev)); held.push({ gid: gid('PaymentRecord', num(n.id)) }); continue }
        if (!db.payments.has(num(n.id))) { db.payments.add(num(n.id)); inserted++ }
      }
      return { data: { received: args.p_nodes.length, inserted, removed: args.p_gone.length, held, missing }, error: null }
    }
    const held = [], missing = { payments: [] }
    let inserted = 0
    for (const n of args.p_nodes) {
      const p = n.balanceTransactions.nodes.map((t) => t.paymentRecord?.id && num(t.paymentRecord.id)).filter(Boolean)
      const lack = p.filter((x) => !db.payments.has(x))
      if (lack.length) { missing.payments.push(...lack.map((x) => gid('PaymentRecord', x))); held.push({ gid: gid('PayoutRecord', num(n.id)) }); continue }
      inserted++
    }
    return { data: { received: args.p_nodes.length, inserted, held, missing }, error: null }
  }
  return db
}
const pay = (n, extra = {}) => ({ id: gid('CheckPaymentRecord', n), adjustmentType: 'PAYMENT', entryDate: `2026-11-1${n % 10}T10:00:00Z`, ...extra })

async function cases(m, label) {
  const results = []
  const t = async (name, fn) => { try { await fn(); results.push([name, true]) } catch (e) { results.push([name, false, e.message]) } }

  await t('a payment held for its invoice gets the invoice imported, then is written', async () => {
    const db = stubDb()
    const imported = []
    const r = await m.writePayments(db.rpc, [pay(1, { invoice: { id: gid('Invoice', 77) } })], [], async () => null,
      async (kind, g) => { imported.push(kind + ':' + num(g)); db.invoices.add(num(g)) })
    assert.deepEqual(imported, ['invoice:77'])
    assert.equal(r.held.length, 0)
    assert.equal(r.inserted, 1)
    assert.equal(db.calls.length, 2)
  })
  await t('a refund held for its original gets the original read by id and written first', async () => {
    const db = stubDb()
    const original = pay(2)
    const read = []
    const r = await m.writePayments(db.rpc, [pay(3, { adjustmentType: 'REFUND', refundedPaymentRecord: { id: gid('JobberPaymentsCreditCardPaymentRecord', 2) } })], [],
      async (g) => { read.push(num(g)); return original }, async () => {})
    assert.deepEqual(read, ['2'])
    assert.equal(r.held.length, 0)
    assert.equal(r.inserted, 2)
  })
  await t('a read by id that is not an answer throws; nothing is treated as gone', async () => {
    const db = stubDb()
    await assert.rejects(m.writePayments(db.rpc, [pay(4, { refundedPaymentRecord: { id: gid('PaymentRecord', 5) } })], [],
      async () => { throw new Error('Jobber returned no data key') }, async () => {}), /no data key/)
    assert.equal(db.calls.every((c) => c.gone === 0), true)
  })
  await t('a payout held for its payment gets the payment read and written, then the payout', async () => {
    const db = stubDb()
    const r = await m.writePayouts(db.rpc, [{ id: gid('PayoutRecord', 9), balanceTransactions: { nodes: [{ paymentRecord: { id: gid('JobberPaymentsACHPaymentRecord', 6) } }] } }], [],
      async (g) => pay(Number(num(g))), async () => {})
    assert.equal(r.held.length, 0)
    assert.equal(r.inserted, 1)
    assert.equal(db.payments.has('6'), true)
  })
  await t('450 payments go in 5 calls of at most 100; the gone ids ride in the first call only', async () => {
    const db = stubDb()
    const nodes = Array.from({ length: 450 }, (_, i) => pay(1000 + i))
    await m.writePayments(db.rpc, nodes, [gid('PaymentRecord', 1)], async () => null, async () => {})
    assert.deepEqual(db.calls.map((c) => [c.nodes, c.gone]), [[100, 1], [100, 0], [100, 0], [100, 0], [50, 0]])
  })
  await t('gone ids with no nodes still make one call', async () => {
    const db = stubDb()
    const r = await m.writePayments(db.rpc, [], [gid('PaymentRecord', 1)], async () => null, async () => {})
    assert.deepEqual(db.calls.map((c) => [c.nodes, c.gone]), [[0, 1]])
    assert.equal(r.removed, 1)
  })
  await t('a refused database call throws, it is never read as an empty result', async () => {
    const rpc = async () => ({ data: null, error: { message: 'permission denied' } })
    await assert.rejects(m.writePayments(rpc, [pay(7)], [], async () => null, async () => {}), /refused: permission denied/)
  })
  console.log(`\n${label}`)
  for (const [name, ok, why] of results) console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}${ok ? '' : '  -> ' + why}`)
  return results
}

const real = await cases(await load(src), 'the real write loop')
// the mutant: the import step dropped. The first case must fail, or the check cannot see a broken loop.
const mutantSrc = src.replace("for (const g of missing.invoices) { await importDep('invoice', g); total.imported.push(g); progressed = true }", '')
assert.notEqual(mutantSrc, src, 'the mutant anchor was not found: update this check')
const mutant = await cases(await load(mutantSrc), 'mutant: invoice imports dropped (the first case must FAIL)')

const ok = real.every((r) => r[1]) && mutant[0][1] === false
console.log(ok ? '\nRESULT: all real cases pass, and the mutant is caught' : '\nRESULT: FAILED')
process.exit(ok ? 0 : 1)
