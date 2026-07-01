# DERM Address-Sheet → Client-Row Mapping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a re-runnable, one-time batch pipeline that maps every DERM FOG-manifest facility row to its client (blind Claude-vision, digit-anchored, flag-don't-guess), stores it in `derm.address_row_map`, and renders Yannick's Confirmed/Unconfirmed legend bundles in the existing 2-week dump-date grouping.

**Architecture:** Node scripts (Supabase Management API for all DB + a shared `lib/db.js`) do the deterministic stages — prep, load, render, audit — while the **matching stage runs via the Workflow tool** (blind vision agents, the POC mechanism). An operator loop processes 2-week windows **most-recent-first**, threading a **gazetteer** (`data/gazetteer.json`) of confirmed `facility→client` learned across sheets. Design spec: [`docs/superpowers/specs/2026-07-01-derm-address-row-mapping-design.md`](../specs/2026-07-01-derm-address-row-mapping-design.md).

**Tech Stack:** Node ≥20 (built-in `https`/`fs`, no external deps), Supabase Management API (`api.supabase.com/v1/projects/<id>/database/query`, Bearer `SUPABASE_PAT` from `Supabase/.env`), the Workflow tool (Claude-vision agents), headless Chrome `--print-to-pdf` for PDFs (as in `Supabase/_derm_bundle.js`).

**Conventions:** money `NUMERIC(12,2)` (n/a here); timestamps `TIMESTAMPTZ` UTC; `updated_at` trigger-managed via `public.set_updated_at()`; audit opt-in via `audit.log_change()` (Rule 8, DERM compliance); reference clients by FK only (Rules 2/3); idempotent upserts on natural keys (Rule 5); soft-delete only (Rule 6); NEVER print/commit secrets/PII/PDFs (PUBLIC repo).

**File layout (all new, under `scripts/derm-mapping/` unless noted):**
- `docs/migrations/2026-07-01_derm_address_row_map.sql` — the table + triggers (DDL)
- `scripts/derm-mapping/apply_sql.js` — POST a `.sql` file to the Management API
- `scripts/derm-mapping/lib/db.js` — env parse + `q(sql)` query helper
- `scripts/derm-mapping/lib/windows.js` — the 13 fixed 2-week windows (mirrors `_derm_bundle.js`)
- `scripts/derm-mapping/lib/gazetteer.js` — load/lookup/merge the confirmed `facility→client` store
- `scripts/derm-mapping/01_prep.js` — per window: candidates + image pages, download images, write `data/sheets_<nn>.json`
- `scripts/derm-mapping/match_workflow.js` — Workflow script (blind agents + reconcile), driven by the Workflow tool with `args`
- `scripts/derm-mapping/03_load.js` — upsert a window's match results into `derm.address_row_map`
- `scripts/derm-mapping/04_render.js` — Confirmed/Unconfirmed legend bundle PDFs for a window
- `scripts/derm-mapping/05_audit.js` — linkage-audit report (UNMATCHED rows + linked-but-absent clients)
- `scripts/derm-mapping/data/` — working dir (git-ignored): `sheets_*.json`, `images/`, `match_*.json`, `gazetteer.json`
- `scripts/derm-mapping/README.md` — the operator loop

**Working directory for all commands:** `C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase`
**Commit convention (this repo):** subject ≤70 chars imperative; footer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`; `git pull --rebase` before commit; push after each task. Stage **only** the files a task creates (never `git add -A` — the shared tree holds other sessions' work + untracked PDFs/scratch).

---

## Task 1: Migration — `derm.address_row_map` table + triggers

**Files:**
- Create: `docs/migrations/2026-07-01_derm_address_row_map.sql`
- Create: `scripts/derm-mapping/lib/db.js`
- Create: `scripts/derm-mapping/apply_sql.js`

- [ ] **Step 1: Write the shared DB helper** `scripts/derm-mapping/lib/db.js`

```js
// Shared: parse Supabase/.env and expose q(sql) against the Management API.
const https = require('https');
const fs = require('fs');
const path = require('path');
const ENV = path.resolve(__dirname, '../../../.env'); // -> Supabase/.env
for (const line of fs.readFileSync(ENV, 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
  if (m) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
}
function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => {
      let j; try { j = JSON.parse(d); } catch (e) { return rej(new Error('non-JSON: ' + d.slice(0, 300))); }
      if (Array.isArray(j)) return res(j);
      if (j && j.error) return rej(new Error(JSON.stringify(j).slice(0, 400)));
      res(j); // DDL returns {} or []
    }); });
    req.on('error', rej); req.write(body); req.end();
  });
}
module.exports = { q };
```

- [ ] **Step 2: Write the migration SQL** `docs/migrations/2026-07-01_derm_address_row_map.sql`

```sql
-- 2026-07-01_derm_address_row_map.sql
-- Physical-row grain map: which client sits in which facility row of each DERM address sheet.
-- Audit: OPT-IN (DERM compliance, Rule 8 / ADR 010). updated_at trigger-managed (Rule 7).
-- Client referenced by FK only (Rules 2/3). Idempotent upsert key = (dump_folder,page,row_index) (Rule 5).
CREATE TABLE IF NOT EXISTS derm.address_row_map (
  id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dump_folder           text NOT NULL,
  white_manifest_number text,
  page                  int  NOT NULL,
  row_index             int  NOT NULL,
  image_url             text NOT NULL,
  facility_name_read    text,
  address_read          text,
  matched_client_id     uuid REFERENCES public.clients(id),
  assignment_status     text NOT NULL CHECK (assignment_status IN ('matched','unmatched','low_confidence','proposed')),
  confidence            text CHECK (confidence IN ('high','medium','low')),
  agent_agreement       text,
  flags                 jsonb NOT NULL DEFAULT '{}'::jsonb,
  source                text NOT NULL DEFAULT 'claude-vision-v1',
  reviewed_by           text,
  reviewed_at           timestamptz,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT address_row_map_natural_key UNIQUE (dump_folder, page, row_index)
);
CREATE INDEX IF NOT EXISTS idx_address_row_map_manifest ON derm.address_row_map (white_manifest_number);
CREATE INDEX IF NOT EXISTS idx_address_row_map_client   ON derm.address_row_map (matched_client_id);

