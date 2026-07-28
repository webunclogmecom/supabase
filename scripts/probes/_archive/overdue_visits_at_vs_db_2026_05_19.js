// overdue_visits_at_vs_db_2026_05_19.js
//
// Identifies clients in AT who are DUE for a visit by end-of-May 2026 but
// have NO upcoming visit scheduled in AT.
//
// AT is still the canonical scheduling system until the Lovable Monthly View
// app ships. The Lovable recurring-visit cron exists but is disabled. So this
// is just an AT-side view of who needs visits scheduled.
//
// Covers GT and CL service lines independently (a Lift Station client has
// both, so will appear in BOTH sections if missing both visit types).
//
// Output: docs/audits/2026-05-19/OPS_LIST_OVERDUE_VISITS_2026-05-19.md

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

const TODAY = new Date('2026-05-19T00:00:00Z');
const END_OF_MONTH = new Date('2026-05-31T23:59:59Z');

function atGet(p) {
  return new Promise((res, rej) => {
    https.get({ hostname: 'api.airtable.com', path: p, headers: { Authorization: 'Bearer ' + AT_KEY } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,200))); res(JSON.parse(d)); }); }).on('error', rej);
  });
}

async function atFetchAll(table, filter) {
  let all = []; let offset = null;
  do {
    const q = new URLSearchParams({ pageSize: '100' });
    if (filter) q.append('filterByFormula', filter);
    if (offset) q.append('offset', offset);
    const j = await atGet('/v0/' + AT_BASE + '/' + encodeURIComponent(table) + '?' + q);
    all = all.concat(j.records); offset = j.offset;
  } while (offset);
  return all;
}

const SERVICE_LINES = [
  {
    code: 'GT',
    label: 'Grease Trap (incl. Gray Water + Lift Station GT-side)',
    atFreq: 'GT Frequency',
    atLastVisit: 'GT Last Visit (visits table)',
    atNextCalc:  'GT Next Visit Calculated',
    qualifyingServiceTypes: ['Grease Trap', 'Gray Water pumping', 'Lift Station'],
    atVisitServiceType: 'GT',
  },
  {
    code: 'CL',
    label: 'Cleaning (MAIN CL, AUX Cleaning, Warranty of drainage, Lift Station CL-side)',
    atFreq: 'CL Frequency',
    atLastVisit: 'CL Last Visit',
    atNextCalc:  'CL Next Visit Calculated',
    qualifyingServiceTypes: ['MAIN CL', 'AUX Cleaning', 'Warranty of drainage', 'Lift Station'],
    atVisitServiceType: 'CL',
  },
];

