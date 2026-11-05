// The proof: the SAME acts, driven through the ORIGINAL monthly.js (under the small
// DOM below) and through monthly-rules.ts, compared byte for byte after every act.
//
// Runs the bot's page, so it refuses to run outside the no-network container. Use
// run-in-container.ps1. No bot source lives in this folder.
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {SEQUENCES, row, ooc, HARBOR, BAYSIDE, CORAL, SUNSET, MARINA, DOCK, PIER} from './sequences.mjs';

if (!fs.existsSync('/.dockerenv')) {
  console.error('refused: this runs the bot\'s code, and only inside the no-network container (run-in-container.ps1).');
  process.exit(2);
}
const here = path.dirname(fileURLToPath(import.meta.url));
const OLD_SRC = fs.readFileSync(process.argv[2], 'utf8');
const RULES_SRC = fs.readFileSync(path.join(here, '..', 'monthly-rules.ts'), 'utf8').replace(/\r\n/g, '\n');
const EXPECTED_SHA = '5cb8098db91440e4b5a498ee9ab560798f66aa6c7e1d550f5dc1d5faeb21d06e';
const FUZZ_SEQ = 400, FUZZ_LEN = 28;
// The run must actually reach these, or a clean match proves less than it says.
const MARKERS = ['"_decal_pinned"', '"_offload_pinned":true', '"_offload_pinned":false', '"_offload_guess"', '"_offload_feed"',
  '"_hand_replaced"', '"_paper"', '"_manual"', '"_decal_feed"', '"_restored"', '"excluded_tickets"', '"candidate_pool"', 'operator_set_decal', 'operator_decal_vs_invoice',
  'decal_feed_vs_invoice', 'manual_load_from_paper', 'operator_set_client', 'client_typed', 'offload_vs_invoice', 'operator_set_offload',
  'manual_load_replaced_by_feed', 'invoice_decal_conflict', 'invoice_parse_warning', 'invoice_total_mismatch', 'saved_month_predates_decal_check',
  'manifest_number_shape', 'feed_rows_conflict', 'pickup_after_offload', 'out_of_county_gallons_held', 'out_of_county_sizes_missing', 'ticket_without_gallons'];
const SEEN = new Set();

const clone = x => (x === undefined ? undefined : JSON.parse(JSON.stringify(x)));
const sha = crypto.createHash('sha256').update(OLD_SRC).digest('hex');
console.log('monthly.js sha256 ' + sha + (sha === EXPECTED_SHA ? ' (the d00636a page)' : ' NOT THE PINNED PAGE'));
if (sha !== EXPECTED_SHA && !process.argv.includes('--any-version')) {
  console.error('The page changed since this port was proven. Re-read it, then update EXPECTED_SHA.');
  process.exit(3);
}

// ---- The smallest DOM the page runs on ------------------------------------
function makeDom() {
  class El {
    constructor(id) {
      this.id = id; this.value = ''; this.textContent = ''; this._html = ''; this.disabled = false; this.checked = false;
      this.hidden = false; this.open = false; this.files = []; this.dataset = {}; this.style = {}; this.className = '';
      this.classList = {add() {}, remove() {}, toggle() {}, contains() { return false; }};
      this.handlers = {}; this.__q = {};
    }
    setAttribute() {}
    getAttribute() { return null; }
    set innerHTML(v) { this._html = v; }
    get innerHTML() { return this._html; }
    addEventListener(ev, fn) { (this.handlers[ev] = this.handlers[ev] || []).push(fn); }
    // tag.class only: enough to reach the handlers the page wires by hand.
    querySelectorAll(sel) {
      const m = /^(\w+)\.([\w-]+)$/.exec(sel);
      if (!m) return [];
      const out = [], re = new RegExp('<' + m[1] + '\\b([^>]*)>', 'g');
      let x;
      while ((x = re.exec(this._html))) {
        const cls = /class="([^"]*)"/.exec(x[1]);
        if (!cls || !cls[1].split(/\s+/).includes(m[2])) continue;
        const el = new El('q');
        for (const d of x[1].matchAll(/data-([\w-]+)="([^"]*)"/g)) el.dataset[d[1]] = d[2];
        out.push(el);
      }
      this.__q[sel] = out;
      return out;
    }
    querySelector() { return null; }
    scrollIntoView() {}
    appendChild() {}
    click() {}
    remove() {}
    focus() {}
  }
  const els = {};
  const byId = id => els[id] || (els[id] = new El(id));
  // What monthly.html says before any script runs.
  byId('approved').disabled = true;
  byId('btnGen').disabled = true;
  byId('btnFiled').disabled = true;
  byId('dryRun').checked = true;
  return {els, byId, document: {getElementById: byId, querySelectorAll() { return []; }, querySelector() { return null; },
    createElement() { return new El('tmp'); }, addEventListener() {}, body: new El('body')}};
}

// Everything the driver reads or calls. It sits in the page's own script scope,
// because the page's top-level let and const are lexical.
const EPILOGUE = `
;globalThis.__ui = {
  fetchMonth, parseDroppedInvoice, setIncluded, refreshAll, setLoadDecal, useInvoiceDecal, useInvoiceDate, undoInvoiceDate,
  addPaperLoad, addPaperFromForm, pfQuery, pfPick, pfRemove, pfTypeOpen, pfTypeCancel, pfTyped, pfPickup, pfOffload, pfUseInvoiceDate,
  openPaperEdit, savePaperEdit, cancelPaperEdit, invoiceTyping, invoiceFinished, addInvTicket, removeInvTicket, acceptCandidate,
  setNumberDecal, matchInvoiceExactly, applyMonth, go, markFiled, adoptSavedFile, savedFileBody, openArchive, setArchiveReason,
  setArchiveText, setArchiveDup, submitArchive, restoreArchived, loadArchiveState, payload, combinedFlagsByTicket, blockingLoads,
  invoiceOnlyTickets, invoiceArchivedTickets, inWindowNotBilled, invoiceWindow, reportShape, knownClients, flagsAreStale, archiveGuard,
  manualLoads, renderTiles, renderLoaded, renderBlockers, syncGenButton, justDatedLines, heldClients, paperProvenance, isHeld,
  state(){ return {LOADS, FETCHF, PAPER_DATES, PAPER_DECALS, PAPER_FORM, PAPER_EDIT, HAND_ADDED, INVOICE_SETTLED, INV_DECALS, INV_DATES,
    INVOICE_SRC, INVOICE_READ, ARCHIVED, ARCHIVED_ROWS, FILED_TICKETS, JUST_ARCHIVED, RESENT, RESTORE_NOTE, PREVIEW_FINDINGS, previewToken, GENERATED}; },
};`;