DROP TRIGGER IF EXISTS trg_address_row_map_updated_at ON derm.address_row_map;
CREATE TRIGGER trg_address_row_map_updated_at BEFORE UPDATE ON derm.address_row_map
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS audit_address_row_map ON derm.address_row_map;
CREATE TRIGGER audit_address_row_map AFTER INSERT OR UPDATE OR DELETE ON derm.address_row_map
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
```

- [ ] **Step 3: Write the apply script** `scripts/derm-mapping/apply_sql.js`

```js
// Apply a .sql file to Prod via the Management API. Usage: node apply_sql.js <path-to-sql>
const fs = require('fs');
const { q } = require('./lib/db');
(async () => {
  const file = process.argv[2];
  if (!file) { console.error('usage: node apply_sql.js <file.sql>'); process.exit(1); }
  const sql = fs.readFileSync(file, 'utf8');
  await q(sql);
  console.log('applied OK:', file);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
```

- [ ] **Step 4: Apply the migration**

Run: `node scripts/derm-mapping/apply_sql.js docs/migrations/2026-07-01_derm_address_row_map.sql`
Expected: `applied OK: docs/migrations/2026-07-01_derm_address_row_map.sql`

- [ ] **Step 5: Verify table + both triggers exist**

Run:
```bash
node -e "require('./scripts/derm-mapping/lib/db').q(\"select trigger_name from information_schema.triggers where event_object_schema='derm' and event_object_table='address_row_map' order by 1\").then(r=>console.log(JSON.stringify(r)))"
```
Expected: JSON containing `audit_address_row_map` and `trg_address_row_map_updated_at`.

- [ ] **Step 6: Commit**

```bash
git pull --rebase origin main
git add docs/migrations/2026-07-01_derm_address_row_map.sql scripts/derm-mapping/lib/db.js scripts/derm-mapping/apply_sql.js
git commit -m "Add derm.address_row_map table for DERM sheet row mapping

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 2: Windows + prep — candidates & images per 2-week window

**Files:**
- Create: `scripts/derm-mapping/lib/windows.js`
- Create: `scripts/derm-mapping/01_prep.js`
- Create: `scripts/derm-mapping/.gitignore`

- [ ] **Step 1: Write the fixed windows** `scripts/derm-mapping/lib/windows.js` (mirrors `_derm_bundle.js` so grouping matches today's bundles)

```js
// The 13 fixed 2-week dump-date windows, most-recent-first (identical to _derm_bundle.js).
module.exports = [
  { n: 1, from: '2026-06-17', to: '2026-06-30' }, { n: 2, from: '2026-06-03', to: '2026-06-16' },
  { n: 3, from: '2026-05-20', to: '2026-06-02' }, { n: 4, from: '2026-05-06', to: '2026-05-19' },
  { n: 5, from: '2026-04-22', to: '2026-05-05' }, { n: 6, from: '2026-04-08', to: '2026-04-21' },
  { n: 7, from: '2026-03-25', to: '2026-04-07' }, { n: 8, from: '2026-03-11', to: '2026-03-24' },
  { n: 9, from: '2026-02-25', to: '2026-03-10' }, { n: 10, from: '2026-02-11', to: '2026-02-24' },
  { n: 11, from: '2026-01-28', to: '2026-02-10' }, { n: 12, from: '2026-01-14', to: '2026-01-27' },
  { n: 13, from: '2026-01-01', to: '2026-01-13' },
];
```

- [ ] **Step 2: Write `.gitignore`** `scripts/derm-mapping/.gitignore` (keep the working data + images out of the PUBLIC repo)

```
data/
```

- [ ] **Step 3: Write the prep script** `scripts/derm-mapping/01_prep.js`

```js
// 01_prep.js <windowNumber> : for one 2-week window, pull each dump-ticket sheet's candidate
// clients (code/name/DB address) + deduped image pages, download the images locally, and write
// data/sheets_<nn>.json. Groups by dump ticket (white_manifest_number; falls back to image URL).
const https = require('https');
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');
const WINDOWS = require('./lib/windows');

const DATA = path.resolve(__dirname, 'data');
const fileName = u => { try { return decodeURIComponent(String(u).split('/').pop().split('?')[0] || u).toLowerCase(); } catch (e) { return String(u).toLowerCase(); } };
const ext = u => { const e = fileName(u).match(/\.(jpe?g|png|pdf|webp|heic)$/i); return e ? e[0].toLowerCase() : '.jpg'; };
function dl(url, dest) {
  return new Promise((res, rej) => {
    const go = (u, n) => { if (n > 5) return rej(new Error('redirects')); https.get(u, r => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) { r.resume(); return go(r.headers.location, n + 1); }
      if (r.statusCode !== 200) { r.resume(); return rej(new Error('HTTP ' + r.statusCode)); }
      const f = fs.createWriteStream(dest); r.pipe(f); f.on('finish', () => f.close(() => res(dest))); }).on('error', rej); };
    go(url, 0);
  });
}
(async () => {
  const n = parseInt(process.argv[2], 10);
  const w = WINDOWS.find(x => x.n === n);
  if (!w) { console.error('usage: node 01_prep.js <1..13>'); process.exit(1); }
  const imgDir = path.join(DATA, 'images', 'w' + String(n).padStart(2, '0'));
  fs.mkdirSync(imgDir, { recursive: true });
  const rows = await q(`
    SELECT coalesce(m.dump_ticket_date, m.service_date)::text AS dump_date,
           m.white_manifest_number AS wm, m.derm_address_url AS url, m.derm_address_extra_urls AS extras,
           c.client_code, c.name,
           (SELECT p.address||', '||coalesce(p.city,'')||', '||coalesce(p.state,'')||' '||coalesce(p.zip,'')
              FROM properties p WHERE p.client_id=c.id ORDER BY p.is_primary DESC NULLS LAST, p.id LIMIT 1) AS address
    FROM derm_manifests m JOIN clients c ON c.id=m.client_id
    WHERE m.deleted_at IS NULL AND m.derm_address_url IS NOT NULL
      AND coalesce(m.dump_ticket_date,m.service_date) >= '${w.from}'
      AND coalesce(m.dump_ticket_date,m.service_date) <= '${w.to}'
    ORDER BY dump_date DESC, m.white_manifest_number`);
  const sheets = new Map(); // key -> sheet
  for (const r of rows) {
    const key = r.wm ? 'WM:' + r.wm : 'URL:' + r.url;
    if (!sheets.has(key)) sheets.set(key, { dump_date: r.dump_date, wm: r.wm, dump_folder: null, candidates: [], imgs: new Map() });
    const s = sheets.get(key);
    s.candidates.push({ code: r.client_code, name: r.name, address: r.address });
    const urls = [r.url, ...(Array.isArray(r.extras) ? r.extras : [])];
    for (const u of urls) if (u && !s.imgs.has(fileName(u))) s.imgs.set(fileName(u), u);
  }
  const out = [];
  let si = 0;
  for (const s of sheets.values()) {
    si++;
    const pages = [...s.imgs.values()];
    // dump_folder = the storage folder that identifies this physical sheet-set (e.g. 'derm/1218')
    const m = String(pages[0] || '').match(/\/manifests\/([^?]+)\/[^/?]+$/);
    s.dump_folder = m ? m[1] : ('window' + n + '-sheet' + si);
    const local = [];
    for (let i = 0; i < pages.length; i++) {
      const dest = path.join(imgDir, `s${String(si).padStart(2, '0')}_p${i + 1}${ext(pages[i])}`);
      try { await dl(pages[i], dest); local.push(dest.replace(/\\/g, '/')); } catch (e) { local.push('DL_FAIL:' + e.message); }
    }
    out.push({ label: `w${n}-s${si}`, dump_folder: s.dump_folder, wm: s.wm, dump_date: s.dump_date,
      candidates: s.candidates, page_urls: pages, local_files: local });
  }
  fs.writeFileSync(path.join(DATA, `sheets_${String(n).padStart(2, '0')}.json`), JSON.stringify({ window: w, sheets: out }, null, 2));
  console.log(`window ${n} (${w.from}..${w.to}): ${out.length} sheets, ${out.reduce((a, s) => a + s.page_urls.length, 0)} pages`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
```

- [ ] **Step 4: Run prep for window 1 and verify shape**

Run: `node scripts/derm-mapping/01_prep.js 1`
Expected: a line like `window 1 (2026-06-17..2026-06-30): N sheets, M pages`, and `data/sheets_01.json` exists with each sheet carrying `dump_folder`, `candidates[]` (code/name/address), and downloaded `local_files`.

- [ ] **Step 5: Assert no image download failures for window 1**

Run:
```bash
node -e "const d=require('./scripts/derm-mapping/data/sheets_01.json');const bad=d.sheets.flatMap(s=>s.local_files).filter(f=>f.startsWith('DL_FAIL'));console.log(bad.length?('FAILS:'+JSON.stringify(bad)):'all images downloaded')"
```
Expected: `all images downloaded` (if any fail, note them; they render as Unconfirmed later).

- [ ] **Step 6: Commit** (code only — `data/` is git-ignored)

```bash
git pull --rebase origin main
git add scripts/derm-mapping/lib/windows.js scripts/derm-mapping/01_prep.js scripts/derm-mapping/.gitignore
git commit -m "Add DERM mapping prep: candidates + images per 2-week window

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 3: Gazetteer — the cross-sheet learning store

**Files:**
- Create: `scripts/derm-mapping/lib/gazetteer.js`

- [ ] **Step 1: Write the gazetteer module** `scripts/derm-mapping/lib/gazetteer.js`

```js
// Confirmed facility->client memory, learned across sheets. Keyed by normalized street#+zip and by
// normalized facility name. Only CONFIRMED matches (unanimous+consistent, or human-reviewed) go in.
const fs = require('fs');
const path = require('path');
const FILE = path.resolve(__dirname, '../data/gazetteer.json');
const norm = s => String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const addrKey = a => { const s = String(a || ''); const num = (s.match(/\b(\d{2,6})\b/) || [])[1]; const zip = (s.match(/\b(3\d{4})\b/) || [])[1]; return num && zip ? num + '|' + zip : null; };
function load() { try { return JSON.parse(fs.readFileSync(FILE, 'utf8')); } catch (e) { return { byAddr: {}, byName: {} }; } }
function save(g) { fs.mkdirSync(path.dirname(FILE), { recursive: true }); fs.writeFileSync(FILE, JSON.stringify(g, null, 2)); }
function lookup(g, name, address) {
  const ak = addrKey(address); if (ak && g.byAddr[ak]) return g.byAddr[ak];
  const nk = norm(name); if (nk && g.byName[nk]) return g.byName[nk];
  return null;
}
// rows: [{facility_name_read, address_read, matched_client_code}] that are CONFIRMED.
function merge(g, rows) {
  for (const r of rows) {
    if (!r.matched_client_code) continue;
    const ak = addrKey(r.address_read); if (ak) g.byAddr[ak] = r.matched_client_code;
    const nk = norm(r.facility_name_read); if (nk) g.byName[nk] = r.matched_client_code;
  }
  return g;
}
module.exports = { load, save, lookup, merge, addrKey, norm };
```

- [ ] **Step 2: Smoke-test lookup/merge**

Run:
```bash
node -e "const gz=require('./scripts/derm-mapping/lib/gazetteer');let g={byAddr:{},byName:{}};gz.merge(g,[{facility_name_read:'La Granja Downtown',address_read:'127 SE 2nd Ave Miami 33131',matched_client_code:'035-LG'}]);console.log(gz.lookup(g,'','127 SE 2nd Ave, 33131')==='035-LG'?'addr-hit OK':'FAIL', gz.lookup(g,'la granja downtown','')==='035-LG'?'name-hit OK':'FAIL')"
```
Expected: `addr-hit OK name-hit OK`

- [ ] **Step 3: Commit**

```bash
git pull --rebase origin main
git add scripts/derm-mapping/lib/gazetteer.js
git commit -m "Add DERM mapping gazetteer for cross-sheet learning

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 4: Match + reconcile workflow (blind vision agents)

**Files:**
- Create: `scripts/derm-mapping/match_workflow.js`

This is the generalized POC workflow. It is invoked via the **Workflow tool** (not `node`), passing one window's sheets + the current gazetteer as `args`. It runs 3 blind agents per sheet, reconciles deterministically, and returns per-row assignments + a `gazetteer_add` list.

- [ ] **Step 1: Write the workflow script** `scripts/derm-mapping/match_workflow.js`

```js
export const meta = {
  name: 'derm-row-match',
  description: 'Blind vision agents match FOG-manifest facility rows to candidate clients; reconcile + confidence',
  phases: [{ title: 'Match', detail: '3 blind agents per sheet, digit-anchored constrained match' }],
}

// args = { sheets: [{label, dump_folder, wm, dump_date, candidates:[{code,name,address}], local_files:[paths]}], gazetteer: {byAddr,byName} }
const SHEETS = (args && args.sheets) || []
const GAZ = (args && args.gazetteer) || { byAddr: {}, byName: {} }

const SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    rows: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: {
        page: { type: 'integer' }, row_index: { type: 'integer' },
        facility_name_read: { type: 'string' }, address_read: { type: 'string' },
        assigned_code: { type: 'string' }, confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        evidence: { type: 'string' },
      }, required: ['page', 'row_index', 'facility_name_read', 'address_read', 'assigned_code', 'confidence'] } },
    unplaced_candidates: { type: 'array', items: { type: 'string' } },
  }, required: ['rows', 'unplaced_candidates'],
}

function buildPrompt(s) {
  const gzHints = s.candidates
    .map(c => c.code).filter(Boolean)
    .concat(Object.values(GAZ.byAddr || {}), Object.values(GAZ.byName || {}))
  return `You are reading a scanned Miami-Dade County "Fats, Oils and Grease (FOG)" eManifest — a grease-disposal form filled out mostly BY HAND. Section B ("Origination of Waste") lists up to 6 serviced facilities per page; each filled facility has a handwritten Facility Name and a Complete Facility Address (street, city, FL, zip). A dump ticket can span multiple pages.

Image page(s) to read (${s.local_files.length}) — call the Read tool on EACH absolute path:
${s.local_files.map((p, i) => `  Page ${i + 1}: ${p}`).join('\n')}

For EVERY filled facility row (top-to-bottom, page by page), transcribe the facility name and address, then assign that row to the SINGLE best-matching candidate below (by code). The STREET NUMBER and ZIP are your most reliable signal — handwritten digits survive messy writing far better than cursive names — so match on those FIRST, then corroborate with the name. If a row plausibly matches NO candidate, set assigned_code to "UNMATCHED" (never force a match).

Candidate clients (order is NOT the row order):
${s.candidates.map(c => `${c.code || '(no code)'} | ${c.name} | ${c.address || ''}`).join('\n')}

Rules:
- Each candidate maps to at most ONE row; each row to at most one candidate.
- Prefer street-number + zip agreement; a clear NAME match can win even if the address differs.
- If illegible/unsure, give your best assignment but mark confidence "low"; use "UNMATCHED" only when nothing fits.
- List every candidate code you could NOT place in unplaced_candidates.
Return ONLY the structured JSON.`
}

const num = a => { const m = String(a || '').match(/\b(\d{2,6})\b/); return m ? m[1] : null }
const zip = a => { const m = String(a || '').match(/\b(3\d{4})\b/); return m ? m[1] : null }

phase('Match')
const perSheet = await parallel(SHEETS.map(s => () =>
  parallel([0, 1, 2].map(k => () =>
    agent(buildPrompt(s), { label: `match:${s.label}#${k + 1}`, phase: 'Match', schema: SCHEMA, effort: 'high' }).catch(() => null)
  )).then(passes => ({ sheet: s, passes: passes.filter(Boolean) }))
))

