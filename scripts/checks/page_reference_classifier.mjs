// page_reference_classifier.mjs - proves the SERVER measuring pipeline (detectRules + classifyPage, the two
// shared modules edge fn measure-page-reference imports) reproduces what the Stamp Studio measured in the
// browser, on real scans whose in-app measurement is on record (runlen-v2 scans, grade OK, same image etag).
//   node scripts/checks/page_reference_classifier.mjs [N]      (default 6 pages)
// Read only. For each page it runs the pipeline twice, with the page's CURRENT extent as the window and
// with no window, because the app used whichever it had on the day (836624 p1 was measured before it had
// an extent). Two assertions:
//   * IDENTITY: one of the two runs finds every stored boundary within 0.15pp, graded OK;
//   * NO CONFIDENT MISREAD: whenever a run grades OK with the same number of boundaries, they match the
//     stored ones within 0.15pp. A run graded IRREGULAR / SPARSE may disagree (934861 p1 with no window):
//     save_page_bands only ever checks against an OK measurement.
import fs from 'node:fs';
import assert from 'node:assert';
import jpeg from 'jpeg-js';
import { detectRules } from '../../supabase/functions/_shared/printed_rule_detector.mjs';
import { classifyPage } from '../../supabase/functions/_shared/printed_rule_classifier.mjs';

const env = Object.fromEntries(fs.readFileSync(new URL('../../.env', import.meta.url), 'utf8').split(/\r?\n/)
  .filter((l) => l.includes('=') && !l.startsWith('#'))
  .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const q = async (sql) => {
  const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', {
    method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: sql }) });
  const j = await r.json(); if (!Array.isArray(j)) throw new Error(JSON.stringify(j).slice(0, 300)); return j;
};

const N = Number(process.argv[2] ?? 6);
const pages = await q(`
  select s.dump_folder, s.effective_page page, s.source, s.source_url, e.top_pct, e.bottom_pct,
         (select jsonb_agg(jsonb_build_object('pct', r.rule_pct, 'kind', r.kind) order by r.rule_pct)
            from derm.page_row_rules r where r.dump_folder = s.dump_folder and r.effective_page = s.effective_page
             and r.source = s.source) rules
    from derm.page_rule_scans s
    left join derm.page_block_extents e on e.dump_folder = s.dump_folder and e.effective_page = s.effective_page
   where s.source like 'runlen-v2-%' and s.grade = 'OK' and s.source_etag is not null
     and s.source_etag = derm._img_etag(s.source_url) and s.source_url like '%.jpg'
     -- the app's own measurements only: a background one was made BY this pipeline, so it proves nothing
     and coalesce(s.detail, '') not like 'background measurement:%'
   order by s.scanned_at desc limit ${N}`);
assert.ok(pages.length >= 3, `need at least 3 control pages, found ${pages.length}`);

let worstApp = 0, worstBg = 0;
for (const p of pages) {
  const bytes = new Uint8Array(await (await fetch(p.source_url)).arrayBuffer());
  const raw = jpeg.decode(bytes, { useTArray: true, maxMemoryUsageInMB: 1024 });
  const stored = p.rules.filter((r) => r.kind === 'boundary').map((r) => Number(r.pct));
  const top = p.top_pct == null ? null : Number(p.top_pct), bot = p.bottom_pct == null ? null : Number(p.bottom_pct);

  const asApp = classifyPage({ ...detectRules(raw, top, bot), top, bot });
  const appB = asApp.rules.filter((r) => r.kind === 'boundary').map((r) => r.pct);
  const dApp = Math.max(...stored.map((s) => Math.min(...appB.map((b) => Math.abs(b - s)))));
  worstApp = Math.max(worstApp, dApp);

  const bg = classifyPage({ ...detectRules(raw, null, null), top: null, bot: null });
  const bgB = bg.rules.filter((r) => r.kind === 'boundary').map((r) => r.pct);
  const dBg = bgB.length ? Math.max(...stored.map((s) => Math.min(...bgB.map((b) => Math.abs(b - s))))) : Infinity;
  worstBg = Math.max(worstBg, dBg);
  console.log(`${p.dump_folder} p${p.page}: stored ${stored.length} boundaries (${p.source}); as the app: ${asApp.grade} ${appB.length}, worst ${dApp.toFixed(3)}pp; background: ${bg.grade} ${bgB.length}, worst ${dBg.toFixed(3)}pp`);
  assert.ok((asApp.grade === 'OK' && dApp <= 0.15) || (bg.grade === 'OK' && dBg <= 0.15),
    `${p.dump_folder} p${p.page}: neither run reproduces the stored measurement (${dApp}, ${dBg})`);
  if (asApp.grade === 'OK' && appB.length === stored.length) assert.ok(dApp <= 0.15, `${p.dump_folder} p${p.page}: OK with the extent but ${dApp}pp off`);
  if (bg.grade === 'OK' && bgB.length === stored.length) assert.ok(dBg <= 0.15, `${p.dump_folder} p${p.page}: OK with no window but ${dBg}pp off`);
}
console.log(`page_reference_classifier: ${pages.length} pages, worst ${worstApp.toFixed(3)}pp as the app, ${worstBg.toFixed(3)}pp in background mode`);