function newOldPage(src, ym) {
  const dom = makeDom();
  const sb = {console, setTimeout, clearTimeout, atob, btoa, document: dom.document, URL: {createObjectURL() { return 'blob:x'; }, revokeObjectURL() {}},
    Blob: class {}, FileReader: class { readAsText() {} }, localStorage: {getItem() { return null; }, setItem() {}, removeItem() {}}};
  sb.window = sb; sb.globalThis = sb;
  const hdr = h => ({get(k) { const key = Object.keys(h).find(x => x.toLowerCase() === String(k).toLowerCase()); return key ? h[key] : null; }});
  const jr = x => { const s = JSON.stringify(x); return {ok: true, status: 200, headers: hdr({}), json: async () => JSON.parse(s), text: async () => s}; };
  const page = {dom, ui: null, net: {parsed: [], posts: {}}, world: null};
  sb.fetch = async (url, opts) => {
    const u = String(url), w = page.world;
    if (u === '/monthly/invoice-parse') {
      page.net.parsed.push(Array.from(opts.body));
      return w.parseOk === false ? {ok: false, status: 500, headers: hdr({}), text: async () => 'boom'} : jr(w.parse);
    }
    if (u.indexOf('/monthly/fetch') === 0) { page.net.posts.fetch = u; return jr(w.fetchResp); }
    if (u === '/monthly/archive' && opts && opts.method === 'POST') {
      const b = JSON.parse(opts.body);
      page.net.posts.archive = opts.body;
      const rec = {reason: b.reason, reason_text: b.reason_text, duplicate_of: b.duplicate_of, by: 'golden', at: '2026-10-29T12:00:00Z'};
      w.archived[b.ticket] = rec;
      w.archiveReply = {archived: clone(w.archived), filed_tickets: clone(w.filed), record: rec};
      return jr(w.archiveReply);
    }
    if (u === '/monthly/archive') { w.archiveRead = {archived: clone(w.archived), filed_tickets: clone(w.filed)}; return jr(w.archiveRead); }
    if (u === '/monthly/restore') {
      delete w.archived[JSON.parse(opts.body).ticket];
      w.restoreReply = {archived: clone(w.archived), filed_tickets: clone(w.filed)};
      return jr(w.restoreReply);
    }
    if (u === '/monthly/preview') {
      page.net.posts.preview = opts.body;
      const r = jr({html: '', findings: w.findings});
      r.headers = hdr({'x-preview-token': w.token, 'x-blocks': '1', 'x-gallons': '100', 'x-gallons-complete': '1'});
      return r;
    }
    if (u === '/monthly/generate') {
      page.net.posts.generate = opts.body;
      return {ok: true, status: 200, blob: async () => ({}), headers: hdr({'content-disposition': 'attachment; filename="x.xlsx"',
        'X-Filing-Id': w.gen.id, 'X-Filing-Tickets': w.gen.tickets, 'X-Filing-List': encodeURIComponent(JSON.stringify(w.gen.list))})};
    }
    if (u === '/monthly/mark-filed-saved') {
      page.net.posts.record = opts.body;
      const raw = JSON.stringify(w.recordReply);
      return {ok: w.recordOk !== false, status: w.recordOk === false ? 409 : 200, headers: hdr({}), text: async () => raw};
    }
    throw new Error('no network here: ' + u);
  };
  const ctx = vm.createContext(sb);
  const cfg = {rule_info: R.RULE_INFO, decal_gallons: R.DECAL_GALLONS, receipt_rules: R.RECEIPT_RULES, no_ticket_key: R.NO_TICKET_KEY, build_stamp: 'golden'};
  vm.runInContext('window.MONTHLY_CONFIG = ' + JSON.stringify(cfg) + ';', ctx);
  vm.runInContext(src + EPILOGUE, ctx);
  page.ui = sb.__ui;
  dom.byId('ym').value = ym;
  dom.byId('key').value = 'golden-key';
  return page;
}

// ---- What is compared after every act, read the same way from both sides ---
const nonBlankForms = f => Object.fromEntries(Object.entries(f).filter(([, s]) =>
  (s.clients && s.clients.length) || s.pickup || s.query || s.typing || s.msg));

