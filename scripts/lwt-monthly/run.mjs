// Fast self-check of monthly-rules.ts, made-up data only. No bot code runs here.
//   node --experimental-strip-types run.mjs
// Non-zero exit on any failure. It ends by breaking the module on purpose, one rule
// at a time, and requires this same suite to fail each time.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath, pathToFileURL} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const modArg = process.argv.find(a => a.startsWith('--module='));
const quiet = process.argv.includes('--no-mutants');
const modPath = modArg ? modArg.slice(9) : path.join(here, 'monthly-rules.ts');
const R = await import(pathToFileURL(modPath).href);
const {MonthlyRules, clientFromVisit, configDrift, parseTickets, reportShape, ruleInfo, latestVisitDate} = R;

let fails = 0, passes = 0;
function check(label, cond, extra) {
  if (cond) { passes++; return; }
  fails++;
  if (!quiet) console.log('  FAIL  ' + label + (extra !== undefined ? '  -> ' + JSON.stringify(extra) : ''));
}
function section(name) { if (!quiet) console.log('[' + name + ']'); }

// ---- Made-up month ---------------------------------------------------------
const fac = (name, address, extra) => Object.assign({name, address}, extra || {});
const HARBOR = fac('Harbor Grill', '100 Harbor Ln, Miami, FL 33101');
const BAYSIDE = fac('Bayside Cafe', '200 Bay Ave, Miami, FL 33102');
const CORAL = fac('Coral Bistro', '300 Coral Rd, Miami, FL 33103');
const SUNSET = fac('Sunset Taqueria', '400 Sunset Dr, Miami, FL 33104');
const MARINA = fac('Marina Deli', '500 Marina Way, Miami, FL 33105');
const DOCK = fac('Dockside Diner', '600 Dock St, Miami, FL 33106');
const row = (t, offload, f, extra) => Object.assign({ticket_number: t, pickup_date: '2026-09-06', offload_date: offload,
  gallons: null, decal: null, facilities: [Object.assign({}, f)], trucks: [], disposal_facility: 'South District WWTP'}, extra || {});
const FEED = () => [
  row('900001', '2026-09-10', HARBOR),
  row('900002', '2026-09-11', BAYSIDE),
  row('900003', '2026-09-03', CORAL),
  row('900004', '2026-09-11', SUNSET),
  row('900005', '2026-09-10', MARINA, {pickup_date: '2026-09-07'}),
];
const fetchResp = (loads, more) => Object.assign({loads: loads || FEED(), fetch_findings: [], meta: {},
  archived: {}, archived_rows: {}, filed_tickets: {}}, more || {});
const P1 = () => ({tickets: ['900001', '900002', '900004', '900005', '900100', '900101'], invoice_id: 'SP00099001',
  decals: {'900001': 'C1184', '900002': 'C0976', '900004': 'C0976', '900100': 'C1184'},
  service_dates: {'900001': '2026-09-07', '900002': '2026-09-11', '900004': '2026-09-11', '900005': '2026-09-08',
                  '900100': '2026-09-11', '900101': '2026-09-12'}});
const P2 = () => Object.assign(P1(), {invoice_id: 'SP00099002',
  service_dates: Object.assign(P1().service_dates, {'900001': '2026-09-08', '900101': '2026-09-13'})});
const CLIENTS = [fac('Harbor Grill', '100 Harbor Ln, Miami, FL 33101', {_src: 'picked'}),
                 fac('Nuevo Sitio', '9 B St, Miami, FL 33125', {_src: 'typed'})];
const ff = m => m.payload().body?.fetch_findings || [];
const get = (m, t) => m.LOADS.find(l => l.ticket_number === t);
const idx = (m, t) => m.indexOfTicket(t);
const clone = x => JSON.parse(JSON.stringify(x));

// The month as a person works it: a hand row typed before the paper (a guess), the
// paper dropped, then the corrections, the returns and a hand un-tick.
function workedMonth() {
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp());
  m.addPaperLoad('900101', '2026-09-05', 'C1184', {pickup: '2026-09-04'});
  m.adoptDroppedInvoice(P1(), 'SP00099001.pdf', 'JVBERi0=');
  m.addPaperLoad('900100', '2026-09-11', 'C1184', {pickup: '2026-09-09', clients: CLIENTS});
  m.setIncluded(idx(m, '900101'), false);
  m.useInvoiceDate('900001');                  // correction: 09-07 over the feed's 09-10
  m.setLoadDecal(idx(m, '900002'), 'C1184');   // correction: the paper names C0976
  m.setLoadDecal(idx(m, '900003'), 'C0976');   // guess: the paper is silent on 900003
  m.setLoadDecal(idx(m, '900004'), 'C1184');   // pinned...
  m.useInvoiceDecal(idx(m, '900004'));         // ...and back to the invoice's
  m.useInvoiceDate('900005'); m.undoInvoiceDate('900005');
  return m;
}
function assertKept(m, tag) {
  const h = get(m, '900100');
  check(tag + ': hand row back, flagged, ticked, clients and pickup as typed',
        h && h._paper === true && h._excluded === false && h.pickup_date === '2026-09-09' && h.decal === 'C1184'
        && h.facilities.length === 2 && h.facilities[0]._src === 'picked' && h.facilities[1]._src === 'typed', h);
  check(tag + ': ...same provenance', m.paperProvenance(h) ===
        'Offload 2026-09-11 typed; pickup 2026-09-09 typed; 1 client picked from this month\u2019s list; 1 client typed.',
        m.paperProvenance(h));
  const u = get(m, '900101');
  check(tag + ': a hand row un-ticked by hand stays un-ticked', u && u._paper === true && u._excluded === true && u._manual === true, u);
  const c = get(m, '900001');
  check(tag + ': a date set after the paper stays pinned, naming the system\'s',
        c && c.offload_date === '2026-09-07' && c._offload_pinned === true && c._offload_src === 'operator' && c._offload_feed === '2026-09-10', c);
  check(tag + ': ...its receipt says what the system had', ff(m).some(f => f.rule === 'operator_set_offload' && f.row_key === '900001'
        && f.detail.indexOf('The system said 2026-09-10.') !== -1));
  const d = get(m, '900002');
  check(tag + ': a truck set after the paper stays pinned', d && d.decal === 'C1184' && d._decal_pinned === true && d._decal_src === 'manual', d);
  check(tag + ': ...and the paper\'s disagreement is said', ff(m).some(f => f.rule === 'operator_decal_vs_invoice' && f.row_key === '900002'
        && f.detail.indexOf('names C0976') !== -1));
  const g = get(m, '900003');
  check(tag + ': a truck guessed where the paper is silent stays a guess', g && g.decal === 'C0976' && g._decal_src === 'manual' && !g._decal_pinned, g);
  const r = get(m, '900004');
  check(tag + ': a truck taken back to the invoice\'s is the default, nothing pinned', r && r.decal === 'C0976' && r._decal_src === 'invoice' && !r._decal_pinned, r);
  const b = get(m, '900005');
  check(tag + ': a date set and undone is the system\'s again, nothing carried',
        b && b.offload_date === '2026-09-10' && !('_offload_src' in b) && !('_offload_pinned' in b) && !('_offload_feed' in b), b);
  check(tag + ': "set by hand" counts only the real hand tick',
        JSON.stringify(m.manualLoads().map(l => l.ticket_number)) === '["900101"]', m.manualLoads().map(l => l.ticket_number));
}