// ---- reconcile: majority vote per physical row across passes; confidence from agreement + digit consistency ----
function reconcile(sheet, passes) {
  // align rows by (page,row_index); collect each pass's assignment for that cell
  const cells = {}
  for (const p of passes) for (const r of (p.rows || [])) {
    const key = `${r.page}:${r.row_index}`
    ;(cells[key] = cells[key] || []).push(r)
  }
  const out = []
  for (const key of Object.keys(cells).sort()) {
    const rs = cells[key]
    const votes = {}
    for (const r of rs) votes[r.assigned_code] = (votes[r.assigned_code] || 0) + 1
    const [topCode, topN] = Object.entries(votes).sort((a, b) => b[1] - a[1])[0]
    const rep = rs.find(r => r.assigned_code === topCode) || rs[0]
    const agreement = `${topN}/${passes.length}`
    const cand = sheet.candidates.find(c => c.code === topCode)
    const digitOK = cand ? (num(rep.address_read) === num(cand.address) || zip(rep.address_read) === zip(cand.address)) : false
    let status, confidence
    if (topCode === 'UNMATCHED') { status = 'unmatched'; confidence = topN === passes.length ? 'high' : 'low' }
    else if (topN === passes.length && (digitOK || (rep.confidence === 'high'))) { status = 'matched'; confidence = 'high' }
    else { status = 'low_confidence'; confidence = 'low' }
    out.push({ page: rep.page, row_index: rep.row_index, facility_name_read: rep.facility_name_read,
      address_read: rep.address_read, matched_client_code: topCode === 'UNMATCHED' ? null : topCode,
      assignment_status: status, confidence, agent_agreement: agreement })
  }
  return out
}

