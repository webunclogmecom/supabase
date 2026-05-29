// Add Donald Barron's Jobber ESL link (employee id=33).
// His Jobber user GID was found via the spot-check probe:
//   Z2lkOi8vSm9iYmVyL1VzZXIvNDAwMTU5Nw==  →  gid://Jobber/User/4001597
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SB_URL = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

(async () => {
  const r = await fetch(`${SB_URL}/rest/v1/entity_source_links`, {
    method: 'POST',
    headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, 'Content-Type': 'application/json', 'X-App-Source': 'sql', Prefer: 'return=representation' },
    body: JSON.stringify({
      entity_type: 'employee',
      entity_id: 33,
      source_system: 'jobber',
      source_id: 'Z2lkOi8vSm9iYmVyL1VzZXIvNDAwMTU5Nw==',
      source_name: 'Donald Barron',
      match_method: 'manual_audit_2026_05_29',
      match_confidence: 1.0
    })
  });
  console.log('Status:', r.status, await r.text());
})();
