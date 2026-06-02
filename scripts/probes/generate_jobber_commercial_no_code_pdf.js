// generate_jobber_commercial_no_code_pdf.js
//
// Renders reports/jobber_commercial_no_code_2026-05-29.csv into a styled
// PDF (Notion-aesthetic, brand orange) for ops review.
//
// Single flat alphabetical list of Commercial Jobber clients with no
// client_code — no visit history columns, no priority split.
//
// Output: reports/jobber_commercial_no_code_2026-05-29.{html,pdf}

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const CSV_PATH = path.resolve(__dirname, '../../reports/jobber_commercial_no_code_2026-05-29.csv');
const HTML_PATH = path.resolve(__dirname, '../../reports/jobber_commercial_no_code_2026-05-29.html');
const PDF_PATH = path.resolve(__dirname, '../../reports/jobber_commercial_no_code_2026-05-29.pdf');

// Simple RFC-4180 CSV parser (handles quoted fields with commas + escaped quotes)
function parseCsv(text) {
  const rows = [];
  let row = [], field = '', inQuotes = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i], n = text[i + 1];
    if (inQuotes) {
      if (c === '"' && n === '"') { field += '"'; i++; }
      else if (c === '"') { inQuotes = false; }
      else { field += c; }
    } else {
      if (c === '"') inQuotes = true;
      else if (c === ',') { row.push(field); field = ''; }
      else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
      else if (c === '\r') { /* skip */ }
      else { field += c; }
    }
  }
  if (field.length > 0 || row.length > 0) { row.push(field); rows.push(row); }
  return rows;
}

function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
}