function snapOld(p) {
  const u = p.ui, $ = p.dom.byId;
  u.renderTiles(); u.renderLoaded(); u.syncGenButton();
  const st = u.state();
  const tiles = {};
  for (const m of $('tiles').innerHTML.matchAll(/<div class="k">([^<]*)<\/div><div class="v [^"]*">([^<]*)<\/div>/g)) tiles[m[1]] = m[2];
  const fl = /Show only the (\d+) ticket/.exec($('loadedwrap').innerHTML);
  return {
    payload: JSON.stringify(u.payload()),
    saved: JSON.stringify(u.savedFileBody()),
    flags: JSON.stringify(u.combinedFlagsByTicket()),
    blocking: JSON.stringify(u.blockingLoads().map(x => [x.i, x.l.ticket_number])),
    only: JSON.stringify(u.invoiceOnlyTickets()),
    archOn: JSON.stringify(u.invoiceArchivedTickets()),
    inWin: JSON.stringify(u.inWindowNotBilled().map(l => l.ticket_number)),
    win: JSON.stringify(u.invoiceWindow()),
    shape: JSON.stringify(u.reportShape(st.LOADS, $('ym').value)),
    tiles: JSON.stringify(tiles),
    flagged: fl ? +fl[1] : 0,
    stale: u.flagsAreStale(),
    locked: $('approved').disabled,
    approved: $('approved').checked,
    canGen: !$('btnGen').disabled,
    paper: JSON.stringify({dates: st.PAPER_DATES, decals: st.PAPER_DECALS, hand: st.HAND_ADDED}),
    forms: JSON.stringify(nonBlankForms(st.PAPER_FORM)),
    edit: JSON.stringify(st.PAPER_EDIT),
    settled: st.INVOICE_SETTLED,
    box: $('invoice').value,
    invid: $('invid').value,
    ym: $('ym').value,
    manual: JSON.stringify(u.manualLoads().map(l => l.ticket_number)),
    known: JSON.stringify(u.knownClients()),
    guards: JSON.stringify(st.LOADS.map(l => { const g = u.archiveGuard(l); return g ? g.why : null; })),
    dated: JSON.stringify(Array.from(u.justDatedLines().matchAll(/data-offundo="([^"]*)"/g)).map(m => m[1])),
    held: JSON.stringify(u.heldClients()),
    prov: JSON.stringify(st.LOADS.filter(l => l._paper).map(l => u.paperProvenance(l))),
    paperFacts: JSON.stringify({d: st.INV_DECALS, s: st.INV_DATES, src: st.INVOICE_SRC, read: st.INVOICE_READ}),
    archive: JSON.stringify({a: st.ARCHIVED, rows: Object.keys(st.ARCHIVED_ROWS).sort(), filed: st.FILED_TICKETS, resent: st.RESENT,
                             note: st.RESTORE_NOTE, just: st.JUST_ARCHIVED}),
    check: JSON.stringify({f: st.PREVIEW_FINDINGS, t: st.previewToken, g: st.GENERATED}),
  };
}

function snapNew(m) {
  const c = m.counts();
  const tiles = {};
  if (m.LOADS.length) {
    tiles['Will be reported'] = String(c.reported);
    tiles['Gallons'] = c.gallons.toLocaleString('en-US');
    tiles['Need a look'] = String(c.look);
    if (c.held) tiles['Waiting on a trap size'] = String(c.held);
    tiles[c.anyOn ? 'Left off by hand' : 'Not ticked yet'] = String(c.off);
  }
  return {
    payload: JSON.stringify(m.payload()),
    saved: JSON.stringify(m.savedFileBody()),
    flags: JSON.stringify(m.combinedFlagsByTicket()),
    blocking: JSON.stringify(m.blockingLoads().map(x => [x.i, x.l.ticket_number])),
    only: JSON.stringify(m.invoiceOnlyTickets()),
    archOn: JSON.stringify(m.invoiceArchivedTickets()),
    inWin: JSON.stringify(m.inWindowNotBilled().map(l => l.ticket_number)),
    win: JSON.stringify(m.invoiceWindow()),
    shape: JSON.stringify(m.reportShape()),
    tiles: JSON.stringify(tiles),
    flagged: c.flagged,
    stale: m.flagsAreStale(),
    locked: m.approvalDisabled,
    approved: m.approved,
    canGen: m.canGenerate(),
    paper: JSON.stringify({dates: m.PAPER_DATES, decals: m.PAPER_DECALS, hand: m.HAND_ADDED}),
    forms: JSON.stringify(nonBlankForms(m.PAPER_FORM)),
    edit: JSON.stringify(m.PAPER_EDIT),
    settled: m.INVOICE_SETTLED,
    box: m.invoiceText,
    invid: m.invoiceId,
    ym: m.ym,
    manual: JSON.stringify(m.manualLoads().map(l => l.ticket_number)),
    known: JSON.stringify(m.knownClients()),
    guards: JSON.stringify(m.LOADS.map(l => { const g = m.archiveGuard(l); return g ? g.why : null; })),
    dated: JSON.stringify(m.datedLines().map(x => x.t)),
    held: JSON.stringify(m.heldClients()),
    prov: JSON.stringify(m.LOADS.filter(l => l._paper).map(l => m.paperProvenance(l))),
    paperFacts: JSON.stringify({d: m.INV_DECALS, s: m.INV_DATES, src: m.INVOICE_SRC, read: m.INVOICE_READ}),
    archive: JSON.stringify({a: m.ARCHIVED, rows: Object.keys(m.ARCHIVED_ROWS).sort(), filed: m.FILED_TICKETS, resent: m.RESENT,
                             note: m.RESTORE_NOTE, just: m.JUST_ARCHIVED}),
    check: JSON.stringify({f: m.PREVIEW_FINDINGS, t: m.previewToken, g: m.GENERATED}),
  };
}

// What the acts themselves answered, beside the state.
const ANSWER = Symbol('answer');

// ---- The act interpreter ---------------------------------------------------
const b64Of = name => Buffer.from('%PDF-' + name).toString('base64');
const bytesOf = name => new Uint8Array(Buffer.from('%PDF-' + name));
const eventsOf = (el, ev, target) => (el.handlers[ev] || []).forEach(h => h.call(el, {target}));

function serverFetch(w, step) {
  // server._apply_archive: archived rows and their findings leave the list.
  const keep = [], gone = {};
  for (const l of clone(step.loads)) (w.archived[String(l.ticket_number || '')] ? (gone[l.ticket_number] = l) : keep.push(l));
  const archived = clone(w.archived);
  for (const t of Object.keys(archived)) archived[t].still_sent = step.unreported ? (t in gone) : null;
  return {loads: keep, fetch_findings: clone(step.fetch_findings || []).filter(f => !archived[String(f.row_key || '')]),
          meta: {}, archived, archived_rows: gone, filed_tickets: clone(w.filed)};
}

const FILE_EDITS = {
  noInvoice: f => { delete f.invoice; return f; },
  schema1: f => { delete f.invoice; f.schema = 1; return f; },
  bareList: f => f.loads,
  noSource: f => { if (f.invoice) f.invoice.source = null; return f; },
};

// Old leads (its stubs answer the way the bot would), new follows with the same answers.
async function actOld(p, step, w, fresh) {
  const u = p.ui, $ = p.dom.byId, idx = t => u.state().LOADS.findIndex(l => String(l.ticket_number || '') === String(t));
  p.world = w;
  switch (step.act) {
    case 'fetch': w.fetchResp = serverFetch(w, step); await u.fetchMonth(!!step.unreported); return;
    case 'drop': {
      w.parse = step.parse; w.lastParse = step.parse; w.parseOk = true;
      const name = step.name, bytes = bytesOf(name);
      const ok = await u.parseDroppedInvoice({name, arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)}, name);
      return {ok, status: $('invstat').textContent,
              cands: Array.from($('invcands').innerHTML.matchAll(/data-add="([^"]*)"/g)).map(x => x[1])};
    }
    case 'tick': { const i = idx(step.ticket); u.setIncluded(i, step.on); u.refreshAll(); return; }
    case 'tickAt': u.setIncluded(step.i, step.on); u.refreshAll(); return;
    case 'decal': { const i = idx(step.ticket); if (i !== -1) u.setLoadDecal(i, step.decal); return; }
    case 'decalAt': u.setLoadDecal(step.i, step.decal); return;
    case 'useInvoiceDecal': { const i = idx(step.ticket); if (i !== -1) u.useInvoiceDecal(i); return; }
    case 'useInvoiceDate': return {r: u.useInvoiceDate(step.ticket)};
    case 'undoInvoiceDate': return {r: u.undoInvoiceDate(step.ticket)};
    case 'addPaper': {
      p.dom.byId('error').textContent = '';
      const r = u.addPaperLoad(step.num, step.offload, step.decal, clone(step.opts));
      return {r, err: r ? '' : $('error').textContent};
    }
    case 'addFromForm': return {r: u.addPaperFromForm(step.ticket)};
    case 'pf': { const r = u[step.fn](...clone(step.args)); return {r: r === undefined ? null : r}; }
    case 'setPaperDecal': eventsOf($('mismatch'), 'change', {dataset: {tk: step.ticket}, className: 'pdecal', value: step.value}); return;
    case 'openEdit': return {r: u.openPaperEdit(step.ticket)};
    case 'saveEdit': return {r: u.savePaperEdit()};
    case 'cancelEdit': u.cancelPaperEdit(); return;
    case 'typing': $('invoice').value = step.text; u.invoiceTyping(); return;
    case 'finished': if (step.text !== undefined) $('invoice').value = step.text; u.invoiceFinished(); return;
    case 'setInvoiceId': $('invid').value = step.value; eventsOf($('invid'), 'input', $('invid')); return;
    case 'setMonth': u.applyMonth(step.ym); return;
    case 'addNumber':
      $('invadd').value = step.raw; $('invaddDecal').value = step.decal || '';
      u.addInvTicket();
      return {text: $('invaddstat').textContent, tone: $('invaddstat').className.replace('status ', '')};
    case 'removeNumber': u.removeInvTicket(step.num); return;
    case 'accept': u.acceptCandidate(step.num); return;
    case 'setNumberDecal': u.setNumberDecal(step.num, step.decal); return;
    case 'match': u.matchInvoiceExactly(); return;
    case 'blockerDecal': case 'blockerLeaveOff': {
      $('blockers').__q = {};
      u.renderBlockers();
      const i = idx(step.ticket), sel = step.act === 'blockerDecal' ? 'select.bdecal' : 'button.bdrop';
      const el = ($('blockers').__q[sel] || []).find(e => +e.dataset.i === i);
      if (!el) return {wired: false};
      el.value = step.value;
      const ev = step.act === 'blockerDecal' ? 'change' : 'click';
      el.handlers[ev].forEach(h => h.call(el, {target: el}));
      return {wired: true};
    }
    case 'archive': {
      const opened = u.openArchive(step.ticket);
      if (!opened) return {opened};
      u.setArchiveReason(step.reason); u.setArchiveText(step.text || ''); u.setArchiveDup(step.dup || '');
      w.archiveReply = null; p.net.posts.archive = null;
      const posted = await u.submitArchive();
      return {opened, posted, body: p.net.posts.archive, replied: !!w.archiveReply};
    }
    case 'restore': w.restoreReply = null; return {r: await u.restoreArchived(step.ticket)};
    case 'loadArchive': return {r: await u.loadArchiveState()};
    case 'preview':
      w.findings = step.findings; w.token = step.token; p.net.posts.preview = null;
      await u.go('preview');
      return {body: p.net.posts.preview};
    case 'approve':
      if (!$('approved').disabled) { $('approved').checked = step.on; eventsOf($('approved'), 'change', $('approved')); }
      return;
    case 'generate':
      u.syncGenButton();
      if ($('btnGen').disabled) return {pressed: false};
      w.gen = {id: step.id, tickets: step.tickets, list: step.list}; p.net.posts.generate = null;
      await u.go('generate');
      return {pressed: true, body: p.net.posts.generate};
    case 'record': {
      w.recordReply = step.ok === false ? step.raw : {said: step.said}; w.recordOk = step.ok !== false; p.net.posts.record = null;
      await u.markFiled();
      const cls = (/<div class="rec (\w+)"/.exec($('filedstat').innerHTML) || [])[1] || null;
      const sent = p.net.posts.record ? JSON.parse(p.net.posts.record) : null;
      return {sent: sent && {id: sent.id, expect_tickets: sent.expect_tickets}, cls, done: $('filedForm').hidden === true};
    }
    case 'saveAndFresh': {
      const keepBox = step.keepBox === 'SAME' ? $('invoice').value : step.keepBox;
      const raw = JSON.stringify(u.savedFileBody());
      const edit = step.transform ? FILE_EDITS[step.transform] : (f => f);
      w.file = JSON.stringify(edit(JSON.parse(raw)));
      const next = fresh(p);
      next.world = w;
      if (keepBox) { next.dom.byId('invoice').value = step.keepBox === 'SAME' ? keepBox.split('\n').reverse().join('\n') : keepBox; next.ui.invoiceFinished(); }
      return {raw, page: next};
    }
    case 'adopt': {
      w.parse = step.parse || w.lastParse; w.parseOk = step.parseOk;
      const r = await u.adoptSavedFile(JSON.parse(w.file));
      return {r: r === undefined ? null : r, status: $('invstat').textContent};
    }
    default: throw new Error('unknown act ' + step.act);
  }
}

function actNew(state, step, w, oldAns, dropThis) {
  const m = state.m, idx = t => m.indexOfTicket(t);
  if (dropThis) return {};
  switch (step.act) {
    case 'fetch': (step.unreported ? m.reload(clone(w.fetchResp)) : m.adoptFetch(clone(w.fetchResp))); return;
    case 'drop': {
      const ok = m.adoptDroppedInvoice(clone(step.parse), step.name, b64Of(step.name));
      return {ok, status: m.invoiceStatus ? m.invoiceStatus.text : '',
              cands: m.candidates.near.map(c => c.guess).concat(m.candidates.outside, m.candidates.other)};
    }
    case 'tick': m.setIncluded(idx(step.ticket), step.on); return;
    case 'tickAt': m.setIncluded(step.i, step.on); return;
    case 'decal': { const i = idx(step.ticket); if (i !== -1) m.setLoadDecal(i, step.decal); return; }
    case 'decalAt': m.setLoadDecal(step.i, step.decal); return;
    case 'useInvoiceDecal': { const i = idx(step.ticket); if (i !== -1) m.useInvoiceDecal(i); return; }
    case 'useInvoiceDate': return {r: m.useInvoiceDate(step.ticket)};
    case 'undoInvoiceDate': return {r: m.undoInvoiceDate(step.ticket)};
    case 'addPaper': {
      m.lastError = '';
      const r = m.addPaperLoad(step.num, step.offload, step.decal, clone(step.opts));
      return {r, err: r ? '' : m.lastError};
    }
    case 'addFromForm': return {r: m.addPaperFromForm(step.ticket)};
    case 'pf': { const r = m[step.fn](...clone(step.args)); return {r: r === undefined ? null : r}; }
    case 'setPaperDecal': m.setPaperDecal(step.ticket, step.value); return;
    case 'openEdit': return {r: m.openPaperEdit(step.ticket)};
    case 'saveEdit': return {r: m.savePaperEdit()};
    case 'cancelEdit': m.cancelPaperEdit(); return;
    case 'typing': m.invoiceTyping(step.text); return;
    case 'finished': m.invoiceFinished(step.text); return;
    case 'setInvoiceId': m.setInvoiceId(step.value); return;
    case 'setMonth': m.applyMonth(step.ym); return;
    case 'addNumber': { const a = m.addInvTicket(step.raw, step.decal); return {text: a.text, tone: a.tone}; }
    case 'removeNumber': m.removeInvTicket(step.num); return;
    case 'accept': m.acceptCandidate(step.num); return;
    case 'setNumberDecal': m.setNumberDecal(step.num, step.decal); return;
    case 'match': m.matchInvoiceExactly(); return;
    case 'blockerDecal': case 'blockerLeaveOff': {
      const i = idx(step.ticket);
      if (!m.blockingLoads().some(x => x.i === i) || !m.LOADS.some(l => !l._excluded)) return {wired: false};
      if (step.act === 'blockerDecal') m.blockerSetDecal(i, step.value); else m.blockerLeaveOff(i);
      return {wired: true};
    }
    case 'archive': {
      const l = m.LOADS.find(x => String(x.ticket_number || '') === String(step.ticket));
      const opened = !!l && !m.archiveGuard(l);
      if (!opened) return {opened};
      const b = m.archiveBody(step.ticket, step.reason, step.text, step.dup);
      if (b.err) return {opened, posted: false, body: null, replied: false};
      const posted = m.applyArchived(step.ticket, clone(w.archiveReply));
      return {opened, posted, body: JSON.stringify(b.body), replied: true};
    }
    case 'restore': if (!w.restoreReply) return {r: false}; m.applyRestored(step.ticket, clone(w.restoreReply)); return {r: true};
    case 'loadArchive': m.meetArchive(clone(w.archiveRead)); return {r: true};
    case 'preview': {
      const p = m.payload();
      if (p.err) return {body: null};
      const s = JSON.stringify(p.body);
      m.setPreviewResult(JSON.parse(s), clone(step.findings), step.token);
      return {body: s};
    }
    case 'approve': m.setApproved(step.on); return;
    case 'generate': {
      if (!m.canGenerate()) return {pressed: false};
      const g = m.generateBody();
      const s = JSON.stringify(g.body);
      m.setGenerated(JSON.parse(s), {id: step.id, tickets: step.tickets, list: encodeURIComponent(JSON.stringify(step.list))});
      return {pressed: true, body: s};
    }
    case 'record': {
      const b = m.recordBody();
      if (b.err) return {sent: null, cls: 'bad', done: false};
      const raw = JSON.stringify(step.ok === false ? step.raw : {said: step.said});
      const o = R.recordOutcome(step.ok !== false, raw);
      const cls = {test: 'test', filed: 'ok', already: 'warn', unconfirmed: 'warn', refused: 'bad', no_answer: 'warn'}[o.state];
      state.done = state.done || o.recorded;
      return {sent: b.body, cls, done: !!state.done};
    }
    case 'saveAndFresh': {
      const raw = JSON.stringify(m.savedFileBody());
      const next = new R.MonthlyRules(m.ym);
      if (step.keepBox) next.invoiceFinished(step.keepBox === 'SAME' ? m.invoiceText.split('\n').reverse().join('\n') : step.keepBox);
      state.m = next;
      return {raw};
    }
    case 'adopt': {
      const r = m.adoptSavedFile(JSON.parse(w.file));
      let ans = null;
      if (r.reread) {
        if (step.parseOk === false) { m.rereadFailed(r.reread); ans = false; }
        else ans = m.applySavedReread(r.reread, clone(w.parse));
      }
      return {r: ans, status: m.invoiceStatus ? m.invoiceStatus.text : ''};
    }
    default: throw new Error('unknown act ' + step.act);
  }
}

// ---- One run ---------------------------------------------------------------
async function runSeq(seq, src, dropAt) {
  const w = {archived: {}, filed: Object.assign({}, seq.filed || {}), parse: null, parseOk: true};
  let page = newOldPage(src, seq.ym);
  const fresh = prev => newOldPage(src, prev.dom.byId('ym').value);
  const state = {m: new R.MonthlyRules(seq.ym), done: false};
  let compared = 0;
  for (let n = 0; n < seq.steps.length; n++) {
    const step = seq.steps[n];
    let a = await actOld(page, step, w, fresh);
    if (a && a.page) { page = a.page; delete a.page; }
    let b;
    try { b = actNew(state, step, w, a, dropAt === n); }
    catch (e) { return {ok: false, seq: seq.name, step: n, act: step.act, field: 'threw', old: '', new: String(e.message), compared}; }
    if (dropAt === n) continue;
    // Status lines: only an act that writes one is compared, and only a re-read says so.
    if (step.act === 'adopt' && a && b && !(b.r !== null) && !/saved with another/.test(a.status || '')) { a.status = b.status = ''; }
    const aj = JSON.stringify(a === undefined ? null : a), bj = JSON.stringify(b === undefined ? null : b);
    if (aj !== bj) return {ok: false, seq: seq.name, step: n, act: step.act, field: 'answer', old: aj, new: bj, compared};
    const so = snapOld(page), sn = snapNew(state.m);
    for (const k of MARKERS) if (!SEEN.has(k) && (so.saved.includes(k) || so.flags.includes(k) || so.payload.includes(k))) SEEN.add(k);
    for (const k of Object.keys(so)) {
      compared++;
      if (String(so[k]) !== String(sn[k]))
        return {ok: false, seq: seq.name, step: n, act: step.act, field: k, old: String(so[k]), new: String(sn[k]), compared};
    }
    // decisions() stands on the same count, and reads nothing but.
    const before = JSON.stringify(state.m.savedFileBody());
    const rows = new Set(state.m.decisions().filter(d => d.counted).map(d => d.index));
    if (rows.size !== so.flagged)
      return {ok: false, seq: seq.name, step: n, act: step.act, field: 'decisions.counted', old: String(so.flagged), new: String(rows.size), compared};
    if (JSON.stringify(state.m.savedFileBody()) !== before)
      return {ok: false, seq: seq.name, step: n, act: step.act, field: 'decisions.readonly', old: before, new: JSON.stringify(state.m.savedFileBody()), compared};
    compared += 2;
  }
  return {ok: true, compared, steps: seq.steps.length};
}

// ---- Random months: the acts the recorded list did not think of ------------
function mulberry(a) {
  return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
const BASE = () => [
  row('900001', '2026-09-10', HARBOR), row('900002', '2026-09-11', BAYSIDE, {decal: 'C0976'}), row('900003', '2026-09-03', CORAL),
  row('900004', '2026-09-11', SUNSET, {decal: 'C1184'}), row('900005', '2026-09-10', MARINA, {pickup_date: '2026-09-07'}),
  row('900006', '2026-08-28', PIER, {facilities: [Object.assign({}, PIER), Object.assign({}, HARBOR)]}), ooc('900201', '2026-09-08', DOCK, 65), ooc('900202', '2026-09-09', PIER, null),
  row('9-24-26', '2026-09-24', DOCK, {out_of_county: true, gallons: 65}), row('', '2026-09-12', CORAL, {pickup_date: null}),
];
const FEEDS = [BASE,
  () => BASE().concat([row('900101', '2026-09-12', SUNSET, {pickup_date: '2026-09-09'})]),
  () => BASE().map(l => l.ticket_number === '900001' ? Object.assign(l, {offload_date: '2026-09-07'})
    : l.ticket_number === '900003' ? Object.assign(l, {decal: 'C1184'}) : l.ticket_number === '900201' ? Object.assign(l, {gallons: null, sizes_missing_clients: ['Dockside Diner']}) : l),
  () => BASE().filter(l => l.ticket_number !== '900004').map(l => l.ticket_number === '900005' ? Object.assign(l, {out_of_county: true, gallons: 80}) : l),
  () => [row('900001', '2026-09-09', HARBOR), row('900100', '2026-09-11', HARBOR, {pickup_date: '2026-09-09'})],
];
const FINDINGS = [[], [{rule: 'data_quality_unchecked', row_key: null, detail: 'month', expected: false}, {rule: 'client_without_address', row_key: '900003', detail: 'no address', expected: false},
  {rule: 'out_of_county_sizes_missing', row_key: '900202', detail: 'waiting', expected: false}, {rule: 'out_of_county_ticket_on_report', row_key: '900201', detail: 'on it', expected: true}]];
const PARSES = [
  () => ({tickets: ['900001', '900002', '900004', '900005', '900100', '900101'], invoice_id: 'SP1', decals: {'900001': 'C1184', '900002': 'C1184', '900004': 'C1184', '900100': 'C1184'},
          service_dates: {'900001': '2026-09-07', '900002': '2026-09-11', '900005': '2026-09-08', '900100': '2026-09-11', '900101': '2026-09-12'}}),
  () => ({tickets: ['900001', '900003', '900006', '900102'], invoice_id: 'SP2', decals: {'900001': 'C0976', '900003': 'C0976'}, service_dates: {'900001': '2026-09-08', '900003': '2026-09-01', '900102': '2026-09-02'}}),
  () => ({tickets: ['900002', '900005'], invoice_id: null, decals: {}, near_tickets: [{guess: '900003', as_read: '9O0003'}], other_sixdigit: ['444111'], outside_column: ['900100'],
          parse_warnings: ['page 2 unread'], total_mismatch: 'totals differ', decal_conflicts: [{detail: 'price', row_key: '900002'}], source: 'ocr'}),
  () => ({tickets: [], invoice_id: 'SP9', near_tickets: [{guess: '900004', as_read: '9OO004'}]}),
  () => ({tickets: ['900001', '900004', '900005'], invoice_id: 'SP3', decals: {'900001': 'C1184', '900005': 'C0976'}, service_dates: {'900001': '2026-09-10', '900005': '2026-09-10'}}),
];
const TICKETS = ['900001', '900002', '900003', '900004', '900005', '900006', '900100', '900101', '900102', '900201', '900202', '9-24-26', '900300'];
const CLIENT_SETS = [[], [{name: 'Harbor Grill', address: '100 Harbor Ln, Miami, FL 33101', _src: 'picked'}],
  [{name: 'Nuevo Sitio', address: '9 B St, Miami, FL 33125', _src: 'typed'}],
  [{name: 'Bayside Cafe', address: '200 Bay Ave', county: 'Miami-Dade', in_dade: true, _src: 'picked'}, {name: 'Otro', address: '1 C St', _src: 'typed'}]];

function randomSeq(seed) {
  const r = mulberry(seed), pick = a => a[Math.floor(r() * a.length)];
  const T = () => pick(TICKETS), day = () => pick(['2026-09-01', '2026-09-05', '2026-09-08', '2026-09-11', '2026-09-12', '', 'bad']);
  const steps = [{act: 'fetch', unreported: true, loads: BASE(), fetch_findings: pick(FINDINGS)}];
  const moves = [
    [5, () => { const pa = pick(PARSES)(); return {act: 'drop', parse: pa, name: 'p' + seed + '.pdf'}; }],
    [4, () => ({act: 'fetch', unreported: r() < 0.8, loads: pick(FEEDS)(), fetch_findings: pick(FINDINGS)})],
    [8, () => ({act: 'tick', ticket: T(), on: r() < 0.5})],
    [2, () => ({act: 'tickAt', i: Math.floor(r() * 10), on: r() < 0.5})],
    [7, () => ({act: 'decal', ticket: T(), decal: pick(['C1184', 'C0976', 'c1184 ', '', 'NOPE'])})],
    [5, () => ({act: 'useInvoiceDecal', ticket: T()})],
    [6, () => ({act: 'useInvoiceDate', ticket: T()})],
    [4, () => ({act: 'undoInvoiceDate', ticket: T()})],
    [5, () => ({act: 'addPaper', num: T(), offload: day(), decal: pick(['', 'C1184', 'C0976', 'NOPE']), opts: {pickup: pick([null, '2026-09-04', '2026-09-20']), clients: pick(CLIENT_SETS), offloadSrc: pick(['typed', 'invoice'])}})],
    [2, () => ({act: 'pf', fn: 'pfQuery', args: [T(), pick(['harbor', 'bay', 'pier', 'zzz'])]})],
    [2, () => ({act: 'pf', fn: 'pfPick', args: [T(), 0]})],
    [2, () => ({act: 'pf', fn: 'pfTyped', args: [T(), pick(['Nuevo', '']), pick(['9 B St', ''])]})],
    [1, () => ({act: 'pf', fn: 'pfRemove', args: [T(), 0]})],
    [2, () => ({act: 'pf', fn: 'pfPickup', args: [T(), day()]})],
    [2, () => ({act: 'pf', fn: 'pfOffload', args: [T(), day()]})],
    [1, () => ({act: 'pf', fn: 'pfUseInvoiceDate', args: [T()]})],
    [3, () => ({act: 'addFromForm', ticket: T()})],
    [1, () => ({act: 'setPaperDecal', ticket: T(), value: pick(['C1184', 'C0976', ''])})],
    [2, () => ({act: 'openEdit', ticket: T()})],
    [2, () => ({act: 'saveEdit'})],
    [1, () => ({act: 'cancelEdit'})],
    [2, () => ({act: 'typing', text: pick(['900001', '900001\n9000', '900001, 900002;900005', ''])})],
    [3, () => ({act: 'finished', text: r() < 0.5 ? undefined : pick(['900001\n900002', '900003 900004', '', '900005\n900100\n900300'])})],
    [2, () => ({act: 'setInvoiceId', value: pick(['SP7', ' SP8 ', ''])})],
    [1, () => ({act: 'setMonth', ym: pick(['2026-08', '2026-09', '2026-10', 'x'])})],
    [3, () => ({act: 'addNumber', raw: pick(['900300', '900100', '12', 'T-900002']), decal: pick(['', 'C0976', 'C1184'])})],
    [3, () => ({act: 'removeNumber', num: T()})],
    [2, () => ({act: 'accept', num: T()})],
    [2, () => ({act: 'setNumberDecal', num: T(), decal: pick(['', 'C0976', 'C1184', 'NOPE'])})],
    [1, () => ({act: 'match'})],
    [2, () => ({act: 'blockerDecal', ticket: T(), value: pick(['C0976', ''])})],
    [2, () => ({act: 'blockerLeaveOff', ticket: T()})],
    [3, () => ({act: 'archive', ticket: T(), reason: pick(['test_data', 'not_ours', 'duplicate', 'other', '']), text: pick(['', 'a reason']), dup: pick(['', '900001', '12'])})],
    [2, () => ({act: 'restore', ticket: T()})],
    [1, () => ({act: 'loadArchive'})],
    [3, () => ({act: 'preview', findings: pick([[], [{rule: 'ticket_not_on_invoice', row_key: T(), detail: 'x', expected: false}, {rule: 'membership_unverified', row_key: null, detail: 'm', expected: false}]]), token: 't' + Math.floor(r() * 9)})],
    [3, () => ({act: 'approve', on: r() < 0.8})],
    [2, () => ({act: 'generate', id: String(Math.floor(r() * 90) + 1), tickets: '2', list: ['900001']})],
    [1, () => ({act: 'record', said: {dry_run: true, what: 'x'}})],
  ];
  const bag = [];
  moves.forEach(([w, f]) => { for (let i = 0; i < w; i++) bag.push(f); });
  for (let n = 0; n < FUZZ_LEN; n++) {
    if (r() < 0.05) {
      const t = pick([undefined, undefined, undefined, 'noInvoice', 'schema1', 'bareList', 'noSource']);
      steps.push({act: 'saveAndFresh', transform: t});
      steps.push({act: 'adopt', parse: pick(PARSES)(), parseOk: r() < 0.85});
    } else steps.push(pick(bag)());
  }
  return {name: 'random ' + seed, ym: '2026-09', steps};
}

// ---- Main ------------------------------------------------------------------
let R = await import(pathToFileURL(path.join(here, '..', 'monthly-rules.ts')).href);

async function runAll(src, seqs) {
  let compared = 0;
  for (const s of seqs) {
    const r = await runSeq(s, src, -1);
    if (!r.ok) return r;
    compared += r.compared;
  }
  return {ok: true, compared};
}

const printMismatch = x => {
  console.log('  MISMATCH in "' + x.seq + '", step ' + x.step + ' (' + x.act + '), field ' + x.field);
  let k = 0;
  while (k < x.old.length && x.old[k] === x.new[k]) k++;
  console.log('    old ...' + x.old.slice(Math.max(0, k - 120), k + 200));
  console.log('    new ...' + x.new.slice(Math.max(0, k - 120), k + 200));
};

let bad = 0;
console.log('\n[1] recorded sequences, old page vs monthly-rules.ts');
let total = 0, okSeq = 0;
for (const s of SEQUENCES) {
  const r = await runSeq(s, OLD_SRC, -1);
  if (r.ok) { okSeq++; total += r.compared; console.log('  match  ' + s.name + '  (' + r.steps + ' acts)'); }
  else { bad++; printMismatch(r); }
}
console.log('  ' + okSeq + ' of ' + SEQUENCES.length + ' sequences match, ' + total + ' fields compared');

console.log('\n[2] random months');
const fuzz = [];
for (let i = 1; i <= FUZZ_SEQ; i++) fuzz.push(randomSeq(i));
const fz = await runAll(OLD_SRC, fuzz);
if (fz.ok) console.log('  ' + FUZZ_SEQ + ' of ' + FUZZ_SEQ + ' random months match (' + (FUZZ_LEN + 1) + ' acts each), ' + fz.compared + ' fields compared');
else { bad++; printMismatch(fz); }

const notSeen = MARKERS.filter(k => !SEEN.has(k));
console.log('  reached ' + SEEN.size + ' of ' + MARKERS.length + ' page states and rules' + (notSeen.length ? ', never: ' + notSeen.join(' ') : ''));
if (notSeen.length) bad++;
if (bad) { console.log('\nFAILED: the port does not equal the page.'); process.exit(1); }

console.log('\n[3] control: drop one act from the new side, the comparison must fail');
let dropped = 0, caught = 0, seqNoCatch = 0;
const unseen = {};
for (const s of SEQUENCES) {
  let here_ = 0;
  for (let n = 0; n < s.steps.length; n++) {
    const r = await runSeq(s, OLD_SRC, n);
    dropped++;
    if (!r.ok) { caught++; here_++; }
    else unseen[s.steps[n].act] = (unseen[s.steps[n].act] || 0) + 1;
  }
  if (!here_) { seqNoCatch++; console.log('  NO DROP CAUGHT in ' + s.name); }
}
console.log('  ' + caught + ' of ' + dropped + ' single-act drops were caught; every sequence caught at least one: ' + (seqNoCatch === 0));
console.log('  not caught, by act (a refused or repeated act changes nothing): ' + JSON.stringify(unseen));
if (seqNoCatch || caught < dropped * 0.7) bad++;

console.log('\n[4] control: a copy of the port with one rule broken must fail');
const MUTANTS = [
  ['pins nothing', "if (setAfterPaper(this.INV_DECALS, l.ticket_number)) l._decal_pinned = true;", "if (false) l._decal_pinned = true;"],
  ['a stale pool order', "body.candidate_pool = this.LOADS.map(l => {", "body.candidate_pool = this.LOADS.slice().reverse().map(l => {"],
  ['findings out of order', ".concat(this.paperLoadFindings()).concat(this.clientFindings())", ".concat(this.clientFindings()).concat(this.paperLoadFindings())"],
  ['a word changed in a finding', "'; the system has it offloaded '", "'; the feed has it offloaded '"],
  ['the guess note lost', "if (!('_offload_guess' in l)) l._offload_guess = String(l.offload_date || '');", ""],
  ['the sequence order', "return String(b.l.offload_date || '').localeCompare(String(a.l.offload_date || ''));", "return String(a.l.offload_date || '').localeCompare(String(b.l.offload_date || ''));"],
  ['a Dade tick carried', "    this.LOADS.forEach(l => { delete l._manual; l._excluded = true; });\n    if (before)", "    if (before)"],
  ['candidates survive an atomic parse', "this.candidates = {near: (p.near_tickets || []).slice(), other: (p.other_sixdigit || []).slice(),\n                       outside: (p.outside_column || []).slice()};", ""],
  ['the leave-off marks a hand decision', "    this.LOADS[i]._excluded = true;\n    this.refreshAll();", "    this.LOADS[i]._excluded = true;\n    this.LOADS[i]._manual = true;\n    this.refreshAll();"],
  ['the blocker path pins', "if (value) { l.decal = value; l._decal_src = 'manual'; }", "if (value) { l.decal = value; l._decal_src = 'manual'; l._decal_pinned = true; }"],
  ['a saved row keeps its stale hand mark', "      else delete l._manual;\n", ""],
  ['the file\'s invoice rules survive', ".filter(f => !INVOICE_RULES.includes(f.rule)));\n  }", ");\n  }"],
];
const mutated = async (name, a, b, seqs) => {
  const n = RULES_SRC.split(a).length - 1;
  if (n !== 1) { console.log('  STALE ANCHOR x' + n + ': ' + name); return false; }
  const f = '/tmp/mut' + crypto.randomBytes(4).toString('hex') + '.mts';
  fs.writeFileSync(f, RULES_SRC.replace(a, () => b));
  const keep = R;
  R = await import(pathToFileURL(f).href);
  let failed = false;
  for (const s of seqs) { const r = await runSeq(s, OLD_SRC, -1); if (!r.ok) { failed = true; break; } }
  R = keep;
  fs.rmSync(f);
  return failed;
};
let killed = 0;
for (const [name, a, b] of MUTANTS) {
  const ok = await mutated(name, a, b, SEQUENCES.concat(fuzz));
  if (ok) killed++; else console.log('  SURVIVED: ' + name);
}
console.log('  ' + killed + ' of ' + MUTANTS.length + ' broken copies were caught');
if (killed !== MUTANTS.length) bad++;

console.log('\n[5] control: the OLD side is really the page, so changing it must fail too');
const OLD_MUTANT = OLD_SRC.replace("if (l._decal_pinned) return;", "");
const om = OLD_MUTANT === OLD_SRC ? {ok: true} : await runAll(OLD_MUTANT, SEQUENCES);
console.log('  a page with the pin guard removed: ' + (om.ok ? 'NOT CAUGHT' : 'caught, at "' + om.seq + '" step ' + om.step));
if (om.ok) bad++;

console.log(bad ? '\nFAILED' : '\nALL GOOD');
process.exit(bad ? 1 : 0);