const results = perSheet.filter(Boolean).map(({ sheet, passes }) => {
  const rows = passes.length ? reconcile(sheet, passes) : []
  const gazetteer_add = rows.filter(r => r.assignment_status === 'matched' && r.confidence === 'high')
    .map(r => ({ facility_name_read: r.facility_name_read, address_read: r.address_read, matched_client_code: r.matched_client_code }))
  return { label: sheet.label, dump_folder: sheet.dump_folder, wm: sheet.wm, dump_date: sheet.dump_date,
    page_urls: sheet.page_urls, local_files: sheet.local_files, candidates: sheet.candidates, rows, gazetteer_add }
})
return { window: (args && args.window) || null, sheets: results }
```

- [ ] **Step 2: Regression-test the workflow on the POC ground-truth sheets (A/B/C)**

Prepare a tiny fixture and run the workflow via the **Workflow tool** with `args` = the fixture (the same A/B/C sheets + candidates used in the validated POC; images at `.../scratchpad/poc_images/`). Assert the returned rows reproduce: **A 4/4 matched, B 4/4 matched, C 9 matched + 5 UNMATCHED**, all `agent_agreement` = `3/3`.

Operator action (Claude): invoke `Workflow({ scriptPath: "<abs path to match_workflow.js>", args: <fixture> })`, then check the result JSON:
```
A: rows where matched_client_code in [092-TCE,104-PV,110-CLA,147-OST] all status=matched
B: rows for [045-NU,063-TCE,148-MOR,191-TEN] all status=matched
C: 9 matched rows + 5 rows matched_client_code=null status=unmatched
```
Expected: matches the POC (17/17 placeable correct, unanimous). If any regress, fix the prompt/reconcile before proceeding.

- [ ] **Step 3: Commit**

```bash
git pull --rebase origin main
git add scripts/derm-mapping/match_workflow.js
git commit -m "Add DERM row-match workflow (blind vision agents + reconcile)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 5: Loader — upsert match results into `derm.address_row_map`

