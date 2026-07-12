// rls_verify_anon_surface.js — Phase-3 "full anon-surface harden" (2026-07-12) verification.
// NEGATIVE (raw anon key): every revoked RPC (public/derm/ops) + every live-write table -> 42501/403/404.
// POSITIVE (real authenticated JWT via password grant): the read-only SECDEF RPCs still work for authenticated
//   (proves the authenticated path is intact — the apps run authenticated). No mutation performed.
// KEEP (anon): FP core read customer.get_visit_by_slug_and_token is NOT permission-blocked for anon.
// Reads prod_anon.txt (gitignored) + SUPABASE_SERVICE_ROLE_KEY/URL from .env + AUTH creds from argv/env.
const fs = require('fs');
const https = require('https');
const SP = __dirname;
const env = {};
for (const l of fs.readFileSync('C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/.env', 'utf8').split(/\r?\n/)) {
  const m = l.match(/^([A-Z0-9_]+)=(.*)$/); if (m) env[m[1]] = m[2].replace(/^["']|["']$/g, '');
}
const ANON = fs.readFileSync(SP + '/prod_anon.txt', 'utf8').trim();
const BASE = env.SUPABASE_URL;
const AUTH_EMAIL = process.env.AUTH_EMAIL || 'fred@ayache.com';
const AUTH_PW = process.env.AUTH_PW || '24438839';

function raw(method, pathname, body, headers) {
  return new Promise((res) => {
    const b = body ? (typeof body === 'string' ? body : JSON.stringify(body)) : null;
    const u = new URL(BASE + pathname);
    const h = { 'Content-Type': 'application/json', ...(headers || {}) };
    if (b) h['Content-Length'] = Buffer.byteLength(b);
    const r = https.request({ hostname: u.hostname, path: u.pathname + u.search, method, headers: h },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res({ s: x.statusCode, d })); });
    r.on('error', e => res({ s: 0, d: e.message })); if (b) r.write(b); r.end();
  });
}
const anonReq = (m, p, body, profile) => raw(m, '/rest/v1' + p, body, { apikey: ANON, Authorization: 'Bearer ' + ANON, Prefer: 'return=representation', ...(profile ? { 'Content-Profile': profile, 'Accept-Profile': profile } : {}) });
const authedReq = (tok) => (m, p, body, profile) => raw(m, '/rest/v1' + p, body, { apikey: ANON, Authorization: 'Bearer ' + tok, Prefer: 'return=representation', ...(profile ? { 'Content-Profile': profile, 'Accept-Profile': profile } : {}) });

// "blocked" for anon = any hard denial: 401/403/404 or 42501 permission-denied or function-hidden,
// OR a non-updatable-view rejection (55000) — a multi-table view anon cannot write through regardless.
const blocked = r => [401, 403, 404].includes(r.s)
  || /42501|permission denied|could not find|not find the function/i.test(r.d)
  || (r.s === 500 && /55000|do not select from a single table|cannot be updated/i.test(r.d));

