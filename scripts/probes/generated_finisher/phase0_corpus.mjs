// Phase 0 of docs/superpowers/plans/2026-09-14-generated-sheet-finisher.md.
// Replays the layout-guided matcher (derm.fn_match_generated_page, migration 2026-09-15_1000) over
// every stamped page of every generated folder, WITHOUT WRITING ANYTHING, and compares its six
// boundaries with the geometry a person accepted (bands, extent, admitted printed rules). Pass 1
// uses the stamp-midpoint template as the prior; the pages it accepts calibrate the prior (the mean
// printed layout) and pass 2 re-runs everything with it and reports the residuals that pin the
// tolerances.
//
// USE: node scripts/probes/generated_finisher/phase0_corpus.mjs
// Reads Supabase/.env (Management API), downloads scans into img/ (gitignored), writes
// phase0_calibration.json and phase0_report.md next to this file. Re-runnable; cached scans are reused.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { detectRules } from '../../../supabase/functions/_shared/printed_rule_detector.mjs';

const require = createRequire(import.meta.url);
const jpeg = require('jpeg-js');
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../../..');

for (const line of fs.readFileSync(path.join(root, '.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!m) continue;
  let v = m[2].trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (!(m[1] in process.env)) process.env[m[1]] = v;
}

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${t.slice(0, 500)}`);
  return JSON.parse(t);
}
const lit = (v) => `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`;
const arr = (a) => `ARRAY[${a.map((x) => x.toFixed(4)).join(',')}]::numeric[]`;

// 1. the corpus: one row per (generated folder, stamped image position), with what a person accepted
const CORPUS_SQL = `
with gen as (
  select distinct r.dump_folder, r.white_manifest_number as ticket
    from derm.address_row_map r
   where r.white_manifest_number is not null and derm.fn_sheet_is_generated(r.white_manifest_number)
), pages as (
  select g.dump_folder, g.ticket, coalesce(r.stamp_page, r.page) as page
    from gen g join derm.address_row_map r on r.dump_folder = g.dump_folder
   where r.stamp_y_pct is not null
   group by 1, 2, 3
)
select p.dump_folder, p.ticket, p.page,
       (derm.ticket_page_images(p.ticket))[p.page] as image_url,
       derm.fn_generated_page_cards(p.dump_folder, p.page) as cards,
       (select jsonb_agg(jsonb_build_object('row_id', r.id, 'y', r.stamp_y_pct, 'y0', r.band_y0_pct, 'y1', r.band_y1_pct) order by r.stamp_y_pct)
          from derm.address_row_map r
         where r.dump_folder = p.dump_folder and coalesce(r.stamp_page, r.page) = p.page and r.stamp_y_pct is not null) as accepted_bands,
       e.top_pct, e.bottom_pct, e.source as extent_source,
       (select jsonb_agg(v.rule_pct order by v.rule_pct) from derm.v_page_printed_rules v
         where v.dump_folder = p.dump_folder and v.effective_page = p.page and v.kind = 'boundary') as admitted_boundaries,
       (select string_agg(distinct v.source, ',') from derm.v_page_printed_rules v
         where v.dump_folder = p.dump_folder and v.effective_page = p.page) as admitted_source,
       coalesce(s.completed, false) as completed
  from pages p
  left join derm.page_block_extents e on e.dump_folder = p.dump_folder and e.effective_page = p.page
  left join derm.stamp_sheet_status s on s.dump_folder = p.dump_folder
 order by 1, 3;`;

async function scanFor(row) {
  const file = path.join(here, 'img', `${row.dump_folder}_p${row.page}.jpg`);
  if (!fs.existsSync(file)) {
    const r = await fetch(row.image_url);
    if (!r.ok) throw new Error(`${row.dump_folder} p${row.page}: image HTTP ${r.status}`);
    fs.writeFileSync(file, Buffer.from(await r.arrayBuffer()));
  }
  const bytes = fs.readFileSync(file);
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return { error: 'not a JPEG (the finisher will leave this page to a person)' };
  return detectRules(jpeg.decode(bytes, { useTArray: true }));
}

function compare(bounds, row) {
  // how far the matched boundaries sit from what a person accepted; null when nothing to compare
  const byRow = new Map((row.cards.cards || []).map((c) => [c.row_id, c.row]));
  const deltas = { bands: [], extent: [], admitted: [] };
  for (const b of row.accepted_bands || []) {
    const r = byRow.get(b.row_id);
    if (!r || b.y0 == null) continue;
    deltas.bands.push(+Math.abs(bounds[r - 1] - b.y0).toFixed(3), +Math.abs(bounds[r] - b.y1).toFixed(3));
  }
  if (row.top_pct != null) deltas.extent.push(+Math.abs(bounds[0] - row.top_pct).toFixed(3), +Math.abs(bounds[5] - row.bottom_pct).toFixed(3));
  for (const x of bounds) {
    const adm = (row.admitted_boundaries || []).map(Number);
    if (adm.length) deltas.admitted.push(+Math.min(...adm.map((a) => Math.abs(a - x))).toFixed(3));
  }
  const max = (a) => (a.length ? Math.max(...a) : null);
  return { max_band: max(deltas.bands), max_extent: max(deltas.extent), max_admitted: max(deltas.admitted), deltas };
}

async function runPass(rows, prior, label) {
  const out = [];
  for (const row of rows) {
    const stamps = (row.cards.cards || []).filter((c) => c.row != null).map((c) => ({ row: c.row, y: Number(c.y) }));
    const m = (await sql(`select derm.fn_match_generated_page(${lit(row.lines)}, ${lit(stamps)}, ${arr(prior)}) as m;`))[0].m;
    const rec = { dump_folder: row.dump_folder, page: row.page, pass: label, ineligible: row.cards.refusal || null,
                  ok: m.ok, reason: m.reason || null, detail: m.detail || null, shift: m.shift ?? null,
                  residuals: m.residuals || null, boundaries: m.boundaries || null };
    if (m.ok) {
      const c = compare(m.boundaries.map(Number), row);
      Object.assign(rec, c);
      const tol = 0.35;
      rec.verdict = rec.ineligible ? 'INELIGIBLE_BUT_MATCHED'
        : (c.max_band != null && c.max_band <= tol && (c.max_extent == null || c.max_extent <= tol)) ? 'MATCH'
        : (c.max_admitted != null && c.max_admitted <= tol) ? 'RULES_ONLY'
        : 'MISMATCH';
      // stamp clearance: the smallest distance from any stamp to either line of its slot
      rec.min_clearance = stamps.length ? +Math.min(...stamps.map((s) => Math.min(s.y - m.boundaries[s.row - 1], m.boundaries[s.row] - s.y))).toFixed(3) : null;
      rec.gap_dev = +Math.max(...[1, 2, 3, 4, 5].map((i) => Math.abs((m.boundaries[i] - m.boundaries[i - 1]) - (prior[i] - prior[i - 1])))).toFixed(3);
    } else {
      rec.verdict = rec.ineligible ? 'INELIGIBLE_AND_REFUSED' : 'REFUSED';
    }
    out.push(rec);
  }
  return out;
}

const roundUp = (x, step) => Math.ceil(x / step - 1e-9) * step;

(async () => {
  fs.mkdirSync(path.join(here, 'img'), { recursive: true });
  const rows = await sql(CORPUS_SQL);
  if (rows.length < 30) throw new Error(`corpus has ${rows.length} pages; expected the 33 measured on 2026-09-14 or more. Check fn_sheet_is_generated.`);
  const template = (await sql('select derm.fn_generated_template_boundaries() as p;'))[0].p.map(Number);

  for (const row of rows) {
    const d = await scanFor(row);
    row.lines = d.error ? null : d.rules;
    row.detect = d.error ? { error: d.error } : { W: d.W, H: d.H, skew: d.skew, n: d.rules.length };
    if (d.error) console.log(`${row.dump_folder} p${row.page}: ${d.error}`);
  }
  const usable = rows.filter((r) => r.lines);

  // pass 1: the template as the prior
  const pass1 = await runPass(usable, template, 'template');
  const accepted = pass1.filter((r) => r.ok && r.verdict === 'MATCH');
  if (accepted.length < 10) throw new Error(`only ${accepted.length} pages MATCH with the template prior; calibration needs at least 10. Read pass 1 before going on.`);
  // the calibrated prior: the mean of each matched boundary over the pages that MATCH (offset and all;
  // the matcher removes the per-page shift itself, so only the SHAPE matters)
  const prior2 = [0, 1, 2, 3, 4, 5].map((i) => +(accepted.reduce((s, r) => s + Number(r.boundaries[i]), 0) / accepted.length).toFixed(3));

  // pass 2: the calibrated prior
  const pass2 = await runPass(usable, prior2, 'calibrated');
  const ok2 = pass2.filter((r) => r.ok);
  const maxRes = Math.max(...ok2.flatMap((r) => r.residuals.map((x) => Math.abs(Number(x)))));
  const maxGap = Math.max(...ok2.map((r) => r.gap_dev));
  const minClear = Math.min(...ok2.filter((r) => r.min_clearance != null).map((r) => r.min_clearance));
  const tolerances = {
    // rule: the worst value the accepted corpus needs, rounded up to 0.05, plus 0.25 of margin;
    // never below 0.5 and never above 1.0. Phase 0's job is to make these measured, not chosen.
    match: +Math.min(1.0, Math.max(0.5, roundUp(maxRes + 0.25, 0.05))).toFixed(2),
    gap:   +Math.min(1.0, Math.max(0.5, roundUp(maxGap + 0.25, 0.05))).toFixed(2),
    clear: minClear >= 1.0 ? 0.5 : +Math.max(0.2, roundUp(minClear / 2, 0.05)).toFixed(2),
    search: 2.5,
    measured: { max_abs_residual: +maxRes.toFixed(3), max_gap_deviation: +maxGap.toFixed(3), min_stamp_clearance: +minClear.toFixed(3) },
  };

  const results = { generated_at: new Date().toISOString(), pages: rows.length, usable: usable.length,
                    template_prior: template, calibrated_prior: prior2, tolerances,
                    pass1, pass2,
                    lines: Object.fromEntries(usable.map((r) => [`${r.dump_folder}_p${r.page}`, { image_url: r.image_url, detect: r.detect, lines: r.lines }])) };
  fs.writeFileSync(path.join(here, 'phase0_calibration.json'), JSON.stringify(results, null, 1) + '\n');

  const fmt = (r) => `| ${r.dump_folder} | ${r.page} | ${r.verdict} | ${r.ok ? `shift ${r.shift}; band ${r.max_band ?? '-'} extent ${r.max_extent ?? '-'} rules ${r.max_admitted ?? '-'}` : r.reason} | ${r.ineligible ?? ''} |`;
  const md = [
    `# Phase 0: the layout-guided matcher over the generated-sheet corpus`, ``,
    `Generated ${results.generated_at} by phase0_corpus.mjs. ${rows.length} pages, ${usable.length} with a readable JPEG. Nothing was written.`, ``,
    `Template prior (stamp midpoints): ${template.join(' / ')}`,
    `Calibrated prior (mean over ${accepted.length} MATCH pages): ${prior2.join(' / ')}`,
    `Tolerances to pin: match ${tolerances.match} (worst residual ${tolerances.measured.max_abs_residual}), gap ${tolerances.gap} (worst ${tolerances.measured.max_gap_deviation}), clear ${tolerances.clear} (smallest stamp clearance ${tolerances.measured.min_stamp_clearance}), search 2.5`, ``,
    `Verdicts: MATCH = every band edge and both extents within 0.35pp of what a person accepted; RULES_ONLY = the six boundaries are the admitted printed rules but the saved bands or extent differ (read why: a templated extent, a hand-set band); MISMATCH = different geometry, must be explained or the matcher does not ship; REFUSED = the matcher declined, a person says whether the refusal is right; INELIGIBLE = fn_generated_page_cards refused the page (multi-row client, card not on the printed list, ...), the matcher result is shown for information only.`, ``,
    `## Pass 2 (calibrated prior)`, ``, `| folder | page | verdict | result | ineligible because |`, `|---|---|---|---|---|`,
    ...pass2.map(fmt), ``,
    `## Pass 1 (template prior)`, ``, `| folder | page | verdict | result | ineligible because |`, `|---|---|---|---|---|`,
    ...pass1.map(fmt), ``,
    `## Counts`, ``,
    ...['MATCH', 'RULES_ONLY', 'MISMATCH', 'REFUSED', 'INELIGIBLE_BUT_MATCHED', 'INELIGIBLE_AND_REFUSED'].map((v) => `- pass 2 ${v}: ${pass2.filter((r) => r.verdict === v).length}`),
    ``, `## Sign-off`, ``, `- [ ] Fred has read the REFUSED / INELIGIBLE / MISMATCH / RULES_ONLY rows and agrees with each (write the reason next to each row that is not MATCH).`, ``,
  ].join('\n');
  fs.writeFileSync(path.join(here, 'phase0_report.md'), md);
  console.log(md.split('\n').slice(0, 8).join('\n'));
  console.log(...['MATCH', 'RULES_ONLY', 'MISMATCH', 'REFUSED', 'INELIGIBLE_BUT_MATCHED', 'INELIGIBLE_AND_REFUSED'].map((v) => `${v}=${pass2.filter((r) => r.verdict === v).length}`));
})().catch((e) => { console.error(e); process.exit(1); });
