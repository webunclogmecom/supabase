// generate_overdue_visits_pdf.js — Notion-aesthetic HTML + PDF version of
// the overdue-visits report. Fetches the same AT data as the markdown
// script, renders HTML, then spawns headless Chrome to produce a PDF.

const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const TODAY = new Date('2026-05-19T00:00:00Z');
const END_OF_MONTH = new Date('2026-05-31T23:59:59Z');

function atGet(p) {
  return new Promise((res, rej) => {
    https.get({ hostname: 'api.airtable.com', path: p, headers: { Authorization: 'Bearer ' + AT_KEY } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,200))); res(JSON.parse(d)); }); }).on('error', rej);
  });
}
async function atFetchAll(table, filter) {
  let all = []; let offset = null;
  do {
    const q = new URLSearchParams({ pageSize: '100' });
    if (filter) q.append('filterByFormula', filter);
    if (offset) q.append('offset', offset);
    const j = await atGet('/v0/' + AT_BASE + '/' + encodeURIComponent(table) + '?' + q);
    all = all.concat(j.records); offset = j.offset;
  } while (offset);
  return all;
}

const SERVICE_LINES = [
  { code: 'GT', label: 'Grease Trap', atFreq: 'GT Frequency', atLastVisit: 'GT Last Visit (visits table)', atNextCalc: 'GT Next Visit Calculated', qualifyingServiceTypes: ['Grease Trap', 'Gray Water pumping', 'Lift Station'], atVisitServiceType: 'GT' },
  { code: 'CL', label: 'Cleaning', atFreq: 'CL Frequency', atLastVisit: 'CL Last Visit', atNextCalc: 'CL Next Visit Calculated', qualifyingServiceTypes: ['MAIN CL', 'AUX Cleaning', 'Warranty of drainage', 'Lift Station'], atVisitServiceType: 'CL' },
];

function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function urgencyClass(days) {
  if (days >= 30) return 'urgency-critical';
  if (days >= 15) return 'urgency-high';
  if (days >= 0)  return 'urgency-medium';
  return 'urgency-low';
}

function urgencyLabel(days) {
  if (days >= 30) return 'Critical';
  if (days >= 15) return 'High';
  if (days >= 0)  return 'Due';
  return 'Upcoming';
}

