// calibrate_ocr_receipts.js — calibrate the receipt-OCR skill against
// ground-truth values. For each manifest with a known number + dump date,
// OCR the receipt photo and compare extracted vs stored values.
//
// State persists between runs in:
//   docs/audits/2026-05-19/ocr_calibration/state.json
// Per-batch results in:
//   docs/audits/2026-05-19/ocr_calibration/batch_<n>_<promptVer>.json
// Cumulative report at:
//   docs/audits/2026-05-19/ocr_calibration/CALIBRATION_REPORT.md
//
// CLI:
//   node scripts/sync/calibrate_ocr_receipts.js                  # 1 batch (10)
//   node scripts/sync/calibrate_ocr_receipts.js --batch-size=20  # 1 batch (20)
//   node scripts/sync/calibrate_ocr_receipts.js --batches=5      # 5 batches in a row
//   node scripts/sync/calibrate_ocr_receipts.js --reset          # clear state, rebuild queue
//
// Prompt versions live in scripts/sync/lib/receipt_ocr_prompts.js — increment
// the version + add a new entry there if you change the prompt.

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
if (!ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY required in .env');

const BATCH_SIZE = parseInt((process.argv.find(a => a.startsWith('--batch-size=')) || '--batch-size=10').split('=')[1], 10);
const NUM_BATCHES = parseInt((process.argv.find(a => a.startsWith('--batches=')) || '--batches=1').split('=')[1], 10);
const RESET = process.argv.includes('--reset');

const STATE_DIR = path.resolve(__dirname, '../../docs/audits/2026-05-19/ocr_calibration');
const STATE_FILE = path.join(STATE_DIR, 'state.json');
const REPORT_FILE = path.join(STATE_DIR, 'CALIBRATION_REPORT.md');

const PROMPTS = require('./lib/receipt_ocr_prompts');
const CURRENT_VERSION = PROMPTS.CURRENT_VERSION;
const PROMPT = PROMPTS[CURRENT_VERSION];

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function fetchBytes(url) {
  return new Promise((res, rej) => {
    https.get(url, r => {
      if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) return fetchBytes(r.headers.location).then(res, rej);
      if (r.statusCode !== 200) return rej(new Error('HTTP ' + r.statusCode));
      const chunks = []; r.on('data', c => chunks.push(c));
      r.on('end', () => res({ buf: Buffer.concat(chunks), contentType: r.headers['content-type'] || 'image/jpeg' }));
    }).on('error', rej);
  });
}