// ---- Who is ticked ---------------------------------------------------------
section('ticks');
{
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp());
  check('Miami-Dade rows arrive un-ticked', m.LOADS.every(l => l._excluded === true));
  check('...so nothing can be filed yet', m.payload().err === 'Every ticket is unchecked \u2014 nothing to file', m.payload());
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  check('the invoice ticks exactly what it bills', get(m, '900001')._excluded === false && get(m, '900003')._excluded === true);
  check('a hand un-tick outlives a re-read', (m.setIncluded(idx(m, '900001'), false), m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA=='), get(m, '900001')._excluded === true));
  m.matchInvoiceExactly();
  check('Match the invoice exactly clears hand ticks', get(m, '900001')._excluded === false && !m.manualLoads().length);
  m.setIncluded(idx(m, '900003'), true);
  check('a hand tick off the paper rides the body', m.payload().body.loads.some(l => l.ticket_number === '900003'));
  check('un-ticked rows travel in excluded_tickets', m.payload().body.excluded_tickets === undefined || !m.payload().body.excluded_tickets.includes('900003'));
  m.setIncluded(idx(m, '900001'), false);
  check('...an un-tick does', m.payload().body.excluded_tickets.includes('900001'));
  check('re-tick takes it out again', (m.setIncluded(idx(m, '900001'), true), !(m.payload().body.excluded_tickets || []).includes('900001')));
}
section('out of county');
{
  const priced = row('900201', '2026-09-08', DOCK, {out_of_county: true, gallons: 65, disposal_facility: 'Water and Wastewater Services'});
  const held = row('900202', '2026-09-08', DOCK, {out_of_county: true, gallons: null, disposal_facility: 'Water and Wastewater Services',
                                                 sizes_missing_clients: ['Dockside Diner']});
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp([clone(priced), clone(held), row('900001', '2026-09-10', HARBOR)]));
  check('ticked when it has a quantity, with no invoice at all', get(m, '900201')._excluded === false);
  check('held when it has none', get(m, '900202')._excluded === true && m.isHeld(get(m, '900202')));
  const b = m.payload().body;
  check('a held row is not an operator exclusion', !(b.excluded_tickets || []).includes('900202'));
  check('candidate_pool marks the class', b.candidate_pool.find(e => e.ticket_number === '900201').out_of_county === true);
  check('a held row is not a blocker', !m.blockingLoads().some(x => x.l.ticket_number === '900202'));
  check('a decal lends a held row nothing', (get(m, '900202').decal = 'C1184', m.resolvedGallons(get(m, '900202')) === null));
  delete get(m, '900202').decal;
  m.setLoadDecal(idx(m, '900201'), 'C1184');
  check('a truck cannot be set on this class', !get(m, '900201').decal);
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  check('an invoice does not re-decide it', get(m, '900201')._excluded === false);
  const d = m.decisions().filter(x => x.ticket === '900202');
  check('decisions: waiting on a size, not counted', d.length === 1 && d[0].kind === 'waiting_on_size' && d[0].counted === false
        && d[0].clients[0] === 'Dockside Diner', d);
  check('counts: held is its own number', m.counts().held === 1 && m.counts().heldClients === 1, m.counts());
  // The hand un-tick of this class is the only decision there is, so Reload keeps it.
  m.setIncluded(idx(m, '900201'), false);
  m.reload(fetchResp([clone(priced), clone(held), row('900001', '2026-09-10', HARBOR)]));
  check('Reload keeps the hand un-tick of an out-of-county load', get(m, '900201')._excluded === true && get(m, '900201')._manual === true);
  const file = clone(m.savedFileBody());
  const m2 = new MonthlyRules('2026-09');
  const r2 = m2.adoptSavedFile(file);
  check('...so does the saved file', get(m2, '900201')._excluded === true && get(m2, '900201')._manual === true && r2.reread !== null);
  // Held now: off by default, nothing to carry.
  m.reload(fetchResp([Object.assign(clone(priced), {gallons: null}), clone(held)]));
  check('a load the system now holds keeps no hand mark', get(m, '900201')._excluded === true && !get(m, '900201')._manual);
  check('reportShape ignores the class', reportShape([Object.assign(clone(priced), {offload_date: '2026-05-01'})], '2026-09') === null);
}