(async () => {
  console.log('Fetching AT data...');
  const allClients = await atFetchAll('Clients', "{ACTIVE/INACTIVE}='Recurring'");
  const visits = await atFetchAll('Visits',
    "AND({Status}='Upcoming',IS_AFTER({Visit Date},DATEADD(TODAY(),-1,'days')),IS_BEFORE({Visit Date},'2026-06-01'))"
  );

  // Index visits
  const visitsByClient = {};
  for (const v of visits) {
    const cc = (v.fields['Client Code #3 (from Client)'] || [])[0];
    const st = v.fields['Service Type'];
    if (!cc || !st) continue;
    if (!visitsByClient[cc]) visitsByClient[cc] = {};
    if (!visitsByClient[cc][st]) visitsByClient[cc][st] = [];
    visitsByClient[cc][st].push(v.fields['Visit Date']);
  }

  const result = {};
  for (const line of SERVICE_LINES) {
    const missing = [];
    for (const rec of allClients) {
      const f = rec.fields;
      const st = f['Service Type'] || [];
      if (!st.some(s => line.qualifyingServiceTypes.includes(s))) continue;
      const cc = f['Client Code #3'];
      if (!cc) continue;
      const freq = f[line.atFreq];
      if (!freq) continue;
      const calcDue = f[line.atNextCalc] ? new Date(f[line.atNextCalc]) : null;
      if (!calcDue || calcDue > END_OF_MONTH) continue;
      const upcoming = (visitsByClient[cc] || {})[line.atVisitServiceType] || [];
      if (upcoming.length > 0) continue;

      missing.push({
        code: cc,
        name: (f['Client Name'] || '').replace(/\s+/g, ' ').trim(),
        serviceTypes: st.join(', '),
        freq,
        lastVisit: f[line.atLastVisit] || '—',
        shouldBe: f[line.atNextCalc],
        daysOverdue: Math.floor((TODAY - calcDue) / 86400000),
        truck: (Array.isArray(f['Truck']) ? f['Truck'][0] : f['Truck']) || '—',
        zone: f['Zone'] || '—',
      });
    }
    missing.sort((a, b) => b.daysOverdue - a.daysOverdue);
    result[line.code] = missing;
  }

  console.log('GT missing:', result.GT.length, '· CL missing:', result.CL.length);

  // Render HTML
  function rowsHtml(rows) {
    if (rows.length === 0) return '<tr><td colspan="9" class="empty-row">None.</td></tr>';
    return rows.map((r, i) => {
      const uc = urgencyClass(r.daysOverdue);
      const label = urgencyLabel(r.daysOverdue);
      return `
        <tr>
          <td class="num">${i + 1}</td>
          <td class="mono">${escapeHtml(r.code)}</td>
          <td class="name">${escapeHtml(r.name)}</td>
          <td class="tags">${(r.serviceTypes || '').split(',').map(s => `<span class="tag">${escapeHtml(s.trim())}</span>`).join(' ')}</td>
          <td class="num">${r.freq}d</td>
          <td class="mono">${escapeHtml(r.lastVisit)}</td>
          <td class="mono">${escapeHtml(r.shouldBe)}</td>
          <td><span class="pill ${uc}">${r.daysOverdue >= 0 ? '+' : ''}${r.daysOverdue}d · ${label}</span></td>
          <td class="muted">${escapeHtml(r.truck)} · ${escapeHtml(r.zone)}</td>
        </tr>`;
    }).join('');
  }

  const dateStr = TODAY.toISOString().slice(0, 10);

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Missing visits in Airtable — ${dateStr}</title>
<style>
  :root {
    --brand: #f14714;
    --text: rgba(55, 53, 47, 1);
    --text-soft: rgba(55, 53, 47, 0.65);
    --text-muted: rgba(55, 53, 47, 0.45);
    --border: rgba(55, 53, 47, 0.09);
    --border-strong: rgba(55, 53, 47, 0.16);
    --bg-page: #ffffff;
    --bg-card: rgba(247, 246, 243, 1);
    --bg-row-hover: rgba(55, 53, 47, 0.03);
    --critical-bg: #fde2dd;
    --critical-fg: #9c1f10;
    --high-bg: #fef0d4;
    --high-fg: #8d5b00;
    --medium-bg: #ddebf1;
    --medium-fg: #1c5779;
    --low-bg: #e8e7e3;
    --low-fg: #5e5b56;
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0;
    background: var(--bg-page);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, 'Inter', 'Manrope', 'Segoe UI', system-ui, sans-serif;
    font-size: 14px;
    line-height: 1.55;
    -webkit-font-smoothing: antialiased;
  }
  .doc {
    max-width: 920px;
    margin: 0 auto;
    padding: 56px 64px 96px 64px;
  }
  .doc-title {
    font-size: 36px;
    font-weight: 700;
    margin: 0 0 6px 0;
    letter-spacing: -0.01em;
    color: var(--text);
  }
  .doc-meta {
    color: var(--text-soft);
    font-size: 14px;
    margin: 0 0 36px 0;
  }
  .doc-meta b { color: var(--text); font-weight: 600; }

  /* TL;DR callout */
  .callout {
    background: var(--bg-card);
    border-radius: 6px;
    padding: 18px 22px;
    margin: 0 0 40px 0;
    display: flex;
    gap: 24px;
    align-items: center;
  }
  .callout-emoji { font-size: 22px; line-height: 1; flex: 0 0 32px; }
  .callout-body { flex: 1; }
  .callout-title { font-weight: 600; font-size: 14px; margin: 0 0 8px 0; color: var(--text); }
  .summary-row { display: flex; gap: 28px; flex-wrap: wrap; }
  .summary-stat { display: flex; flex-direction: column; min-width: 120px; }
  .summary-stat .label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--text-muted); font-weight: 600; }
  .summary-stat .value { font-size: 28px; font-weight: 700; color: var(--text); letter-spacing: -0.01em; margin-top: 2px; }
  .summary-stat .value.critical { color: var(--critical-fg); }

  /* Section */
  .section {
    margin: 48px 0 0 0;
    page-break-inside: auto;
  }
  .section-head {
    display: flex;
    align-items: baseline;
    gap: 12px;
    padding-bottom: 8px;
    border-bottom: 1px solid var(--border);
    margin-bottom: 20px;
  }
  .section-title {
    font-size: 22px;
    font-weight: 700;
    margin: 0;
    letter-spacing: -0.005em;
  }
  .section-count {
    color: var(--text-muted);
    font-size: 14px;
    font-weight: 500;
  }
  .section-sub {
    color: var(--text-soft);
    font-size: 13px;
    margin: -8px 0 16px 0;
  }

  /* Table */
  table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
  thead th {
    text-align: left;
    font-weight: 600;
    color: var(--text-muted);
    text-transform: uppercase;
    font-size: 10.5px;
    letter-spacing: 0.06em;
    padding: 8px 10px;
    border-bottom: 1px solid var(--border-strong);
    white-space: nowrap;
  }
  tbody td {
    padding: 10px;
    border-bottom: 1px solid var(--border);
    vertical-align: top;
  }
  tbody tr:hover { background: var(--bg-row-hover); }
  tbody tr:last-child td { border-bottom: none; }
  td.num { color: var(--text-muted); width: 24px; text-align: right; padding-right: 14px; font-variant-numeric: tabular-nums; }
  td.mono { font-family: 'JetBrains Mono', 'SF Mono', Menlo, Consolas, monospace; font-size: 12px; color: var(--text-soft); white-space: nowrap; }
  td.name { font-weight: 500; min-width: 180px; }
  td.muted { color: var(--text-soft); font-size: 12px; }
  td.tags { max-width: 280px; }
  td.empty-row { color: var(--text-muted); padding: 18px 10px; font-style: italic; }

  .tag {
    display: inline-block;
    background: var(--bg-card);
    color: var(--text-soft);
    font-size: 10.5px;
    padding: 1px 7px;
    border-radius: 3px;
    margin: 1px 2px 1px 0;
    white-space: nowrap;
  }

  .pill {
    display: inline-block;
    padding: 2px 8px;
    border-radius: 12px;
    font-size: 11.5px;
    font-weight: 600;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }
  .urgency-critical { background: var(--critical-bg); color: var(--critical-fg); }
  .urgency-high { background: var(--high-bg); color: var(--high-fg); }
  .urgency-medium { background: var(--medium-bg); color: var(--medium-fg); }
  .urgency-low { background: var(--low-bg); color: var(--low-fg); }

  .notes {
    margin-top: 48px;
    color: var(--text-soft);
    font-size: 12px;
    line-height: 1.7;
    padding-top: 16px;
    border-top: 1px solid var(--border);
  }
  .notes h3 { font-size: 12.5px; font-weight: 600; color: var(--text); margin: 0 0 6px 0; letter-spacing: 0.02em; }
  .notes ul { margin: 0; padding-left: 18px; }
  .notes li { margin-bottom: 4px; }
  code { background: var(--bg-card); padding: 1px 5px; border-radius: 3px; font-size: 11.5px; color: var(--text); }

  @media print {
    .doc { padding: 24px 32px; }
    .section { page-break-inside: avoid; }
    table { page-break-inside: auto; }
    tr { page-break-inside: avoid; page-break-after: auto; }
  }
