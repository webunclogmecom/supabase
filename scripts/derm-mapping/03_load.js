// 03_load.js data/match_<nn>.json : upsert a window's reconciled rows into derm.address_row_map.
// Idempotent on (dump_folder,page,row_index). Resolves client_id from code (NOCODE-<id> => id).
// NEVER overwrites a human's reviewed_by/reviewed_at (those columns are omitted from the UPDATE SET).
const fs = require('fs');
const { q } = require('./lib/db');
const S = s => s == null ? 'NULL' : `'${String(s).replace(/'/g, "''")}'`;
const J = o => `'${JSON.stringify(o || {}).replace(/'/g, "''")}'::jsonb`;
(async () => {
  const file = process.argv[2];
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  // resolve code -> client_id once (NOCODE-<id> encodes the id directly for null-code clients)
  const codes = [...new Set(data.sheets.flatMap(s => s.rows).map(r => r.matched_client_code).filter(c => c && !/^NOCODE-\d+$/.test(c)))];
  let byCode = {};
  if (codes.length) {
    const rows = await q(`SELECT id, client_code FROM clients WHERE client_code IN (${codes.map(S).join(',')})`);
    for (const r of rows) byCode[r.client_code] = r.id;
  }
  const resolveId = code => { if (!code) return null; const m = /^NOCODE-(\d+)$/.exec(code); return m ? Number(m[1]) : (byCode[code] || null); };
  let n = 0;
  for (const sheet of data.sheets) {
    for (const r of sheet.rows) {
      const cid = resolveId(r.matched_client_code);
      const flags = {};
      if (r.assignment_status === 'unmatched') flags.unlinked_facility = true;
      const sql = `
        INSERT INTO derm.address_row_map
          (dump_folder,white_manifest_number,page,row_index,image_url,facility_name_read,address_read,
           matched_client_id,assignment_status,confidence,agent_agreement,flags,source)
        VALUES (${S(sheet.dump_folder)},${S(sheet.wm)},${r.page},${r.row_index},
           ${S(sheet.local_files[r.page - 1] ? sheet.page_urls[r.page - 1] : sheet.page_urls[0])},
           ${S(r.facility_name_read)},${S(r.address_read)},${cid != null ? cid : 'NULL'},
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
  // OCR flywheel: fold this batch's high-trust matches into the persistent label store
  await require('./lib/aliases').refresh();
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