// ---- The M1 truth table ----------------------------------------------------
section('M1: Reload');
{
  const m = workedMonth();
  check('the worked month: the guess was replaced by the paper', get(m, '900101').offload_date === '2026-09-12' && get(m, '900101')._offload_pinned === false);
  const before = JSON.stringify(m.payload().body);
  m.reload(fetchResp());
  assertKept(m, 'Reload');
  check('Reload: the signed body is the one before Reload, byte for byte', JSON.stringify(m.payload().body) === before);
  // A later invoice that disagrees.
  m.adoptDroppedInvoice(P2(), 'b.pdf', 'AA==');
  check('later invoice: the pinned date stays and offload_vs_invoice names both', get(m, '900001').offload_date === '2026-09-07'
        && m.offloadInvoiceFindings().some(f => f.row_key === '900001' && f.detail ===
          'The invoice bills this ticket on 2026-09-08; the row says it was offloaded 2026-09-07.'), m.offloadInvoiceFindings());
  check('later invoice: the guess is replaced again, naming what was typed', get(m, '900101').offload_date === '2026-09-13'
        && m.paperProvenance(get(m, '900101')).indexOf('Offload 2026-09-13 from the invoice, replacing 2026-09-05 typed before it') === 0,
        m.paperProvenance(get(m, '900101')));
  check('later invoice: the pinned truck stays', get(m, '900002').decal === 'C1184' && get(m, '900002')._decal_pinned === true);
  // Second paper silent about a guess truck: mergeDecals finds nothing.
  check('later invoice: a truck guess the paper is silent on stays', get(m, '900003').decal === 'C0976');
}
{
  const m = workedMonth();
  m.reload(fetchResp(FEED().map(l => l.ticket_number === '900001' ? Object.assign(l, {offload_date: '2026-09-07'}) : l)));
  check('Reload: once the system has the operator\'s date, the pin is released',
        get(m, '900001').offload_date === '2026-09-07' && !('_offload_src' in get(m, '900001')) && !('_offload_pinned' in get(m, '900001'))
        && !ff(m).some(f => f.rule === 'operator_set_offload'), get(m, '900001'));
}
{
  const m = workedMonth();
  m.reload(fetchResp(FEED().map(l => l.ticket_number === '900001' ? Object.assign(l, {offload_date: '2026-09-09'}) : l)));
  check('Reload: another date in the system now: the pin stays, naming the new one',
        get(m, '900001').offload_date === '2026-09-07' && get(m, '900001')._offload_feed === '2026-09-09'
        && ff(m).some(f => f.rule === 'operator_set_offload' && f.detail.indexOf('The system said 2026-09-09.') !== -1));
}
{
  const m = workedMonth();
  m.reload(fetchResp(FEED().map(l => l.ticket_number === '900003' ? Object.assign(l, {decal: 'C1184'}) : l)));
  check('Reload: a truck guess yields to a truck the system now sends', get(m, '900003').decal === 'C1184' && !get(m, '900003')._decal_src, get(m, '900003'));
  check('Reload: ...a correction does not', get(m, '900002').decal === 'C1184' && get(m, '900002')._decal_pinned === true);
}
{
  const m = workedMonth();
  m.reload(fetchResp(undefined, {archived: {'900101': {reason: 'test_data', by: 'someone', at: '2026-10-29'}}}));
  check('Reload: an archived hand row is not brought back', !get(m, '900101'));
}
{
  const m = workedMonth();
  m.reload(fetchResp(FEED().concat([row('900100', '2026-09-11', HARBOR, {pickup_date: '2026-09-10'})])));
  const fr = m.LOADS.filter(l => l.ticket_number === '900100');
  check('Reload: a hand row the system now sends gives way: one row, the system\'s',
        fr.length === 1 && !fr[0]._paper && fr[0].pickup_date === '2026-09-10' && fr[0].facilities.length === 1 && fr[0]._excluded === false, fr);
  const hr = ff(m).filter(f => f.rule === 'manual_load_replaced_by_feed');
  check('Reload: ...it says what differs, and the act', hr.length === 1 && hr[0].detail ===
        'Entered by hand before the system had this ticket; Reload put the system\u2019s row in its place. It differs from what was typed: ' +
        'pickup \u2014 the system has 2026-09-10, typed 2026-09-09; clients \u2014 the system has Harbor Grill, typed Harbor Grill, Nuevo Sitio. Check it against the paper.', hr);
  check('Reload: ...never a field of the signed row', m.payload().body.loads.every(l => !('_hand_replaced' in l)));
}
{
  const m = workedMonth();
  m.adoptFetch(fetchResp());
  check('a clean pull carries nothing', !get(m, '900100') && !('_offload_src' in get(m, '900001')));
}
{
  const m = workedMonth();
  m.setIncluded(idx(m, '900002'), false);
  m.reload(fetchResp());
  check('Reload does not carry a Dade tick: the invoice re-ticks', get(m, '900002')._excluded === false && !get(m, '900002')._manual);
}

section('M1: saved file');
{
  const m = workedMonth();
  const saved = clone(m.savedFileBody());
  const before = JSON.stringify(m.payload().body);
  check('schema 2, and the invoice is carried: list, number, bytes', saved.schema === 2 && saved.invoice.text === m.invoiceText
        && saved.invoice.invoice_id === 'SP00099001' && saved.invoice.source.b64 === 'JVBERi0=');
  check('nothing the parse derived is stored', JSON.stringify(Object.keys(saved.invoice).sort()) === '["invoice_id","source","text"]');
  const n = new MonthlyRules('2026-09');
  const r = n.adoptSavedFile(clone(saved));
  check('the list is back BEFORE the ticks are read: no row reads as a hand tick',
        JSON.stringify(n.manualLoads().map(l => l.ticket_number)) === '["900101"]', n.manualLoads().map(l => l.ticket_number));
  check('the bytes are asked to be read again', r.reread && r.reread.source.b64 === 'JVBERi0=' && !r.stale && !r.differs, r);
  check('applySavedReread lands', n.applySavedReread(r.reread, P1()) === true && n.invoiceStatus.tone === 'ok'
        && n.invoiceStatus.text === 'SP00099001.pdf, from the saved month \u2014 read again: 6 tickets on the invoice', n.invoiceStatus);
  assertKept(n, 'save -> load');
  check('save -> load: the signed body is the one saved, byte for byte', JSON.stringify(n.payload().body) === before);
  n.adoptDroppedInvoice(P2(), 'b.pdf', 'AA==');
  check('save -> load, later invoice: the date stays pinned, the guess is replaced', get(n, '900001').offload_date === '2026-09-07'
        && get(n, '900101').offload_date === '2026-09-13' && get(n, '900002')._decal_pinned === true);
  // A re-read that lands after a newer act is dropped.
  const n2 = new MonthlyRules('2026-09');
  const r2 = n2.adoptSavedFile(clone(saved));
  n2.invoiceFinished('900001');
  check('a re-read after a newer act is dropped', n2.applySavedReread(r2.reread, P1()) === false && n2.invoiceText === '900001');
  // A re-read that fails: the list and the pins stand.
  const n3 = new MonthlyRules('2026-09');
  const r3 = n3.adoptSavedFile(clone(saved));
  n3.rereadFailed(r3.reread);
  check('a failed re-read says so, and the corrections stand', n3.invoiceStatus.tone === 'bad' && n3.invoiceStatus.text.indexOf('Could not re-read SP00099001.pdf') === 0
        && get(n3, '900001')._offload_pinned === true && n3.invoiceText === saved.invoice.text);
  check('...and the month saved again still carries the paper', n3.savedFileBody().invoice.source.b64 === 'JVBERi0=');
  // A live invoice on the page rules.
  const n4 = new MonthlyRules('2026-09');
  n4.invoiceFinished('900001\n900002');
  const r4 = n4.adoptSavedFile(clone(saved));
  check('a live invoice stays, and the page says so', r4.differs === true && !r4.reread && n4.invoiceText === '900001\n900002'
        && n4.invoiceStatus.text.indexOf('This month was saved with another invoice list.') === 0);
  // An archive since the save.
  const n5 = new MonthlyRules('2026-09');
  n5.setArchiveState({archived: {'900003': {reason: 'test_data', by: 'someone', at: '2026-10-29'}}}, false);
  n5.adoptSavedFile(clone(saved));
  check('a ticket archived since is re-applied', !get(n5, '900003') && !!n5.ARCHIVED_ROWS['900003']);
  // A file saved before M1: no invoice key.
  const old = clone(saved); delete old.invoice;
  const n6 = new MonthlyRules('2026-09');
  const r6 = n6.adoptSavedFile(old);
  check('a v2 file without the invoice key loads as before, not "older build"', !r6.stale && n6.invoiceText === ''
        && !n6.FETCHF.some(f => f.rule === 'saved_month_predates_decal_check') && get(n6, '900001')._offload_pinned === true);
  check('...its ticks read against an empty box: every ticked row a hand tick', n6.manualLoads().length === 5, n6.manualLoads().map(l => l.ticket_number));
  check('no invoice on the page: no invoice key', !('invoice' in n6.savedFileBody()));
  // Older than v2.
  const n7 = new MonthlyRules('2026-09');
  check('a schema-less file says it is from an older build', n7.adoptSavedFile({loads: clone(saved.loads)}).stale === true
        && n7.FETCHF.some(f => f.rule === 'saved_month_predates_decal_check'));
  const n8 = new MonthlyRules('2026-09');
  check('a bare list is an older build too', n8.adoptSavedFile(clone(saved.loads)).stale === true);
  let threw = false;
  try { new MonthlyRules('2026-09').adoptSavedFile({nope: 1}); } catch (e) { threw = true; }
  check('anything else is refused', threw);
  // The bytes go with the paper's list only.
  m.invoiceFinished('700001\n700002');
  check('a list replaced by another invoice\'s numbers saves no bytes', m.savedFileBody().invoice.source === null);
}