</style>
</head>
<body>
<div class="doc">
  <h1 class="doc-title">Missing visits in Airtable</h1>
  <p class="doc-meta">Recurring AT clients due by <b>2026-05-31</b> with no upcoming visit scheduled in AT. Generated <b>${dateStr}</b>.</p>

  <div class="callout">
    <div class="callout-emoji">⚠️</div>
    <div class="callout-body">
      <p class="callout-title">Summary</p>
      <div class="summary-row">
        <div class="summary-stat">
          <span class="label">GT missing</span>
          <span class="value ${result.GT.length >= 10 ? 'critical' : ''}">${result.GT.length}</span>
        </div>
        <div class="summary-stat">
          <span class="label">CL missing</span>
          <span class="value ${result.CL.length >= 10 ? 'critical' : ''}">${result.CL.length}</span>
        </div>
        <div class="summary-stat">
          <span class="label">Total clients reviewed</span>
          <span class="value">${allClients.length}</span>
        </div>
        <div class="summary-stat">
          <span class="label">Upcoming visits in window</span>
          <span class="value">${visits.length}</span>
        </div>
      </div>
    </div>
  </div>

  <div class="section">
    <div class="section-head">
      <h2 class="section-title">Grease Trap visits</h2>
      <span class="section-count">${result.GT.length} need scheduling</span>
    </div>
    <p class="section-sub">Includes Grease Trap, Gray Water pumping, and Lift Station (GT side).</p>
    <table>
      <thead>
        <tr>
          <th>#</th><th>Code</th><th>Client</th><th>Service Type</th><th>Freq</th><th>Last visit</th><th>Should be</th><th>Status</th><th>Truck · Zone</th>
        </tr>
      </thead>
      <tbody>${rowsHtml(result.GT)}</tbody>
    </table>
  </div>

  <div class="section">
    <div class="section-head">
      <h2 class="section-title">Cleaning visits</h2>
      <span class="section-count">${result.CL.length} need scheduling</span>
    </div>
    <p class="section-sub">Includes MAIN CL, AUX Cleaning, Warranty of drainage, and Lift Station (CL side).</p>
    <table>
      <thead>
        <tr>
          <th>#</th><th>Code</th><th>Client</th><th>Service Type</th><th>Freq</th><th>Last visit</th><th>Should be</th><th>Status</th><th>Truck · Zone</th>
        </tr>
      </thead>
      <tbody>${rowsHtml(result.CL)}</tbody>
    </table>
  </div>

  <div class="notes">
    <h3>Notes</h3>
    <ul>
      <li>Filter: <code>{ACTIVE/INACTIVE}='Recurring'</code> — Active, PAUSED, INACTIVE all excluded.</li>
      <li>"Due" = AT's <code>Next Visit Calculated</code> ≤ 2026-05-31. That's <code>Last Visit + Frequency</code> per AT's own formula.</li>
      <li>"Missing" = no AT Visit with <code>Status='Upcoming'</code> for that client + that service line through 2026-05-31.</li>
      <li>Lift Station clients can appear in BOTH sections (they need both visit types).</li>
      <li>"Requires Phone Call" clients excluded (emergency-only, no recurring schedule).</li>
    </ul>
  </div>
