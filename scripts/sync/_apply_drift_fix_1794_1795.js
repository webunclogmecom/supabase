// Apply targeted date-drift fix: bring rows 1794 and 1795 in line with
// Jobber's current state. Both visits are UPCOMING in Jobber (not yet
// completed), so updating visit_date / start_at / end_at is safe.
//
// Audit attribution: writes use X-App-Source: 'sql' header so the audit
// row clearly shows these came from a manual repair, not from a Calendar
// or Field Portal user.
//
// Dry-run by default. Pass --apply to actually mutate.

const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const APPLY = process.argv.includes('--apply');

const FIXES = [
  { id: 1794, client_code: '170-PV', visit_date: '2026-07-04', start_at: '2026-07-04T11:15:00Z', end_at: '2026-07-04T12:15:00Z' },
  { id: 1795, client_code: '093-KC', visit_date: '2026-07-04', start_at: '2026-07-04T08:30:00Z', end_at: '2026-07-04T09:30:00Z' },
];

async function run() {
  for (const fix of FIXES) {
    const body = {
      visit_date: fix.visit_date,
      start_at: fix.start_at,
      end_at: fix.end_at,
    };
    console.log(`${APPLY ? 'APPLY' : 'DRY-RUN'}: visit id=${fix.id} (${fix.client_code}) → date=${fix.visit_date} ${fix.start_at} → ${fix.end_at}`);
    if (!APPLY) continue;
    const r = await fetch(`${URL}/rest/v1/visits?id=eq.${fix.id}`, {
      method: 'PATCH',
      headers: {
        apikey: KEY,
        Authorization: `Bearer ${KEY}`,
        'Content-Type': 'application/json',
        'X-App-Source': 'sql',
        Prefer: 'return=representation',
      },
      body: JSON.stringify(body),
    });
    if (!r.ok) {
      console.error(`  FAILED: ${r.status} ${await r.text()}`);
    } else {
      const j = await r.json();
      console.log(`  OK → visit_date=${j[0].visit_date} start_at=${j[0].start_at}`);
    }
  }
}

run().catch(e => { console.error(e); process.exit(1); });
