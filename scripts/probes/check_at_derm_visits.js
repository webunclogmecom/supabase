// One-off: for the 13 orphaned DERM manifests, report each AT DERM record's
// `Visits` field (empty vs populated) + its dump/GT-last dates, to decide the
// source fix (populate Visits) vs a deeper issue (Visits point to missing visits).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const DERM_TABLE = 'tblz0CnWim7ViFjcw';
const recs = {
  recWJGedptCKHElMM: '294999/028-HUM', reck1LPtaPXto4w21: '294999/090-OAK',
  recdfULlkmaAv1GS3: '294999/106-ALC', recjR8UPg8Z6xdcVz: '294999/152-DAV',
  rec7qrgNXB5evS6R1: '294999/169-TCE', recJ3DV8k71utPcOz: '298064/010-CS',
  recYHUn2pBbtwtJ7K: '818188/025-GRO', recp82Xe4DY690kow: '822050/001-VIN',
  recvNfQWjOrp9iCbf: '822919/009-CN', recg8TwfvavY7nVOD: '824026/212-TRUE',
  recx8GS6WLt9pJPD0: '824533/221-MP', recaf61Ct1sK53Tzw: '824949/221-YAS',
  recuISA7Af2tvmfLv: '824949/222-SPE',
};
(async () => {
  for (const [id, label] of Object.entries(recs)) {
    try {
      const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${DERM_TABLE}/${id}`, { headers: { Authorization: `Bearer ${AT_KEY}` } }).then(x => x.json());
      const f = r.fields || {};
      const visits = f.Visits || [];
      console.log(`${label.padEnd(16)} Visits=${visits.length} [${visits.join(',') || 'EMPTY'}]  DumpTicket=${f['Date Dump Ticket'] || '-'}  GTLast=${f['GT Last Visit'] || '-'}`);
    } catch (e) { console.log(`${label.padEnd(16)} ERR ${String(e).slice(0, 80)}`); }
    await new Promise(rs => setTimeout(rs, 150));
  }
})();