// ---- Truck -----------------------------------------------------------------
section('truck');
{
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp());
  m.setLoadDecal(idx(m, '900001'), 'C0976');
  check('set before the paper: a guess', get(m, '900001').decal === 'C0976' && !get(m, '900001')._decal_pinned);
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  check('the paper replaces a guess', get(m, '900001').decal === 'C1184' && get(m, '900001')._decal_src === 'invoice');
  m.setLoadDecal(idx(m, '900001'), 'C0976');
  check('set after the paper: pinned', get(m, '900001')._decal_pinned === true);
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  check('a re-read does not undo a correction', get(m, '900001').decal === 'C0976');
  check('one voice: the cross-check, not operator_set_decal', !ff(m).some(f => f.rule === 'operator_set_decal' && f.row_key === '900001')
        && ff(m).some(f => f.rule === 'operator_decal_vs_invoice' && f.row_key === '900001'));
  m.setLoadDecal(idx(m, '900001'), 'C1184');
  check('choosing the invoice\'s own truck clears the pin', !get(m, '900001')._decal_pinned && get(m, '900001')._decal_src === 'invoice');
  m.setLoadDecal(idx(m, '900001'), 'NOPE');
  check('an unknown decal changes nothing', get(m, '900001').decal === 'C1184');
}
{
  // The system and the paper disagree: the paper wins, on the signed channel.
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp(FEED().map(l => l.ticket_number === '900001' ? Object.assign(l, {decal: 'C0976'}) : l)));
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  check('feed vs invoice: the paper\'s truck, the note signed', get(m, '900001').decal === 'C1184' && get(m, '900001')._decal_feed === 'C0976'
        && ff(m).some(f => f.rule === 'decal_feed_vs_invoice' && f.row_key === '900001'));
  const once = ff(m).filter(f => f.rule === 'decal_feed_vs_invoice').length;
  m.mergeDecals();
  check('...a later merge does not lose it', ff(m).filter(f => f.rule === 'decal_feed_vs_invoice').length === once && once === 1);
  m.adoptDroppedInvoice({tickets: ['900002'], invoice_id: 'SP00099003'}, 'y.pdf', 'AA==');
  check('a second invoice silent on it gives the system\'s truck back', get(m, '900001').decal === 'C0976' && !('_decal_feed' in get(m, '900001')));
  check('...and the note goes', !m.FETCHF.some(f => f.rule === 'decal_feed_vs_invoice'));
}

// ---- Date ------------------------------------------------------------------
section('date');
{
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp());
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  check('every ticked load is cross-checked', m.offloadInvoiceFindings().some(f => f.row_key === '900001' && f.detail ===
        'The invoice bills this ticket on 2026-09-07; the system has it offloaded 2026-09-10.'));
  check('use the invoice\'s date', m.useInvoiceDate('900001') === true && get(m, '900001').offload_date === '2026-09-07');
  check('...a receipt, naming the system\'s date', m.operatorOffloadFindings().some(f => f.detail ===
        'Offload date set by the operator: 2026-09-07, the invoice\u2019s Service Date. The system said 2026-09-10.'));
  check('...the line is on, with Undo', m.datedLines().length === 1 && m.datedLines()[0].was === '2026-09-10');
  check('...the feed\'s date never reaches the signed row', m.payload().body.loads.every(l => !('_offload_feed' in l)));
  check('Undo puts it back exactly', m.undoInvoiceDate('900001') === true && get(m, '900001').offload_date === '2026-09-10' && !('_offload_src' in get(m, '900001')));
  m.useInvoiceDate('900001');
  m.adoptDroppedInvoice(P2(), 'b.pdf', 'AA==');
  check('Undo refuses once the invoice moved on: a newer word stands', m.undoInvoiceDate('900001') === false && get(m, '900001').offload_date === '2026-09-07');
  check('a second click keeps the first "before"', (m.useInvoiceDate('900001'), m.undoInvoiceDate('900001'), get(m, '900001').offload_date === '2026-09-10'));
  // The invoice's day before the pickup.
  m.adoptFetch(fetchResp());
  m.adoptDroppedInvoice(Object.assign(P1(), {service_dates: {'900001': '2026-09-01'}}), 'x.pdf', 'AA==');
  m.useInvoiceDate('900001');
  check('pickup after the invoice\'s date is said at once', (m.combinedFlagsByTicket()['900001'] || []).some(f => f.rule === 'pickup_after_offload'));
}

