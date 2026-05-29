// scripts/probes/_check_jobber_token.js — print Jobber token freshness from DB
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

(async () => {
  const r = await fetch(`${URL}/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token,refresh_token,expires_at`, {
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}` },
  });
  const rows = await r.json();
  const row = rows[0];
  if (!row) { console.log('no token row in webhook_tokens'); return; }
  const exp = new Date(row.expires_at);
  console.log('expires_at:    ', row.expires_at);
  console.log('now:           ', new Date().toISOString());
  console.log('remaining_min: ', Math.round((exp - new Date()) / 60000));
  console.log('access_token_len:', row.access_token?.length, 'first6:', row.access_token?.slice(0, 6));
})();
