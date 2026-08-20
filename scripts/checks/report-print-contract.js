#!/usr/bin/env node
/**
 * report-print-contract.js — assert the Field Portal Service Report still satisfies the
 * contract the PDF renderer depends on, from the SHIPPED bundle.
 *
 *   node scripts/checks/report-print-contract.js
 *   node scripts/checks/report-print-contract.js --verbose
 *
 * WHY THIS EXISTS (2026-08-20). This page is printed to PDF by unclogme-pdf-service and
 * emailed to a municipal FOG regulator. The renderer refuses to print unless it finds the
 * literal text "service performed" or "issued by unclogme llc" in `document.body.innerText`.
 *
 * So the failure mode is not a red build. It is:
 *
 *     a purely cosmetic CSS change moves a heading into `::before { content: "..." }`,
 *     the page looks identical in a browser, the text leaves innerText, and EVERY
 *     visit stops producing a PDF. The first symptom is a failed email to a city.
 *
 * That was verified by hand three separate times on 2026-08-20 while restyling the report,
 * and every one of those verifications was thrown away afterwards. This file is the part
 * worth keeping.
 *
 * 🛑 WHAT IT DOES NOT DO, stated plainly so nobody reads a pass as more than it is.
 * It does NOT render the page, does NOT print a PDF, and therefore cannot check page
 * counts, pagination, blank pages, or geometry. The report is a client-rendered SPA, so
 * fetching its URL returns a shell with no report in it; checking the DOM needs a real
 * browser and that is a heavier harness than this repo's other checks.
 *
 * What it CAN do without a browser is the half that actually kills the feature: read the
 * shipped CSS and JS and assert the fatal shapes are absent and the load-bearing rules are
 * present. The marker test is transport-level rather than catalogue-level, in the same
 * spirit as app-rpc-contract.js: if a heading were moved into CSS `content:`, the string
 * would MOVE from the JS bundle into the stylesheet, and that is exactly what is asserted.
 *
 * For the geometry half, print real PDFs and rasterize them. The procedure and the
 * measured baselines are in Building Apps/Field Portal/docs/08-changelog.md (2026-08-20).
 */

const FP = process.env.FP_ORIGIN || 'https://fp.unclogme.app';
const VERBOSE = process.argv.includes('--verbose');

// The two strings the renderer waits for. Lowercased, whitespace-collapsed, exactly as
// pdf_service/generators/visit_report.py compares them.
const MARKERS = ['service performed', 'issued by unclogme llc'];

const results = [];
const ok   = (name, detail) => results.push({ pass: true,  name, detail });
const bad  = (name, detail) => results.push({ pass: false, name, detail });

/** Strip @media print blocks so a rule can be attributed to screen or to print. */
function splitMedia(css) {
  const blocks = [];
  let i = 0;
  while (true) {
    const at = css.indexOf('@media print', i);
    if (at === -1) break;
    const open = css.indexOf('{', at);
    let depth = 0, k = open;
    for (; k < css.length; k++) {
      if (css[k] === '{') depth++;
      else if (css[k] === '}') { depth--; if (!depth) break; }
    }
    blocks.push(css.slice(open + 1, k));
    i = k + 1;
  }
  const outside = css.replace(/@media print\s*\{(?:[^{}]|\{[^{}]*\})*\}/g, '');
  return { print: blocks.join('\n'), screen: outside, blockCount: blocks.length };
}

/**
 * --self-test: prove the detectors can FAIL before trusting a pass.
 *
 * Every assertion in this file is a regex, and a regex that silently matches nothing is
 * indistinguishable from a healthy app. This repo has been bitten by that shape more than
 * once (a ["']-only literal extractor reporting an entire app calls zero RPCs; a
 * case-sensitive @page check reporting a missing rule that was there). So each fatal-shape
 * detector is fired at input that MUST trip it.
 */
