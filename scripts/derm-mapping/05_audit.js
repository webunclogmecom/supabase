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
