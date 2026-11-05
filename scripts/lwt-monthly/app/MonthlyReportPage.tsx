// The Monthly Report page (Trello EOnFKqSK, #173). Fred: "adding the monthly report to the apps ... instead of using the
// dashboard made by Jon"; "i don't want the simple fields to fill the data ... i want to have maybe a prefilled data, where
// you can select the visits/clients".
// Downloaded byte-identical into the DERM Tracker with monthly-rules.ts and monthly-report.css: change it here, never there.
// The bot stays the engine. Every rule that decides what is sent lives in monthly-rules.ts; this file only draws and asks.
// Holds no client data, no secret and no key. The route gives it the functions URL and the session token.
// Plan: Building Apps/DERM Tracker/docs/specs/2026-11-05-monthly-report-in-the-app.md
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import type { CSSProperties, DragEvent, ReactNode } from 'react';
import {
  ARCHIVE_REASONS, DECAL_GALLONS, MonthlyRules, explainError, isHeld, isOutOfCounty, monthLabel, offloadMonth, parseTickets,
  recordOutcome, resolvedGallons, ruleInfo,
} from './monthly-rules';
import type { Decision, FetchResponse, Finding, InvoiceParse, Load, SavedFile } from './monthly-rules';
import { fitted, reportHtml } from './xlsx-view';
import type { ReportPage } from './xlsx-view';

export interface MonthlyReportPageProps {
  functionsUrl: string;                     // https://<project>.supabase.co/functions/v1
  getToken: () => Promise<string | null>;   // the signed-in session's access token
}

interface Truck { id: number; name: string; color: string | null; decal: string | null }
interface Stop {
  ticket: string; visit_id: number; pickup_date: string | null; offload_date: string | null; client_code: string | null;
  client_name: string; address: string | null; city: string | null; county: string | null; vehicle_id: number | null;
  truck: string | null; gallons: number | null; gallons_source: string | null; property_id: number | null;
}
interface Gps { vehicle_id: number; day: string; at: string; site: string | null }
interface BoardData { stops: Stop[]; trucks: Truck[]; gps: Gps[] }
interface Visit {
  visit_id: number; visit_date: string; client_code: string | null; client_name: string; form_name: string; form_address: string;
  address: string | null; city: string | null; county: string | null; vehicle_id: number | null; truck: string | null;
  truck_color: string | null; on_ticket: string | null; group: string;
}
interface FilingRow {
  period: string; invoice_id: string | null; ticket_count: number; gallons: string; fee: string; status_text: string; tone: string;
  who: string | null; when: string | null; id: number; ym: string; filed: boolean; tickets: string[]; discarded: unknown; report: boolean;
}
interface Overview {
  current: { period: string; due: string; days_left: number; badge: string; tone: string; note: string; cta: string };
  rows: FilingRow[];
  me: { name: string; email: string; can_edit: boolean };
}
interface Ui { acks: Record<string, boolean>; ticks: Record<string, boolean>; parsed: InvoiceParse | null; invoiceName?: string; ym?: string }
interface WorkFile extends SavedFile { ui?: Ui }
interface Item {
  t: string; l: Load | null; date: string; lane: number | null; need: Decision | null; on: boolean; held: boolean; ooc: boolean;
  placed: boolean; billed: boolean;
}
type Stage = 'loading' | 'home' | 'start' | 'reading' | 'board' | 'check' | 'wait';
type DialogState = { kind: 'record'; id: number; tickets: string[]; label: string; invoice: string | null; period: string }
  | { kind: 'discard'; id: number; label: string } | { kind: 'startover'; period: string; label: string } | null;

// ---- Small helpers ---------------------------------------------------------------------------------------------------
const MONTH_KEY = '__month';
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const md = (d?: string | null) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d || '')); return m ? `${+m[2]}/${+m[3]}` : String(d || ''); };
const mdy = (d?: string | null) => { const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d || '')); return m ? `${+m[2]}/${+m[3]}/${m[1]}` : String(d || ''); };
const dayNo = (d: string) => Math.round(Date.UTC(+d.slice(0, 4), +d.slice(5, 7) - 1, +d.slice(8, 10)) / 864e5);
const dayStr = (n: number) => new Date(n * 864e5).toISOString().slice(0, 10);
const int = (n: number) => n.toLocaleString('en-US');
const count = (n: number, w: string) => `${int(n)} ${w}${n === 1 ? '' : 's'}`;
const plain = (s: unknown) => String(s ?? '').replace(/\s*(--|—)\s*/g, ', ');
const ymOfLabel = (label: string) => {
  const m = /^([A-Za-z]+)\s+(\d{4})$/.exec(label.trim());
  const i = m ? MONTHS.indexOf(m[1]) : -1;
  return m && i >= 0 ? `${m[2]}-${String(i + 1).padStart(2, '0')}` : '';
};
const shiftYm = (ym: string, n: number) => {
  const d = new Date(Date.UTC(+ym.slice(0, 4), +ym.slice(5, 7) - 1 + n, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
};
const lastDay = (ym: string) => dayStr(dayNo(`${shiftYm(ym, 1)}-01`) - 1);
const clock = (iso?: string | null) => (iso ? new Date(iso).toLocaleTimeString('en-US', { timeZone: 'America/New_York', hour: 'numeric', minute: '2-digit' }) : '');
const msg = (e: unknown) => (e instanceof Error ? e.message : String(e));
const reduced = () => typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion:reduce)').matches;

async function problem(r: Response): Promise<string> {
  const raw = await r.text();
  try {
    const j = JSON.parse(raw);
    if (typeof j.message === 'string') return j.message;
    if (typeof j.detail === 'string') return explainError(r.status, j.detail);
    if (j.detail) return explainError(r.status, JSON.stringify(j.detail));
  } catch { /* not JSON */ }
  return explainError(r.status, raw);
}
async function okJson<T>(r: Response): Promise<T> {
  if (!r.ok) throw new Error(await problem(r));
  return r.json() as Promise<T>;
}
async function saveBlob(r: Response, fallback: string) {
  const blob = await r.blob();
  const m = (r.headers.get('content-disposition') || '').match(/filename="?([^";]+)"?/i);
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = m ? m[1] : fallback;
  a.click();
  URL.revokeObjectURL(a.href);
}

const Ic = ({ d, style }: { d: string; style?: CSSProperties }) => (
  <svg className="lw-i" viewBox="0 0 24 24" aria-hidden="true" style={style}><path d={d} /></svg>
);
const I = {
  check: 'M20 6 9 17l-5-5', down: 'M12 4v12m0 0 5-5m-5 5-5-5M4 20h16', plus: 'M12 5v14M5 12h14', x: 'M18 6 6 18M6 6l12 12',
  bang: 'M12 5v9m0 4h.01', dash: 'M6 12h12', pin: 'M12 21s7-6 7-11a7 7 0 1 0-14 0c0 5 7 11 7 11zM12 12.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z',
  file: 'M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM14 3v6h6M12 18v-6m0 0-2.5 2.5M12 12l2.5 2.5', back: 'M15 18l-6-6 6-6',
  redo: 'M21 12a9 9 0 1 1-3-6.7L21 8m0-5v5h-5', eye: 'M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7-10-7-10-7zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
};

// ---- What needs a person ----------------------------------------------------------------------------------------------
// decisions() lists everything the old page shows. Only these need a person to choose; the rest are notes on the ticket.
const QUEUE_ORDER = ['number_no_ticket', 'archived_on_invoice', 'date_differs', 'truck_differs', 'unresolved_gallons', 'dumped_not_billed',
  'waiting_on_size', 'not_manifest_number', 'pickup_after_offload', 'reader_candidate', 'report_shape'];
const WHY: Record<string, string> = {
  number_no_ticket: 'Billed, but nobody logged it', archived_on_invoice: 'Billed, but archived on our side', date_differs: 'Invoice and ticket disagree on the date',
  truck_differs: 'Invoice and ticket name different trucks', unresolved_gallons: 'No gallons yet', dumped_not_billed: 'Dumped in the dates, not on the invoice',
  waiting_on_size: 'A client has no trap size', not_manifest_number: 'Not a manifest number', pickup_after_offload: 'Picked up after it was dumped',
  reader_candidate: 'The invoice reader was not sure of this number', report_shape: 'Check the report month',
};
const keyOf = (d: Decision) => (d.ticket === null ? MONTH_KEY : String(d.ticket));
const ackKey = (d: Decision) => (d.kind === 'date_differs' || d.kind === 'truck_differs' ? `${d.kind}|${d.ticket}` : `${d.kind}|${d.ticket}|${d.detail}`);
const tOf = (l: Load) => String(l.ticket_number || '');

function laneOf(t: string, l: Load | null, decal: string | null | undefined, board: BoardData | null): number | null {
  if (!board) return null;
  const d = String((l && l.decal) || decal || '').trim().toUpperCase();
  const byDecal = d ? board.trucks.find(x => (x.decal || '').toUpperCase() === d) : null;
  if (byDecal) return byDecal.id;
  const seen = new Map<number, number>();
  board.stops.forEach(s => { if (s.ticket === t && s.vehicle_id != null) seen.set(s.vehicle_id, (seen.get(s.vehicle_id) || 0) + 1); });
  const best = [...seen.entries()].sort((a, b) => b[1] - a[1])[0];
  if (best) return best[0];
  const named = l && (l.trucks || [])[0];
  const byName = named ? board.trucks.find(x => x.name === named) : null;
  return byName ? byName.id : null;
}

function buildVM(r: MonthlyRules, ui: Ui, board: BoardData | null) {
  const decisions = r.decisions();
  const invoice = parseTickets(r.invoiceText);
  const seen = new Set<string>();
  const queue = decisions.filter(d => {
    if (!QUEUE_ORDER.includes(d.kind) || ui.acks[ackKey(d)]) return false;
    const once = `${d.kind}|${d.ticket}`;
    if (seen.has(once)) return false;
    if (d.kind === 'waiting_on_size') {
      // A load out of county belongs to its dump month (Yan, 2026-09-17): another month's size waits for that month.
      const l = r.LOADS[r.indexOfTicket(d.ticket)];
      if (!l || offloadMonth(l.offload_date) !== r.ym) return false;
    }
    if (d.kind === 'reader_candidate' && (invoice || []).includes(String(d.ticket))) return false;
    seen.add(once);
    return true;
  }).sort((a, b) => QUEUE_ORDER.indexOf(a.kind) - QUEUE_ORDER.indexOf(b.kind));
  const needOf = (t: string) => queue.find(q => q.ticket === t) || null;

  // The board's days: the invoice's own dates and the month. A stray old date never stretches it.
  const billed = new Set((invoice || []).map(String));
  const start = `${r.ym}-01`, end = lastDay(r.ym);
  const dates = [start, end];
  r.LOADS.forEach(l => { if (billed.has(tOf(l)) && l.offload_date) dates.push(String(l.offload_date)); });
  Object.values(r.INV_DATES).forEach(d => dates.push(String(d)));
  const nums = dates.filter(d => /^\d{4}-\d{2}-\d{2}$/.test(d)).map(dayNo);
  const lo = Math.max(dayNo(start) - 40, Math.min(...nums));
  const hi = Math.min(dayNo(end) + 40, Math.max(...nums));

  const items: Item[] = r.LOADS.map(l => {
    const t = tOf(l), date = String(l.offload_date || ''), ooc = isOutOfCounty(l), held = isHeld(l);
    const otherMonth = ooc && offloadMonth(date) !== r.ym;
    const inDays = !!date && /^\d{4}-\d{2}-\d{2}$/.test(date) && dayNo(date) >= lo && dayNo(date) <= hi;
    return {
      t, l, date, lane: laneOf(t, l, null, board), need: needOf(t), held, ooc, billed: billed.has(t),
      on: !l._excluded && !held && !otherMonth,
      placed: inDays && !otherMonth,
    };
  });
  queue.filter(q => q.kind === 'number_no_ticket' || q.kind === 'archived_on_invoice').forEach(q => {
    const t = String(q.ticket), date = String(q.offload || q.invoiceDate || r.INV_DATES[t] || '');
    const decal = (q.invoiceDecal as string | null) || (q.typedDecal as string | null) || r.INV_DECALS[t] || null;
    const inDays = !!date && dayNo(date) >= lo && dayNo(date) <= hi;
    items.push({ t, l: null, date, lane: laneOf(t, null, decal, board), need: q, on: false, held: false, ooc: false, placed: inDays, billed: true });
  });
  const onReport = items.filter(i => i.on);
  const gallons = onReport.reduce((s, i) => s + (i.l ? resolvedGallons(i.l) || 0 : 0), 0);
  const notes = decisions.filter(d => d.kind === 'month_note');
  return { decisions, queue, items, lo, hi, days: hi - lo + 1, onReport, gallons, notes, invoice, placed: items.filter(i => i.placed), older: items.filter(i => !i.placed) };
}