if (process.argv.includes('--self-test')) {
  const cases = [
    ['heading moved into ::before content',
      /content\s*:\s*["'][^"']*(service performed|issued by unclogme llc)/i,
      '.svcrep-section-title::before{content:"SERVICE PERFORMED";}'],
    ['section title hidden in print',
      /\.svcrep-section-title[^{}]*\{[^}]*display\s*:\s*none/i,
      '.svcrep-section-title{display:none}'],
    ['uppercasing a .svcrep rule',
      /\.svcrep[^{}]*\{[^}]*text-transform\s*:\s*uppercase/i,
      '.svcrep-section-title{text-transform:uppercase;color:red}'],
    ['@page Letter present (capital L, the real casing)',
      /@page[^{}]*\{[^}]*size\s*:\s*letter/i,
      '@page{size:Letter;margin:.4in}'],
    ['identity 4-track grid, whitespace tolerant',
      /\.svcrep-identity-row-[12][^{}]*\{[^}]*repeat\(\s*4\s*,\s*1fr\s*\)/i,
      '.svcrep-identity-row-1{grid-template-columns:repeat( 4 , 1fr )}'],
    ['lone document half width, whitespace tolerant',
      /only-child[^{}]*\{[^}]*flex\s*:\s*0\s*0\s*calc\(\s*50%/i,
      '.a .svcrep-evidence-item:only-child{flex:0 0 calc(50% - 6px)}'],
  ];
  let bad = 0;
  console.log('report-print-contract --self-test\n');
  for (const [name, re, fixture] of cases) {
    const fired = re.test(fixture);
    if (!fired) bad++;
    console.log(`  ${fired ? 'ok  ' : 'FAIL'}  detector fires on: ${name}`);
  }
  // and a negative: the fatal-shape regex must NOT fire on ordinary generated content
  const benign = '.svcrep-foot::after{content:"·"}';
  const falsePos = /content\s*:\s*["'][^"']*(service performed|issued by unclogme llc)/i.test(benign);
  console.log(`  ${falsePos ? 'FAIL' : 'ok  '}  no false positive on a benign ::after separator`);
  if (falsePos) bad++;
  console.log(`\n  ${cases.length + 1 - bad}/${cases.length + 1} detector checks passed`);
  process.exit(bad ? 1 : 0);
}

(async () => {
  // ---- discover the shipped assets -----------------------------------------
  let html;
  try {
    html = await fetch(`${FP}/?cb=${Date.now()}`, { headers: { 'cache-control': 'no-cache' } }).then(r => r.text());
  } catch (e) {
    console.error(`FAIL: cannot reach ${FP}: ${e.message}`);
    process.exit(2);
  }
  const assets = [...new Set([...html.matchAll(/\/assets\/([A-Za-z0-9_.-]+\.(?:js|css))/g)].map(m => m[1]))];
  const cssName = assets.find(a => a.endsWith('.css'));
  if (!cssName) { console.error('FAIL: no stylesheet found in the shipped index'); process.exit(2); }

  const css = await fetch(`${FP}/assets/${cssName}`).then(r => r.text());

  /**
   * 🛑 WALK THE CHUNKS TRANSITIVELY. index.html lists only the entry chunks. The report
   * route is code-split and lazily imported, so its bundle is referenced from INSIDE
   * another chunk and never appears in the shipped index.
   *
   * Reading index.html alone fetched 4 files and reported both renderer markers MISSING,
   * on a page that had been verified rendering them in the live DOM an hour earlier. That
   * is a false FAIL on the most important assertion in this file, i.e. exactly the kind of
   * check that gets muted as noisy and then never catches the real thing.
   *
   * The workspace CLAUDE.md already records this failure mode from the DERM Stamp Studio
   * sweep, which walked 3 chunks of a 6-chunk app and confidently reported zero RPCs.
   */
  const seen = new Set(assets.filter(a => a.endsWith('.js')));
  const queue = [...seen];
  const sources = [];
  while (queue.length) {
    const name = queue.shift();
    let body;
    try { body = await fetch(`${FP}/assets/${name}`).then(r => r.ok ? r.text() : ''); } catch { body = ''; }
    if (!body) continue;
    sources.push(body);
    for (const m of body.matchAll(/["'`](?:\.?\/)?(?:assets\/)?([A-Za-z0-9_.-]+-[A-Za-z0-9_-]{8}\.js)["'`]/g)) {
      if (!seen.has(m[1])) { seen.add(m[1]); queue.push(m[1]); }
    }
  }
  const jsNames = [...seen];
  const js = sources.join('\n');

  // CONTROL for the walk itself: a code-split app has more than its entry chunks, and a
  // walk that finds none has silently degraded to reading index.html.
  if (jsNames.length <= assets.filter(a => a.endsWith('.js')).length) {
    console.error(`FAIL: chunk walk found no lazily-loaded chunks (${jsNames.length}); the walk is broken, not the app`);
    process.exit(2);
  }

  // CONTROL. Every assertion below is worthless if we fetched the wrong thing, and a
  // fallback page is served without an auth token, which has produced a 20KB stylesheet
  // that failed every check for the wrong reason. Refuse to report on a suspect fetch.
  if (!/\.svcrep/.test(css)) { console.error(`FAIL: ${cssName} contains no .svcrep rules; wrong asset fetched`); process.exit(2); }
  const svcrepRules = (css.match(/\.svcrep/g) || []).length;
  if (svcrepRules < 30) { console.error(`FAIL: only ${svcrepRules} .svcrep rules in ${cssName}; expected 60+`); process.exit(2); }

  const { print, screen, blockCount } = splitMedia(css);
  if (!blockCount) { console.error('FAIL: no @media print block in the stylesheet'); process.exit(2); }

  // ---- 1. the fatal shapes, which silence the whole feature ------------------
  // A heading rendered through generated content leaves document.innerText and the
  // renderer then refuses every visit.
  bad_if('no heading text in CSS ::before/::after content',
    new RegExp(`content\\s*:\\s*["'][^"']*(${MARKERS.map(esc).join('|')})`, 'i').test(css));
  bad_if('no display:none on .svcrep-section-title in print',
    /\.svcrep-section-title[^{}]*\{[^}]*display\s*:\s*none/i.test(print));
  bad_if('no text-transform:uppercase on any .svcrep rule',
    /\.svcrep[^{}]*\{[^}]*text-transform\s*:\s*uppercase/i.test(css));

  // The marker strings must live in the JS (as rendered text), not in the stylesheet.
  for (const m of MARKERS) {
    const inJs  = new RegExp(esc(m), 'i').test(js);
    const inCss = new RegExp(`content\\s*:\\s*["'][^"']*${esc(m)}`, 'i').test(css);
    if (inJs && !inCss) ok(`renderer marker present as text: "${m}"`, 'found in the JS bundle');
    else if (inCss)     bad(`renderer marker "${m}" is CSS generated content`, 'this produces ZERO PDFs for every visit');
    else                bad(`renderer marker "${m}" not found in the shipped bundle`, 'the renderer will refuse to print');
  }

  // ---- 2. load-bearing print rules -------------------------------------------
  need('@page is Letter',                    /@page[^{}]*\{[^}]*size\s*:\s*letter/i.test(css));
  need('@page margin is .4in',               /@page[^{}]*\{[^}]*margin\s*:\s*\.?0?\.4in/i.test(css));
  need('photo container is block in print',  /\.svcrep-photos[^{}]*\{[^}]*display\s*:\s*block/i.test(print));
  need('photo tiles are inline-block in print', /display\s*:\s*inline-block/i.test(print));
  need('photo container is grid on screen',  /\.svcrep-photos[^{}]*\{[^}]*display\s*:\s*grid/i.test(screen));
  need('photo section break-inside:avoid',   /\.svcrep-section:has\(\.svcrep-photos\)[^{}]*\{[^}]*break-inside\s*:\s*avoid/i.test(css));
  need('individual photo break-inside:avoid',/\.svcrep-photo[^{}]*\{[^}]*break-inside\s*:\s*avoid/i.test(css));
  need('section title break-after:avoid',    /\.svcrep-section-title[^{}]*\{[^}]*break-after\s*:\s*avoid/i.test(css));
  // Fred's instruction: page 1 is data, the compliance documents go on their own page.
  need('evidence keeps its forced page break', /\.svcrep-break-before[^{}]*\{[^}]*break-before\s*:\s*page/i.test(css));

  // ---- 3. the alignment fixes shipped 2026-08-20 ------------------------------
  need('identity rows share one 4-track grid', /\.svcrep-identity-row-[12][^{}]*\{[^}]*repeat\(\s*4\s*,\s*1fr\s*\)/i.test(css));
  need('evidence row is centred',              /\.svcrep-evidence-row[^{}]*\{[^}]*justify-content\s*:\s*center/i.test(css));
  need('a lone document keeps its half width', /only-child[^{}]*\{[^}]*flex\s*:\s*0\s*0\s*calc\(\s*50%/i.test(css));

  // ---- 4. brand -------------------------------------------------------------
  need('Manrope is declared', /Manrope/i.test(css));
  need('brand red #F14714 present', /f14714/i.test(css));

  // ---- report ---------------------------------------------------------------
  const failed = results.filter(r => !r.pass);
  console.log(`\nreport-print-contract  ${FP}`);
  console.log(`  stylesheet ${cssName}  (${css.length} bytes, ${svcrepRules} .svcrep rules, ${blockCount} @media print blocks)`);
  console.log(`  js bundles ${jsNames.length}  (${js.length} bytes)\n`);
  for (const r of results) if (VERBOSE || !r.pass)
    console.log(`  ${r.pass ? 'ok  ' : 'FAIL'}  ${r.name}${r.detail ? '  — ' + r.detail : ''}`);
  console.log(`\n  ${results.length - failed.length}/${results.length} passed`);
  if (failed.length) {
    console.log('\n  🛑 A failure here can mean every visit stops producing a PDF, and the first');
    console.log('     symptom would be a failed compliance email to a municipality.');
    process.exit(1);
  }
  console.log('  (geometry, page counts and blank pages are NOT covered — see the header)');
  process.exit(0);

  function need(name, cond) { cond ? ok(name) : bad(name, 'required rule missing'); }
  function bad_if(name, cond) { cond ? bad(name, 'FATAL SHAPE PRESENT') : ok(name); }
})();

function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