const REVOKED_RPCS = {
  derm: { add_client_card_and_link: { p_dump_folder: 'x', p_page: 1, p_client_id: 1, p_visit_id: 1 }, add_sheet_client: { p_dump_folder: 'x', p_page: 1, p_client_id: 1, p_custom_code: 'x' }, clear_stamp_position: { p_row_id: 1 }, file_manifest_and_link: { p_row_id: 1, p_visit_id: 1 }, link_row_visit: { p_row_id: 1, p_visit_id: 1 }, remove_sheet_client: { p_row_id: 1 }, set_row_band: { p_row_id: 1, p_y0: 0, p_y1: 1 }, set_row_reviewed: { p_row_id: 1, p_reviewed: true }, set_sheet_completed: { p_dump_folder: 'x', p_completed: true }, set_stamp_position: { p_row_id: 1, p_page: 1, p_x_pct: 0, p_y_pct: 0 }, unlink_row_visit: { p_row_id: 1, p_visit_id: 1 }, audit_pack: { p_manifest_id: 1 }, audit_pack_client: { p_client_id: 1, p_from: '2026-01-01', p_to: '2026-01-02' }, lookup_client_alias: { p_name: 'x', p_min_similarity: 0.5 }, sheet_page_images: { p_dump_folder: 'x' }, ticket_page_images: { p_wm: 'x' } },
  public: { edit_manifest: { p_old_number: 'x', p_old_jurisdiction: 'x', p_new_number: 'x', p_new_jurisdiction: 'x' }, file_manifest: { p_client_id: 1, p_jurisdiction: 'x', p_number: 'x' }, file_manifest_on_shared_ticket: { p_white_manifest_number: 'x', p_client_id: 1, p_visit_id: 1 }, set_visit_manholes: { p_visit_id: 1, p_location_ids: [1] }, zones_hard_delete: { _code: 'ZZZ_NOPE' }, gen_short_id: { n_chars: 6 }, get_record_history: { p_table: 'visits', p_record_id: '1' }, calendar_visit_drift_candidates: { p_back_days: 1, p_fwd_days: 1 }, visit_last_schedule_edit: { p_visit_id: 1 }, log_calendar_push_health: {}, rederive_visits_derm_required: {}, set_visit_derm_required: { p_visit_id: 1 } },
  ops: { get_record_history: { p_table: 'visits', p_record_id: '1' } },
};
const REVOKED_TABLE_WRITES = [
  ['derm_manifests', 'POST', { client_id: 381, white_manifest_number: 'ZZTEST', service_date: '2026-01-01', dump_ticket_date: '2026-01-02' }],
  ['manifest_visits', 'POST', { visit_id: 1, manifest_id: 1 }],
  ['shift_reviews', 'POST', { }],
  ['visit_reviews', 'POST', { }],
  ['photo_classifications', 'POST', { }],
  ['zones', 'POST', { code: 'ZZTEST' }],
  ['derm_manifest_number_proposals', 'POST', { }],
  ['derm_required_backfill_snapshot_2026_06_24', 'POST', { }],
  ['gdos', 'PATCH', { status: 'HACKED' }, '?id=eq.999999999'],
  // Phase-3-bypass class: anon write through OWNER-RIGHTS auto-updatable views over the locked visits table.
  ['v_visits_live', 'PATCH', { visit_status: 'completed' }, '?id=eq.999999999'],
  ['visits_with_status', 'PATCH', { visit_status: 'completed' }, '?id=eq.999999999'],
];

(async () => {
  let pass = 0, fail = 0;
  const check = (label, ok, r) => { console.log((ok ? 'PASS ' : '**FAIL** ') + label + '  [' + r.s + ' ' + (r.d || '').replace(/\s+/g, ' ').slice(0, 60) + ']'); ok ? pass++ : fail++; };

  console.log('=== NEGATIVE: anon EXECUTE on every revoked RPC must be BLOCKED ===');
  for (const schema of Object.keys(REVOKED_RPCS)) {
    for (const [fn, body] of Object.entries(REVOKED_RPCS[schema])) {
      const r = await anonReq('POST', `/rpc/${fn}`, body, schema === 'public' ? undefined : schema);
      check(`anon ${schema}.${fn}`, blocked(r), r);
    }
  }

  console.log('\n=== NEGATIVE: anon WRITE on every live-write table must be BLOCKED ===');
  for (const [tbl, method, body, qs] of REVOKED_TABLE_WRITES) {
    const r = await anonReq(method, `/${tbl}${qs || ''}`, body);
    check(`anon ${method} ${tbl}`, blocked(r), r);
  }

  console.log('\n=== KEEP: FP anon read customer.get_visit_by_slug_and_token must NOT be permission-blocked ===');
  const fp = await anonReq('POST', '/rpc/get_visit_by_slug_and_token', { p_slug: 'nope', p_token: 'nope' }, 'customer');
  check('anon customer.get_visit_by_slug_and_token (not 42501)', !/42501|permission denied|not find the function/i.test(fp.d) && fp.s !== 401 && fp.s !== 403, fp);

  console.log('\n=== POSITIVE: authenticated JWT still executes the (revoked-from-anon) read RPCs ===');
  const tokRes = await raw('POST', '/auth/v1/token?grant_type=password', { email: AUTH_EMAIL, password: AUTH_PW }, { apikey: ANON });
  let tok = null; try { tok = JSON.parse(tokRes.d).access_token; } catch (e) {}
  if (!tok) { check('obtain authenticated JWT (password grant)', false, tokRes); }
  else {
    check('obtain authenticated JWT (password grant)', true, { s: tokRes.s, d: 'token acquired' });
    const A = authedReq(tok);
    const g = await A('POST', '/rpc/get_record_history', { p_table: 'visits', p_record_id: '1' });
    check('authenticated public.get_record_history works', !blocked(g), g);
    const ap = await A('POST', '/rpc/audit_pack', { p_manifest_id: 1 }, 'derm');
    check('authenticated derm.audit_pack works', !blocked(ap), ap);
  }

  console.log(`\n=== ${pass} pass / ${fail} fail ===`);
})().catch(e => console.log('ERR', e.message));
