// 25_sandbox_vs_prod_audit.mjs
// Compare HR sandbox (klgtrdwrasrlxbmfyvdh) public.* vs Prod public.*:
//  - which tables exist on each
//  - row counts where possible
// Surfaces the gap between "claimed Prod mirror" and reality.

import 'dotenv/config';

const PROD = {
  url: process.env.SUPABASE_URL,
  key: process.env.SUPABASE_SERVICE_ROLE_KEY,
  label: 'PROD',
};
const SBX = {
  url: process.env.FIELD_PORTAL_SUPABASE_URL,
  key: process.env.FIELD_PORTAL_SUPABASE_SERVICE_ROLE_KEY,
  label: 'SANDBOX',
};

const CANDIDATES = [
  'clients','client_groups','client_contacts',
  'properties','service_configs',
  'gdos','derm_manifests','inspections','disposal_facilities',
  'visits','visit_assignments','line_items','notes','photos','photo_links','photo_classifications','manifest_visits',
  'jobs','quotes','invoices',
  'employees','vehicles','entity_source_links',
  'app_admin_users','app_shift_reviews','app_visit_reviews','visit_recommendations',
  'work_orders','crew_assignments','client_lookups','user_profiles',
];

async function probe(target, table) {
  const r = await fetch(`${target.url}/rest/v1/${table}?select=count`, {
    headers: { apikey: target.key, Authorization: `Bearer ${target.key}`, Prefer: 'count=exact' },
  });
  if (r.status === 200 || r.status === 206) {
    const cr = r.headers.get('content-range');
    return { ok: true, count: cr?.split('/')?.[1] ?? '?' };
  }
  const body = await r.text();
  return { ok: false, status: r.status, body: body.slice(0, 120) };
}

const results = {};
for (const t of CANDIDATES) {
  const [prod, sbx] = await Promise.all([probe(PROD, t), probe(SBX, t)]);
  results[t] = { prod, sbx };
}

console.log('\nTABLE'.padEnd(30) + 'PROD'.padEnd(16) + 'SANDBOX'.padEnd(40) + 'NOTE');
console.log('-'.repeat(110));
for (const [t, r] of Object.entries(results)) {
  const p = r.prod.ok ? `${r.prod.count} rows` : `HTTP ${r.prod.status}`;
  const s = r.sbx.ok ? `${r.sbx.count} rows` : `HTTP ${r.sbx.status} ${r.sbx.body?.slice(0, 40) || ''}`;
  let note = '';
  if (r.prod.ok && !r.sbx.ok) note = '⚠ missing in sandbox';
  else if (!r.prod.ok && !r.sbx.ok) note = '— neither';
  else if (r.prod.ok && r.sbx.ok) {
    const dp = parseInt(r.prod.count), ds = parseInt(r.sbx.count);
    if (Number.isFinite(dp) && Number.isFinite(ds)) {
      if (ds === 0 && dp > 0) note = '⚠ empty in sandbox';
      else if (ds === dp) note = '= same';
      else note = `Δ ${ds - dp}`;
    }
  }
  console.log(t.padEnd(30) + p.padEnd(16) + s.padEnd(40) + note);
}