**Files:**
- Create: `scripts/derm-mapping/03_load.js`

- [ ] **Step 1: Write the loader** `scripts/derm-mapping/03_load.js`

```js
// 03_load.js data/match_<nn>.json : upsert a window's reconciled rows into derm.address_row_map.
// Idempotent on (dump_folder,page,row_index). Resolves client_id from code. NEVER overwrites a human's
// reviewed_by/reviewed_at (those columns are omitted from the UPDATE SET).
const fs = require('fs');
const { q } = require('./lib/db');
const S = s => s == null ? 'NULL' : `'${String(s).replace(/'/g, "''")}'`;
const J = o => `'${JSON.stringify(o || {}).replace(/'/g, "''")}'::jsonb`;
(async () => {
  const file = process.argv[2];
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  // resolve code -> client_id once
  const codes = [...new Set(data.sheets.flatMap(s => s.rows).map(r => r.matched_client_code).filter(Boolean))];
  let byCode = {};
  if (codes.length) {
    const rows = await q(`SELECT id, client_code FROM clients WHERE client_code IN (${codes.map(S).join(',')})`);
    for (const r of rows) byCode[r.client_code] = r.id;
  }
  let n = 0;
  for (const sheet of data.sheets) {
    for (const r of sheet.rows) {
      const cid = r.matched_client_code ? byCode[r.matched_client_code] : null;
      const flags = {};
      if (r.assignment_status === 'unmatched') flags.unlinked_facility = true;
      const sql = `
        INSERT INTO derm.address_row_map
          (dump_folder,white_manifest_number,page,row_index,image_url,facility_name_read,address_read,
           matched_client_id,assignment_status,confidence,agent_agreement,flags,source)
        VALUES (${S(sheet.dump_folder)},${S(sheet.wm)},${r.page},${r.row_index},
           ${S(sheet.local_files[r.page - 1] ? sheet.page_urls[r.page - 1] : sheet.page_urls[0])},
           ${S(r.facility_name_read)},${S(r.address_read)},${cid ? S(cid) : 'NULL'},
           ${S(r.assignment_status)},${S(r.confidence)},${S(r.agent_agreement)},${J(flags)},'claude-vision-v1')
        ON CONFLICT (dump_folder,page,row_index) DO UPDATE SET
           white_manifest_number=EXCLUDED.white_manifest_number, image_url=EXCLUDED.image_url,
           facility_name_read=EXCLUDED.facility_name_read, address_read=EXCLUDED.address_read,
           matched_client_id=EXCLUDED.matched_client_id, assignment_status=EXCLUDED.assignment_status,
           confidence=EXCLUDED.confidence, agent_agreement=EXCLUDED.agent_agreement,
           flags=EXCLUDED.flags, source=EXCLUDED.source;`;
      await q(sql); n++;
    }
  }
  console.log(`loaded/upserted ${n} rows from ${file}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
```

- [ ] **Step 2: Load the Task-4 regression result and verify readback**

Run: `node scripts/derm-mapping/03_load.js scripts/derm-mapping/data/match_poc.json` (the saved A/B/C result)
Then:
```bash
node -e "require('./scripts/derm-mapping/lib/db').q(\"select assignment_status,count(*) from derm.address_row_map group by 1 order by 1\").then(r=>console.log(JSON.stringify(r)))"
```
Expected: counts showing `matched` (17), `unmatched` (5) for the POC set.

- [ ] **Step 3: Verify idempotency (re-run creates no duplicates)**

Run: `node scripts/derm-mapping/03_load.js scripts/derm-mapping/data/match_poc.json` again, then:
```bash
node -e "require('./scripts/derm-mapping/lib/db').q(\"select count(*) total, count(distinct (dump_folder,page,row_index)) uniq from derm.address_row_map\").then(r=>console.log(JSON.stringify(r)))"
```
Expected: `total === uniq` (no duplicate rows).

- [ ] **Step 4: Commit**

```bash
git pull --rebase origin main
git add scripts/derm-mapping/03_load.js
git commit -m "Add DERM mapping loader (idempotent upsert to address_row_map)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 6: Renderer — Confirmed/Unconfirmed 2-week legend bundles

**Files:**
- Create: `scripts/derm-mapping/04_render.js`

- [ ] **Step 1: Write the renderer** `scripts/derm-mapping/04_render.js` (HTML→Chrome PDF, legend beside each sheet; two sections: Unconfirmed first, then Confirmed)

```js
// 04_render.js <windowNumber> : build a legend bundle PDF for one 2-week window from
// derm.address_row_map. Splits sheets into UNCONFIRMED (any row not high-confidence matched)
// and CONFIRMED. Unconfirmed rows show the code blank + "?". Output to C:/Users/FRED/Downloads/.
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { q } = require('./lib/db');
const WINDOWS = require('./lib/windows');
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function sheetHtml(title, sheets) {
  if (!sheets.length) return `<h2>${title}</h2><p class="muted">none</p>`;
  const blocks = sheets.map(s => {
    const rows = s.rows.map(r => {
      const conf = r.assignment_status === 'matched' && r.confidence === 'high';
      const code = conf ? esc(r.code || '') : '<span class="q">?</span>';
      return `<tr class="${conf ? '' : 'flag'}"><td class="ri">${r.page}.${r.row_index}</td><td class="code">${code}</td><td>${esc(r.facility_name_read || '')}</td><td class="addr">${esc(r.address_read || '')}</td></tr>`;
    }).join('');
    const links = s.page_urls.map((u, i) => `<a href="${esc(u)}">Image ${i + 1}</a>`).join(' · ');
    return `<div class="sheet"><div class="hd"><b>${esc(s.dump_date)}</b> · ticket ${esc(s.wm || '—')} · ${links}</div>
      <table><thead><tr><th>Row</th><th>Code</th><th>Facility (read)</th><th>Address (read)</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  }).join('');
  return `<h2>${title} <span class="muted">(${sheets.length})</span></h2>${blocks}`;
}

(async () => {
  const n = parseInt(process.argv[2], 10);
  const w = WINDOWS.find(x => x.n === n);
  if (!w) { console.error('usage: node 04_render.js <1..13>'); process.exit(1); }
  const rows = await q(`
    SELECT m.dump_folder, m.white_manifest_number AS wm, m.page, m.row_index, m.image_url,
           m.facility_name_read, m.address_read, m.assignment_status, m.confidence,
           c.client_code AS code,
           (SELECT coalesce(dm.dump_ticket_date,dm.service_date)::text FROM derm_manifests dm
             WHERE dm.white_manifest_number=m.white_manifest_number ORDER BY 1 LIMIT 1) AS dump_date
    FROM derm.address_row_map m LEFT JOIN clients c ON c.id=m.matched_client_id
    WHERE m.white_manifest_number IN (
       SELECT white_manifest_number FROM derm_manifests
        WHERE deleted_at IS NULL AND coalesce(dump_ticket_date,service_date) >= '${w.from}'
          AND coalesce(dump_ticket_date,service_date) <= '${w.to}')
    ORDER BY dump_date DESC, m.dump_folder, m.page, m.row_index`);
  const byFolder = new Map();
  for (const r of rows) {
    if (!byFolder.has(r.dump_folder)) byFolder.set(r.dump_folder, { dump_folder: r.dump_folder, wm: r.wm, dump_date: r.dump_date, page_urls: [], rows: [] });
    const s = byFolder.get(r.dump_folder);
    s.rows.push(r);
  }
  // reconstruct page_urls per folder (distinct image_url in page order)
  for (const s of byFolder.values()) { const seen = new Set(); for (const r of s.rows) if (r.image_url && !seen.has(r.image_url)) { seen.add(r.image_url); s.page_urls.push(r.image_url); } }
  const all = [...byFolder.values()];
  const isConfirmed = s => s.rows.every(r => r.assignment_status === 'matched' && r.confidence === 'high');
  const unconfirmed = all.filter(s => !isConfirmed(s));
  const confirmed = all.filter(isConfirmed);
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
   body{font-family:'Segoe UI',system-ui,sans-serif;color:#2b2b2b;margin:0;font-size:12px}.doc{max-width:940px;margin:0 auto;padding:36px 46px}
   h1{font-size:22px;margin:0 0 2px}.sub{color:#777;margin:0 0 16px}.muted{color:#999;font-weight:400}
   h2{font-size:15px;margin:20px 0 8px;border-bottom:2px solid #eee;padding-bottom:4px}
   .sheet{border:1px solid #eee;border-radius:6px;padding:8px 10px;margin:0 0 12px;page-break-inside:avoid}
   .hd{font-size:11px;color:#555;margin-bottom:5px}.hd a{color:#1c5779}
   table{width:100%;border-collapse:collapse}th{font-size:9px;text-transform:uppercase;color:#999;text-align:left;border-bottom:1px solid #ddd;padding:3px 6px}
   td{padding:3px 6px;border-bottom:1px solid #f2f2f2;vertical-align:top}.ri{color:#aaa;width:34px}.code{font-family:Consolas,monospace;font-weight:700;width:70px}
   .addr{color:#555}tr.flag{background:#fff8e1}.q{color:#e67700;font-weight:700}
   </style></head><body><div class="doc">
   <h1>DERM Addresses — Window ${n} of 13</h1><p class="sub">dump dates ${w.from} to ${w.to} · ${unconfirmed.length} to confirm · ${confirmed.length} confirmed</p>
   <div class="sheet" style="background:#f7f6f3"><b>Yannick:</b> the <b>Unconfirmed</b> sheets below have blank codes marked <span class="q">?</span> — please fill those first. The <b>Confirmed</b> sheets are for reference; correct anything that looks off.</div>
   ${sheetHtml('Unconfirmed — tackle first', unconfirmed)}
   ${sheetHtml('Confirmed', confirmed)}
   </div></body></html>`;
  const chrome = ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe', 'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe', (process.env.LOCALAPPDATA || '') + '\\Google\\Chrome\\Application\\chrome.exe'].find(c => fs.existsSync(c));
  const htmlPath = path.resolve(__dirname, 'data', `render_${String(n).padStart(2, '0')}.html`);
  fs.writeFileSync(htmlPath, html);
  const out = `C:/Users/FRED/Downloads/DERM_RowMap_Window_${String(n).padStart(2, '0')}_${w.from}_to_${w.to}.pdf`;
  execSync(`"${chrome}" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="${out}" "file:///${htmlPath.replace(/\\/g, '/')}"`, { stdio: 'pipe' });
  console.log(`window ${n}: ${unconfirmed.length} unconfirmed, ${confirmed.length} confirmed -> ${out}`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
```

- [ ] **Step 2: Render a window and verify the split**

Run: `node scripts/derm-mapping/04_render.js 1`
Expected: `window 1: X unconfirmed, Y confirmed -> C:/Users/FRED/Downloads/DERM_RowMap_Window_01_...pdf`; open the PDF and confirm the **Unconfirmed section is first**, flagged rows show `?`, and confirmed sheets show codes.

- [ ] **Step 3: Commit** (never commit the PDF — PUBLIC repo)

```bash
git pull --rebase origin main
git add scripts/derm-mapping/04_render.js
git commit -m "Add DERM mapping renderer (Confirmed/Unconfirmed legend bundles)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 7: Linkage-audit report

**Files:**
- Create: `scripts/derm-mapping/05_audit.js`

- [ ] **Step 1: Write the audit** `scripts/derm-mapping/05_audit.js`

```js
// 05_audit.js : from derm.address_row_map + derm_manifests, report linkage gaps per dump ticket:
//  (a) UNMATCHED rows = a facility on the sheet with no matched client (unlinked / possibly non-client)
//  (b) linked-but-absent = a client linked to the ticket in derm_manifests but on no matched row
// Writes data/linkage_audit.json (machine) + prints a short summary. Does NOT mutate anything.
const fs = require('fs');
const path = require('path');
const { q } = require('./lib/db');
(async () => {
  const unmatched = await q(`
    SELECT white_manifest_number AS wm, dump_folder, page, row_index, facility_name_read, address_read
    FROM derm.address_row_map WHERE assignment_status='unmatched' ORDER BY wm, page, row_index`);
  const absent = await q(`
    SELECT m.white_manifest_number AS wm, c.client_code, c.name
    FROM derm_manifests m JOIN clients c ON c.id=m.client_id
    WHERE m.deleted_at IS NULL AND m.white_manifest_number IS NOT NULL
      AND m.white_manifest_number IN (SELECT DISTINCT white_manifest_number FROM derm.address_row_map)
      AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                       WHERE r.white_manifest_number=m.white_manifest_number AND r.matched_client_id=c.id)
    ORDER BY m.white_manifest_number, c.client_code`);
  fs.writeFileSync(path.resolve(__dirname, 'data', 'linkage_audit.json'), JSON.stringify({ unmatched_rows: unmatched, linked_but_absent: absent }, null, 2));
  console.log(`linkage audit: ${unmatched.length} UNMATCHED rows (facility on sheet, no client), ${absent.length} linked-but-absent clients`);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
```

- [ ] **Step 2: Run and sanity-check against the known sheet-C gaps**

Run: `node scripts/derm-mapping/05_audit.js`
Expected: nonzero counts; `data/linkage_audit.json` includes the sheet-C `UNMATCHED` facilities (e.g. "One Oak Walk", "Cafe Club") and the linked-but-absent codes (047-PAM, 061-TCE, 077-TCE, 155-PV, 231-CHE) once window 3-ish (827989) is processed.

- [ ] **Step 3: Commit**

```bash
git pull --rebase origin main
git add scripts/derm-mapping/05_audit.js
git commit -m "Add DERM linkage-audit report from address_row_map

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 8: Operator loop (README) + full run, most-recent-first

**Files:**
- Create: `scripts/derm-mapping/README.md`

- [ ] **Step 1: Write the operator README** `scripts/derm-mapping/README.md`

````markdown
# DERM address-sheet → client-row mapping (one-time batch)

Process windows **most-recent-first** (1 → 13), threading the gazetteer. Per window `N`:

1. `node scripts/derm-mapping/01_prep.js N`            # -> data/sheets_0N.json + images
2. **Claude** runs the matcher via the Workflow tool:
   `Workflow({ scriptPath: ".../match_workflow.js", args: { window: <win>, sheets: <sheets_0N.json .sheets>, gazetteer: <data/gazetteer.json or {byAddr:{},byName:{}}> } })`
   Save the returned JSON to `data/match_0N.json`.
3. Merge the window's confirmed matches into the gazetteer:
   `node -e "const gz=require('./lib/gazetteer');const d=require('./data/match_0N.json');let g=gz.load();d.sheets.forEach(s=>gz.merge(g,s.gazetteer_add));gz.save(g)"`
4. `node scripts/derm-mapping/03_load.js data/match_0N.json`   # upsert into derm.address_row_map
5. `node scripts/derm-mapping/04_render.js N`                  # Confirmed/Unconfirmed PDF for the window

After all 13: `node scripts/derm-mapping/05_audit.js` for the linkage-gap report.
Re-running any window is safe (idempotent). Human `reviewed_*` edits in the table are never overwritten.
````

- [ ] **Step 2: Execute windows 1–13**

For each window 1..13, run the 5-step loop above. Watch each Confirmed/Unconfirmed PDF; the gazetteer should make later (older) windows resolve more recurring facilities automatically.

- [ ] **Step 3: Final verification — coverage**

Run:
```bash
node -e "require('./scripts/derm-mapping/lib/db').q(\"select count(distinct dump_folder) sheets, count(*) rows, count(*) filter (where assignment_status='matched' and confidence='high') confirmed, count(*) filter (where assignment_status<>'matched' or confidence<>'high') to_review from derm.address_row_map\").then(r=>console.log(JSON.stringify(r)))"
```
Expected: `sheets` ≈ the ~92–113 dump-ticket sheets; `confirmed` is the large majority; `to_review` is the flagged set Yannick tackles.

- [ ] **Step 4: Commit the README**

```bash
git pull --rebase origin main
git add scripts/derm-mapping/README.md
git commit -m "Document DERM mapping operator loop (windows + gazetteer)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Self-review notes (spec coverage)

- Data layer → Task 2. Matching engine → Task 4. Reconciliation/confidence → Task 4 (`reconcile`). Mapping store → Task 1 + Task 5. Linkage audit → Task 7. Gazetteer/learning → Task 3 + Task 8 loop. Renderer v1 (Confirmed/Unconfirmed, 2-week grouping) → Task 6. Scope (this session; FP later; v2 stamped later) → honored (v2 not in this plan). Server-side `service_role` image reads → **note:** v1 downloads via the still-live public URLs (Task 2); when Supabase flips `manifests` private, switch `dl()` to send `apikey`/`Authorization: Bearer <SERVICE_ROLE_KEY>` or the `/object/authenticated/` path — one-line change, no dependency on `get-derm-doc`.
- Open questions resolved: cutoff = 2026-01-01 (13 windows); schema = `derm.*`; audit = flag-only in v1 (proposing links deferred).
- v2 stamped-in-cell renderer is intentionally a **separate future plan** (needs template registration).