// ---- Hand rows, visits -----------------------------------------------------
section('hand rows');
{
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp());
  check('refused with no offload date', m.addPaperLoad('900100', '', '', {}) === false && m.lastError.indexOf('Copy the offload date') === 0);
  check('already here: not added twice', m.addPaperLoad('900001', '2026-09-10', '', {}) === false);
  m.invoiceFinished('900100');
  check('on the invoice with no ticket: a decision', m.decisions().some(d => d.kind === 'number_no_ticket' && d.ticket === '900100' && !d.counted));
  m.addPaperLoad('900100', '2026-09-11', 'c1184', {clients: [{name: 'Harbor Grill', address: '100 Harbor Ln', _src: 'picked'}]});
  const h = get(m, '900100');
  check('it IS on the invoice: this ticks it', h._excluded === false && h.decal === 'C1184' && h._decal_src === 'manual');
  check('the _src never reaches the signed facility', Object.keys(m.payload().body.loads.find(l => l.ticket_number === '900100').facilities[0]).join() === 'name,address');
  const ks = Object.keys(m.payload().body.loads.find(l => l.ticket_number === '900100')).filter(k => k.startsWith('_'));
  check('no page field reaches the signed row', ks.length === 0, ks);
  const fsL = m.decisions().filter(d => d.ticket === '900100' && d.counted).map(d => d.kind).sort();
  check('a picked client adds no decision', JSON.stringify(fsL) === '["hand_row","truck_set_by_hand"]', fsL);
  check('a typed client adds one', (m.openPaperEdit('900100'), m.pfTyped('900100', 'Nuevo Sitio', '9 B St'), m.savePaperEdit(),
        m.decisions().filter(d => d.ticket === '900100' && d.kind === 'client_typed' && d.counted && d.client.name === 'Nuevo Sitio').length === 1));
  check('a typed client needs an address', (m.pfTypeOpen('900777'), m.pfTyped('900777', 'X', '') === false && m.formFor('900777').msg === 'Type the address \u2014 the form prints it.'));
  m.openPaperEdit('900100');
  m.pfOffload('900100', '');
  check('edit: the offload stays required', m.savePaperEdit() === false && get(m, '900100').offload_date === '2026-09-11');
  m.cancelPaperEdit();
}
section('visits');
{
  const v1 = {name: 'Harbor Grill', address: '100 Harbor Ln', county: 'Miami-Dade', in_dade: true, visit_id: 11, visit_date: '2026-09-08'};
  const v2 = {name: 'Bayside Cafe', address: '200 Bay Ave', visit_id: 12, visit_date: '2026-09-10'};
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp());
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  const c = [clientFromVisit(v1), clientFromVisit(v2)];
  check('latestVisitDate takes the latest stop', latestVisitDate(c) === '2026-09-10');
  m.addPaperLoad('900100', '2026-09-11', '', {clients: c, pickup: '2026-09-01', offloadSrc: 'invoice'});
  const h = get(m, '900100');
  check('the pickup comes from the visit, the latest stop, over anything typed', h.pickup_date === '2026-09-10', h);
  check('a visit counts like a pick: operator_set_client, no decision', m.clientFindings().filter(f => f.row_key === '900100').every(f => f.rule === 'operator_set_client'));
  const cnt = m.decisions().filter(d => d.ticket === '900100' && d.counted).map(d => d.kind);
  check('...only the hand row itself counts', JSON.stringify(cnt) === '["hand_row"]', cnt);
  check('the provenance says where it came from, not "typed", not "this month\'s list"', m.paperProvenance(h) ===
        'Offload 2026-09-11 from the invoice, confirmed; pickup 2026-09-10 from the visit; 2 clients picked from recorded visits.', m.paperProvenance(h));
  const body = m.payload().body;
  const sr = body.loads.find(l => l.ticket_number === '900100');
  check('nothing about the visit reaches the signed row', sr.facilities.every(f => !Object.keys(f).some(k => k.startsWith('_'))), sr);
  check('county and in_dade ride along', sr.facilities[0].county === 'Miami-Dade' && sr.facilities[0].in_dade === true);
  // A typed fallback beside a visit.
  m.openPaperEdit('900100');
  m.pfTyped('900100', 'Nuevo Sitio', '9 B St');
  m.savePaperEdit();
  check('a typed client still flags, the pickup stays the visit\'s', m.clientFindings().some(f => f.rule === 'client_typed') && get(m, '900100').pickup_date === '2026-09-10');
  // Remove the visits on edit: the pickup does not stay on a date with no visit.
  m.openPaperEdit('900100');
  check('edit opens with no typed pickup', m.PAPER_EDIT.pickup === '' && m.formPickup(m.PAPER_EDIT) === '2026-09-10');
  m.pfRemove('900100', 0); m.pfRemove('900100', 0);
  m.savePaperEdit();
  check('remove every visit: no pickup, and the words say so', get(m, '900100').pickup_date === null
        && m.paperProvenance(get(m, '900100')).indexOf('no pickup date') !== -1, m.paperProvenance(get(m, '900100')));
  // The form path.
  const n = new MonthlyRules('2026-09');
  n.adoptFetch(fetchResp());
  n.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  n.pfPickVisit('900101', v1);
  check('the form prefills the invoice\'s date and reads ready', n.formLine('900101', n.formFor('900101'), 'add').tone === 'ok', n.formLine('900101', n.formFor('900101'), 'add'));
  check('addPaperFromForm confirms the invoice\'s date', n.addPaperFromForm('900101') === true && get(n, '900101')._offload_src === 'invoice'
        && get(n, '900101').offload_date === '2026-09-12' && get(n, '900101').pickup_date === '2026-09-08');
  check('the row saves and restores', (() => { const f = clone(n.savedFileBody()); const o = new MonthlyRules('2026-09'); o.adoptSavedFile(f);
    return o.paperProvenance(get(o, '900101')).indexOf('from the visit') !== -1 && get(o, '900101').facilities[0]._from === 'visit'; })());
  // Old rows, with no visit, read the old words exactly.
  const o = new MonthlyRules('2026-09');
  o.adoptFetch(fetchResp());
  o.addPaperLoad('900100', '2026-09-11', '', {pickup: '2026-09-09', clients: CLIENTS});
  check('with no visit the old words are untouched', o.paperProvenance(get(o, '900100')) ===
        'Offload 2026-09-11 typed; pickup 2026-09-09 typed; 1 client picked from this month\u2019s list; 1 client typed.');
}

// ---- Archive ---------------------------------------------------------------
section('archive');
{
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp(FEED().concat([row('9-24-26', '2026-09-24', DOCK)])));
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  check('a malformed number cannot be archived', m.archiveGuard(get(m, '9-24-26')).why === 'Not archivable');
  check('...it is a decision, and un-ticked', m.decisions().some(d => d.kind === 'not_manifest_number' && d.ticket === '9-24-26' && d.counted) && get(m, '9-24-26')._excluded === true);
  check('a billed number cannot', m.archiveGuard(get(m, '900001')).why === 'On invoice SP00099001 \u2014 it is billed, so the paper decides');
  m.setIncluded(idx(m, '900003'), true);
  check('a ticked row cannot', m.archiveGuard(get(m, '900003')).why === 'Ticked for this filing');
  m.setIncluded(idx(m, '900003'), false);
  check('an off row can', m.archiveGuard(get(m, '900003')) === null);
  m.FILED_TICKETS = {'900003': {period: '2026-08-01', filed_at: '2026-09-20'}};
  check('a filed ticket stays filed', m.archiveGuard(get(m, '900003')).why.indexOf('In the August 2026 filing') === 0);
  m.FILED_TICKETS = {};
  check('a reason is required', m.archiveBody('900003', '').err === 'Pick a reason.');
  check('a duplicate names the real ticket', m.archiveBody('900003', 'duplicate', '', '12').err.indexOf('six digits') !== -1);
  const b = m.archiveBody('900003', 'test_data').body;
  check('the body is what the bot expects', b.ticket === '900003' && b.reason === 'test_data' && b.reason_text === null && b.duplicate_of === null
        && b.ticked === false && b.known_tickets.includes('900001') && b.invoice_tickets.includes('900001'), b);
  m.applyArchived('900003', {archived: {'900003': {reason: 'test_data', by: 'someone', at: '2026-10-29'}}, record: {reason: 'test_data', by: 'someone'}});
  check('archived: off the list, the body and the pool', !get(m, '900003') && !m.payload().body.candidate_pool.some(e => e.ticket_number === '900003'));
  m.invoiceFinished(m.invoiceText + '\n900003');
  check('archived, then billed: never "no ticket in the system"', !m.invoiceOnlyTickets().includes('900003') && m.invoiceArchivedTickets().includes('900003'));
  check('...a decision with the record', m.decisions().some(d => d.kind === 'archived_on_invoice' && d.ticket === '900003' && d.record.by === 'someone'));
  m.applyRestored('900003', {archived: {}});
  check('restored: back, ticked by the invoice, tagged', get(m, '900003')._excluded === false && get(m, '900003')._restored === true && !m.payload().body.loads.some(l => '_restored' in l));
  m.meetArchive({archived: {'900004': {reason: 'not_ours', by: 'someone', at: '2026-10-29'}}});
  check('the archive read on open meets the list', !get(m, '900004') && !!m.ARCHIVED_ROWS['900004']);
}

