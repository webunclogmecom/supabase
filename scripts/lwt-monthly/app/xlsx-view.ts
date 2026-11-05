// Draws a report's .xlsx on the Monthly Report page, for the View button (Fred, 2026-11-05: "a "View" button instead of Download").
// Downloaded byte-identical into the DERM Tracker with the page: change it here, never there.
// The app reads the same file Download gets, so what is viewed is what was filed, with no bot change and no library:
// the browser's own DecompressionStream opens the zip and its DOMParser reads the XML. It covers what the bot's template uses
// (inline and shared strings, number formats, merges, fills, borders, pictures). Check: xlsx-view.check.mjs.
// ponytail: no theme colours, dates as numbers or conditional formats, because the report has none. Add them if the template grows them.

export interface ReportPage { html: string; width: number }

const BORDER: Record<string, string> = {
  hair: '1px dotted #666', dotted: '1px dotted #000', dashed: '1px dashed #000', thin: '1px solid #000',
  medium: '2px solid #000', thick: '3px solid #000', double: '3px double #000',
};
const BUILTIN_FORMAT: Record<number, string> = { 1: '0', 2: '0.00', 3: '#,##0', 4: '#,##0.00' };

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const colNumber = (letters: string) => [...letters].reduce((n, c) => n * 26 + c.charCodeAt(0) - 64, 0);
// Colours and sizes reach a style attribute, so only a real ARGB value and a real number get through.
const argb = (v: string | null | undefined) => (v && /^[0-9a-f]{8}$/i.test(v) ? `#${v.slice(2)}` : null);
const baseName = (p: string) => p.split('/').pop() || p;
const tags = (n: Document | Element, t: string) => [...n.getElementsByTagName(t)];
const xml = (s: string) => new DOMParser().parseFromString(s, 'application/xml');

