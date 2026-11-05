// Which filings the Monthly Report's history table shows, and in what order (Fred, 2026-11-05: "make the table have filters and sorts", design C).
// Downloaded byte-identical into the DERM Tracker with the page: change it here, never there. Check: history-rows.check.mjs.
// It only hides and orders rows that are already on the screen. Nothing here touches what is filed.

export interface HistoryRow {
  period: string; ym: string; invoice_id: string | null; ticket_count: number; gallons: string; fee: string;
  status_text: string; who: string | null; when: string | null; filed: boolean; discarded: unknown;
}
export type Show = 'live' | 'filed' | 'draft' | 'discarded';
export type SortKey = 'period' | 'invoice' | 'tickets' | 'gallons' | 'fee' | 'status' | 'who' | 'handled';
export type SortDir = 'asc' | 'desc';
export interface HistoryView { show: Show; who: string; year: string; q: string; sort: SortKey; dir: SortDir }

// What the table shows on arrival: filed and drafts, newest month first, as it always has.
export const DEFAULT_VIEW: HistoryView = { show: 'live', who: '', year: '', q: '', sort: 'period', dir: 'desc' };

// A column's first click: words read A to Z, everything else starts with the most or the newest.
export const firstDir = (key: SortKey): SortDir => (key === 'invoice' || key === 'status' || key === 'who' ? 'asc' : 'desc');

export function showsRow(x: HistoryRow, show: Show): boolean {
  if (show === 'discarded') return !!x.discarded;
  if (x.discarded) return false;
  return show === 'live' || (show === 'filed') === !!x.filed;
}

export const yearOf = (x: HistoryRow) => x.ym.slice(0, 4);

// "53,400" and "$223.74" sort as numbers: as text, 9,000 would come after 53,400.
export const numberOf = (s: string | number | null | undefined) => Number(String(s ?? '').replace(/[^0-9.-]/g, '')) || 0;

const sortValue = (x: HistoryRow, key: SortKey): string | number | null => {
  switch (key) {
    case 'period': return x.ym;
    case 'invoice': return x.invoice_id ? x.invoice_id.toLowerCase() : null;
    case 'tickets': return x.ticket_count;
    case 'gallons': return numberOf(x.gallons);
    case 'fee': return numberOf(x.fee);
    case 'status': return x.status_text.toLowerCase();
    case 'who': return x.who ? x.who.toLowerCase() : null;
    case 'handled': return x.when || null;
  }
};

export function historyRows<T extends HistoryRow>(rows: T[], v: HistoryView): T[] {
  const words = v.q.toLowerCase().split(/\s+/).filter(Boolean);
  const kept = rows.filter(x => {
    if (!showsRow(x, v.show) || (v.who && x.who !== v.who) || (v.year && yearOf(x) !== v.year)) return false;
    const text = [x.period, x.invoice_id, x.who].filter(Boolean).join(' ').toLowerCase();
    return words.every(w => text.includes(w));
  });
  const sign = v.dir === 'asc' ? 1 : -1;
  return kept
    .map((x, i) => ({ x, i, s: sortValue(x, v.sort) }))
    .sort((a, b) => {
      // A row with nothing in the sorted column goes last either way, then equal rows read newest month first.
      if (a.s === null || b.s === null) { if (a.s !== b.s) return a.s === null ? 1 : -1; }
      else if (a.s !== b.s) return (a.s < b.s ? -1 : 1) * sign;
      return b.x.ym.localeCompare(a.x.ym) || a.i - b.i;
    })
    .map(r => r.x);
}

// The filters that take rows away, for the Filters button's count and its pills. The search box shows itself.
export const filterCount = (v: HistoryView) => (v.show !== 'live' ? 1 : 0) + (v.who ? 1 : 0) + (v.year ? 1 : 0);