// ---- Approval --------------------------------------------------------------
section('approval');
{
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp());
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  check('locked before any check', m.approvalDisabled === true && m.flagsAreStale() === true);
  m.setApproved(true);
  check('a locked box cannot be ticked', m.approved === false);
  const sent = m.payload().body;
  m.setPreviewResult(sent, [{rule: 'ticket_not_on_invoice', row_key: '900001', detail: 'd', expected: false}], 'tok-1');
  check('a check opens it', m.approvalDisabled === false && m.flagsAreStale() === false);
  m.setApproved(true);
  check('...and generate can run once nothing blocks', m.canGenerate() === false || m.blockingLoads().length === 0);
  m.setLoadDecal(idx(m, '900005'), 'C1184');
  check('any change re-locks', m.approvalDisabled === true && m.approved === false && m.flagsAreStale() === true);
  m.setPreviewResult(m.payload().body, [], 'tok-2');
  m.setApproved(true);
  const g = m.generateBody().body;
  check('the generate body carries the proof', g.approved === true && g.preview_token === 'tok-2');
  // Undo the change: the data matches again, the box stays locked.
  const m2 = new MonthlyRules('2026-09');
  m2.adoptFetch(fetchResp());
  m2.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  m2.setPreviewResult(m2.payload().body, [], 'tok');
  m2.setIncluded(idx(m2, '900001'), false);
  m2.setIncluded(idx(m2, '900001'), true);
  check('a change back does not unlock: only a new check does', m2.approvalDisabled === true);
  check('...though the flags read fresh again', m2.flagsAreStale() === false);
  m2.setInvoiceId('SP00099009');
  check('the invoice number re-locks and changes the body', m2.payload().body.invoice_id === 'SP00099009' && m2.flagsAreStale() === true);
  m2.setPreviewResult(m2.payload().body, [], 'tok');
  m2.applyMonth('2026-10');
  check('the month re-locks', m2.approvalDisabled === true && m2.payload().body.month === 10);
  check('a bad month is ignored', (m2.applyMonth('2026-13x'), m2.ym === '2026-10'));
  // Record.
  check('record refuses with no generate', !!m2.recordBody().err);
  m2.setGenerated(m2.payload().body, {id: '7', tickets: '2', list: encodeURIComponent(JSON.stringify(['900001', '900002']))});
  check('record sends the list the person was shown', m2.recordBody().body.id === 7 && m2.recordBody().body.expect_tickets.join() === '900001,900002' && m2.GENERATED.ym === '2026-10');
}

// ---- Blockers, candidates, the list ----------------------------------------
section('blockers and the list');
{
  const m = new MonthlyRules('2026-09');
  m.adoptFetch(fetchResp());
  m.adoptDroppedInvoice(P1(), 'x.pdf', 'AA==');
  const missing = m.blockingLoads().map(x => x.l.ticket_number);
  check('a ticked row with no gallons blocks', JSON.stringify(missing) === '["900005"]', missing);
  check('...and is a decision', m.decisions().some(d => d.kind === 'unresolved_gallons' && d.ticket === '900005' && d.counted && d.onInvoice === true));
  check('...and generate cannot run', (m.setPreviewResult(m.payload().body, [], 't'), m.setApproved(true), m.canGenerate() === false));
  m.blockerSetDecal(idx(m, '900005'), 'C0976');
  check('naming the truck clears it', m.blockingLoads().length === 0 && get(m, '900005')._decal_src === 'manual');
  m.blockerSetDecal(idx(m, '900005'), '');
  check('...un-naming it brings it back', m.blockingLoads().length === 1 && get(m, '900005').decal === null);
  m.blockerLeaveOff(idx(m, '900005'));
  check('Leave it off: off, and no hand mark', get(m, '900005')._excluded === true && !get(m, '900005')._manual);
  m.invoiceFinished(m.invoiceText);
  check('...so the next read of the invoice ticks it again (kept as the old page does)', get(m, '900005')._excluded === false);
  // Typing.
  m.invoiceTyping(m.invoiceText + '\n8286');
  check('mid-typing: ticks, does not accuse', m.INVOICE_SETTLED === false && !m.decisions().some(d => d.kind === 'number_no_ticket' && d.ticket === '8286'));
  m.invoiceFinished();
  check('finished: it accuses', m.decisions().some(d => d.kind === 'number_no_ticket' && d.ticket === '8286'));
  m.removeInvTicket('8286');
  check('remove takes it off', !parseTickets(m.invoiceText).includes('8286'));
  // Add number.
  check('a short number is refused', m.addInvTicket('123').ok === false);
  const a = m.addInvTicket('900301', 'C0976');
  check('a new number gets its truck kept for the paper row', a.ok && m.PAPER_DECALS['900301'] === 'C0976' && m.HAND_ADDED['900301'] === true && a.tone === 'warn', a);
  m.reload(fetchResp(FEED().concat([row('900301', '2026-09-12', DOCK)])));
  check('Reload: the kept truck rides onto the row the system now sends', get(m, '900301').decal === 'C0976' && get(m, '900301')._decal_src === 'manual');
  // Window.
  check('dumped inside the invoice\'s dates, not billed', m.decisions().some(d => d.kind === 'dumped_not_billed') === m.inWindowNotBilled().length > 0);
  const w = new MonthlyRules('2026-09');
  w.adoptFetch(fetchResp());
  w.invoiceFinished('900001\n900002');
  check('window: between its first and last date, un-ticked, off the paper', JSON.stringify(w.invoiceWindow()) === '{"from":"2026-09-10","to":"2026-09-11"}'
        && w.inWindowNotBilled().map(l => l.ticket_number).join() === '900004,900005', w.inWindowNotBilled().map(l => l.ticket_number));
  check('...a decision, with the row\'s index', w.decisions().filter(d => d.kind === 'dumped_not_billed').every(d => w.LOADS[d.index].ticket_number === d.ticket));
  w.setIncluded(idx(w, '900004'), true);
  check('...filing it answers it', !w.inWindowNotBilled().some(l => l.ticket_number === '900004'));
  // Candidates.
  const c = new MonthlyRules('2026-09');
  c.adoptFetch(fetchResp());
  check('atomic: no tickets, nothing touched, candidates offered', c.applyInvoiceParse({tickets: [], invoice_id: 'X', near_tickets: [{guess: '900001', as_read: '9O0001'}]}, 'x.pdf') === false
        && c.invoiceText === '' && c.invoiceId === '' && c.decisions().some(d => d.kind === 'reader_candidate' && d.ticket === '900001' && d.group === 'near'));
  c.acceptCandidate('900001');
  check('accepting ticks, and the offer goes', get(c, '900001')._excluded === false && !c.decisions().some(d => d.kind === 'reader_candidate'));
  // Findings of the invoice survive a fetch.
  c.applyInvoiceParse({tickets: ['900001'], total_mismatch: 'Total 10 vs 20', parse_warnings: ['page 3 unread']}, 'x.pdf');
  c.reload(fetchResp());
  check('invoice rules survive a fetch', c.FETCHF.filter(f => f.rule === 'invoice_total_mismatch' || f.rule === 'invoice_parse_warning').length === 2);
  check('...they are month notes', c.decisions().filter(d => d.kind === 'month_note' && d.ticket === null).length === 2);
  // Numberless row.
  const nl = new MonthlyRules('2026-09');
  nl.adoptFetch(fetchResp([row('', '2026-09-10', HARBOR), row('900001', '2026-09-10', HARBOR)]));
  check('a numberless row gets a placeholder in excluded_tickets', (nl.setIncluded(1, true), nl.payload().body.excluded_tickets[0] === '<row 1 without ticket>'), nl.payload().body.excluded_tickets);
  // Shape.
  const sh = new MonthlyRules('2026-08');
  sh.adoptFetch(fetchResp());
  sh.invoiceFinished('900001\n900002\n900003');
  const s = sh.decisions().find(d => d.kind === 'report_shape');
  check('most of the report outside the month: said, with a suggestion', s && s.suggest === '2026-09' && s.topN === 3 && s.total === 3, s);
  // Offload month forms.
  check('reportShape reads US dates too', reportShape([{offload_date: '09/10/2026'}], '2026-08').top === '2026-09');
}

