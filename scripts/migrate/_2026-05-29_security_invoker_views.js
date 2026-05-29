// Apply security_invoker=true to 3 views surfaced by zero-runs iter 1.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;

const sql = `
  ALTER VIEW public.manifest_pickable_visits SET (security_invoker = true);
  ALTER VIEW public.visits_with_status SET (security_invoker = true);
  ALTER VIEW public.zones_with_usage SET (security_invoker = true);
`;

fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }),
}).then(r => r.text()).then(t => console.log('result:', t.slice(0, 200)));
