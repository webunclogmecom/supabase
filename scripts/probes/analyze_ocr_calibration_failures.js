// analyze_ocr_calibration_failures.js — read all batch result files, classify
// failures into OCR-side vs source-data-side, output summary.

const fs = require('fs');
const path = require('path');

const DIR = path.resolve(__dirname, '../../docs/audits/2026-05-19/ocr_calibration');

const allResults = [];
for (const f of fs.readdirSync(DIR).filter(x => /^batch_\d+_v\d+\.json$/.test(x))) {
  allResults.push(...JSON.parse(fs.readFileSync(path.join(DIR, f), 'utf-8')));
}

console.log(`Total result rows loaded: ${allResults.length}`);

const ok = allResults.filter(r => !r.error && r.match && r.match.jurisdiction && r.match.number && r.match.date);
const errors = allResults.filter(r => r.error);
const failures = allResults.filter(r => !r.error && r.match && !(r.match.jurisdiction && r.match.number && r.match.date));

console.log(`OK: ${ok.length} · Failures: ${failures.length} · API errors: ${errors.length}`);

// Classify failures
const cats = {
  source_text_in_number: [],        // expected = text like "Broward", clearly AT data quality
  source_long_number: [],            // expected number length > 6 (probably AT typo)
  digit_off_by_one: [],              // numbers differ by 1 character only
  date_off_small: [],                // dates within 5 days of each other (close miss)
  date_year_wrong: [],               // year differs (model misread year)
  date_invalid: [],                  // OCR returned invalid date like Feb 31
  jurisdiction_mismatch: [],         // model said wrong jurisdiction
  ocr_returned_null: [],             // model returned null when value existed
  completely_different: [],          // wildly different values (probably wrong photo)
};

for (const f of failures) {
  const e = f.expected, o = f.ocr;

  if (!f.match.number) {
    if (e.number && /[^0-9]/.test(e.number)) cats.source_text_in_number.push(f);
    else if (e.number && e.number.length > 6) cats.source_long_number.push(f);
    else if (!o.number) cats.ocr_returned_null.push(f);
    else if (e.number && o.number && e.number.length === o.number.length) {
      const diffs = [...e.number].filter((c, i) => c !== o.number[i]).length;
      if (diffs === 1) cats.digit_off_by_one.push(f);
      else cats.completely_different.push(f);
    } else {
      cats.completely_different.push(f);
    }
  }

  if (!f.match.date && f.match.number) {
    // Number was right but date wrong — pure date issue
    if (!o.date) cats.ocr_returned_null.push(f);
    else if (o.date && /^(\d{4})-(\d{2})-(\d{2})$/.test(o.date)) {
      const m = o.date.match(/^(\d{4})-(\d{2})-(\d{2})$/);
      const [_, y, mo, d] = m;
      const day = parseInt(d, 10);
      const month = parseInt(mo, 10);
      // Check if invalid date
      const daysInMonth = new Date(parseInt(y, 10), month, 0).getDate();
      if (day > daysInMonth) cats.date_invalid.push(f);
      else if (e.date && e.date.slice(0, 4) !== o.date.slice(0, 4)) cats.date_year_wrong.push(f);
      else if (e.date) {
        const ed = new Date(e.date), od = new Date(o.date);
        const diff = Math.abs((ed - od) / 86400000);
        if (diff <= 7) cats.date_off_small.push(f);
        else cats.completely_different.push(f);
      }
    } else {
      cats.completely_different.push(f);
    }
  }

  if (!f.match.jurisdiction) cats.jurisdiction_mismatch.push(f);
}

console.log('\n=== Failure breakdown ===');
const lines = Object.entries(cats).map(([k, v]) => [k, v.length]);
lines.sort((a, b) => b[1] - a[1]);
for (const [cat, n] of lines) {
  if (n > 0) console.log(`  ${cat.padEnd(30)} ${n}`);
}

console.log('\n=== AT data quality (source side, not OCR) ===');
console.log(`  source_text_in_number:  ${cats.source_text_in_number.length} manifests`);
console.log(`  source_long_number:     ${cats.source_long_number.length} manifests`);
const sourceTotal = cats.source_text_in_number.length + cats.source_long_number.length;
console.log(`  Subtotal:               ${sourceTotal} (${(sourceTotal/failures.length*100).toFixed(0)}% of failures)`);

console.log('\n=== Manifests likely WRONG in AT (OCR found a better value) ===');
console.log('Top 10 candidates by jurisdiction signal:');
const ocrRightCandidates = [
  ...cats.source_text_in_number.slice(0, 5),
  ...cats.source_long_number.slice(0, 5),
];
for (const f of ocrRightCandidates) {
  console.log(`  manifest ${f.manifest_id}: AT="${f.expected.number}" → OCR="${f.ocr.number}" (jurisdiction ${f.ocr.jurisdiction})`);
}

// Output JSON dump for further analysis
fs.writeFileSync(path.join(DIR, 'failure_analysis.json'), JSON.stringify({
  summary: {
    total: allResults.length,
    ok: ok.length,
    failures: failures.length,
    api_errors: errors.length,
  },
  categories: Object.fromEntries(Object.entries(cats).map(([k, v]) => [k, v.length])),
  source_side_total: sourceTotal,
  source_side_pct_of_failures: (sourceTotal/failures.length*100).toFixed(1),
  by_category: cats,
}, null, 2));
console.log(`\nDetail JSON: ${path.join(DIR, 'failure_analysis.json')}`);