// ---- Decisions match the count they stand on ------------------------------
section('decisions');
{
  const m = workedMonth();
  const before = JSON.stringify(m.savedFileBody());
  const ds = m.decisions();
  check('read-only: nothing moved', JSON.stringify(m.savedFileBody()) === before);
  const byT = {};
  ds.filter(d => d.counted).forEach(d => { byT[d.ticket] = (byT[d.ticket] || 0) + 1; });
  check('tickets with a counted item = the old "to decide" count', Object.keys(byT).length === m.counts().flagged, [byT, m.counts()]);
  const flags = m.combinedFlagsByTicket();
  check('per ticket: as many items as the old pill says', Object.keys(byT).every(t => byT[t] === (flags[t] || []).length), byT);
  check('every row item has an index that finds its row', ds.filter(d => d.counted).every(d => m.LOADS[d.index] && String(m.LOADS[d.index].ticket_number) === d.ticket));
  check('truck_differs carries both trucks and the way back', ds.some(d => d.kind === 'truck_differs' && d.ticket === '900002' && d.rowDecal === 'C1184'
        && d.invoiceDecal === 'C0976' && d.pinned === true && d.canUseInvoice === true));
  check('words come from the vocabulary', ds.every(d => typeof d.title === 'string' && d.title.length > 0 && ['block', 'warn', 'hold', 'policy'].includes(d.tone)));
  // After a check, the same questions are not asked twice.
  const n = new MonthlyRules('2026-09');
  n.adoptFetch(fetchResp());
  n.invoiceFinished('900001\n900999');
  const before2 = n.decisions().filter(d => d.ticket === '900999').length;
  n.setPreviewResult(n.payload().body, [{rule: 'invoice_ticket_missing_from_report', row_key: '900999', detail: 'x', expected: false},
    {rule: 'membership_unverified', row_key: null, detail: 'month', expected: false},
    {rule: 'out_of_county_ticket_on_report', row_key: '900001', detail: 'x', expected: true}], 't');
  check('a check does not repeat the number with no ticket', n.decisions().filter(d => d.ticket === '900999').length === before2 && before2 === 1);
  check('a check\'s month item shows until the data drifts', n.decisions().some(d => d.kind === 'month_note' && d.rule === 'membership_unverified'));
  check('expected findings ask nothing', !n.decisions().some(d => d.rule === 'out_of_county_ticket_on_report'));
  n.setIncluded(idx(n, '900001'), false);
  check('...then it goes', !n.decisions().some(d => d.rule === 'membership_unverified'));
}