(async () => {
  console.log('Parsing CSV...');
  const text = fs.readFileSync(CSV_PATH, 'utf8');
  const rows = parseCsv(text).filter(r => r.length >= 10 && r[0] !== '' && r[0] !== 'db_id');

  const records = rows.map(r => ({
    db_id: r[0],
    jobber_name: r[1],
    address: r[5],
    phone: r[6],
    email: r[7],
    jobber_url: r[9],
  }));

  // Sort alphabetically (case-insensitive, ignoring leading whitespace)
  records.sort((a, b) => a.jobber_name.trim().toLowerCase().localeCompare(b.jobber_name.trim().toLowerCase()));
  console.log(`Records: ${records.length}`);

  const dateStr = new Date('2026-05-29').toISOString().slice(0, 10);

  function rowsHtml(rows) {
    if (rows.length === 0) return '<tr><td colspan="4" class="empty-row">None.</td></tr>';
    return rows.map((r, i) => {
      const contact = [r.phone, r.email].filter(Boolean).map(escapeHtml).join('<br>');
      return `
        <tr>
          <td class="num">${i + 1}</td>
          <td class="name"><a href="${escapeHtml(r.jobber_url)}" class="link">${escapeHtml(r.jobber_name)}</a></td>
          <td class="addr">${escapeHtml(r.address || '—')}</td>
          <td class="contact">${contact || '<span class="muted">—</span>'}</td>
        </tr>`;
    }).join('');
  }

  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Commercial Jobber clients with no client_code — ${dateStr}</title>
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
  .doc { max-width: 960px; margin: 0 auto; padding: 56px 64px 96px 64px; }

  /* Brand stripe + identity */
  .brand-stripe { height: 4px; background: var(--brand); border-radius: 2px; margin-bottom: 28px; }
  .doc-eyebrow { font-size: 11px; font-weight: 700; letter-spacing: 0.14em; text-transform: uppercase; color: var(--brand); margin: 0 0 4px 0; }
  .doc-title { font-size: 32px; font-weight: 700; margin: 0 0 6px 0; letter-spacing: -0.01em; color: var(--text); }
  .doc-meta { color: var(--text-soft); font-size: 13px; margin: 0 0 36px 0; }
  .doc-meta b { color: var(--text); font-weight: 600; }

  /* Summary callout */
  .callout { background: var(--bg-card); border-radius: 6px; padding: 20px 24px; margin: 0 0 40px 0; }
  .summary-row { display: flex; gap: 36px; flex-wrap: wrap; }
  .summary-stat { display: flex; flex-direction: column; min-width: 130px; }
  .summary-stat .label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--text-muted); font-weight: 600; }
  .summary-stat .value { font-size: 30px; font-weight: 700; color: var(--text); letter-spacing: -0.01em; margin-top: 2px; }
  .summary-stat .value.brand { color: var(--brand); }

  /* Table */
  table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
  thead th {
    text-align: left; font-weight: 600; color: var(--text-muted); text-transform: uppercase;
    font-size: 10.5px; letter-spacing: 0.06em; padding: 8px 10px;
    border-bottom: 1px solid var(--border-strong); white-space: nowrap;
  }
  tbody td { padding: 9px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
  tbody tr:hover { background: var(--bg-row-hover); }
  tbody tr:last-child td { border-bottom: none; }
  td.num { color: var(--text-muted); width: 28px; text-align: right; padding-right: 14px; font-variant-numeric: tabular-nums; }
  td.name { font-weight: 500; min-width: 200px; max-width: 280px; }
  td.addr { color: var(--text-soft); font-size: 11.5px; max-width: 320px; }
  td.contact { font-size: 11.5px; color: var(--text-soft); max-width: 220px; }
  td.empty-row { color: var(--text-muted); padding: 18px 10px; font-style: italic; }
  .muted { color: var(--text-muted); }

  /* Links */
  .link { color: var(--text); text-decoration: none; border-bottom: 1px solid var(--border-strong); }
  .link:hover { color: var(--brand); border-bottom-color: var(--brand); }

  /* Notes */
  .notes { margin-top: 48px; color: var(--text-soft); font-size: 12px; line-height: 1.7; padding-top: 16px; border-top: 1px solid var(--border); }
  .notes h3 { font-size: 12.5px; font-weight: 600; color: var(--text); margin: 0 0 6px 0; letter-spacing: 0.02em; }
  .notes ul { margin: 0; padding-left: 18px; }
  .notes li { margin-bottom: 4px; }
  code { background: var(--bg-card); padding: 1px 5px; border-radius: 3px; font-size: 11.5px; color: var(--text); }

  /* Footer */
  .footer { margin-top: 40px; color: var(--text-muted); font-size: 10.5px; line-height: 1.6; text-align: center; padding-top: 16px; border-top: 1px solid var(--border); }
  .footer b { color: var(--text-soft); font-weight: 600; }

  @media print {
    .doc { padding: 24px 32px; }
    table { page-break-inside: auto; }
    tr { page-break-inside: avoid; page-break-after: auto; }
    thead { display: table-header-group; }
  }
</style>
</head>
<body>
<div class="doc">
  <div class="brand-stripe"></div>
  <p class="doc-eyebrow">Client onboarding</p>
  <h1 class="doc-title">Commercial Jobber clients with no client_code</h1>
  <p class="doc-meta">Jobber clients that have NOT been assigned a <code>NNN-XX</code> code in Airtable, filtered to <b>Commercial</b> (Jobber <code>isCompany=true</code> · "Payment terms: Commercial default"). Sorted alphabetically. Generated <b>${dateStr}</b>.</p>

  <div class="callout">
    <div class="summary-row">
      <div class="summary-stat">
        <span class="label">Commercial · no code</span>
        <span class="value brand">${records.length}</span>
      </div>
    </div>
  </div>

  <table>
    <thead>
      <tr><th>#</th><th>Client</th><th>Address</th><th>Contact</th></tr>
    </thead>
    <tbody>${rowsHtml(records)}</tbody>
  </table>

  <div class="notes">
    <h3>Notes</h3>
    <ul>
      <li>Source: Jobber GraphQL <code>Client.isCompany=true</code>. Filtered against <code>public.clients.client_code IS NULL</code>.</li>
      <li>Client names link directly to the Jobber profile.</li>
      <li>Before assigning a new code, run <code>scripts/probes/check_client_code_available.js &lt;prefix&gt;</code> to confirm no collision across DB, Jobber, and Airtable (lesson learned 2026-05-29: 226-PER vs 226-JER).</li>
    </ul>
  </div>

  <div class="footer">
    <div><b>Unclogme LLC</b> · 333 West 41st Street, Suite 606 · Miami Beach, FL 33140</div>
    <div>Generated from <code>reports/jobber_commercial_no_code_${dateStr}.csv</code></div>
  </div>
</div>
</body>
</html>`;

  fs.writeFileSync(HTML_PATH, html);
  console.log('HTML written:', HTML_PATH);

  // Convert to PDF via headless Chrome
  const chromeCandidates = [
    'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
    'C:\\Program Files\\Google\\Chrome Beta\\Application\\chrome.exe',
    process.env.LOCALAPPDATA + '\\Google\\Chrome\\Application\\chrome.exe',
  ];
  let chromePath = null;
  for (const c of chromeCandidates) { if (fs.existsSync(c)) { chromePath = c; break; } }
  if (!chromePath) {
    console.log('Chrome not found at standard paths. HTML is ready; open it in any browser and Print to PDF.');
    console.log('  HTML:', HTML_PATH);
    return;
  }
  console.log('Using Chrome at:', chromePath);
  const cmd = `"${chromePath}" --headless=new --disable-gpu --no-margins --print-to-pdf="${PDF_PATH}" --print-to-pdf-no-header "file:///${HTML_PATH.replace(/\\/g, '/')}"`;
  try {
    execSync(cmd, { stdio: 'inherit' });
    console.log('PDF written:', PDF_PATH);
  } catch (e) {
    console.error('Chrome PDF conversion failed:', e.message);
    console.log('  HTML is ready at:', HTML_PATH, '— open and Print to PDF manually.');
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