</div>
</body>
</html>`;

  // Write HTML
  const outDir = path.resolve(__dirname, '../../docs/audits/2026-05-19');
  fs.mkdirSync(outDir, { recursive: true });
  const htmlPath = path.join(outDir, 'OPS_LIST_OVERDUE_VISITS_2026-05-19.html');
  const pdfPath  = path.join(outDir, 'OPS_LIST_OVERDUE_VISITS_2026-05-19.pdf');
  fs.writeFileSync(htmlPath, html);
  console.log('HTML written:', htmlPath);

  // Convert to PDF via headless Chrome
  const chromeCandidates = [
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files\\Google\\Chrome Beta\\Application\\chrome.exe',
    process.env.LOCALAPPDATA + '\\Google\\Chrome\\Application\\chrome.exe',
  ];
  let chromePath = null;
  for (const c of chromeCandidates) {
    if (fs.existsSync(c)) { chromePath = c; break; }
  }
  if (!chromePath) {
    console.log('Chrome not found at standard paths. HTML is ready; open it in any browser and Print to PDF.');
    console.log('  HTML:', htmlPath);
    return;
  }

  console.log('Using Chrome at:', chromePath);
  const cmd = `"${chromePath}" --headless=new --disable-gpu --no-margins --print-to-pdf="${pdfPath}" --print-to-pdf-no-header "file:///${htmlPath.replace(/\\\\/g, '/').replace(/\\\\/g, '/')}"`;
  try {
    execSync(cmd, { stdio: 'inherit' });
    console.log('PDF written:', pdfPath);
  } catch (e) {
    console.error('Chrome PDF conversion failed:', e.message);
    console.log('  HTML is ready at:', htmlPath, '— open and Print to PDF manually.');
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