async function askClaude(imageBuf, contentType, promptText) {
  const mediaType = contentType.split(';')[0].trim();
  const body = JSON.stringify({
    model: 'claude-opus-4-7',
    max_tokens: 400,
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mediaType, data: imageBuf.toString('base64') } },
        { type: 'text', text: promptText },
      ]
    }]
  });
  return new Promise((res, rej) => {
    const req = https.request({ hostname: 'api.anthropic.com', path: '/v1/messages', method: 'POST', headers: { 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error('Anthropic ' + r.statusCode + ': ' + d.slice(0, 400))); try { res(JSON.parse(d)); } catch (e) { rej(e); } }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function loadState() {
  if (fs.existsSync(STATE_FILE) && !RESET) {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf-8'));
  }
  return null;
}

async function initializeState() {
  console.log('Building work queue...');
  const candidates = await pg(`
    SELECT id, white_manifest_number, yellow_ticket_number, dump_ticket_date::text AS dump_ticket_date, derm_manifest_url
    FROM public.derm_manifests
    WHERE derm_manifest_url IS NOT NULL
      AND dump_ticket_date IS NOT NULL
      AND (white_manifest_number IS NOT NULL OR yellow_ticket_number IS NOT NULL)
    ORDER BY id`);
  console.log('  Candidates:', candidates.length);

  return {
    initialized_at: new Date().toISOString(),
    total: candidates.length,
    queue: candidates,
    processed_ids: [],
    batches: [],
    cumulative_stats: {
      total_tested: 0,
      jurisdiction_correct: 0,
      number_correct: 0,
      date_correct: 0,
      all_three_correct: 0,
      errors: 0,
    },
  };
}

function saveState(state) {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function normalizeDate(s) {
  if (!s) return null;
  // Accept YYYY-MM-DD or MM/DD/YYYY or other forms; output YYYY-MM-DD
  const m = String(s).match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  const us = String(s).match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})/);
  if (us) {
    const yyyy = us[3].length === 2 ? `20${us[3]}` : us[3];
    return `${yyyy}-${us[1].padStart(2,'0')}-${us[2].padStart(2,'0')}`;
  }
  return String(s);
}

function compareResults(m, parsed) {
  const expectedJurisdiction = m.yellow_ticket_number ? 'broward' : 'dade';
  const expectedNumber = m.yellow_ticket_number || m.white_manifest_number;
  const expectedDate = normalizeDate(m.dump_ticket_date);

  const ocrJurisdiction = (parsed.jurisdiction || '').toLowerCase();
  const ocrNumber = (parsed.number || '').replace(/\D/g, '');  // digits only
  const ocrDate = normalizeDate(parsed.dump_date);

  return {
    expected: { jurisdiction: expectedJurisdiction, number: expectedNumber, date: expectedDate },
    ocr:      { jurisdiction: ocrJurisdiction,      number: ocrNumber,      date: ocrDate },
    match: {
      jurisdiction: expectedJurisdiction === ocrJurisdiction,
      number: expectedNumber === ocrNumber,
      date: expectedDate === ocrDate,
    },
  };
}

async function runOneBatch(state) {
  const batchNum = state.batches.length + 1;
  const batchSize = Math.min(BATCH_SIZE, state.queue.length);
  if (batchSize === 0) { console.log('Queue empty.'); return null; }
  const batch = state.queue.splice(0, batchSize);
  console.log(`\n--- Batch ${batchNum} (prompt ${CURRENT_VERSION}, n=${batchSize}, remaining after: ${state.queue.length}) ---`);

  const batchResults = [];
  let errs = 0;
  for (const m of batch) {
    process.stdout.write(`  ${m.id} ... `);
    try {
      const { buf, contentType } = await fetchBytes(m.derm_manifest_url);
      const resp = await askClaude(buf, contentType, PROMPT);
      const text = (resp.content || []).map(b => b.text || '').join('').trim();
      let parsed; try { parsed = JSON.parse(text); } catch { parsed = { _raw: text, _parseError: true }; }
      const cmp = compareResults(m, parsed);
      const allMatch = cmp.match.jurisdiction && cmp.match.number && cmp.match.date;
      const symbol = allMatch ? 'OK' : (
        (cmp.match.jurisdiction ? 'J' : 'j') +
        (cmp.match.number ? 'N' : 'n') +
        (cmp.match.date ? 'D' : 'd')
      );
      console.log(symbol, JSON.stringify(cmp.ocr));
      batchResults.push({ manifest_id: m.id, prompt_version: CURRENT_VERSION, ...cmp, parsed });
      state.processed_ids.push(m.id);
    } catch (e) {
      console.log('ERR:', e.message.slice(0, 60));
      batchResults.push({ manifest_id: m.id, prompt_version: CURRENT_VERSION, error: e.message });
      state.processed_ids.push(m.id);
      errs++;
    }
  }

  // Tally batch
  const successful = batchResults.filter(r => !r.error);
  const stat = {
    n: batchResults.length,
    errors: errs,
    jurisdiction_correct: successful.filter(r => r.match && r.match.jurisdiction).length,
    number_correct:       successful.filter(r => r.match && r.match.number).length,
    date_correct:         successful.filter(r => r.match && r.match.date).length,
    all_three_correct:    successful.filter(r => r.match && r.match.jurisdiction && r.match.number && r.match.date).length,
  };
  const pct = n => batchResults.length ? ((n / batchResults.length) * 100).toFixed(0) : '0';
  console.log(`  → jurisdiction ${pct(stat.jurisdiction_correct)}% · number ${pct(stat.number_correct)}% · date ${pct(stat.date_correct)}% · all-three ${pct(stat.all_three_correct)}%`);

  // Failure detail summary
  const failures = successful.filter(r => !(r.match.jurisdiction && r.match.number && r.match.date));
  if (failures.length > 0) {
    console.log(`  Failures (${failures.length}):`);
    for (const f of failures) {
      const w = [];
      if (!f.match.jurisdiction) w.push(`jurisdiction: exp=${f.expected.jurisdiction} got=${f.ocr.jurisdiction}`);
      if (!f.match.number) w.push(`number: exp=${f.expected.number} got=${f.ocr.number}`);
      if (!f.match.date) w.push(`date: exp=${f.expected.date} got=${f.ocr.date}`);
      console.log(`    [${f.manifest_id}] ${w.join('; ')}`);
    }
  }

  // Cumulative
  state.cumulative_stats.total_tested += stat.n;
  state.cumulative_stats.errors += stat.errors;
  state.cumulative_stats.jurisdiction_correct += stat.jurisdiction_correct;
  state.cumulative_stats.number_correct += stat.number_correct;
  state.cumulative_stats.date_correct += stat.date_correct;
  state.cumulative_stats.all_three_correct += stat.all_three_correct;

  state.batches.push({
    batch_num: batchNum,
    prompt_version: CURRENT_VERSION,
    timestamp: new Date().toISOString(),
    stats: stat,
  });

  // Persist
  fs.writeFileSync(path.join(STATE_DIR, `batch_${String(batchNum).padStart(3,'0')}_${CURRENT_VERSION}.json`), JSON.stringify(batchResults, null, 2));

  return { batchNum, stat, failures };
}

(async () => {
  fs.mkdirSync(STATE_DIR, { recursive: true });
  let state = loadState();
  if (!state) {
    state = await initializeState();
    saveState(state);
  }
  console.log(`Loaded state: ${state.processed_ids.length}/${state.total} done, ${state.queue.length} remaining`);

  for (let i = 0; i < NUM_BATCHES; i++) {
    const out = await runOneBatch(state);
    if (!out) break;
    saveState(state);
  }

  // Update report
  const c = state.cumulative_stats;
  const pct = n => c.total_tested ? ((n / c.total_tested) * 100).toFixed(1) : '0';
  console.log('\n=== Cumulative ===');
  console.log(`  Tested: ${c.total_tested}/${state.total}`);
  console.log(`  jurisdiction ${pct(c.jurisdiction_correct)}% · number ${pct(c.number_correct)}% · date ${pct(c.date_correct)}% · all-three ${pct(c.all_three_correct)}% · errors ${c.errors}`);

  // Cumulative markdown report
  const report = `# OCR Receipt Calibration — running report

_Last updated ${new Date().toISOString()}_

## Cumulative accuracy

| Metric | Correct | Total | % |
|---|---:|---:|---:|
| Jurisdiction match | ${c.jurisdiction_correct} | ${c.total_tested} | ${pct(c.jurisdiction_correct)}% |
| Number match | ${c.number_correct} | ${c.total_tested} | ${pct(c.number_correct)}% |
| Dump date match | ${c.date_correct} | ${c.total_tested} | ${pct(c.date_correct)}% |
| All three correct | ${c.all_three_correct} | ${c.total_tested} | ${pct(c.all_three_correct)}% |
| Errors (fetch / parse) | ${c.errors} | ${c.total_tested} | ${pct(c.errors)}% |

Progress: **${c.total_tested}/${state.total}** (${((c.total_tested/state.total)*100).toFixed(1)}%)

## Per-batch detail

| Batch | Prompt | Tested | Jur OK | # OK | Date OK | All 3 |
|---|---|---:|---:|---:|---:|---:|
${state.batches.map(b => `| ${b.batch_num} | ${b.prompt_version} | ${b.stats.n} | ${b.stats.jurisdiction_correct} | ${b.stats.number_correct} | ${b.stats.date_correct} | ${b.stats.all_three_correct} |`).join('\n')}

## Prompt history

Current version: \`${CURRENT_VERSION}\` — see [\`scripts/sync/lib/receipt_ocr_prompts.js\`](../../../scripts/sync/lib/receipt_ocr_prompts.js)
`;
  fs.writeFileSync(REPORT_FILE, report);
  console.log(`\nReport written: ${REPORT_FILE}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