(async () => {
  console.log('# Missing-visits-in-AT report — ' + TODAY.toISOString().slice(0,10));

  // 1. Recurring-only clients (Active is excluded — they're one-off / non-subscription)
  console.log('\n[1] Fetching AT Clients (Recurring only)...');
  const allClients = await atFetchAll('Clients', "{ACTIVE/INACTIVE}='Recurring'");
  console.log('  total:', allClients.length);

  // 2. AT Visits — upcoming, in the window
  console.log('\n[2] Fetching AT Visits with Status=Upcoming through end-of-May...');
  const visits = await atFetchAll('Visits',
    "AND({Status}='Upcoming',IS_AFTER({Visit Date},DATEADD(TODAY(),-1,'days')),IS_BEFORE({Visit Date},'2026-06-01'))"
  );
  console.log('  upcoming visits in window:', visits.length);

  // Index: visitsByClient[clientCode][serviceType] = [date, date...]
  const visitsByClient = {};
  for (const v of visits) {
    const clientCode = (v.fields['Client Code #3 (from Client)'] || [])[0];
    const st = v.fields['Service Type'];
    if (!clientCode || !st) continue;
    if (!visitsByClient[clientCode]) visitsByClient[clientCode] = {};
    if (!visitsByClient[clientCode][st]) visitsByClient[clientCode][st] = [];
    visitsByClient[clientCode][st].push(v.fields['Visit Date']);
  }

  // 3. Per service line, find clients due but with no upcoming
  const result = {};
  for (const line of SERVICE_LINES) {
    const missing = [];
    for (const rec of allClients) {
      const f = rec.fields;
      const st = f['Service Type'] || [];
      if (!st.some(s => line.qualifyingServiceTypes.includes(s))) continue;

      const clientCode = f['Client Code #3'];
      if (!clientCode) continue;

      const freq = f[line.atFreq];
      if (!freq) continue;  // no frequency on this line for this client

      const calcDue = f[line.atNextCalc] ? new Date(f[line.atNextCalc]) : null;
      if (!calcDue || calcDue > END_OF_MONTH) continue;  // not due in window

      // Does this client have an upcoming AT visit of this service line?
      const upcoming = (visitsByClient[clientCode] || {})[line.atVisitServiceType] || [];
      if (upcoming.length > 0) continue;  // has a visit scheduled

      const lastVisit = f[line.atLastVisit];
      const daysOverdue = Math.floor((TODAY - calcDue) / (1000 * 60 * 60 * 24));
      const truck = Array.isArray(f['Truck']) ? f['Truck'][0] : f['Truck'];
      const zone = f['Zone'];

      missing.push({
        clientCode,
        clientName: (f['Client Name'] || '').replace(/\s+/g, ' ').trim(),
        serviceTypes: st.join(', '),
        freq,
        lastVisit: lastVisit || '—',
        calcDue: f[line.atNextCalc],
        daysOverdue,
        truck: truck || '—',
        zone: zone || '—',
      });
    }
    missing.sort((a, b) => b.daysOverdue - a.daysOverdue);
    result[line.code] = missing;
    console.log(`\n[${line.code}] missing in AT:`, missing.length);
  }

  // 4. Write markdown
  const outDir = path.resolve(__dirname, '../../docs/audits/2026-05-19');
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, 'OPS_LIST_OVERDUE_VISITS_2026-05-19.md');

  function table(rows) {
    if (rows.length === 0) return '_None._\n';
    const lines = [
      '| # | Code | Client | Service Type | Freq | Last visit | Should be | Days past due | Truck | Zone |',
      '|---|---|---|---|---|---|---|---|---|---|',
    ];
    rows.forEach((r, i) => {
      lines.push(`| ${i+1} | ${r.clientCode} | ${r.clientName.slice(0, 35)} | ${r.serviceTypes} | ${r.freq}d | ${r.lastVisit} | ${r.calcDue} | ${r.daysOverdue} | ${r.truck} | ${r.zone} |`);
    });
    return lines.join('\n') + '\n';
  }

  const md = `# Missing visits in Airtable — ${TODAY.toISOString().slice(0,10)}

_Recurring AT clients who are due by 2026-05-31 but have NO upcoming visit scheduled in AT. Sorted by days past due (most urgent first). Negative "Days past due" means due-soon-but-not-yet-overdue._

## TL;DR

| Service line | Missing in AT |
|---|---:|
| **GT** (Grease Trap + Gray Water + Lift Station GT-side) | **${result.GT.length}** |
| **CL** (MAIN CL + AUX Cleaning + Warranty of drainage + Lift Station CL-side) | **${result.CL.length}** |

_Lift Station clients appear in BOTH sections if missing both visit types. "Requires Phone Call" clients excluded (emergency-only, no recurring schedule)._

---

# GT visits — need scheduling (${result.GT.length})

${table(result.GT)}

---

# CL visits — need scheduling (${result.CL.length})

${table(result.CL)}

---

## Notes

- Filter: \`ACTIVE/INACTIVE = 'Recurring'\` — Active, PAUSED, INACTIVE all excluded.
- "Due" = AT's \`Next Visit Calculated\` ≤ 2026-05-31. That's \`Last Visit + Frequency\` per AT's own formula.
- "No upcoming visit" = no AT Visit with \`Status='Upcoming'\` for that client + that service line, dated through 2026-05-31.
- Cross-key: AT \`Client Code #3\`.
`;

  fs.writeFileSync(outFile, md);
  console.log(`\nReport written: ${outFile}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