// ---- The vocabulary --------------------------------------------------------
section('config');
{
  const cfg = () => ({rule_info: R.RULE_INFO, decal_gallons: R.DECAL_GALLONS, receipt_rules: R.RECEIPT_RULES, no_ticket_key: R.NO_TICKET_KEY, build_stamp: 'build x'});
  const js = o => 'window.MONTHLY_CONFIG = ' + JSON.stringify(o).replace(/<\//g, '<\\/') + ';';
  check('the same tables: no drift', configDrift(js(cfg())).length === 0, configDrift(js(cfg())));
  const moved = JSON.parse(JSON.stringify(cfg()));
  moved.decal_gallons.C1184 = 3700;
  moved.rule_info.brand_new = ['New', 'warn', 'Words'];
  delete moved.rule_info.client_typed;
  moved.receipt_rules.push('another');
  moved.no_ticket_key = '<none>';
  const d = configDrift(js(moved));
  check('every kind of difference is said', d.length === 5 && d.some(x => x.indexOf('decal_gallons.C1184') === 0) && d.some(x => x.indexOf('brand_new') !== -1)
        && d.some(x => x.indexOf('client_typed') !== -1) && d.some(x => x.indexOf('receipt_rules') === 0) && d.some(x => x.indexOf('no_ticket_key') === 0), d);
  check('text it cannot read is a drift, never a pass', configDrift('<html>not found</html>').length === 1 && configDrift('').length === 1);
  check('an unknown rule degrades to words', ruleInfo('some_brand_new_rule').title === 'Some brand new rule');
  check('tones the page keys on exist', ruleInfo('out_of_county_sizes_missing').tone === 'hold' && ruleInfo('decal_feed_vs_invoice').tone === 'block');
  check('prices name the two trucks', R.PRICE_TO_DECAL['357.20'] === 'C1184' && R.PRICE_TO_DECAL['188.00'] === 'C0976' && R.DECAL_GALLONS.C0976 === 2000);
  check('explainError keeps its words', R.explainError(409, 'unresolved gallons').indexOf('The file cannot be generated yet') === 0 && R.explainError(500, 'x') === 'Error 500: x');
  check('recordOutcome: "already" is not a record', R.recordOutcome(true, JSON.stringify({said: {state: 'already', dry_run: false}})).state === 'already'
        && R.recordOutcome(true, JSON.stringify({said: {state: 'recorded', dry_run: false}})).recorded === true
        && R.recordOutcome(true, 'x').state === 'unconfirmed' && R.recordOutcome(null, '').state === 'no_answer'
        && R.recordOutcome(false, JSON.stringify({detail: 'no', refused_by: 'tracker'})).who === 'The Tracker');
  check('base64 round trip', Buffer.from(R.b64ToBytes(R.bytesToB64(new Uint8Array([37, 80, 0, 255])))).toString('hex') === '255000ff');
}

if (quiet) process.exit(fails ? 1 : 0);
console.log(passes + ' checks passed, ' + fails + ' failed');

// ---- Mutants: the suite must be able to fail -------------------------------
const MUTANTS = [
  ['a correction does not pin', "if (setAfterPaper(this.INV_DECALS, l.ticket_number)) l._decal_pinned = true;", "if (false) l._decal_pinned = true;"],
  ['the merge overrides a pin', "      if (l._decal_pinned) return;\n      const own", "      const own"],
  ['every date reads as pinned', "l._offload_pinned = setAfterPaper(this.INV_DATES, l.ticket_number);", "l._offload_pinned = true;"],
  ['the paper replaces a correction', "if (!paper || l._offload_pinned !== false || isOutOfCounty(l)) return;", "if (!paper || isOutOfCounty(l)) return;"],
  ['a held load is ticked', "if (isOutOfCounty(l)) return isHeld(l);", "if (isOutOfCounty(l)) return false;"],
  ['a priced out-of-county load is off', "if (isOutOfCounty(l)) return isHeld(l);", "if (isOutOfCounty(l)) return true;"],
  ['Dade ticks with no invoice', "return inv === null || inv.indexOf(String(l.ticket_number || '')) === -1;", "return inv !== null && inv.indexOf(String(l.ticket_number || '')) === -1;"],
  ['Reload loses hand rows', "if (!n) { hand.push(o); return; }", "if (!n) return;"],
  ['Reload brings back an archived hand row', "        if (this.ARCHIVED[t]) return;\n        if (!n) {", "        if (!n) {"],
  ['Reload loses a pinned date', "o._offload_src === 'operator' && o._offload_pinned === true &&", "false && o._offload_pinned === true &&"],
  ['Reload loses a pinned truck', "if (o._decal_src === 'manual' && o.decal && (o._decal_pinned || !sys)) {", "if (false) {"],
  ['Reload loses an out-of-county un-tick', "          n._excluded = true;\n          n._manual = true;\n", ""],
  ['a saved tick reads as no hand mark', "if (!!l._excluded !== defaultExcluded(l, inv)) l._manual = true;", "if (false) l._manual = true;"],
  ['the file drops the bytes', "source: samePaper ? this.INVOICE_SRC : null", "source: null"],
  ['ticks read before the saved list', "      const took = this.takeSavedInvoice(j.invoice);\n      inv = took.inv; differs = !!took.differs;\n      this.restoreLoads(j.loads);", "      this.restoreLoads(j.loads);\n      const took = this.takeSavedInvoice(j.invoice);\n      inv = took.inv; differs = !!took.differs;"],
  ['the use-invoice truck keeps the pin', "    delete l._decal_pinned;\n    this.mergeDecals();", "    this.mergeDecals();"],
  ['a page field leaks into the body', "        delete c._hand_replaced;\n", ""],
  ['a client _src leaks into the body', "if (k.charAt(0) === '_') delete g[k];", ""],
  ['a held row reads as an un-tick', "(l._excluded && !isHeld(l))", "(l._excluded)"],
  ['a visit counts as a typed client', "rule: f._src === 'typed' ? 'client_typed' : 'operator_set_client'", "rule: 'client_typed'"],
  ['the first visit, not the latest', "if (d > best) best = d;", "if (d && !best) best = d;"],
  ['a typed pickup outranks the visit', "pickup_date: fromVisit || o.pickup || null", "pickup_date: o.pickup || fromVisit || null"],
  ['provenance lies about a visit', "(latestVisitDate(fa) === l.pickup_date ? ' from the visit' : ' typed')", "' typed'"],
  ['approval never re-locks', "if (this.previewedPayload === null || current === null || current !== this.previewedPayload)\n      this.lockApproval();", "if (this.previewedPayload === null)\n      this.lockApproval();"],
  ['a change back unlocks', "current !== this.previewedPayload)\n      this.lockApproval();", "current !== this.previewedPayload)\n      this.lockApproval();\n    else this.approvalDisabled = false;"],
  ['generate carries no proof', "p.body.preview_token = this.previewToken;", ""],
  ['invoice findings die on a fetch', "const keep = this.FETCHF.filter(f => INVOICE_RULES.includes(f.rule));", "const keep: Finding[] = [];"],
  ['the system-vs-paper note is lost', "      l._decal_feed = own;\n", ""],
  ['Undo erases a newer word', "if (!was || !l || !this.datedLineTrue(was, l)) { this.refreshAll(); return false; }", "if (!was || !l) { this.refreshAll(); return false; }"],
  ['a billed row can be archived', "    if (inv.indexOf(t) !== -1) {\n      const id = this.invoiceId.trim();", "    if (false) {\n      const id = this.invoiceId.trim();"],
  ['a held wait counts as a decision', "const counted = fs.length > 0 && !(isHeld(l) && onlyWaiting(fs));", "const counted = fs.length > 0;"],
  ['decisions accuse mid-typing', "const only = (this.LOADS.length && this.INVOICE_SETTLED) ? this.invoiceOnlyTickets() : [];", "const only = this.invoiceOnlyTickets();"],
  ['decal drift goes unsaid', "cmp('decal_gallons', DECAL_GALLONS, cfg.decal_gallons || {});", ""],
  ['unreadable config passes', "catch (e) { return ['could not read the config text: ' + (e as Error).message]; }", "catch (e) { return []; }"],
  ['Leave it off marks a hand decision', "    this.LOADS[i]._excluded = true;\n    this.refreshAll();", "    this.LOADS[i]._excluded = true;\n    this.LOADS[i]._manual = true;\n    this.refreshAll();"],
];

const src = fs.readFileSync(path.join(here, 'monthly-rules.ts'), 'utf8').replace(/\r\n/g, '\n');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lwt-rules-'));
let killed = 0, broken = 0;
for (let i = 0; i < MUTANTS.length; i++) {
  const [name, a, b] = MUTANTS[i];
  const n = src.split(a).length - 1;
  if (n !== 1) { console.log('  ANCHOR x' + n + '  ' + name); broken++; continue; }
  const f = path.join(tmp, 'mutant' + i + '.mts');
  fs.writeFileSync(f, src.replace(a, () => b));
  const r = spawnSync(process.execPath, ['--experimental-strip-types', '--no-warnings', fileURLToPath(import.meta.url),
                                          '--no-mutants', '--module=' + f], {encoding: 'utf8'});
  if (r.status === 1) killed++;
  else console.log('  SURVIVED (' + r.status + ')  ' + name + (r.stderr ? ' :: ' + r.stderr.split('\n').slice(0, 4).join(' ') : ''));
}
fs.rmSync(tmp, {recursive: true, force: true});
console.log('mutants: ' + killed + ' of ' + MUTANTS.length + ' killed' + (broken ? ', ' + broken + ' with a stale anchor' : ''));
process.exit(fails || killed !== MUTANTS.length ? 1 : 0);