// ---- The page ---------------------------------------------------------------------------------------------------------
export default function MonthlyReportPage({ functionsUrl, getToken }: MonthlyReportPageProps) {
  const api = useMemo(() => {
    const url = functionsUrl.replace(/\/+$/, '') + '/lwt-monthly';
    const head = async (type: string) => {
      const t = await getToken();
      if (!t) throw new Error('Sign in first.');
      return { Authorization: `Bearer ${t}`, 'Content-Type': type };
    };
    return {
      post: async (action: string, body: Record<string, unknown> = {}) =>
        fetch(url, { method: 'POST', headers: await head('application/json'), body: JSON.stringify({ action, ...body }) }),
      upload: async (file: File) => fetch(`${url}?action=read_invoice`, { method: 'POST', headers: await head('application/octet-stream'), body: file }),
    };
  }, [functionsUrl, getToken]);

  const [ov, setOv] = useState<Overview | null>(null);
  const [homeWork, setHomeWork] = useState<{ by?: string; at?: string } | null>(null);
  const [stage, setStage] = useState<Stage>('loading');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState('');
  const [showDiscarded, setShowDiscarded] = useState(false);
  const [dialog, setDialog] = useState<DialogState>(null);
  const [picked, setPicked] = useState<Set<number>>(() => new Set());
  const [viewing, setViewing] = useState<{ row: FilingRow; page: ReportPage | null; err: string } | null>(null);
  const [viewW, setViewW] = useState(0);
  const viewBody = useRef<HTMLDivElement | null>(null);
  const [dlgReason, setDlgReason] = useState('');
  const [dlgText, setDlgText] = useState('');
  const [dlgErr, setDlgErr] = useState('');
  const [homeNote, setHomeNote] = useState('');

  const rulesRef = useRef<MonthlyRules | null>(null);
  const uiRef = useRef<Ui>({ acks: {}, ticks: {}, parsed: null });
  const openYm = useRef('');   // the month this work was opened from: its saved file stays there, whatever the chips say
  const boardRef = useRef<BoardData | null>(null);
  const [, bump] = useReducer((x: number) => x + 1, 0);
  const [boardErr, setBoardErr] = useState('');
  const [sel, setSel] = useState<string | null>(null);
  const [animRoute, setAnimRoute] = useState(0);
  const [view, setView] = useState<'board' | 'list' | null>(null);
  const [readN, setReadN] = useState(0);
  const [byHand, setByHand] = useState(false);
  const [typedNum, setTypedNum] = useState('');
  const [typedDecal, setTypedDecal] = useState('');
  const [typedNote, setTypedNote] = useState('');
  const [pull, setPull] = useState(0);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  const [savedBy, setSavedBy] = useState<string | null>(null);
  const [saveErr, setSaveErr] = useState('');
  const [preview, setPreview] = useState<{ html: string; findings: Finding[] } | null>(null);
  const [draftId, setDraftId] = useState<number | null>(null);
  const [overDrop, setOverDrop] = useState(false);
  const [overRoute, setOverRoute] = useState(false);

  // One ticket's answers, reset when the panel moves on.
  const [ans, setAns] = useState<Record<string, string>>({});
  const [query, setQuery] = useState('');
  const [typing, setTyping] = useState<{ name: string; address: string } | null>(null);
  const [customSize, setCustomSize] = useState('');
  const [pickSize, setPickSize] = useState<Record<number, number>>({});
  const [arch, setArch] = useState<{ open: boolean; reason: string; text: string; dup: string }>({ open: false, reason: '', text: '', dup: '' });
  const [sugg, setSugg] = useState<Record<string, Visit[] | 'loading' | { error: string }>>({});
  const prefilled = useRef<Record<string, boolean>>({});

  const [compact, setCompact] = useState(false);
  useEffect(() => {
    const m = window.matchMedia('(max-width: 699px)');
    const on = () => setCompact(m.matches);
    on();
    m.addEventListener('change', on);
    return () => m.removeEventListener('change', on);
  }, []);
  const gridRef = useRef<HTMLDivElement | null>(null);
  const [gridW, setGridW] = useState(0);
  useEffect(() => {
    const el = gridRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setGridW(Math.max(0, el.clientWidth - 104)));
    ro.observe(el);
    return () => ro.disconnect();
  }, [stage, view, boardRef.current]);

  const r = rulesRef.current;
  const ui = uiRef.current;
  const board = boardRef.current;
  const vm = r && stage !== 'home' && stage !== 'loading' ? buildVM(r, ui, board) : null;
  const canEdit = !!ov?.me.can_edit;

  // ---- Keep the work ---------------------------------------------------------------------------------------------------
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const saveNow = useCallback(async () => {
    const rr = rulesRef.current;
    if (!rr || !ov?.me.can_edit) return;
    try {
      const work = { ...JSON.parse(JSON.stringify(rr.savedFileBody())), ui: { ...uiRef.current, ym: rr.ym } };
      const reply = await okJson<{ saved_at: string }>(await api.post('save_work', { period: openYm.current || rr.ym, work }));
      setSavedAt(reply.saved_at); setSavedBy(null); setSaveErr('');
    } catch (e) { setSaveErr(msg(e)); }
  }, [api, ov]);
  const scheduleSave = useCallback(() => {
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(saveNow, 800);
  }, [saveNow]);
  useEffect(() => () => { if (saveTimer.current) clearTimeout(saveTimer.current); }, []);

  const pick = useCallback((key: string | null) => {
    setSel(key); setAns({}); setQuery(''); setTyping(null); setCustomSize(''); setPickSize({}); setArch({ open: false, reason: '', text: '', dup: '' });
    setAnimRoute(n => n + 1);
  }, []);
  const advance = useCallback(() => {
    const rr = rulesRef.current;
    if (!rr) return;
    const q = buildVM(rr, uiRef.current, boardRef.current).queue;
    pick(q[0] ? keyOf(q[0]) : null);
  }, [pick]);
  // Every act on the rules comes through here: re-draw, then keep the work.
  const act = useCallback((fn: () => void, then?: 'advance') => {
    fn();
    bump();
    scheduleSave();
    if (then === 'advance') advance();
  }, [advance, scheduleSave]);
  const ack = (d: Decision) => { uiRef.current.acks[ackKey(d)] = true; };

  // ---- Loading -----------------------------------------------------------------------------------------------------------
  const loadHome = useCallback(async () => {
    setBusy('home'); setErr('');
    try {
      const o = await okJson<Overview>(await api.post('overview'));
      setOv(o);
      const ym = ymOfLabel(o.current.period);
      if (ym) {
        const w = await okJson<{ work: unknown; saved_by?: string; saved_at?: string }>(await api.post('load_work', { period: ym }));
        setHomeWork(w.work ? { by: w.saved_by, at: w.saved_at } : null);
      }
      setStage('home');
    } catch (e) { setErr(msg(e)); setStage('home'); } finally { setBusy(''); }
  }, [api]);
  useEffect(() => { void loadHome(); }, [loadHome]);

  const loadBoard = useCallback(async (rr: MonthlyRules) => {
    setBoardErr('');
    try {
      const tickets = rr.LOADS.map(tOf).filter(Boolean);
      const v = buildVM(rr, uiRef.current, null);
      boardRef.current = await okJson<BoardData>(await api.post('board', { tickets, from: dayStr(v.lo - 3), to: dayStr(v.hi + 1) }));
    } catch (e) { setBoardErr(msg(e)); }
    bump();
  }, [api]);

  const reapplyTicks = (rr: MonthlyRules, u: Ui) => {
    Object.entries(u.ticks).forEach(([t, on]) => {
      const i = rr.indexOfTicket(t);
      if (i >= 0 && !isHeld(rr.LOADS[i])) rr.setIncluded(i, on);
    });
  };

  const openFiling = useCallback(async (ym: string) => {
    setBusy('open'); setErr(''); setHomeNote('');
    try {
      const [f, w] = await Promise.all([api.post('tickets'), api.post('load_work', { period: ym })]);
      const feed = await okJson<FetchResponse>(f);
      const saved = await okJson<{ work: WorkFile | null; saved_by?: string; saved_at?: string }>(w);
      const rr = new MonthlyRules(ym);
      const u: Ui = { acks: {}, ticks: {}, parsed: null };
      let fresh = 0;
      if (saved.work && Array.isArray(saved.work.loads)) {
        const res = rr.adoptSavedFile(saved.work);
        Object.assign(u, saved.work.ui || {});
        if (res.reread && u.parsed) rr.applySavedReread(res.reread, u.parsed);
        if (u.ym && u.ym !== ym) rr.applyMonth(u.ym);
        rr.meetArchive(feed);
        const have = new Set(rr.LOADS.map(tOf));
        fresh = (feed.loads || []).filter(l => !have.has(tOf(l))).length;
        setSavedAt(saved.saved_at || null); setSavedBy(saved.saved_by || null);
      } else {
        rr.adoptFetch(feed);
        setSavedAt(null); setSavedBy(null);
      }
      rulesRef.current = rr; uiRef.current = u; boardRef.current = null; prefilled.current = {}; openYm.current = ym;
      setPull(fresh); setPreview(null); setDraftId(null); setView(null); setByHand(false); setSaveErr('');
      await loadBoard(rr);
      const hasInvoice = parseTickets(rr.invoiceText) !== null;
      setStage(hasInvoice ? 'board' : 'start');
      const q = buildVM(rr, u, boardRef.current).queue;
      pick(hasInvoice && q[0] ? keyOf(q[0]) : null);
    } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
  }, [api, loadBoard, pick]);

  const pullFresh = useCallback(async (then?: () => void) => {
    const rr = rulesRef.current;
    if (!rr) return;
    const feed = await okJson<FetchResponse>(await api.post('tickets'));
    rr.reload(feed);
    reapplyTicks(rr, uiRef.current);
    setPull(0);
    await loadBoard(rr);
    if (then) then();
    bump(); scheduleSave();
  }, [api, loadBoard, scheduleSave]);

  // ---- The invoice ----------------------------------------------------------------------------------------------------
  const readFile = useCallback(async (file: File) => {
    const rr = rulesRef.current;
    if (!rr) return;
    setBusy('reading'); setErr('');
    try {
      const parsed = await okJson<InvoiceParse>(await api.upload(file));
      // The bytes are not kept. The parse is, so a reopened month needs no second read.
      if (!rr.adoptDroppedInvoice(parsed, file.name, '')) {
        setErr(plain(rr.invoiceStatus?.text || `No ticket numbers found in ${file.name}. Type them by hand below.`));
        bump();
        return;
      }
      uiRef.current.parsed = parsed; uiRef.current.invoiceName = file.name; uiRef.current.acks = {};
      reapplyTicks(rr, uiRef.current);
      await loadBoard(rr);
      scheduleSave();
      const n = (parseTickets(rr.invoiceText) || []).length;
      if (reduced()) { setStage('board'); advance(); return; }
      setReadN(0); setStage('reading');
      let k = 0;
      const tm = setInterval(() => {
        k += 1; setReadN(k);
        if (k >= n) { clearInterval(tm); setTimeout(() => { setStage('board'); advance(); }, 420); }
      }, Math.min(110, Math.floor(1800 / Math.max(1, n))));
    } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
  }, [advance, api, loadBoard, scheduleSave]);

  // ---- Check, generate, record -------------------------------------------------------------------------------------------
  const runCheck = useCallback(async () => {
    const rr = rulesRef.current;
    if (!rr) return;
    setBusy('check'); setErr('');
    try {
      const p = rr.payload();
      if (p.err || !p.body) throw new Error(p.err || 'Nothing to check.');
      const reply = await api.post('check', { payload: p.body });
      if (!reply.ok) throw new Error(await problem(reply));
      const j = await reply.json() as { html: string; findings: Finding[] };
      rr.setPreviewResult(p.body, j.findings, reply.headers.get('x-preview-token'));
      setPreview({ html: j.html, findings: j.findings || [] });
      setStage('check');
      bump();
    } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
  }, [api]);

  const generate = useCallback(async () => {
    const rr = rulesRef.current;
    if (!rr) return;
    setBusy('generate'); setErr('');
    try {
      const g = rr.generateBody();
      if (g.err || !g.body) throw new Error(g.err || 'Nothing to generate.');
      const reply = await api.post('generate', { payload: g.body });
      if (!reply.ok) throw new Error(await problem(reply));
      await saveBlob(reply.clone(), `LWT_report_${rr.ym}.xlsx`);
      rr.setGenerated(g.body, { id: reply.headers.get('X-Filing-Id'), tickets: reply.headers.get('X-Filing-Tickets'), list: reply.headers.get('X-Filing-List') });
      setDraftId(rr.GENERATED?.id ? +rr.GENERATED.id : null);
      setStage('wait');
      bump(); scheduleSave();
    } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
  }, [api, scheduleSave]);

  const download = useCallback(async (id: number, name: string) => {
    setBusy(`dl${id}`); setErr('');
    try {
      const reply = await api.post('download', { id });
      if (!reply.ok) throw new Error(await problem(reply));
      await saveBlob(reply, name);
    } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
  }, [api]);

  // Fred, 2026-11-05: "a "View" button instead of Download, and on the table header have the download, where the rows of the table are selectable".
  const downloadPicked = useCallback(async (rows: FilingRow[]) => {
    setBusy('dlmany'); setErr('');
    try {
      for (const x of rows) {
        const reply = await api.post('download', { id: x.id });
        if (!reply.ok) throw new Error(`${x.period}: ${await problem(reply)}`);
        await saveBlob(reply, `LWT_report_${x.ym}.xlsx`);
      }
    } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
  }, [api]);
  const openReport = useCallback(async (row: FilingRow) => {
    setViewing({ row, page: null, err: '' });
    try {
      const reply = await api.post('download', { id: row.id });
      if (!reply.ok) throw new Error(await problem(reply));
      const page = await reportHtml(await reply.arrayBuffer());
      setViewing(v => (v?.row.id === row.id ? { row, page, err: '' } : v));
    } catch (e) { setViewing(v => (v?.row.id === row.id ? { row, page: null, err: msg(e) } : v)); }
  }, [api]);
  const viewOpen = !!viewing;
  useEffect(() => {
    const el = viewBody.current;
    if (!viewOpen || !el) return;
    const watch = new ResizeObserver(([e]) => setViewW(e.contentRect.width));
    watch.observe(el);
    return () => watch.disconnect();
  }, [viewOpen]);

  const closeDialog = () => { setDialog(null); setDlgReason(''); setDlgText(''); setDlgErr(''); };
  const startOver = useCallback(async () => {
    if (!dialog || dialog.kind !== 'startover') return;
    setBusy('startover'); setDlgErr('');
    try {
      await okJson(await api.post('save_work', { period: dialog.period, work: null }));
      closeDialog();
      await loadHome();
    } catch (e) { setDlgErr(msg(e)); } finally { setBusy(''); }
  }, [api, dialog, loadHome]);
  const record = useCallback(async () => {
    if (!dialog || dialog.kind !== 'record') return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    setBusy('record'); setDlgErr('');
    try {
      const reply = await api.post('record', { id: dialog.id, expect_tickets: dialog.tickets });
      const raw = await reply.text();
      let said = raw;
      try { const j = JSON.parse(raw); if (typeof j.message === 'string' && !j.detail) said = JSON.stringify({ detail: j.message }); } catch { /* the raw text is the reason */ }
      const out = recordOutcome(reply.ok, said);
      if (out.state === 'filed') {
        await api.post('save_work', { period: rulesRef.current ? openYm.current : dialog.period, work: null }).catch(() => null);
        closeDialog();
        setHomeNote(`${dialog.label} is recorded as filed.`);
        rulesRef.current = null;
        await loadHome();
        return;
      }
      if (out.state === 'refused') setDlgErr(`${out.who}: ${plain(out.why)}`);
      else if (out.state === 'already') setDlgErr('This report was already recorded as filed. Nothing changed.');
      else setDlgErr('The server answered without confirming the record. Check the filing history before pressing again.');
    } catch { setDlgErr('The report service did not answer. Check the filing history before pressing again.'); } finally { setBusy(''); }
  }, [api, dialog, loadHome]);

  const discard = useCallback(async () => {
    if (!dialog || dialog.kind !== 'discard') return;
    setBusy('discard'); setDlgErr('');
    try {
      await okJson(await api.post('discard', { id: dialog.id, reason: dlgReason, reason_text: dlgText.trim() || undefined }));
      closeDialog();
      await loadHome();
    } catch (e) { setDlgErr(msg(e)); } finally { setBusy(''); }
  }, [api, dialog, dlgReason, dlgText, loadHome]);

  const restoreRow = useCallback(async (id: number) => {
    setBusy(`re${id}`); setErr('');
    try { await okJson(await api.post('restore', { id })); await loadHome(); } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
  }, [api, loadHome]);

  // ---- The picker's suggestions ------------------------------------------------------------------------------------------
  const pendingD = r && vm && sel ? vm.queue.find(q => keyOf(q) === sel) || null : null;
  const editing = !!(r && r.PAPER_EDIT && sel === r.PAPER_EDIT.t);
  const pickerT = pendingD?.kind === 'number_no_ticket' || editing ? sel : null;
  const pickerDate = pickerT && r ? r.formOffload(pickerT, r.formFor(pickerT)) : '';
  const pickerDecal = pickerT && r ? String(r.PAPER_DECALS[pickerT] || r.INV_DECALS[pickerT] || (r.LOADS[r.indexOfTicket(pickerT)]?.decal) || '') : '';
  const pickerVehicle = pickerT && pickerDecal && board ? board.trucks.find(t => (t.decal || '').toUpperCase() === pickerDecal.toUpperCase())?.id ?? null : null;
  const suggKey = pickerT && pickerDate ? `${pickerDate}|${pickerVehicle ?? ''}` : '';
  useEffect(() => {
    if (!suggKey || sugg[suggKey]) return;
    const [date, veh] = suggKey.split('|');
    setSugg(s => ({ ...s, [suggKey]: 'loading' }));
    api.post('suggest', { dump_date: date, vehicle_id: veh ? +veh : null })
      .then(reply => okJson<{ visits: Visit[] }>(reply))
      .then(j => setSugg(s => ({ ...s, [suggKey]: j.visits || [] })))
      .catch(e => setSugg(s => ({ ...s, [suggKey]: { error: msg(e) } })));
  }, [api, suggKey, sugg]);
  const visits = suggKey && Array.isArray(sugg[suggKey]) ? (sugg[suggKey] as Visit[]) : [];
  const toPick = (v: Visit) => ({ name: v.form_name, address: v.form_address, county: v.county, in_dade: v.county === 'Dade', visit_id: v.visit_id, visit_date: v.visit_date });
  // The likely stops are already on the ticket when it opens. A person only corrects them.
  useEffect(() => {
    const rr = rulesRef.current;
    if (!rr || !pickerT || !visits.length || editing || prefilled.current[pickerT]) return;
    prefilled.current[pickerT] = true;
    if (rr.formFor(pickerT).clients.length) return;
    visits.filter(v => v.group === 'likely').forEach(v => rr.pfPickVisit(pickerT, toPick(v)));
    bump();
  }, [pickerT, visits, editing]);

  // ---- Small pieces of markup --------------------------------------------------------------------------------------------
  const errLine = err ? <div className="lw-err" role="alert"><span>{err}</span><button type="button" className="lw-b" onClick={() => setErr('')}>Dismiss</button></div> : null;
  const truckById = (id: number | null) => (id != null && board ? board.trucks.find(t => t.id === id) || null : null);
  const badge = (tr: { name: string; color: string | null } | null, small?: boolean) => (
    <span className={`lw-tr ${small ? 's' : ''}`} style={tr?.color ? { background: tr.color } : undefined} title={tr?.name || 'No truck'}>{tr ? tr.name[0] : '?'}</span>
  );
  const tile = (on: boolean, title: ReactNode, sub: ReactNode, onClick: () => void, key?: string) => (
    <button key={key} type="button" className={`lw-tile ${on ? 'on' : ''}`} aria-pressed={on} onClick={onClick}>
      <span className="dot">{on && <Ic d={I.check} style={{ width: 12, height: 12 }} />}</span>
      <span><b>{title}</b><small>{sub}</small></span>
    </button>
  );
  const decalLine = (decal: unknown) => {
    const d = String(decal || '').toUpperCase();
    const tr = board?.trucks.find(t => (t.decal || '').toUpperCase() === d) || null;
    const g = DECAL_GALLONS[d];
    return `${tr ? `${tr.name}, ` : ''}${d || 'No decal'}${g ? `, ${int(g)} gal` : ''}`;
  };

  function renderFacts(it: Item | null, t: string) {
    const l = it?.l || null;
    const tr = truckById(it?.lane ?? null);
    const decal = (l && l.decal) || (r && (r.PAPER_DECALS[t] || r.INV_DECALS[t])) || '';
    const g = l ? resolvedGallons(l) : (decal ? DECAL_GALLONS[String(decal).toUpperCase()] : null);
    const date = it?.date || '';
    const gps = tr && date ? board?.gps.find(x => x.vehicle_id === tr.id && x.day === date) : null;
    return (
      <>
        <div className="lw-read">
          <span>Truck</span><b>{badge(tr, true)} {tr ? tr.name : 'Not known'}{decal ? `, ${decal}` : ''}</b>
          <span>Offload</span><b>{mdy(date) || 'Not known'}</b>
          <span>Plant</span><b>{plain((l && l.disposal_facility) || 'South District WWTP')}</b>
          <span>Gallons</span><b>{g != null ? `${int(g)} gal` : 'Not known yet'}</b>
        </div>
        {gps && <div className="lw-gps"><Ic d={I.pin} /><span>GPS saw {tr?.name} at {gps.site || 'a dump site'} on {md(date)} at {gps.at}.</span></div>}
      </>
    );
  }
  function renderStops(t: string, l: Load | null) {
    const stops = board ? board.stops.filter(s => s.ticket === t) : [];
    const rows: { k: string; name: string; sub: string }[] = stops.length
      ? stops.map(s => ({ k: String(s.visit_id), name: s.client_name, sub: [s.client_code, s.address, md(s.pickup_date), s.gallons ? `${int(s.gallons)} gal` : ''].filter(Boolean).join(', ') }))
      : (l?.facilities || []).map((f, i) => ({ k: String(i), name: String(f.name || ''), sub: String(f.address || '') }));
    if (!rows.length) return <div className="lw-route ro"><div className="lw-empty">No stops on this ticket.</div></div>;
    return (
      <div className="lw-route ro">
        {rows.map(s => <div className="lw-rs" key={s.k}><div className="bd"><b>{s.name}</b><small>{s.sub}</small></div></div>)}
        <div className="lw-rs end"><div className="bd"><b>{plain(l?.disposal_facility || 'South District WWTP')}</b><small>Dumped {md(l?.offload_date)}</small></div></div>
      </div>
    );
  }
  const panelHead = (t: string, chip: ReactNode, lead: ReactNode) => (
    <div className="lw-ph">
      <div className="lw-pt"><b>{t === MONTH_KEY ? monthLabel(r?.ym) : `#${t}`}</b>{chip}
        {compact && <button type="button" className="lw-rm x" aria-label="Close" onClick={() => pick(null)}><Ic d={I.x} /></button>}
      </div>
      <p>{lead}</p>
      {errLine}
    </div>
  );
  const warnChip = (s: string) => <span className="lw-chip warn">{s}</span>;
  const panelClass = `lw-panel ${compact ? 'sheet' : ''}`;

  // ---- The picker: a ticket nobody logged ------------------------------------------------------------------------------------
  function renderPicker(t: string, it: Item | null) {
    if (!r) return null;
    const st = r.formFor(t);
    const mode: 'add' | 'edit' = editing ? 'edit' : 'add';
    const off = r.formOffload(t, st);
    const decal = pickerDecal;
    const picked = new Set(st.clients.map(c => String(c._visit_id ?? '')));
    const left = visits.filter(v => !picked.has(String(v.visit_id)));
    const q = query.trim().toLowerCase();
    const found = q ? left.filter(v => `${v.client_code || ''} ${v.client_name} ${v.address || ''} ${v.city || ''}`.toLowerCase().includes(q)).slice(0, 8) : [];
    const grp = (g: string) => left.filter(v => v.group === g);
    const truckName = truckById(pickerVehicle)?.name;
    const add = (v: Visit) => act(() => r.pfPickVisit(t, toPick(v)));
    const onDrop = (e: DragEvent) => {
      e.preventDefault(); setOverRoute(false);
      const v = visits.find(x => String(x.visit_id) === e.dataTransfer.getData('text/plain'));
      if (v && !picked.has(String(v.visit_id))) add(v);
    };
    const tileFor = (v: Visit, key: string) => (
      <button key={key} type="button" className={`lw-pick ${v.on_ticket ? 'taken' : ''}`} draggable onDragStart={e => e.dataTransfer.setData('text/plain', String(v.visit_id))} onClick={() => add(v)}>
        <span className="plus"><Ic d={I.plus} /></span>
        <span className="bd"><b>{v.form_name}</b><small>{v.client_code ? `${v.client_code}, ` : ''}{v.on_ticket ? `already on #${v.on_ticket}` : v.form_address}{v.county && v.county !== 'Dade' ? `, ${v.county}: this form leaves it off` : ''}</small></span>
        <span className="when">{badge(v.truck ? { name: v.truck, color: v.truck_color } : null, true)} {md(v.visit_date)}</span>
      </button>
    );
    const sect = (title: string, sub: string, list: Visit[]) => (list.length ? <div><div className="lw-sect">{title} <small>{sub}</small></div>{list.map(v => tileFor(v, `${title}${v.visit_id}`))}</div> : null);
    const loadingS = suggKey && sugg[suggKey] === 'loading';
    const failedS = suggKey && sugg[suggKey] && typeof sugg[suggKey] === 'object' && !Array.isArray(sugg[suggKey]) ? (sugg[suggKey] as { error: string }).error : '';
    const onTaken = grp('same_truck_on_ticket'), otherTaken = grp('other_truck_on_ticket');
    const latest = st.clients.length ? r.formPickup(st) : '';
    const inputs = decal ? null : (
      <div><div className="lw-sect">Which truck? <small>the invoice does not say</small></div>
        {Object.keys(DECAL_GALLONS).map(d => tile(false, decalLine(d), 'From the Decal column on the paper', () => act(() => r.setNumberDecal(t, d)), d))}
      </div>
    );
    return (
      <aside className={panelClass}>
        {mode === 'add'
          ? panelHead(t, warnChip('Needs stops'), 'The county billed this ticket and nobody logged it. Pick its stops from the truck’s real visits.')
          : panelHead(t, <span className="lw-chip ok">On this report</span>, 'Change the stops on this hand row.')}
        <div className="lw-pb">
          {it ? renderFacts(it, t) : null}
          {r.INV_DATES[t] ? null : (
            <label className="lw-fld">When was it dumped? <small>The Service Date on the ticket&rsquo;s row</small>
              <input className="lw-inp" type="date" value={off} onChange={e => act(() => r.pfOffload(t, e.target.value))} />
            </label>
          )}
          {inputs}
          <div>
            <div className="lw-sect">On this ticket <small>{count(st.clients.length, 'stop')}</small></div>
            <div className={`lw-route ${overRoute ? 'over' : ''}`} onDragOver={e => { e.preventDefault(); setOverRoute(true); }} onDragLeave={() => setOverRoute(false)} onDrop={onDrop}>
              {st.clients.length ? st.clients.map((c, j) => (
                <div className="lw-rs" key={`${c.name}${j}`}>
                  <div className="bd"><b>{c.name}</b><small>{c.address}{c._visit_date ? `, ${md(String(c._visit_date))}` : c._src === 'typed' ? ', typed by hand' : ''}{c.in_dade === false ? `, ${c.county || 'out of county'}: this form leaves it off` : ''}</small></div>
                  <button type="button" className="lw-rm" aria-label={`Remove ${c.name}`} onClick={() => act(() => r.pfRemove(t, j))}><Ic d={I.x} /></button>
                </div>
              )) : <div className="lw-empty">{compact ? 'Tap a stop below.' : 'Drag a stop here, or tap one below.'}</div>}
              {st.clients.length > 0 && <div className="lw-rs end"><div className="bd"><b>South District WWTP</b><small>Dumped {md(off)}</small></div></div>}
            </div>
          </div>
          {loadingS && <div className="lw-empty">Reading the truck&rsquo;s visits</div>}
          {failedS && <div className="lw-warnbox">{failedS}</div>}
          {sect(`${truckName || 'This truck'}’s stops`, 'since its last dump, no ticket yet', grp('likely'))}
          {sect(`${truckName || 'This truck'}, earlier`, 'no ticket yet', grp('same_truck_older'))}
          {sect('Other trucks', 'no ticket yet', grp('other_truck'))}
          <div>
            <label className="lw-sect" htmlFor="lw-find">Find any visit <small>last 14 days</small></label>
            <input id="lw-find" className="lw-inp" placeholder="Client or street" value={query} onChange={e => setQuery(e.target.value)} />
            {q && <div style={{ marginTop: 6 }}>{found.length ? found.map(v => tileFor(v, `f${v.visit_id}`)) : <div className="lw-empty">No visit in those 14 days matches.</div>}</div>}
          </div>
          {onTaken.length + otherTaken.length > 0 && (
            <details className="lw-fold"><summary>Already on another ticket <small>{onTaken.length + otherTaken.length}</small></summary>
              <div className="in">{[...onTaken, ...otherTaken].map(v => tileFor(v, `t${v.visit_id}`))}</div>
            </details>
          )}
          {typing ? (
            <div className="lw-card" style={{ padding: 12, display: 'grid', gap: 8 }}>
              <label className="lw-fld">Client<input className="lw-inp" value={typing.name} onChange={e => setTyping({ ...typing, name: e.target.value })} /></label>
              <label className="lw-fld">Address <small>The form prints it</small><input className="lw-inp" value={typing.address} onChange={e => setTyping({ ...typing, address: e.target.value })} /></label>
              {st.msg && <div className="lw-warnbox">{st.msg}</div>}
              <div className="lw-acts">
                <button type="button" className="lw-b" onClick={() => setTyping(null)}>Cancel</button>
                <button type="button" className="lw-b" onClick={() => act(() => { if (r.pfTyped(t, typing.name, typing.address)) setTyping(null); })}>Add this client</button>
              </div>
            </div>
          ) : (
            <div><button type="button" className="lw-b q" onClick={() => setTyping({ name: query, address: '' })}>Client not listed? Type it</button></div>
          )}
        </div>
        <div className="lw-pf">
          <div className="note">{st.clients.length ? (latest ? `The form prints pickup ${md(latest)}, the last stop. This row goes on the report only, not in the Tracker.` : plain(r.formLine(t, st, mode).text)) : 'Pick at least one stop.'}</div>
          {r.lastError && <div className="lw-warnbox">{plain(r.lastError)}</div>}
          <div className="lw-acts">
            {mode === 'add'
              ? <button type="button" className="lw-b" onClick={() => act(() => r.removeInvTicket(t), 'advance')}>Take it off the invoice</button>
              : <button type="button" className="lw-b" onClick={() => act(() => r.cancelPaperEdit())}>Cancel</button>}
            {mode === 'add'
              ? <button type="button" className="lw-b p" disabled={!st.clients.length || !off} onClick={() => act(() => { r.addPaperFromForm(t); }, 'advance')}>Add ticket with {count(st.clients.length, 'stop')}</button>
              : <button type="button" className="lw-b p" onClick={() => act(() => { r.savePaperEdit(); })}>Save</button>}
          </div>
        </div>
      </aside>
    );
  }

  // ---- A trap size ---------------------------------------------------------------------------------------------------------
  async function saveSize(propertyId: number, gallons: number) {
    setBusy('size'); setErr('');
    try {
      await okJson(await api.post('save_size', { property_id: propertyId, gallons }));
      setPickSize({}); setCustomSize('');
      await pullFresh(advance);
    } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
  }
  function renderSizes(t: string) {
    const missing = board ? board.stops.filter(s => s.ticket === t && s.gallons == null) : [];
    const seen = new Set<string>();
    const props = missing.filter(s => { const k = `${s.property_id}`; if (seen.has(k)) return false; seen.add(k); return true; });
    if (!props.length) return <div className="lw-warnbox">Its property could not be read here. Add the size in the Client App, then press Reload.</div>;
    return props.map(s => {
      const pid = s.property_id;
      const v = pid == null ? 0 : (pickSize[pid] || 0);
      const custom = customSize.replace(/\D/g, '');
      const value = v || (custom ? +custom : 0);
      return (
        <div key={String(pid ?? s.visit_id)}>
          <div className="lw-sect" style={{ display: 'grid', gap: 1 }}>{s.client_name} <small>{[s.client_code, s.address].filter(Boolean).join(', ')}</small></div>
          {pid == null ? <div className="lw-warnbox">This visit has no property. Fix it in the Client App.</div> : (
            <>
              <div className="lw-sizes" role="group" aria-label="Trap size in gallons">
                {[250, 500, 750, 1000, 1500].map(g => (
                  <button type="button" key={g} className={v === g ? 'on' : ''} aria-pressed={v === g} onClick={() => { setCustomSize(''); setPickSize({ [pid]: g }); }}>{int(g)}</button>
                ))}
              </div>
              <label className="lw-fld" style={{ marginTop: 8 }}>Another size <small>From 1 to 20,000 gallons</small>
                <input className="lw-inp" inputMode="numeric" value={customSize} onChange={e => { setPickSize({}); setCustomSize(e.target.value); }} />
              </label>
              <div className="lw-acts" style={{ marginTop: 8, justifyContent: 'flex-end' }}>
                <button type="button" className="lw-b p" disabled={!value || value > 20000 || busy === 'size'} onClick={() => saveSize(pid, value)}>{busy === 'size' ? 'Saving' : value ? `Save ${int(value)} gal` : 'Save the size'}</button>
              </div>
            </>
          )}
        </div>
      );
    });
  }

  // ---- The panel ------------------------------------------------------------------------------------------------------------
  function renderNotes(t: string) {
    if (!vm) return null;
    const notes = vm.decisions.filter(d => d.ticket === t && !QUEUE_ORDER.includes(d.kind) && !['off_form', 'fetch_note'].includes(d.kind));
    const seen = new Set<string>();
    const list = notes.filter(d => { const k = `${d.rule}|${d.detail}`; if (seen.has(k)) return false; seen.add(k); return true; });
    if (!list.length) return null;
    return (
      <div><div className="lw-sect">Worth a look <small>{list.length}</small></div>
        {list.map(d => <div className="lw-find" key={`${d.rule}${d.detail}`}><b>{plain(d.title)}</b><small>{plain(d.detail)}</small></div>)}
      </div>
    );
  }
  function renderAllSet() {
    if (!vm || !r) return null;
    const done = Object.keys(ui.acks).length;
    return (
      <aside className="lw-panel">
        <div className="lw-ph">
          <div className="lw-pt"><b>All set</b><span className="lw-chip ok"><Ic d={I.check} /> Nothing left to decide</span></div>
          <p>{count(vm.onReport.length, 'ticket')} on this report. Tap any pin to look at it, or run the check.</p>
        </div>
        {done > 0 && <div className="lw-pb"><p style={{ margin: 0, fontSize: 12.5, color: 'var(--lw-ink2)' }}>You answered {count(done, 'question')}. Open a ticket to change an answer.</p></div>}
      </aside>
    );
  }
  function renderPanel() {
    if (!vm || !r) return null;
    if (!sel) return compact ? null : renderAllSet();
    const it = vm.items.find(i => i.t === sel) || null;
    const d = pendingD;
    if (d?.kind === 'number_no_ticket' || editing) return renderPicker(sel, it);
    const i = d && d.index != null ? d.index : (it?.l ? r.LOADS.indexOf(it.l) : -1);
    const facts = it ? renderFacts(it, sel) : null;
    const foot = (children: ReactNode, note?: ReactNode) => <div className="lw-pf">{note && <div className="note">{note}</div>}<div className="lw-acts">{children}</div></div>;
    const body = (children: ReactNode) => <div className="lw-pb">{children}</div>;
    const done = (fn: () => void) => act(fn, 'advance');
    const route = it?.l ? <div><div className="lw-sect">Stops</div>{renderStops(sel, it.l)}</div> : null;

    if (d) switch (d.kind) {
      case 'date_differs': {
        const inv = String(d.invoiceDate || ''), row = String(d.rowDate || '');
        const v = ans.date || inv;
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('Dates differ'), 'The invoice and our ticket disagree on the offload date.')}
            {body(<>{facts}<div>
              {tile(v === inv, `${md(inv)}, the invoice’s`, 'The county’s paper. Its Service Date is the offload date.', () => setAns({ date: inv }), 'a')}
              {tile(v === row, `${md(row)}, our ticket’s`, 'What the driver logged.', () => setAns({ date: row }), 'b')}
              {d.pickupAfterInvoiceDate ? <div className="lw-warnbox">The pickup on this ticket is after {md(inv)}. Check the paper before using that date.</div> : null}
            </div>{route}</>)}
            {foot(<button type="button" className="lw-b p" onClick={() => done(() => { if (v === inv && d.canUseInvoice) r.useInvoiceDate(sel); ack(d); })}>Use {md(v)}</button>)}
          </aside>
        );
      }
      case 'truck_differs': {
        const inv = String(d.invoiceDecal || d.rowDecal || ''), other = String((d.rowDecal && d.rowDecal !== d.invoiceDecal ? d.rowDecal : d.systemDecal) || '');
        const v = ans.truck || inv;
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('Trucks differ'), 'The truck decides the gallons, so two trucks are two quantities.')}
            {body(<>{facts}<div>
              {tile(v === inv, decalLine(inv), 'The invoice’s. It is the paper the county is paid against.', () => setAns({ truck: inv }), 'a')}
              {other && other !== inv ? tile(v === other, decalLine(other), 'Ours.', () => setAns({ truck: other }), 'b') : null}
            </div>{route}</>)}
            {foot(<button type="button" className="lw-b p" onClick={() => done(() => {
              if (v === inv) { if (d.canUseInvoice) r.useInvoiceDecal(i); } else r.setLoadDecal(i, v);
              ack(d);
            })}>Use {v}</button>)}
          </aside>
        );
      }
      case 'dumped_not_billed': {
        const v = ans.nb || 'leave';
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('Not on the invoice'), 'Dumped inside this invoice’s dates, but the county did not bill it.')}
            {body(<>{facts}<div>
              {tile(v === 'leave', 'Leave it off', 'It stays pending for its own invoice. The invoice decides the month.', () => setAns({ nb: 'leave' }), 'a')}
              {tile(v === 'file', 'File it on this report', 'The form will not match the county’s invoice.', () => setAns({ nb: 'file' }), 'b')}
            </div>{route}</>)}
            {foot(<button type="button" className="lw-b p" onClick={() => done(() => {
              if (v === 'file') { ui.ticks[sel] = true; r.setIncluded(i, true); }
              ack(d);
            })}>{v === 'file' ? 'File it' : 'Leave it off'}</button>)}
          </aside>
        );
      }
      case 'waiting_on_size':
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('Needs a size'), 'Dumped out of county, so its gallons come from each client’s trap size, and one has none on file.')}
            {body(<>{facts}{renderSizes(sel)}{route}</>)}
            {foot(<button type="button" className="lw-b" onClick={() => done(() => ack(d))}>Leave it waiting</button>, 'Saved on the property, so next month it is already known. It only fills a size that is missing.')}
          </aside>
        );
      case 'not_manifest_number':
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('Not a manifest number'), plain(ruleInfo('manifest_number_shape').explain))}
            {body(<>{facts}{route}</>)}
            {foot(<>
              <a className="lw-b" href={`/manifests?q=${encodeURIComponent(sel)}`}>Open in Manifests</a>
              <button type="button" className="lw-b p" onClick={() => done(() => { if (i >= 0 && !it?.l?._excluded) { ui.ticks[sel] = false; r.setIncluded(i, false); } ack(d); })}>Leave it off</button>
            </>)}
          </aside>
        );
      case 'unresolved_gallons':
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('No gallons'), 'The form cannot print a quantity nobody knows. Name the truck from the Decal column, or leave it off.')}
            {body(<>{facts}<div>{Object.keys(DECAL_GALLONS).map(k => tile(ans.truck === k, decalLine(k), 'From the Decal column on the paper', () => setAns({ truck: k }), k))}</div>{route}</>)}
            {foot(<>
              <button type="button" className="lw-b" onClick={() => done(() => r.blockerLeaveOff(i))}>Leave it off</button>
              <button type="button" className="lw-b p" disabled={!ans.truck} onClick={() => done(() => r.blockerSetDecal(i, ans.truck))}>Use {ans.truck || 'this truck'}</button>
            </>)}
          </aside>
        );
      case 'pickup_after_offload':
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('Dates cross'), `This ticket says the pickup on ${md(String(d.pickup || ''))} came after the dump on ${md(String(d.offload || ''))}. One of the dates is wrong.`)}
            {body(<>{facts}{route}</>)}
            {foot(<>
              <button type="button" className="lw-b" onClick={() => done(() => { ui.ticks[sel] = false; r.setIncluded(i, false); })}>Leave it off</button>
              <button type="button" className="lw-b p" onClick={() => done(() => ack(d))}>I checked the paper, keep it</button>
            </>)}
          </aside>
        );
      case 'archived_on_invoice':
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('Archived'), plain(d.detail))}
            {body(<>{facts}</>)}
            {foot(<>
              <button type="button" className="lw-b" onClick={() => done(() => r.removeInvTicket(sel))}>Take it off the invoice</button>
              <button type="button" className="lw-b p" disabled={busy === 'unarchive'} onClick={async () => {
                setBusy('unarchive'); setErr('');
                try { const j = await okJson<FetchResponse>(await api.post('unarchive', { ticket: sel })); done(() => r.applyRestored(sel, j)); } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
              }}>Restore it</button>
            </>)}
          </aside>
        );
      case 'reader_candidate':
        return (
          <aside className={panelClass}>
            {panelHead(sel, warnChip('Not sure'), plain(d.detail))}
            {foot(<>
              <button type="button" className="lw-b" onClick={() => done(() => ack(d))}>Not a ticket</button>
              <button type="button" className="lw-b p" onClick={() => done(() => r.acceptCandidate(sel))}>Add it to the invoice</button>
            </>)}
          </aside>
        );
      case 'report_shape': {
        const s = String(d.suggest || '');
        return (
          <aside className={panelClass}>
            {panelHead(MONTH_KEY, warnChip('Check the month'), plain(d.detail))}
            {foot(<>
              <button type="button" className="lw-b" onClick={() => done(() => ack(d))}>Keep {monthLabel(r.ym)}</button>
              {s && <button type="button" className="lw-b p" onClick={() => done(() => r.applyMonth(s))}>Change to {monthLabel(s)}</button>}
            </>)}
          </aside>
        );
      }
      default:
    }

    // Nothing to decide on this ticket: look at it, leave it off, put it back.
    if (!it || !it.l) return compact ? null : renderAllSet();
    const l = it.l;
    const paper = !!l._paper;
    const held = it.held;
    const otherMonth = it.ooc && offloadMonth(it.date) !== r.ym;
    const guard = r.archiveGuard(l);
    const acked = Object.keys(ui.acks).filter(k => k.split('|')[1] === sel);
    const chip = it.on ? <span className={`lw-chip ${it.ooc ? 'brow' : 'ok'}`}>{it.ooc ? 'Out of county' : paper ? 'Added by hand' : 'Ready'}</span>
      : held ? <span className="lw-chip warn">Waiting on a size</span>
        : otherMonth ? <span className="lw-chip idle">Its own month</span> : <span className="lw-chip idle">Left off</span>;
    const lead = it.on ? (it.ooc ? 'Not on the county’s invoice. Its gallons come from the trap sizes on file.' : paper ? 'On this report, built from real visits. It stays out of the Tracker.' : 'On the invoice and in our system. Nothing to do.')
      : otherMonth ? `Dumped in ${monthLabel(offloadMonth(it.date) || '')}. A load out of county belongs to its dump month, so this report leaves it off.`
        : held ? 'It prints nothing until the size is on file.' : 'Not on this report. It stays pending.';
    return (
      <aside className={panelClass}>
        {panelHead(sel, chip, lead)}
        {body(<>
          {facts}
          {held && renderSizes(sel)}
          {renderNotes(sel)}
          <div><div className="lw-sect">Stops</div>{renderStops(sel, l)}</div>
          {arch.open && !guard && (
            <div className="lw-card" style={{ padding: 12, display: 'grid', gap: 8 }}>
              <div className="lw-sect" style={{ margin: 0 }}>Why archive it? <small>Nothing is deleted. It can be restored.</small></div>
              {ARCHIVE_REASONS.map(a => tile(arch.reason === a[0], a[1], a[2], () => setArch({ ...arch, reason: a[0] }), a[0]))}
              {arch.reason === 'duplicate' && <label className="lw-fld">The real ticket&rsquo;s number<input className="lw-inp" inputMode="numeric" value={arch.dup} onChange={e => setArch({ ...arch, dup: e.target.value })} /></label>}
              {arch.reason === 'other' && <label className="lw-fld">Say why<input className="lw-inp" value={arch.text} onChange={e => setArch({ ...arch, text: e.target.value })} /></label>}
              <div className="lw-acts" style={{ justifyContent: 'flex-end' }}>
                <button type="button" className="lw-b" onClick={() => setArch({ open: false, reason: '', text: '', dup: '' })}>Cancel</button>
                <button type="button" className="lw-b p" disabled={busy === 'archive'} onClick={async () => {
                  const b = r.archiveBody(sel, arch.reason, arch.text, arch.dup);
                  if (b.err || !b.body) { setErr(b.err || 'Nothing to archive.'); return; }
                  setBusy('archive'); setErr('');
                  try { const j = await okJson<FetchResponse & { record?: unknown }>(await api.post('archive', b.body)); done(() => r.applyArchived(sel, j)); } catch (e) { setErr(msg(e)); } finally { setBusy(''); }
                }}>Archive it</button>
              </div>
            </div>
          )}
        </>)}
        {canEdit && foot(<>
          {acked.length > 0 && <button type="button" className="lw-b" onClick={() => act(() => { acked.forEach(k => { delete ui.acks[k]; }); })}><Ic d={I.redo} /> Change my answer</button>}
          {paper && <button type="button" className="lw-b" onClick={() => act(() => { r.openPaperEdit(sel); })}>Change the stops</button>}
          {!guard && !arch.open && <button type="button" className="lw-b" onClick={() => setArch({ ...arch, open: true })}>Archive</button>}
          {!held && !otherMonth && (it.on
            ? <button type="button" className="lw-b" onClick={() => act(() => { ui.ticks[sel] = false; r.setIncluded(r.LOADS.indexOf(l), false); })}>Leave it off this report</button>
            : <button type="button" className="lw-b" onClick={() => act(() => { ui.ticks[sel] = true; r.setIncluded(r.LOADS.indexOf(l), true); })}>Put it back</button>)}
        </>)}
      </aside>
    );
  }

  // ---- The board --------------------------------------------------------------------------------------------------------------
  function pinClass(it: Item) {
    if (stage === 'start' || stage === 'reading') {
      if (it.on && it.ooc) return 'ooc';
      if (stage === 'reading') {
        const inv = vm?.invoice || [];
        const k = inv.indexOf(it.t);
        if (k >= 0 && k < readN) return `${it.need ? 'need' : 'ok'}${k === readN - 1 ? ' lit' : ''}`;
      }
      return 'idle';
    }
    if (it.need) return 'need';
    if (!it.on) return 'off';
    return it.ooc ? 'ooc' : 'ok';
  }
  const pinIcon = (c: string) => (c.startsWith('need') ? I.bang : c === 'off' ? I.dash : c === 'idle' ? '' : I.check);
  function renderBoard() {
    if (!vm || !board) return null;
    const { lo, days } = vm;
    const x = (n: number) => ((Math.min(days - 1, Math.max(0, n - lo)) + 0.5) / days) * 100;
    const weekends: number[] = [];
    const labels: { n: number; text: string }[] = [];
    for (let n = lo; n < lo + days; n++) {
      const dow = new Date(n * 864e5).getUTCDay();
      if (dow === 0 || dow === 6) weekends.push(n);
      if (dow === 1) labels.push({ n, text: `${MONTHS[new Date(n * 864e5).getUTCMonth()].slice(0, 3)} ${new Date(n * 864e5).getUTCDate()}` });
    }
    const trucks = [...board.trucks].sort((a, b) => (a.decal ? 0 : 1) - (b.decal ? 0 : 1) || (b.decal || '').localeCompare(a.decal || ''));
    const stack: Record<string, number> = {};
    const laneY = (id: number) => trucks.findIndex(t => t.id === id) * 92 + 46;
    const selected = sel && stage === 'board' ? vm.items.find(i => i.t === sel) : null;
    let overlay: ReactNode = null;
    if (selected && selected.lane != null && selected.date && gridW > 0) {
      const px = (d: string) => ((Math.min(days - 1, Math.max(0, dayNo(d) - lo)) + 0.5) / days) * gridW;
      const end: [number, number] = [px(selected.date), laneY(selected.lane)];
      const form = pickerT === selected.t && r ? r.formFor(selected.t).clients : [];
      const fromForm = form.map(c => {
        const v = visits.find(y => String(y.visit_id) === String(c._visit_id ?? ''));
        return { date: String(c._visit_date || ''), vehicle: v?.vehicle_id ?? selected.lane };
      }).filter(s => s.date);
      const stops = fromForm.length ? fromForm : board.stops.filter(s => s.ticket === selected.t && s.pickup_date).map(s => ({ date: String(s.pickup_date), vehicle: s.vehicle_id }));
      const seen: Record<string, number> = {};
      const dots = stops.map(s => {
        const veh = s.vehicle != null && trucks.some(t => t.id === s.vehicle) ? s.vehicle : (selected.lane as number);
        const key = `${veh}|${s.date}`;
        seen[key] = (seen[key] || 0) + 1;
        return [px(s.date), laneY(veh) + 18 + (seen[key] - 1) * 7] as [number, number];
      });
      overlay = (
        <svg key={animRoute} className="lw-ov" aria-hidden="true" viewBox={`0 0 ${gridW} ${trucks.length * 92}`}>
          {dots.map(([a, b], k) => <path key={`p${k}`} pathLength={1} className="draw" d={`M${a} ${b} C ${a + (end[0] - a) * 0.5} ${b}, ${a + (end[0] - a) * 0.5} ${end[1]}, ${end[0]} ${end[1]}`} />)}
          {dots.map(([a, b], k) => <circle key={`c${k}`} cx={a} cy={b} r={3.5} />)}
        </svg>
      );
    }
    return (
      <>
        <div className="lw-grid" ref={gridRef}>
          <div className="lw-days">{labels.map(l => <span key={l.n} style={{ left: `${x(l.n)}%` }}>{l.text}</span>)}</div>
          {trucks.map(tr => {
            const pins = vm.placed.filter(i => i.lane === tr.id && i.date);
            return [
              <div className="lw-laneh" key={`h${tr.id}`}>{badge(tr)}<div>{tr.name}<small>{tr.decal || 'No decal'}</small></div></div>,
              <div className="lw-lane" key={`l${tr.id}`} style={{ '--lc': tr.color || '#64748b' } as CSSProperties}>
                {weekends.map(n => <i className="lw-we" key={n} style={{ left: `${((n - lo) / days) * 100}%`, width: `${100 / days}%` }} />)}
                {pins.map(it => {
                  const c = pinClass(it);
                  const on = sel === it.t;
                  const k = `${tr.id}|${it.date}`;
                  stack[k] = (stack[k] || 0) + 1;
                  const shift = [0, -29, 29, -14, 14][(stack[k] - 1) % 5];
                  const icon = pinIcon(c);
                  return (
                    <button type="button" key={it.t} className={`lw-pin ${c} ${on ? 'sel' : ''}`} style={{ left: `${x(dayNo(it.date))}%`, top: `calc(50% + ${shift}px)`, background: c.startsWith('ok') ? (tr.color || undefined) : undefined }}
                      aria-label={`Ticket ${it.t}, dumped ${md(it.date)}`} title={`#${it.t}, dumped ${md(it.date)}`} disabled={stage !== 'board'} onClick={() => pick(it.t)}>
                      {icon && <Ic d={icon} />}
                      {(on || c.startsWith('need')) && <span className="lw-tag">{it.t}</span>}
                    </button>
                  );
                })}
              </div>,
            ];
          })}
          {overlay}
        </div>
        <div className="lw-legend">
          <span><i style={{ background: 'var(--lw-ink2)' }} />Ready, in the truck&rsquo;s color</span>
          <span><i style={{ background: 'var(--lw-brand)' }} />Needs you</span>
          <span><i style={{ background: 'var(--lw-pur)' }} />Out of county</span>
          <span><i style={{ boxShadow: 'inset 0 0 0 2px var(--lw-line2)' }} />Left off</span>
        </div>
      </>
    );
  }
  function rowFor(it: Item) {
    const c = pinClass(it);
    const chip = it.need ? <span className="lw-chip warn">Needs you</span>
      : it.on ? (it.ooc ? <span className="lw-chip brow">Out of county</span> : <span className="lw-chip ok">Ready</span>)
        : it.held ? <span className="lw-chip warn">Size</span> : <span className="lw-chip idle">Left off</span>;
    const names = (it.l?.facilities || []).map(f => String(f.name || ''));
    const label = it.need ? WHY[it.need.kind] : names.length ? `${names[0]}${names.length > 1 ? ` and ${names.length - 1} more` : ''}` : 'No stops yet';
    return (
      <button type="button" key={it.t} className={`lw-row ${sel === it.t ? 'sel' : ''}`} data-pin={c} onClick={() => pick(it.t)}>
        {badge(truckById(it.lane))}
        <span className="bd"><b>#{it.t}</b><small>{label}</small></span>
        {chip}
      </button>
    );
  }
  function renderList() {
    if (!vm) return null;
    const rank = (i: Item) => vm.queue.findIndex(q => q === i.need);
    const need = vm.items.filter(i => i.need).sort((a, b) => rank(a) - rank(b));
    const rest = vm.placed.filter(i => !i.need);
    const byDay = new Map<string, Item[]>();
    rest.forEach(i => { byDay.set(i.date, [...(byDay.get(i.date) || []), i]); });
    return (
      <div className="lw-lst">
        {need.length > 0 && <><div className="lw-dh need">Needs you</div>{need.map(rowFor)}</>}
        {[...byDay.keys()].sort().reverse().map(d => <div key={d} className="lw-q"><div className="lw-dh">Dumped {md(d)}</div>{(byDay.get(d) || []).map(rowFor)}</div>)}
      </div>
    );
  }
  function renderQueueStrip() {
    if (!vm || !vm.queue.length) return null;
    return (
      <div className="lw-q">
        <div className="lw-sect">Needs you <small>{int(vm.queue.length)} left</small></div>
        {vm.queue.map(q => {
          const k = keyOf(q);
          const it = vm.items.find(i => i.t === k);
          return (
            <button type="button" key={`${q.kind}${k}`} className={`lw-row ${sel === k ? 'sel' : ''}`} onClick={() => pick(k)}>
              {badge(truckById(it?.lane ?? null))}
              <span className="bd"><b>{k === MONTH_KEY ? monthLabel(r?.ym) : `#${k}`}</b><small>{WHY[q.kind]}</small></span>
              {it?.date && <span className="when">{md(it.date)}</span>}
            </button>
          );
        })}
      </div>
    );
  }

  // ---- The steps and the header --------------------------------------------------------------------------------------------------
  function renderHead(n: number) {
    if (!r) return null;
    const months = [shiftYm(r.ym, -1), r.ym, shiftYm(r.ym, 1)];
    const labels = ['Invoice', 'Tickets', 'Check and download', 'Record'];
    return (
      <>
        <div className="lw-fhead">
          <button type="button" className="lw-b q" onClick={() => { if (saveTimer.current) { clearTimeout(saveTimer.current); void saveNow(); } rulesRef.current = null; void loadHome(); }}><Ic d={I.back} /> Monthly Report</button>
          <h1>{monthLabel(r.ym)}</h1>
          {stage !== 'wait' && (
            <div className="lw-months" role="group" aria-label="Report month">
              {months.map(m => <button type="button" key={m} className={m === r.ym ? 'on' : ''} aria-pressed={m === r.ym} onClick={() => { r.applyMonth(m); bump(); if (savedAt) scheduleSave(); }}>{MONTHS[+m.slice(5, 7) - 1].slice(0, 3)}</button>)}
            </div>
          )}
          {savedAt && !saveErr && <span className="lw-saved"><Ic d={I.check} /> Saved {clock(savedAt)}{savedBy && savedBy !== ov?.me.name ? ` by ${savedBy}` : ''}</span>}
        </div>
        {saveErr && <div className="lw-err"><span>{saveErr}</span><button type="button" className="lw-b" onClick={() => void saveNow()}>Save again</button></div>}
        <div className="lw-steps" aria-label="Steps">
          {labels.map((t, i) => (
            <span key={t} style={{ display: 'contents' }}>
              {i > 0 && <span className={`lw-rt ${i < n - 1 ? 'done' : ''}`} />}
              <span className={`lw-st ${i + 1 < n ? 'done' : i + 1 === n ? 'now' : ''}`}><i>{i + 1 < n ? <Ic d={I.check} style={{ width: 11, height: 11 }} /> : i + 1}</i><span>{t}</span></span>
            </span>
          ))}
        </div>
      </>
    );
  }
  // ---- The invoice box, before and after ----------------------------------------------------------------------------------------------
  function renderDrop() {
    if (!r) return null;
    const list = parseTickets(r.invoiceText) || [];
    const onFile = (f?: File | null) => { if (f) void readFile(f); };
    return (
      <>
        <label className={`lw-drop ${overDrop ? 'over' : ''}`} onDragOver={e => { e.preventDefault(); setOverDrop(true); }} onDragLeave={() => setOverDrop(false)}
          onDrop={e => { e.preventDefault(); setOverDrop(false); onFile(e.dataTransfer.files[0]); }}>
          <span className="lw-ic"><Ic d={I.file} /></span>
          <b>{busy === 'reading' ? 'Reading the invoice' : 'Drop the county’s invoice here'}</b>
          <small>PDF is best, a photo works too. It reads the number, tickets, dates and trucks.</small>
          <input type="file" hidden accept=".pdf,image/*" disabled={busy === 'reading' || !canEdit} onChange={e => { onFile(e.target.files?.[0]); e.target.value = ''; }} />
          <span className="lw-b p" style={{ marginTop: 6 }}>Choose a file</span>
        </label>
        <div><button type="button" className="lw-b q" onClick={() => setByHand(!byHand)}>No file? Type the ticket numbers by hand</button></div>
        {byHand && (
          <div className="lw-card" style={{ padding: '12px 14px', display: 'grid', gap: 8 }}>
            {renderAddNumber()}
            {list.length > 0 && <div className="lw-nums">{list.map(n => renderNum(n))}</div>}
            <label className="lw-fld" style={{ maxWidth: 260 }}>Invoice number <small>From the top of the paper</small>
              <input className="lw-inp" value={r.invoiceId} onChange={e => act(() => r.setInvoiceId(e.target.value))} />
            </label>
            <div><button type="button" className="lw-b p" disabled={!list.length} onClick={() => { setStage('board'); advance(); }}>Continue with {count(list.length, 'ticket')}</button></div>
          </div>
        )}
      </>
    );
  }
  function renderAddNumber() {
    if (!r) return null;
    return (
      <>
        <div className="lw-addrow">
          <input className="lw-inp" inputMode="numeric" placeholder="Ticket number" aria-label="Ticket number from the paper" value={typedNum} onChange={e => setTypedNum(e.target.value)} />
          <select className="lw-inp" aria-label="Truck" value={typedDecal} onChange={e => setTypedDecal(e.target.value)}>
            <option value="">Truck from the paper</option>
            {Object.keys(DECAL_GALLONS).map(d => <option key={d} value={d}>{decalLine(d)}</option>)}
          </select>
          <button type="button" className="lw-b" onClick={() => act(() => {
            const res = r.addInvTicket(typedNum, typedDecal);
            setTypedNote(res.ok ? '' : res.text);
            if (res.ok) { setTypedNum(''); setTypedDecal(''); }
          })}>Add</button>
        </div>
        {typedNote && <div className="lw-warnbox">{typedNote}</div>}
      </>
    );
  }
  function renderNum(n: string) {
    if (!r) return null;
    const missing = r.indexOfTicket(n) < 0;
    return (
      <span key={n} className={`lw-n ${missing ? 'miss' : ''}`}>
        <small>{(r.INV_DECALS[n] || r.PAPER_DECALS[n] || '').slice(-2)}</small>{n}
        <button type="button" className="lw-rm" aria-label={`Take ${n} off the invoice`} onClick={() => act(() => r.removeInvTicket(n))}><Ic d={I.x} /></button>
      </span>
    );
  }
  function renderInvoiceFold() {
    if (!r || !vm) return null;
    const list = vm.invoice || [];
    const status = r.invoiceStatus;
    const ocr = ui.parsed?.source === 'ocr';
    return (
      <details className="lw-fold">
        <summary>{r.invoiceId.trim() ? `Invoice ${r.invoiceId.trim()}` : 'The invoice'} <small>{count(list.length, 'ticket')}{ui.invoiceName ? `, read from ${ui.invoiceName}` : ''}</small><span className="sp lw-chip idle">Change</span></summary>
        <div className="in">
          {status && <div className={ocr || status.tone === 'bad' ? 'lw-warnbox' : 'lw-gps'}>{plain(status.text)}</div>}
          <div className="lw-inv2">
            <div style={{ display: 'grid', gap: 8 }}>
              <div className="lw-nums">{list.map(n => renderNum(n))}</div>
              {renderAddNumber()}
            </div>
            <div style={{ display: 'grid', gap: 8 }}>
              <label className="lw-fld">Invoice number<input className="lw-inp" value={r.invoiceId} onChange={e => act(() => r.setInvoiceId(e.target.value))} /></label>
              <label className="lw-b" style={{ cursor: 'pointer' }}>Drop a different invoice
                <input type="file" hidden accept=".pdf,image/*" onChange={e => { const f = e.target.files?.[0]; e.target.value = ''; if (f) void readFile(f); }} />
              </label>
            </div>
          </div>
        </div>
      </details>
    );
  }

  // ---- Stages -----------------------------------------------------------------------------------------------------------------------------
  function renderWork() {
    if (!vm || !r) return null;
    const pre = stage === 'start' || stage === 'reading';
    const v = view || (compact || !board ? 'list' : 'board');
    const needN = vm.queue.length;
    const total = vm.placed.length;
    if (compact && !pre && sel && !(pendingD === null && !vm.items.some(i => i.t === sel))) return <div className="lwt" data-stage={stage}>{renderPanel()}</div>;
    const oocOn = vm.onReport.filter(i => i.ooc).length;
    return (
      <div className="lwt" data-stage={stage}>
        {renderHead(pre ? 1 : 2)}
        {(!sel || pre) && errLine}
        {boardErr && <div className="lw-err"><span>The board could not load: {boardErr}</span><button type="button" className="lw-b" onClick={() => void loadBoard(r)}>Try again</button></div>}
        {pull > 0 && (
          <div className="lw-warnbox" style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap' }}>
            <span>{count(pull, 'new ticket')} came in since this work was saved.</span>
            <button type="button" className="lw-b" style={{ marginLeft: 'auto' }} onClick={() => { pullFresh().catch(e => setErr(msg(e))); }}>Pull them in</button>
          </div>
        )}
        {vm.notes.filter(n => ['block', 'warn'].includes(n.tone)).map(n => <div className="lw-warnbox" key={`${n.rule}${n.detail}`}><b>{plain(n.title)}.</b> {plain(n.detail)}</div>)}
        {stage === 'start' && renderDrop()}
        {stage === 'reading' && (
          <div className="lw-card" style={{ padding: '12px 14px' }}>
            <div className="lw-sect">Reading {ui.invoiceName || 'the invoice'} <small>{Math.min(readN, (vm.invoice || []).length)} of {(vm.invoice || []).length} rows</small></div>
            {(vm.invoice || []).slice(0, readN).slice(-3).map(n => (
              <div className="lw-invr" key={n}><b>{n}</b><span>{r.INV_DECALS[n] || ''}</span><span className="sp">{md(r.INV_DATES[n])}</span></div>
            ))}
          </div>
        )}
        {stage === 'board' && ui.parsed?.source === 'ocr' && (
          <div className="lw-warnbox"><b>This invoice was a scan, so it was read by OCR.</b> Count the ticket rows on the paper against the {count((vm.invoice || []).length, 'ticket')} read here, and check every digit.</div>
        )}
        {stage === 'board' && renderInvoiceFold()}
        <div className="lw-work">
          <div className="lw-col">
            <div className="lw-board">
              <div className="lw-btop">
                <b>{pre ? 'Tickets waiting to be matched' : `${count(total, 'ticket')} this month`}</b>
                {!compact && !pre && board && (
                  <div className="lw-seg" role="group" aria-label="View">
                    <button type="button" className={v === 'board' ? 'on' : ''} aria-pressed={v === 'board'} onClick={() => setView('board')}>Board</button>
                    <button type="button" className={v === 'list' ? 'on' : ''} aria-pressed={v === 'list'} onClick={() => setView('list')}>List</button>
                  </div>
                )}
                {!pre && canEdit && <button type="button" className={`lw-b q`} style={compact ? { marginLeft: 'auto' } : undefined} disabled={busy === 'reload'} onClick={() => { setBusy('reload'); pullFresh().catch(e => setErr(msg(e))).finally(() => setBusy('')); }}><Ic d={I.redo} /> Reload</button>}
              </div>
              {compact && pre ? <div className="lw-lst"><div className="lw-dh">Loaded and waiting: {count(vm.items.length, 'ticket')}</div></div> : v === 'board' ? renderBoard() : renderList()}
              {vm.older.length > 0 && (
                <details className="lw-older">
                  <summary style={{ cursor: 'pointer' }}>{count(vm.older.length, 'other ticket')} {vm.older.length === 1 ? 'is' : 'are'} waiting for {vm.older.length === 1 ? 'its' : 'their'} own month, not on this report.</summary>
                  <div className="lw-lst" style={{ padding: '8px 0 0' }}>{vm.older.map(rowFor)}</div>
                </details>
              )}
            </div>
            {!pre && !compact && renderQueueStrip()}
            {!pre && compact && vm.queue.length === 0 && renderAllSet()}
            {!pre && Object.keys(r.ARCHIVED).length > 0 && (
              <details className="lw-fold"><summary>Archived <small>{Object.keys(r.ARCHIVED).length}</small></summary>
                <div className="in">{Object.keys(r.ARCHIVED).map(t => (
                  <div className="lw-find" key={t} style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                    <span style={{ flex: 1 }}><b>#{t}</b><small>{plain(r.ARCHIVED[t].reason)}{r.ARCHIVED[t].by ? `, by ${r.ARCHIVED[t].by}` : ''}</small></span>
                    {canEdit && <button type="button" className="lw-b" onClick={async () => {
                      setErr('');
                      try { const j = await okJson<FetchResponse>(await api.post('unarchive', { ticket: t })); act(() => r.applyRestored(t, j)); } catch (e) { setErr(msg(e)); }
                    }}>Restore</button>}
                  </div>
                ))}</div>
              </details>
            )}
          </div>
          {compact ? null : pre ? (
            <aside className="lw-panel">
              <div className="lw-ph"><div className="lw-pt"><b>What happens next</b></div>
                <p>The invoice decides which tickets go on the report. Each row it reads lights up its dump on the board. What can&rsquo;t be matched comes to you here, one at a time, already filled in.</p>
              </div>
            </aside>
          ) : renderPanel()}
        </div>
        {pre ? (
          <div className="lw-bar"><span className="tx">{stage === 'reading' ? 'Matching the invoice to our tickets' : <><b>{oocOn}</b> on this report so far, the out-of-county loads</>}</span></div>
        ) : (
          <div className="lw-bar">
            <span className="tx">{needN ? <><b>{needN} need{needN === 1 ? 's' : ''} you</b>, </> : <><b>All decided</b>, </>}<b>{int(vm.onReport.length)}</b> on this report, <b>{int(vm.gallons)}</b> gal</span>
            <span className="lw-prog" role="img" aria-label={`${total - needN} of ${total} decided`}><i style={{ width: `${total ? (Math.max(0, total - needN) / total) * 100 : 0}%` }} /></span>
            <span className="sp"><button type="button" className="lw-b p" disabled={!!needN || busy === 'check' || !canEdit} onClick={() => void runCheck()}>{busy === 'check' ? 'Checking' : 'Run the check'}</button></span>
          </div>
        )}
      </div>
    );
  }

  function renderCheck() {
    if (!vm || !r || !preview) return null;
    const review = (preview.findings || []).filter(f => !f.expected);
    const byRule = new Map<string, Finding[]>();
    review.forEach(f => byRule.set(f.rule, [...(byRule.get(f.rule) || []), f]));
    const strong = [...byRule.keys()].filter(k => ruleInfo(k).tone === 'block');
    const stale = r.flagsAreStale();
    return (
      <div className="lwt" data-stage="check">
        {renderHead(3)}
        {errLine}
        <div className="lw-chk">
          <div><iframe className="lw-form" title="The county's form, as it will be filed" sandbox="" srcDoc={preview.html} /></div>
          <div className="lw-side">
            <div className="lw-big">
              <div><b>{int(vm.onReport.length)}</b><span>tickets</span></div>
              <div><b>{int(vm.gallons)}</b><span>gallons</span></div>
            </div>
            {strong.length === 0
              ? <div className="lw-okbox"><Ic d={I.check} /><div>The bot&rsquo;s checks found nothing that stops this<small>Read what is left below, then compare the form to the paper.</small></div></div>
              : <div className="lw-warnbox"><b>{count(strong.length, 'thing')} to look at before approving.</b> They are at the top of the list below.</div>}
            {stale
              ? <div className="lw-warnbox">Something changed since this check, so it no longer matches. Run it again.</div>
              : tile(r.approved, 'This matches the paper', 'Changing anything locks this again.', () => act(() => r.setApproved(!r.approved)))}
            <div className="lw-acts">
              <button type="button" className="lw-b" onClick={() => setStage('board')}>Back to the tickets</button>
              {stale
                ? <button type="button" className="lw-b p" disabled={busy === 'check'} onClick={() => void runCheck()}>Run the check again</button>
                : <button type="button" className="lw-b p" disabled={!r.canGenerate() || busy === 'generate'} onClick={() => void generate()}><Ic d={I.down} /> {busy === 'generate' ? 'Building the file' : 'Download the Excel file'}</button>}
            </div>
            <div style={{ fontSize: 12, color: 'var(--lw-ink2)' }}>The file is saved with the report. Nothing goes to the county from here.</div>
            {byRule.size > 0 && (
              <details className="lw-fold" open={strong.length > 0}>
                <summary>What the check says <small>{review.length}</small></summary>
                <div className="in">
                  {[...byRule.entries()].sort((a, b) => (ruleInfo(a[0]).tone === 'block' ? 0 : 1) - (ruleInfo(b[0]).tone === 'block' ? 0 : 1)).map(([rule, list]) => (
                    <div className="lw-find" key={rule}><b>{plain(ruleInfo(rule).title)}{list.length > 1 ? `, ${list.length}` : ''}</b><small>{plain(ruleInfo(rule).explain)}</small>
                      {list.slice(0, 6).map((f, i) => <small key={i}>{f.row_key ? `#${f.row_key}: ` : ''}{plain(f.detail)}</small>)}
                      {list.length > 6 && <small>and {list.length - 6} more.</small>}
                    </div>
                  ))}
                </div>
              </details>
            )}
          </div>
        </div>
      </div>
    );
  }
  function renderWait() {
    if (!r) return null;
    const g = r.GENERATED;
    return (
      <div className="lwt" data-stage="wait">
        {renderHead(4)}
        {errLine}
        <div className="lw-hero">
          <div><span className="lw-chip warn">Drafted, not filed</span><div className="lw-mo" style={{ fontSize: 30 }}>Waiting for the county</div><div className="lw-due">Email the file to the county. Come back here when they approve it.</div></div>
          <div className="lw-go"><div className="lw-acts">
            {draftId != null && <button type="button" className="lw-b" disabled={busy === `dl${draftId}`} onClick={() => void download(draftId, `LWT_report_${r.ym}.xlsx`)}><Ic d={I.down} /> Download again</button>}
            {g?.id && canEdit && <button type="button" className="lw-b p" onClick={() => setDialog({ kind: 'record', id: +(g.id as string), tickets: g.list || [], label: monthLabel(g.ym), invoice: g.invoice, period: g.ym })}>Record as filed</button>}
          </div></div>
        </div>
        {!g?.id && <div className="lw-err"><span>The file downloaded, but the service did not save a record of it. Generate it again before recording it.</span></div>}
        <div><button type="button" className="lw-b q" onClick={() => setStage('check')}><Ic d={I.back} /> Back to the check</button></div>
      </div>
    );
  }
  function renderHome() {
    if (!ov) {
      return (
        <div className="lwt">
          <div className="lw-head"><h1>Monthly Report</h1></div>
          {err ? <div className="lw-err" role="alert"><span>{err}</span><button type="button" className="lw-b" onClick={() => void loadHome()}>Try again</button></div> : <div className="lw-wait">Loading</div>}
        </div>
      );
    }
    const c = ov.current;
    const ym = ymOfLabel(c.period);
    const mine = ov.rows.filter(x => x.ym === ym && !x.discarded);
    const filed = mine.find(x => x.filed);
    const draft = mine.find(x => !x.filed);
    const visible = ov.rows.filter(x => showDiscarded || !x.discarded);
    const hiddenN = ov.rows.filter(x => x.discarded).length;
    const choosable = visible.filter(x => x.report);
    const chosen = choosable.filter(x => picked.has(x.id));
    const allPicked = choosable.length > 0 && chosen.length === choosable.length;
    const togglePicked = (id: number) => setPicked(p => { const n = new Set(p); if (n.has(id)) n.delete(id); else n.add(id); return n; });
    const tone = (t: string) => (t === 'ok' ? 'ok' : t === 'warn' ? 'warn' : 'idle');
    const recordDlg = (x: FilingRow): DialogState => ({ kind: 'record', id: x.id, tickets: x.tickets || [], label: x.period, invoice: x.invoice_id, period: x.ym });
    const actions = (x: FilingRow) => (
      <span className="lw-acts" style={{ justifyContent: 'flex-end' }}>
        {x.report && <button type="button" className="lw-b" aria-label={`View ${x.period}`} onClick={() => void openReport(x)}><Ic d={I.eye} /> View</button>}
        {!x.filed && !x.discarded && canEdit && <button type="button" className="lw-b" onClick={() => setDialog(recordDlg(x))}>Record as filed</button>}
        {!x.filed && !x.discarded && canEdit && <button type="button" className="lw-b q" onClick={() => setDialog({ kind: 'discard', id: x.id, label: x.period })}>Discard</button>}
        {!!x.discarded && canEdit && <button type="button" className="lw-b" disabled={busy === `re${x.id}`} onClick={() => void restoreRow(x.id)}>Restore</button>}
      </span>
    );
    return (
      <div className="lwt" data-stage="home">
        <div className="lw-head"><h1>Monthly Report</h1><p>The county&rsquo;s form ST. One per month, emailed to the county by the 20th.</p></div>
        {errLine}
        {homeNote && <div className="lw-okbox"><Ic d={I.check} /><div>{homeNote}</div></div>}
        <div className="lw-hero">
          <div>
            <span className={`lw-chip ${tone(c.tone)}`}>{filed && <Ic d={I.check} />}{homeWork && !draft && !filed ? 'In progress' : c.badge}</span>
            <div className="lw-mo">{c.period}</div>
            <div className="lw-due">{filed ? `Recorded${filed.who ? ` by ${filed.who}` : ''}.` : `Due ${c.due}, ${count(c.days_left, 'day')} left`}</div>
          </div>
          <div className="lw-go">
            <div className="lw-acts">
              {filed && filed.report && <button type="button" className="lw-b" onClick={() => void download(filed.id, `LWT_report_${filed.ym}.xlsx`)}><Ic d={I.down} /> Download</button>}
              {draft && canEdit && <button type="button" className="lw-b" onClick={() => setDialog(recordDlg(draft))}>Record as filed</button>}
              {homeWork && !filed && !draft && canEdit && <button type="button" className="lw-b q" onClick={() => setDialog({ kind: 'startover', period: ym, label: c.period })}>Start over</button>}
              {!filed && canEdit && <button type="button" className={`lw-b ${draft ? '' : 'p'}`} disabled={!ym || busy === 'open' || busy === 'home'} onClick={() => void openFiling(ym)}>{busy === 'open' ? 'Opening' : homeWork ? 'Continue filing' : draft ? 'Open the tickets' : 'Start filing'}</button>}
            </div>
            {!canEdit && <span className="lw-hint">You can see the history here. Filing needs Edit in the DERM Tracker.</span>}
            {canEdit && !filed && !draft && <span className="lw-hint">{homeWork ? `Saved ${clock(homeWork.at)}${homeWork.by ? ` by ${homeWork.by}` : ''}.` : 'Everything unreported is already loaded. Have the county’s invoice ready.'}</span>}
          </div>
        </div>
        <div className="lw-hist">
          <h3 className="lw-histt">Filing history {hiddenN > 0 && <button type="button" className="lw-b q" onClick={() => setShowDiscarded(!showDiscarded)}>{showDiscarded ? 'Hide' : 'Show'} {count(hiddenN, 'discarded draft')}</button>}</h3>
          <div className="lw-htbl" role="table" aria-label="Filing history">
            <div className="lw-hrow lw-hhead" role="row">
              <span className="lw-hck" role="columnheader">{choosable.length > 0 && <label className="lw-cku"><input type="checkbox" className="lw-ck" aria-label="Select all" checked={allPicked} ref={el => { if (el) el.indeterminate = chosen.length > 0 && !allPicked; }} onChange={() => setPicked(new Set(allPicked ? [] : choosable.map(x => x.id)))} /></label>}</span>
              <span className="lw-hper" role="columnheader">Period</span>
              <span className="lw-hcount" aria-live="polite">{chosen.length ? `${chosen.length} selected` : 'Select all'}</span>
              <span className="lw-hinv" role="columnheader">Invoice</span>
              <span className="lw-hn" role="columnheader">Tickets</span>
              <span className="lw-hn" role="columnheader">Gallons</span>
              <span className="lw-hn" role="columnheader">Fee</span>
              <span className="lw-hst" role="columnheader">Status</span>
              <span className="lw-hwho" role="columnheader">Handled by</span>
              <span className="lw-hact" role="columnheader"><button type="button" className={`lw-b ${chosen.length ? 'p' : ''}`} disabled={!chosen.length || busy === 'dlmany'} onClick={() => void downloadPicked(chosen)}><Ic d={I.down} /> {busy === 'dlmany' ? 'Downloading' : `Download${chosen.length ? ` ${chosen.length}` : ''}`}</button></span>
            </div>
            {visible.map(x => (
              <div key={x.id} role="row" className={`lw-hrow ${picked.has(x.id) && x.report ? 'on' : ''} ${x.discarded ? 'off' : ''} ${!x.filed && !x.discarded ? 'draft' : ''}`} style={{ '--rail': x.tone === 'ok' ? 'var(--lw-ok)' : x.tone === 'warn' ? 'var(--lw-warn)' : 'var(--lw-line2)' } as CSSProperties}>
                <span className="lw-hck" role="cell">{x.report && <label className="lw-cku"><input type="checkbox" className="lw-ck" aria-label={`Select ${x.period}`} checked={picked.has(x.id)} onChange={() => togglePicked(x.id)} /></label>}</span>
                <span className="lw-hper" role="cell"><b>{x.period}</b><small>{x.invoice_id || 'No invoice'}</small></span>
                <span className="lw-hinv" role="cell">{x.invoice_id || 'None'}</span>
                <span className="lw-hn t" role="cell" data-l="Tickets">{x.ticket_count}</span>
                <span className="lw-hn g" role="cell" data-l="Gallons">{x.gallons}</span>
                <span className="lw-hn f" role="cell" data-l="Fee">{x.fee}</span>
                <span className="lw-hst" role="cell"><span className={`lw-chip ${tone(x.tone)}`}>{x.filed && <Ic d={I.check} />}{x.status_text}</span></span>
                <span className="lw-hwho" role="cell">{x.who && <><span className="lw-hav" aria-hidden="true">{x.who[0].toUpperCase()}</span><span><b>{x.who}</b><small>{mdy(x.when)}</small></span></>}</span>
                <span className="lw-hact" role="cell">{actions(x)}</span>
              </div>
            ))}
            {!visible.length && <div className="lw-wait">No filings yet.</div>}
          </div>
        </div>
      </div>
    );
  }
  function renderDialog() {
    if (!dialog) return null;
    if (dialog.kind === 'record') {
      return (
        <div className="lwt lw-scrim" role="dialog" aria-modal="true" aria-label="Record as filed" onKeyDown={e => { if (e.key === 'Escape') closeDialog(); }}>
          <div className="lw-dlg">
            <h3>Record {dialog.label} as filed?</h3>
            <p>Do this once the county has approved it. These tickets then count as reported, and a filing cannot be taken back.</p>
            <div className="lw-read">
              <span>Invoice</span><b>{dialog.invoice || 'None'}</b>
              <span>Tickets</span><b>{int(dialog.tickets.length)}</b>
              <span>Filed by</span><b><span className="lw-av">{(ov?.me.name || '?')[0]}</span> {ov?.me.name}, from your sign-in</b>
            </div>
            {dlgErr && <div className="lw-warnbox">{dlgErr}</div>}
            <div className="lw-acts">
              <button type="button" className="lw-b" autoFocus onClick={closeDialog}>Cancel</button>
              <button type="button" className="lw-b p" disabled={busy === 'record'} onClick={() => void record()}>{busy === 'record' ? 'Recording' : 'Record as filed'}</button>
            </div>
          </div>
        </div>
      );
    }
    if (dialog.kind === 'startover') {
      return (
        <div className="lwt lw-scrim" role="dialog" aria-modal="true" aria-label={`Start ${dialog.label} over`} onKeyDown={e => { if (e.key === 'Escape') closeDialog(); }}>
          <div className="lw-dlg">
            <h3>Start {dialog.label} over?</h3>
            <p>This clears the invoice and the answers saved for this month, and it opens fresh from the live tickets. A trap size saved on a property stays, and so do tickets left off the report.</p>
            {dlgErr && <div className="lw-warnbox">{dlgErr}</div>}
            <div className="lw-acts">
              <button type="button" className="lw-b" autoFocus onClick={closeDialog}>Keep my work</button>
              <button type="button" className="lw-b p" disabled={busy === 'startover'} onClick={() => void startOver()}>{busy === 'startover' ? 'Clearing' : 'Start over'}</button>
            </div>
          </div>
        </div>
      );
    }
    const reasons = [['superseded', 'Replaced by a newer draft'], ['duplicate', 'A duplicate'], ['test', 'Test data'], ['other', 'Other']];
    return (
      <div className="lwt lw-scrim" role="dialog" aria-modal="true" aria-label="Discard this draft" onKeyDown={e => { if (e.key === 'Escape') closeDialog(); }}>
        <div className="lw-dlg">
          <h3>Discard the {dialog.label} draft?</h3>
          <p>It leaves the list. Nothing is deleted, and Restore brings it back.</p>
          <div>{reasons.map(([k, v]) => tile(dlgReason === k, v, '', () => setDlgReason(k), k))}</div>
          {dlgReason === 'other' && <label className="lw-fld">Say why<input className="lw-inp" value={dlgText} onChange={e => setDlgText(e.target.value)} /></label>}
          {dlgErr && <div className="lw-warnbox">{dlgErr}</div>}
          <div className="lw-acts">
            <button type="button" className="lw-b" autoFocus onClick={closeDialog}>Cancel</button>
            <button type="button" className="lw-b p" disabled={busy === 'discard' || !dlgReason || (dlgReason === 'other' && !dlgText.trim())} onClick={() => void discard()}>Discard</button>
          </div>
        </div>
      </div>
    );
  }

  function renderViewer() {
    if (!viewing) return null;
    const { row, page, err: viewErr } = viewing;
    const said = [row.invoice_id ? `Invoice ${row.invoice_id}` : 'No invoice', count(row.ticket_count, 'ticket'), [row.status_text, row.who && `by ${row.who}`, row.when && `on ${mdy(row.when)}`].filter(Boolean).join(' ')].join(', ');
    return (
      <div className="lwt lw-scrim lw-vw" role="dialog" aria-modal="true" aria-label={`${row.period} report`} onKeyDown={e => { if (e.key === 'Escape') setViewing(null); }} onClick={e => { if (e.target === e.currentTarget) setViewing(null); }}>
        <div className="lw-vwbox">
          <div className="lw-vwhead">
            <div><b>{row.period}</b><small>{said}</small></div>
            <button type="button" className="lw-b" autoFocus onClick={() => setViewing(null)}><Ic d={I.x} /> Close</button>
          </div>
          <div className="lw-vwbody" ref={viewBody}>
            {viewErr ? <div className="lw-err" style={{ margin: 16, alignSelf: 'start' }}><span>{viewErr}</span><button type="button" className="lw-b" onClick={() => void openReport(row)}>Try again</button></div>
              : !page ? <div className="lw-wait">Opening the report</div>
                : <iframe title={`${row.period} report`} sandbox="" srcDoc={fitted(page, viewW)} />}
          </div>
        </div>
      </div>
    );
  }

  return (
    <>
      {stage === 'loading' ? <div className="lwt"><div className="lw-head"><h1>Monthly Report</h1></div><div className="lw-wait">Loading</div></div>
        : stage === 'home' || !r ? renderHome()
          : stage === 'check' ? renderCheck()
            : stage === 'wait' ? renderWait()
              : renderWork()}
      {renderDialog()}
      {renderViewer()}
    </>
  );
}