// The number as the file's own format prints it. General drops the float noise (87.9899999999999 is 87.99).
export function formatNumber(raw: string, code: string | undefined): string {
  const n = Number(raw);
  if (raw === '' || !Number.isFinite(n)) return raw;
  const m = code && /^(#,##)?0(\.(0+))?$/.exec(code);
  if (!m) return String(+n.toPrecision(12));
  return n.toLocaleString('en-US', { minimumFractionDigits: m[3]?.length ?? 0, maximumFractionDigits: m[3]?.length ?? 0, useGrouping: !!m[1] });
}

async function openZip(file: ArrayBuffer) {
  const view = new DataView(file);
  let end = file.byteLength - 22;
  while (end >= 0 && view.getUint32(end, true) !== 0x06054b50) end--;
  if (end < 0) throw new Error('This report file could not be read. Try Download instead.');
  const names = new TextDecoder();
  const entries = new Map<string, { method: number; size: number; at: number }>();
  let p = view.getUint32(end + 16, true);
  for (let i = view.getUint16(end + 10, true); i > 0; i--) {
    const nameLen = view.getUint16(p + 28, true);
    entries.set(names.decode(new Uint8Array(file, p + 46, nameLen)), { method: view.getUint16(p + 10, true), size: view.getUint32(p + 20, true), at: view.getUint32(p + 42, true) });
    p += 46 + nameLen + view.getUint16(p + 30, true) + view.getUint16(p + 32, true);
  }
  const bytes = async (name: string) => {
    const e = entries.get(name);
    if (!e) throw new Error(`This report file is missing ${baseName(name)}. Try Download instead.`);
    const start = e.at + 30 + view.getUint16(e.at + 26, true) + view.getUint16(e.at + 28, true);
    const raw = new Uint8Array(file, start, e.size);
    if (e.method === 0) return raw;
    return new Uint8Array(await new Response(new Blob([raw]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());
  };
  const text = async (name: string) => new TextDecoder().decode(await bytes(name));
  return { has: (name: string) => entries.has(name), bytes, text };
}

function readStyles(doc: Document) {
  const list = (parent: string) => [...(tags(doc, parent)[0]?.children ?? [])];
  const fonts = list('fonts').map(f => ({
    bold: tags(f, 'b').length > 0, italic: tags(f, 'i').length > 0,
    size: Number(tags(f, 'sz')[0]?.getAttribute('val')) || 11, color: argb(tags(f, 'color')[0]?.getAttribute('rgb')),
  }));
  const fills = list('fills').map(f => argb(tags(f, 'fgColor')[0]?.getAttribute('rgb')));
  const borders = list('borders').map(b => ['left', 'right', 'top', 'bottom'].map(side => {
    const line = BORDER[tags(b, side)[0]?.getAttribute('style') ?? ''];
    return line ? `border-${side}:${line};` : '';
  }).join(''));
  const custom = new Map(tags(doc, 'numFmt').map(n => [Number(n.getAttribute('numFmtId')), n.getAttribute('formatCode') ?? '']));
  return list('cellXfs').map(x => {
    const align = tags(x, 'alignment')[0];
    const id = Number(x.getAttribute('numFmtId')) || 0;
    const font = fonts[Number(x.getAttribute('fontId')) || 0];
    const fill = fills[Number(x.getAttribute('fillId')) || 0];
    const horizontal = align?.getAttribute('horizontal') ?? '';
    const vertical = align?.getAttribute('vertical') ?? '';
    const css = [
      font?.bold ? 'font-weight:700;' : '', font?.italic ? 'font-style:italic;' : '',
      font ? `font-size:${Math.round(font.size * 96 / 72 * 10) / 10}px;` : '', font?.color ? `color:${font.color};` : '',
      fill ? `background:${fill};` : '', /^(left|right|center)$/.test(horizontal) ? `text-align:${horizontal};` : '',
      vertical === 'center' ? 'vertical-align:middle;' : vertical === 'top' ? 'vertical-align:top;' : '',
      align?.getAttribute('wrapText') === '1' ? 'white-space:normal;' : '', borders[Number(x.getAttribute('borderId')) || 0] ?? '',
    ].join('');
    return { css, marks: !!(fill || borders[Number(x.getAttribute('borderId')) || 0]), format: custom.get(id) ?? BUILTIN_FORMAT[id] };
  });
}

// A picture sits on the page by its cell and offsets, in EMU. Its source is only ever a data: URL built here.
async function pictures(zip: Awaited<ReturnType<typeof openZip>>, sheetPath: string, colPx: number[], rowPx: number[]) {
  const rels = `xl/worksheets/_rels/${baseName(sheetPath)}.rels`;
  if (!zip.has(rels)) return '';
  const drawing = tags(xml(await zip.text(rels)), 'Relationship').find(r => /drawing$/.test(r.getAttribute('Type') ?? ''))?.getAttribute('Target');
  if (!drawing) return '';
  const name = `xl/drawings/${baseName(drawing)}`;
  const targets = new Map(tags(xml(await zip.text(`xl/drawings/_rels/${baseName(drawing)}.rels`)), 'Relationship').map(r => [r.getAttribute('Id'), r.getAttribute('Target') ?? '']));
  let out = '';
  for (const anchor of [...xml(await zip.text(name)).documentElement.children]) {
    const part = (el: Element | undefined, t: string) => Number(el?.getElementsByTagNameNS('*', t)[0]?.textContent) || 0;
    const from = anchor.getElementsByTagNameNS('*', 'from')[0];
    const blip = anchor.getElementsByTagNameNS('*', 'blip')[0];
    const target = targets.get(blip?.getAttribute('r:embed') ?? '');
    if (!from || !target) continue;
    const media = `xl/media/${baseName(target)}`;
    const mime = /\.png$/i.test(media) ? 'image/png' : /\.jpe?g$/i.test(media) ? 'image/jpeg' : null;
    if (!mime || !zip.has(media)) continue;
    const data = await zip.bytes(media);
    let bin = '';
    for (let i = 0; i < data.length; i += 0x8000) bin += String.fromCharCode(...data.subarray(i, i + 0x8000));
    let x = part(from, 'colOff') / 9525, y = part(from, 'rowOff') / 9525;
    for (let c = 1; c <= part(from, 'col'); c++) x += colPx[c] ?? 0;
    for (let r = 1; r <= part(from, 'row'); r++) y += rowPx[r] ?? 0;
    const ext = anchor.getElementsByTagNameNS('*', 'ext')[0];
    const w = Number(ext?.getAttribute('cx')) / 9525, h = Number(ext?.getAttribute('cy')) / 9525;
    out += `<img alt="" src="data:${mime};base64,${btoa(bin)}" style="position:absolute;left:${Math.round(x)}px;top:${Math.round(y)}px;${w ? `width:${Math.round(w)}px;` : ''}${h ? `height:${Math.round(h)}px;` : ''}">`;
  }
  return out;
}

function sheetTable(doc: Document, styles: ReturnType<typeof readStyles>, shared: string[]) {
  const widths = new Map<number, number>();
  for (const c of tags(doc, 'col')) {
    const hidden = c.getAttribute('hidden') === '1';
    for (let i = Number(c.getAttribute('min')); i <= Math.min(Number(c.getAttribute('max')), 200); i++) widths.set(i, hidden ? 0 : Number(c.getAttribute('width')));
  }
  const format = tags(doc, 'sheetFormatPr')[0];
  const defWidth = Number(format?.getAttribute('defaultColWidth')) || 8.43;
  const defHeight = Number(format?.getAttribute('defaultRowHeight')) || 15;
  const cells = new Map<string, { text: string; style: number }>();
  const heights = new Map<number, number>();
  let lastRow = 0, lastCol = 0;
  for (const row of tags(doc, 'row')) {
    const r = Number(row.getAttribute('r'));
    if (row.getAttribute('hidden') === '1') heights.set(r, 0);
    else if (row.getAttribute('ht')) heights.set(r, Number(row.getAttribute('ht')));
    for (const c of tags(row, 'c')) {
      const m = /^([A-Z]+)(\d+)$/.exec(c.getAttribute('r') ?? '');
      if (!m) continue;
      const col = colNumber(m[1]);
      const type = c.getAttribute('t') ?? 'n';
      const style = Number(c.getAttribute('s')) || 0;
      const v = tags(c, 'v')[0]?.textContent ?? '';
      const text = type === 'inlineStr' ? tags(c, 't').map(t => t.textContent ?? '').join('')
        : type === 's' ? shared[Number(v)] ?? ''
          : type === 'n' ? formatNumber(v, styles[style]?.format)
            : v;
      cells.set(`${r}:${col}`, { text, style });
      // The template runs to row 984 with empty cells: the sheet ends at its last mark, not its last cell.
      if (text !== '' || styles[style]?.marks) { lastRow = Math.max(lastRow, r); lastCol = Math.max(lastCol, col); }
    }
  }
  const spans = new Map<string, string>();
  const covered = new Set<string>();
  for (const m of tags(doc, 'mergeCell')) {
    const ref = /^([A-Z]+)(\d+):([A-Z]+)(\d+)$/.exec(m.getAttribute('ref') ?? '');
    if (!ref) continue;
    const c1 = colNumber(ref[1]), r1 = Number(ref[2]), c2 = colNumber(ref[3]), r2 = Number(ref[4]);
    spans.set(`${r1}:${c1}`, ` colspan="${c2 - c1 + 1}" rowspan="${r2 - r1 + 1}"`);
    for (let r = r1; r <= r2; r++) for (let c = c1; c <= c2; c++) if (r !== r1 || c !== c1) covered.add(`${r}:${c}`);
    lastRow = Math.max(lastRow, r2); lastCol = Math.max(lastCol, c2);
  }
  const colPx = [0], rowPx = [0];
  for (let c = 1; c <= lastCol; c++) { const w = widths.get(c) ?? defWidth; colPx[c] = w ? Math.round(w * 7 + 5) : 0; }
  for (let r = 1; r <= lastRow; r++) rowPx[r] = Math.round((heights.get(r) ?? defHeight) * 96 / 72);
  let body = '';
  for (let r = 1; r <= lastRow; r++) {
    body += `<tr style="height:${rowPx[r]}px">`;
    for (let c = 1; c <= lastCol; c++) {
      const key = `${r}:${c}`;
      if (covered.has(key)) continue;
      const cell = cells.get(key);
      const css = cell ? styles[cell.style]?.css : '';
      body += `<td${spans.get(key) ?? ''}${css ? ` style="${css}"` : ''}>${esc(cell?.text ?? '')}</td>`;
    }
    body += '</tr>';
  }
  const width = colPx.reduce((a, b) => a + b, 0);
  return { body, width, colPx, rowPx, cols: colPx.slice(1).map(w => `<col style="width:${w}px">`).join('') };
}

const PAGE_CSS = 'html,body{margin:0}body{background:transparent;font:13px Arial,Helvetica,sans-serif;color:#000;padding:12px;width:max-content}'
  + 'section{position:relative;background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.2);margin:0 0 12px}section:last-child{margin:0}'
  + 'table{border-collapse:collapse;table-layout:fixed}td{padding:0 2px;white-space:nowrap;vertical-align:bottom}';

export async function reportHtml(file: ArrayBuffer): Promise<ReportPage> {
  const zip = await openZip(file);
  const styles = readStyles(xml(await zip.text('xl/styles.xml')));
  const shared = zip.has('xl/sharedStrings.xml') ? tags(xml(await zip.text('xl/sharedStrings.xml')), 'si').map(si => tags(si, 't').map(t => t.textContent ?? '').join('')) : [];
  const book = xml(await zip.text('xl/workbook.xml'));
  const targets = new Map(tags(xml(await zip.text('xl/_rels/workbook.xml.rels')), 'Relationship').map(r => [r.getAttribute('Id'), r.getAttribute('Target') ?? '']));
  let pages = '', width = 0;
  for (const s of tags(book, 'sheet')) {
    if (s.getAttribute('state') && s.getAttribute('state') !== 'visible') continue;
    const target = targets.get(s.getAttribute('r:id'));
    if (!target) continue;
    const path = `xl/worksheets/${baseName(target)}`;
    const t = sheetTable(xml(await zip.text(path)), styles, shared);
    if (!t.body) continue;
    width = Math.max(width, t.width);
    pages += `<section style="width:${t.width}px">${await pictures(zip, path, t.colPx, t.rowPx)}<table style="width:${t.width}px"><colgroup>${t.cols}</colgroup>${t.body}</table></section>`;
  }
  if (!pages) throw new Error('This report file has no pages to show. Try Download instead.');
  return { html: `<!doctype html><meta charset="utf-8"><style>${PAGE_CSS}/*zoom*/</style>${pages}`, width: width + 24 };
}

// The report at the width it has on screen. A phone keeps a readable size and pans sideways inside the frame.
export function fitted(page: ReportPage, boxWidth: number): string {
  const zoom = boxWidth > 0 ? Math.min(1.25, Math.max(0.55, (boxWidth - 20) / page.width)) : 1;
  return page.html.replace('/*zoom*/', `html{zoom:${zoom.toFixed(3)}}`);
}
