// ============================================================================
// rescue_oversized.js — download 35 oversized Jobber attachments before signed
// URLs expire. Signed URLs were captured 2026-04-20 with 72h validity → they
// expire 2026-04-23. Need to fetch to local disk NOW so we don't lose the
// files when URLs expire / Jobber sunsets in May 2026.
//
// Writes files to ./oversized_backup/<attachment_id>_<filename>.
// Does NOT modify the DB (future: when R2/S3 storage is provisioned, re-upload
// from this backup and add a link row).
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');
const { newQuery } = require('../populate/lib/db');

const OUT_DIR = path.resolve(__dirname, '../../oversized_backup');
fs.mkdirSync(OUT_DIR, { recursive: true });

function downloadTo(url, filePath) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(filePath);
    const req = https.get(url, res => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        // follow redirect once
        file.close(() => fs.unlinkSync(filePath));
        return downloadTo(res.headers.location, filePath).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        file.close(() => fs.unlinkSync(filePath));
        return reject(new Error(`HTTP ${res.statusCode} ${url.slice(0, 80)}`));
      }
      res.pipe(file);
      file.on('finish', () => file.close(() => resolve(fs.statSync(filePath).size)));
    });
    req.on('error', err => { file.close(() => fs.unlinkSync(filePath)); reject(err); });
    req.setTimeout(300_000, () => req.destroy(new Error('timeout')));
  });
}

(async () => {
  const rows = await newQuery(
    `SELECT id, attachment_jobber_id, file_name, size_bytes, jobber_url_signed
     FROM jobber_oversized_attachments
     ORDER BY id;`
  );
  console.log(`${rows.length} files to rescue → ${OUT_DIR}`);

  let ok = 0, fail = 0;
  const failures = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    const safeName = r.file_name.replace(/[^\w.\-]/g, '_');
    const out = path.join(OUT_DIR, `${r.attachment_jobber_id}_${safeName}`);
    if (fs.existsSync(out) && fs.statSync(out).size === r.size_bytes) {
      console.log(`  [${i + 1}/${rows.length}] skip (already have ${out})`);
      ok++;
      continue;
    }
    try {
      process.stdout.write(`  [${i + 1}/${rows.length}] ${safeName} (${(r.size_bytes / 1024 / 1024).toFixed(1)}MB) ... `);
      const size = await downloadTo(r.jobber_url_signed, out);
      console.log(`ok ${size} bytes`);
      ok++;
    } catch (err) {
      console.log(`FAIL: ${err.message.slice(0, 120)}`);
      failures.push({ id: r.id, name: safeName, error: err.message });
      fail++;
    }
  }

  console.log(`\n${'='.repeat(60)}\nDone: ok=${ok} fail=${fail} (total ${rows.length})\n${'='.repeat(60)}`);
  if (failures.length) console.log('failures:', JSON.stringify(failures, null, 2));
})();
