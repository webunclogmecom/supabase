// access-switch-on.mjs - the live check for switching an app's access from watch to on.
// Plan: Building Apps/HR App/docs/specs/2026-10-21-access-switch-on-and-invite-plan.md (A0.11).
//
// Usage: node scripts/checks/access-switch-on.mjs <app> [--as-is | --all-on] [--edge-all] [--json out.json]
//   default   : inside ONE rolled-back transaction, sets <app> to 'on' (other apps as they are now) and probes.
//   --as-is   : probes with the modes exactly as stored (use after the real switch-on).
//   --all-on  : every top-level app 'on' inside the rollback (the end state).
//   --edge-all: also checks every deployed edge function, not only the ones the app calls.
//
// What it does, all read-only except the probe, whose transaction always ends in RAISE (nothing is kept):
//   1. walks the LIVE bundle of the app to closure and lists its .rpc() calls, edge functions and direct table writes
//      (extractor self-test first: all three quote styles, captured and back-referenced);
//   2. builds one call per called function (and per edge action of this app, and per extra trigger statement) and runs
//      every call as Fred, Diego, jon.v (no employee row), then Aaron with a temporary View / None override;
//   3. scores: staff must never be refused by an access check; jon.v and Aaron-None must be refused BY THIS APP's
//      check (or a shared check naming it); Aaron-View must pass View calls and be refused Edit calls;
//      the positive control, with its check removed (a temp copy), must NOT refuse jon.v (instrument check);
//   4. reports the edge functions the app calls: each must call checkAppAction or be allowlisted with a reason;
//   5. --as-is: asserts mode 'on' + on_since and that the app's planned revokes are gone.
// Exit 0 only if every part passes. A failed control means "instrument broken", never a clean result.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
for (const l of fs.readFileSync(path.resolve(here, '../../.env'), 'utf8').split(/\r?\n/)) {
  const m = l.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
}
const REF = process.env.SUPABASE_PROJECT_ID, PAT = process.env.SUPABASE_PAT;

const PEOPLE = {
  fred:  { sub: '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', email: 'fred@ayache.com', staff: true },
  diego: { sub: 'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8', email: 'contact@unclogme.com', staff: true },
  jonv:  { sub: '8bdb9ba7-e917-466d-bdb1-c525dbf90194', email: 'jon.v@ayache.com', staff: false },
  aaron: { sub: '77d4c343-1e21-44eb-98ce-c221028d028a', email: 'aaron@unclogme.com', emp: 26 },
};

// Per app: host, the positive control (a function this app checks itself), readers left to the read gate
// (no check of their own, allowed), edge functions allowed without checkAppAction, planned revokes, extra statements.
const APPS = {
  stamp_studio: {
    host: 'https://stamp.unclogme.app', control: 'derm.clear_stamp_position',
    gateReaders: ['derm.fn_sheet_publishable_detail', 'derm.fn_sheet_publishable'],
    edgeAllow: {}, revokes: [], extra: [],
  },
  picture_planner: {
    host: 'https://planner.unclogme.app', control: 'client.rotate_driver_link',
    gateReaders: [], edgeAllow: { 'driver-page': 'public Site file page', 'intake-submit': 'public collector form' },
    revokes: [], extra: [],
  },
  admin_review: {
    host: 'https://admin.unclogme.app', control: 'public.review_set_property_counts',
    gateReaders: ['hr.get_review_bonuses', 'hr.get_person_bonus_amounts'],
    edgeAllow: {},
    revokes: [
      { kind: 'column', obj: 'public.visits', col: 'manhole_count', priv: 'UPDATE' },
      { kind: 'column', obj: 'public.properties', col: 'grease_trap_manhole_count', priv: 'UPDATE' },
      { kind: 'column', obj: 'public.properties', col: 'sample_port_count', priv: 'UPDATE' },
      { kind: 'table', obj: 'public.photo_links', priv: 'INSERT' },
    ],
    extra: [{ name: 'trigger visit_reviews (visit 8742)', sql: "update public.visit_reviews set updated_at = updated_at where visit_id = 8742" }],
    // a dummy id writes no row, so the review_scope_inclusions trigger would never fire: use a real visit
    args: { 'public.include_visits_in_review': "array[1468]::bigint[], 'live check'",
            'public.remove_visits_from_review': "array[1468]::bigint[], 'live check'" },
    // refusals by a permission switch, not by the app level: custom visit amounts need "Pay rates and bonus settings"
    staffSwitchRefusals: { 'hr.set_visit_bonus': 'hr_pay' },
    // run as the owner, inside the same rolled-back step, just before that call (so the call has a row to change)
    pre: { 'public.remove_visits_from_review': "select public.include_visits_in_review(array[1468]::bigint[], 'live check setup')" },
  },
  derm_tracker: {
    host: 'https://derm.unclogme.app', control: 'public.derm_unlink_visit',
    gateReaders: ['public.fn_dump_county_warnings'],
    edgeAllow: { 'get-derm-doc': 'the Field Portal uses it (anon)' },
    revokes: [
      { kind: 'table', obj: 'public.manifest_visits', priv: 'INSERT' }, { kind: 'table', obj: 'public.manifest_visits', priv: 'DELETE' },
      { kind: 'table', obj: 'public.derm_manifests', priv: 'INSERT' }, { kind: 'table', obj: 'public.derm_manifests', priv: 'UPDATE' },
      { kind: 'column', obj: 'public.visits', col: 'derm_required', priv: 'UPDATE' },
    ],
    extra: [],
  },
  client_app: {
    host: 'https://clients.unclogme.app', control: 'client.update_property_operational',
    gateReaders: ['client.global_search', 'client.recurring_eligibility'],
    edgeAllow: { 'emergency-session': 'leftover, returns 404' },
    revokes: [], extra: [],
  },
  visit_calendar: {
    host: 'https://calendar.unclogme.app', control: 'ops.link_day_marker_dump_visit',
    gateReaders: ['ops.calendar_hours_estimates', 'public.dump_site_status', 'ops.start_first_visit'],
    edgeAllow: {},
    revokes: [{ kind: 'column', obj: 'ops.calendar_day_markers', col: 'dump_visit_id', priv: 'UPDATE' }],
    extra: [{ name: 'trigger zones (lowest id)', sql: "update public.zones set color_hex = color_hex where id = (select min(id) from public.zones)" }],
  },
};
// Everywhere: the no-access card must load.
const ALWAYS_ALLOWED = ['hr.get_my_access'];
const EXPOSED = ['public', 'derm', 'client', 'ops', 'hr', 'customer'];

const args = process.argv.slice(2);
const app = args.find(a => !a.startsWith('--'));
const flag = f => args.includes(f);
const jsonOut = args.includes('--json') ? args[args.indexOf('--json') + 1] : null;
if (!APPS[app]) { console.error('usage: node access-switch-on.mjs <' + Object.keys(APPS).join('|') + '> [--as-is|--all-on] [--edge-all]'); process.exit(2); }
const cfg = APPS[app];
let fails = 0, pending = 0;
const fail = m => { fails++; console.log('  FAIL  ' + m); };
const ok = m => console.log('  ok    ' + m);
const warn = m => console.log('  note  ' + m);

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json' }, body: JSON.stringify({ query }),
  });
  const t = await r.text();
  return { status: r.status, text: t, json: (() => { try { return JSON.parse(t); } catch { return null; } })() };
}
const lit = s => "'" + String(s).replace(/'/g, "''") + "'";

// ---------- 1. extractor + self-test ----------
const RPC_RE = /\.rpc\(\s*(["'`])([A-Za-z0-9_]+)\1/g;
const EDGE_RE = /functions\/v1\/([a-z0-9-]+)|functions\.invoke\(\s*(["'`])([a-z0-9-]+)\2/g;
const WRITE_RE = /\.from\(\s*(["'`])([A-Za-z0-9_]+)\1\s*\)\s*\.(insert|update|upsert|delete)\(/g;
function extract(src) {
  const rpc = new Set(), edge = new Set(), writes = new Set();
  for (const m of src.matchAll(RPC_RE)) rpc.add(m[2]);
  for (const m of src.matchAll(EDGE_RE)) edge.add(m[1] || m[3]);
  for (const m of src.matchAll(WRITE_RE)) writes.add(m[2] + ':' + m[3]);
  const indirect = (src.match(/\.rpc\(\s*[A-Za-z_$][A-Za-z0-9_$]*\s*[,)]/g) || []).length;
  // calls through a wrapper (the Client App's Ct("name", {...}) / ct("name", {...})): any call whose first argument is a
  // literal name and second an object. Only names that are real functions in the exposed schemas are kept (see below).
  const helperCalls = new Set();
  for (const m of src.matchAll(/[A-Za-z_$][A-Za-z0-9_$]*\(\s*(["'`])([a-z][a-z0-9_]{3,})\1\s*,\s*\{/g)) helperCalls.add(m[2]);
  return { rpc, edge, writes, indirect, helperCalls };
}
{
  const fx = 'a.rpc("one",{}) b.rpc(\'two\') c.rpc(`three`,x) d.rpc("bad`) e.rpc(fnName,{}) fetch(u+"/functions/v1/edge-a") s.functions.invoke(`edge-b`) x.from("t1").update({}) y.from(`t2`).delete()'
    + ' async function C$t(e,t){let n;try{n=await ae.rpc(e,t)}catch{}} C$t("four",{}) xC$t("notme")';
  const e = extract(fx);
  const want = ['one', 'two', 'three'].every(n => e.rpc.has(n)) && e.helperCalls.has('four') && !e.rpc.has('bad') && !e.helperCalls.has('notme') && e.indirect === 2
    && e.edge.has('edge-a') && e.edge.has('edge-b') && e.writes.has('t1:update') && e.writes.has('t2:delete');
  if (!want) { console.log('FAIL extractor self-test', JSON.stringify({ rpc: [...e.rpc], edge: [...e.edge], w: [...e.writes], i: e.indirect })); process.exit(2); }
}

async function walk(base) {
  const seen = new Set(), q = ['/'], parts = [];
  while (q.length) {
    const p = q.shift(); if (seen.has(p)) continue; seen.add(p);
    let r; try { r = await fetch(base + p); } catch { continue; }
    if (!r.ok) continue;
    const t = await r.text(); parts.push(t);
    for (const m of t.matchAll(/["'`(](\/?assets\/[A-Za-z0-9_.\-]+\.js)/g)) { const x = m[1].startsWith('/') ? m[1] : '/' + m[1]; if (!seen.has(x)) q.push(x); }
    for (const m of t.matchAll(/["'`]\.\/([A-Za-z0-9_.\-]+\.js)["'`]/g)) { const x = '/assets/' + m[1]; if (!seen.has(x)) q.push(x); }
  }
  return { chunks: seen.size - 1, src: parts.join('\n') };
}

// ---------- 2. probe ----------
function dummy(type) {
  if (/^(bigint|integer|smallint|numeric|double precision|real)$/.test(type)) return `(-1)::${type}`;
  if (/^(bigint|integer|smallint)\[\]$/.test(type)) return `'{-1}'::${type}`;
  if (/^(text|character varying)$/.test(type)) return `'probe'::text`;
  if (/^(text|character varying)\[\]$/.test(type)) return `'{probe}'::text[]`;
  if (type === 'boolean') return 'false';
  if (type === 'jsonb' || type === 'json') return `'{}'::${type}`;
  if (type === 'date') return 'current_date';
  if (type.startsWith('timestamp')) return 'now()';
  if (type === 'uuid') return `'00000000-0000-0000-0000-000000000000'::uuid`;
  return `null::${type}`;
}

function buildProbe({ calls, mode }) {
  // calls: [{key, sql, view: bool|null}]  view = the function's own level for this app is 'view' (null = unknown)
  const setModes = mode === 'all-on'
    ? `update hr.access_apps set mode = 'on', on_since = coalesce(on_since, now()) where parent is null;`
    : mode === 'as-is' ? '' : `update hr.access_apps set mode = 'on', on_since = coalesce(on_since, now()) where app = ${lit(app)};`;
  const ctl = cfg.control;
  // partner apps of every shared check: the *_all copies of Aaron lower these too, so a shared action is judged with no
  // access in ANY of its apps (Aaron is Office, so his own default in a partner app would otherwise let it pass)
  const partners = [...new Set(calls.flatMap(c => c.shared || []))];
  const lowered = [app, ...partners].map(lit).join(', ');
  return `do $probe$
declare r jsonb := '[]'::jsonb; v_state text; v_msg text; v_det text; c record; who record; v_def text; v_ctl text; v_cnt int;
begin
  ${setModes}
  -- the instrument control: a temp copy of the control function with every access check statement removed
  select pg_get_functiondef(p.oid), p.oid::regprocedure::text into v_def, v_ctl from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname || '.' || p.proname = ${lit(ctl)} order by p.oid limit 1;
  if v_def is null then raise exception 'PROBE_RESULT:{"error":"control function not found"}'; end if;
  v_cnt := (length(v_def) - length(regexp_replace(v_def, 'perform[[:space:]]+hr[.]fn_(check|require)(_any)?_app[(][^;]*[)];', '', 'g')));
  v_def := regexp_replace(v_def, 'perform[[:space:]]+hr[.]fn_(check|require)(_any)?_app[(][^;]*[)];', 'perform 1;', 'g');
  v_def := regexp_replace(v_def, 'CREATE OR REPLACE FUNCTION [^(]+[(]', 'CREATE FUNCTION pg_temp.probe_ctl(');
  execute v_def;
  r := r || jsonb_build_object('ctl_removed_chars', v_cnt);
  for who in select * from (values
      ('fred', ${lit(PEOPLE.fred.sub)}, ${lit(PEOPLE.fred.email)}, null::text),
      ('diego', ${lit(PEOPLE.diego.sub)}, ${lit(PEOPLE.diego.email)}, null),
      ('jonv', ${lit(PEOPLE.jonv.sub)}, ${lit(PEOPLE.jonv.email)}, null),
      ('aaron_view', ${lit(PEOPLE.aaron.sub)}, ${lit(PEOPLE.aaron.email)}, 'view'),
      ('aaron_none', ${lit(PEOPLE.aaron.sub)}, ${lit(PEOPLE.aaron.email)}, 'none'),
      ('aaron_view_all', ${lit(PEOPLE.aaron.sub)}, ${lit(PEOPLE.aaron.email)}, 'view'),
      ('aaron_none_all', ${lit(PEOPLE.aaron.sub)}, ${lit(PEOPLE.aaron.email)}, 'none')) w(name, sub, email, lvl)
  loop
    delete from hr.access_overrides where employee_id = ${PEOPLE.aaron.emp} and app in (${lowered});
    if who.lvl is not null then
      insert into hr.access_overrides (employee_id, app, level, set_by_email)
        select ${PEOPLE.aaron.emp}, a, who.lvl, 'access-switch-on probe'
          from unnest(case when who.name like '%_all' then array[${lowered}] else array[${lit(app)}] end) a;
    end if;
    for c in select * from jsonb_to_recordset(${lit(JSON.stringify(calls))}::jsonb) as x(key text, sql text, pre text) loop
      begin
        if c.pre is not null then
          perform set_config('request.jwt.claims', '', true);
          execute c.pre;
        end if;
        perform set_config('request.jwt.claims', json_build_object('sub', who.sub, 'role', 'authenticated', 'email', who.email, 'aud', 'authenticated')::text, true);
        perform set_config('request.headers', '{}', true);
        perform set_config('role', 'authenticated', true);
        if current_user <> 'authenticated' then raise exception 'role switch failed'; end if;
        execute c.sql;
        perform set_config('role', 'postgres', true);
        r := r || jsonb_build_object('k', c.key, 'w', who.name, 's', 'ok');
      exception when others then
        get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text, v_det = pg_exception_detail;
        perform set_config('role', 'postgres', true);
        r := r || jsonb_build_object('k', c.key, 'w', who.name, 's', v_state, 'm', left(v_msg, 160), 'd', left(coalesce(v_det, ''), 160));
      end;
    end loop;
  end loop;
  raise exception 'PROBE_RESULT:%', r::text;
end $probe$;`;
}

(async () => {
  console.log(`== access-switch-on ${app}  mode=${flag('--as-is') ? 'as-is' : flag('--all-on') ? 'all-on' : 'this app on (rolled back)'}`);

  // ---------- bundle ----------
  const { chunks, src } = await walk(cfg.host);
  const ex = extract(src);
  console.log(`bundle: ${chunks} chunks, ${src.length} bytes, ${ex.rpc.size} rpc names (+${ex.helperCalls.size} wrapper-call candidates), ${ex.edge.size} edge fns, ${ex.writes.size} direct writes, ${ex.indirect} indirect .rpc(var)`);
  if (!src.includes('get_my_access')) fail('bundle does not call get_my_access (the access screen is missing)'); else ok('bundle calls get_my_access');
  if (chunks < 2) fail('bundle walk found no chunks (instrument broken)');

  // ---------- resolve functions ----------
  const names = [...new Set([...ex.rpc, ...ex.helperCalls])];
  const fq = await sql(`select n.nspname||'.'||p.proname as fn, p.oid::regprocedure::text as sig, p.pronargs, p.pronargdefaults, p.prokind,
     array(select format_type(t, null) from unnest(p.proargtypes) t) as types, pg_get_functiondef(p.oid) as def
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = any(array[${EXPOSED.map(lit).join(',')}]) and p.proname = any(array[${names.map(lit).join(',') || "''"}]) and p.prokind = 'f'`);
  if (fq.status > 299) { console.log(fq.text); process.exit(2); }
  const fns = fq.json;
  const found = new Set(fns.map(f => f.fn.split('.')[1]));
  for (const n of ex.rpc) if (!found.has(n)) warn(`rpc "${n}" matches no function in ${EXPOSED.join('/')} (dead call or another project)`);
  const levelFor = def => {
    const m = [...def.matchAll(new RegExp(`fn_(?:check|require)_app\\(\\s*'${app}'\\s*,\\s*'(view|edit)'`, 'g'))].map(x => x[1]);
    const a = [...def.matchAll(/fn_(?:check|require)_any_app\(\s*(?:array|ARRAY)\[([^\]]*)\]\s*,\s*'(view|edit)'/g)].filter(x => x[1].includes(`'${app}'`)).map(x => x[2]);
    const all = [...m, ...a];
    return all.length ? (all.includes('view') && !all.includes('edit') ? 'view' : all.includes('edit') && !all.includes('view') ? 'edit' : 'mixed') : null;
  };
  // other apps named in a shared (any-app) check of this function, e.g. ['client_app']
  const sharedWith = def => [...def.matchAll(/fn_(?:check|require)_any_app\(\s*(?:array|ARRAY)\[([^\]]*)\]/g)]
    .filter(x => x[1].includes(`'${app}'`)).flatMap(x => [...x[1].matchAll(/'([a-z_]+)'/g)].map(y => y[1])).filter(a => a !== app);
  const calls = [];
  for (const f of fns) {
    const req = f.pronargs - f.pronargdefaults;
    const argList = (cfg.args || {})[f.fn] ?? f.types.slice(0, req).map(dummy).join(', ');
    // a plain call: wrapping it in count(*) lets the planner skip a STABLE function entirely (measured 2026-10-21)
    calls.push({ key: f.sig, sql: `select ${f.fn}(${argList})`, pre: (cfg.pre || {})[f.fn] || null, fn: f.fn, level: levelFor(f.def), shared: sharedWith(f.def), def: f.def });
  }
  // a thin wrapper (ops.get_record_history -> public.get_record_history) carries no check of its own: give it the
  // partner apps of a probed function it calls by name
  for (const c of calls) if (!c.shared.length && c.level === null) {
    const inner = calls.find(o => o !== c && o.shared.length && c.def.includes(o.fn.split('.').pop() + '('));
    if (inner) c.shared = inner.shared;
  }
  // edge actions of this app
  const cq = await sql(`select pg_get_functiondef('hr.check_app_action'::regproc) d`);
  const actions = [...cq.json[0].d.matchAll(/\('([a-z_]+)',\s*array\[([^\]]*)\],\s*'(view|edit)'\)/g)].filter(m => m[2].includes(`'${app}'`));
  for (const m of actions) calls.push({ key: 'action:' + m[1], sql: `select hr.check_app_action(${lit(m[1])})`, fn: 'action:' + m[1], level: m[3], shared: [...m[2].matchAll(/'([a-z_]+)'/g)].map(y => y[1]).filter(a => a !== app) });
  for (const e of cfg.extra) calls.push({ key: 'extra:' + e.name, sql: e.sql, fn: 'extra:' + e.name, level: 'edit' });
  calls.push({ key: 'control:copy-without-check', sql: null, fn: 'control', level: null });
  // the control copy: same args as the control
  const ctlF = fns.find(f => f.fn === cfg.control);
  if (!ctlF) { fail(`control ${cfg.control} is not called by the bundle (pick another control)`); }
  else {
    const c = calls.find(x => x.key === 'control:copy-without-check');
    c.sql = `select pg_temp.probe_ctl(${ctlF.types.slice(0, ctlF.pronargs - ctlF.pronargdefaults).map(dummy).join(', ')})`;
  }

  // ---------- run the probe ----------
  const mode = flag('--as-is') ? 'as-is' : flag('--all-on') ? 'all-on' : 'this';
  const pr = await sql(buildProbe({ calls: calls.map(c => ({ key: c.key, sql: c.sql, pre: c.pre || null, shared: c.shared || [] })), mode }));
  const mm = String(pr.json?.message || '').match(/PROBE_RESULT:(\[.*\])/s);
  if (!mm) { console.log('probe did not return a result:', pr.text.slice(0, 800)); process.exit(2); }
  const res = JSON.parse(mm[1]);
  const ctlRemoved = res.find(x => x.ctl_removed_chars !== undefined)?.ctl_removed_chars || 0;
  const rows = res.filter(x => x.k);
  const get = (k, w) => rows.find(x => x.k === k && x.w === w) || {};
  const refusedByApp = x => x.s === '42501' && /blocker=no_access/.test(x.d || '') && new RegExp(`app=([a-z_|]*\\b)?${app}\\b`).test(x.d);
  const refusedByOther = x => x.s === '42501' && /blocker=no_access/.test(x.d || '') && !refusedByApp(x);
  const accessRefused = x => x.s === '42501' && /blocker=no_access/.test(x.d || '');

  // modes as seen now, to mark shared actions PENDING
  const mq = await sql(`select app, mode, on_since from hr.access_apps where parent is null`);
  const modes = Object.fromEntries(mq.json.map(r => [r.app, r]));
  // apps 'on' in the probe's state (this app is on inside the rollback unless --as-is)
  const onNow = Object.fromEntries(mq.json.filter(r => r.mode === 'on' || (mode === 'this' && r.app === app) || mode === 'all-on').map(r => [r.app, 1]));

  console.log(`\nprobe: ${calls.length} calls x 5 sign-ins (+2 for shared actions: Aaron lowered in every partner app too), control check statements removed: ${ctlRemoved} chars`);
  const table = [];
  for (const c of calls) {
    const f = get(c.key, 'fred'), d = get(c.key, 'diego'), j = get(c.key, 'jonv'), sh = (c.shared || []).length > 0,
      av = get(c.key, sh ? 'aaron_view_all' : 'aaron_view'), an = get(c.key, sh ? 'aaron_none_all' : 'aaron_none');
    const allowed = ALWAYS_ALLOWED.includes(c.fn) || cfg.gateReaders.includes(c.fn);
    let verdict = 'ok', why = '';
    if (c.key === 'control:copy-without-check') {
      if (ctlRemoved === 0) { verdict = 'FAIL'; why = 'control: no check statement found to remove (instrument broken)'; }
      else if (accessRefused(j)) { verdict = 'FAIL'; why = 'control: the copy WITHOUT its check still refused jon.v (instrument broken)'; }
      table.push({ c, f, d, j, av, an, verdict, why }); continue;
    }
    const sw = (cfg.staffSwitchRefusals || {})[c.fn];
    for (const [who, x] of [['fred', f], ['diego', d]]) {
      if (sw && accessRefused(x) && (x.d || '').includes(`app=${sw} `)) { why += `${who} refused by the ${sw} switch (by design); `; continue; }
      if (accessRefused(x) || x.s === '28000') { verdict = 'FAIL'; why += `${who} refused (${x.s} ${x.d}); `; }
    }
    if (allowed) {
      if (accessRefused(j)) why += 'allowed reader refuses jon.v (fine, it has a check); ';
    } else {
      for (const [who, x] of [['jon.v', j], ['aaron None', an]]) {
        if (refusedByApp(x)) continue;
        if (refusedByOther(x)) { verdict = 'FAIL'; why += `${who} refused by ANOTHER app's check (${x.d}); `; }
        else if (mode !== 'all-on' && (c.shared || []).some(p => !(p in onNow))) { if (verdict === 'ok') verdict = 'PENDING'; why += `${who} passes: shared action, partner app not on; `; }
        else { verdict = 'FAIL'; why += `${who} NOT refused (${x.s}${x.d ? ' ' + x.d : ''}); `; }
      }
      if (c.level === 'view' && accessRefused(av)) { verdict = 'FAIL'; why += `aaron View refused on a View call (${av.d}); `; }
      if (c.level === 'edit' && !accessRefused(av) && verdict !== 'PENDING') { verdict = 'FAIL'; why += `aaron View NOT refused on an Edit call (${av.s}); `; }
      if (c.level === 'edit' && accessRefused(av) && !/needs=edit/.test(av.d)) { verdict = 'FAIL'; why += `aaron View refused without needs=edit (${av.d}); `; }
    }
    table.push({ c, f, d, j, av, an, verdict, why, allowed });
  }
  for (const t of table) {
    const line = `${t.c.key}  [lvl ${t.c.level || '?'}${t.allowed ? ', read-gate reader' : ''}]  fred=${t.f.s} diego=${t.d.s} jonv=${t.j.s} view=${t.av.s} none=${t.an.s}`;
    if (t.verdict === 'FAIL') fail(line + '  -> ' + t.why);
    else if (t.verdict === 'PENDING') { pending++; console.log('  PEND  ' + line + '  -> ' + t.why); }
    else ok(line + (t.why ? '  (' + t.why + ')' : ''));
  }
  const diegoOk = table.some(t => !t.allowed && t.c.key !== 'control:copy-without-check' && t.d.s === 'ok');
  if (!diegoOk) warn('no call returned a real ok for Diego (only errors from dummy arguments); staff path proven by "not refused" only');

  // ---------- edge functions ----------
  console.log(`\nedge functions called: ${[...ex.edge].join(', ') || 'none'}`);
  let edgeList = [...ex.edge];
  if (flag('--edge-all')) {
    const lr = await fetch(`https://api.supabase.com/v1/projects/${REF}/functions`, { headers: { Authorization: 'Bearer ' + PAT } });
    edgeList = (await lr.json()).map(f => f.slug);
  }
  for (const slug of edgeList) {
    if (cfg.edgeAllow[slug]) { ok(`${slug}: allowed (${cfg.edgeAllow[slug]})`); continue; }
    const br = await fetch(`https://api.supabase.com/v1/projects/${REF}/functions/${slug}/body`, { headers: { Authorization: 'Bearer ' + PAT } });
    if (br.status !== 200) { warn(`${slug}: body HTTP ${br.status} (not deployed here?)`); continue; }
    const body = await br.text();
    if (!body.includes('Deno')) { fail(`${slug}: body read has no "Deno" control string (instrument broken)`); continue; }
    if (body.includes('checkAppAction')) ok(`${slug}: calls checkAppAction`);
    else if (/service_role/.test(body)) warn(`${slug}: no checkAppAction; mentions service_role (check by hand: server-only?)`);
    else fail(`${slug}: no checkAppAction and no service_role gate`);
  }

  // ---------- direct table writes ----------
  if (ex.writes.size) {
    console.log(`\ndirect table writes in the bundle: ${[...ex.writes].join(', ')}`);
    const tabs = [...new Set([...ex.writes].map(w => w.split(':')[0]))];
    const tq = await sql(`select c.relname, n.nspname, exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname like 'aa_access_%') trg
      from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'r' and c.relname = any(array[${tabs.map(lit).join(',')}])`);
    for (const t of tabs) {
      const rows = tq.json.filter(r => r.relname === t);
      if (t === 'saved_views') { ok(`${t}: direct write allowed (a person's own saved views)`); continue; }
      if (!rows.length) warn(`${t}: no such table found`);
      else if (rows.some(r => r.trg)) ok(`${t}: direct write, access trigger present (${rows.filter(r => r.trg).map(r => r.nspname).join(',')})`);
      else fail(`${t}: direct write with no aa_access_ trigger`);
    }
  }

  // ---------- step 0 (after the real switch) ----------
  if (flag('--as-is')) {
    const m = modes[app];
    if (m?.mode === 'on' && m.on_since) ok(`mode on since ${m.on_since}`); else fail(`mode is ${m?.mode} (on_since ${m?.on_since})`);
    for (const rv of cfg.revokes) {
      const q = rv.kind === 'column'
        ? `select has_column_privilege('authenticated', ${lit(rv.obj)}, ${lit(rv.col)}, ${lit(rv.priv)}) v`
        : `select has_table_privilege('authenticated', ${lit(rv.obj)}, ${lit(rv.priv)}) v`;
      const r = (await sql(q)).json[0].v;
      const label = `${rv.priv} on ${rv.obj}${rv.col ? '.' + rv.col : ''}`;
      if (r) fail(`planned revoke still granted: ${label}`); else ok(`revoked: ${label}`);
    }
  }

  if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify({ app, mode, chunks, rpc: [...ex.rpc], edge: [...ex.edge], writes: [...ex.writes], rows }, null, 1));
  console.log(`\n${fails ? 'FAILED' : 'PASSED'}: ${fails} fail, ${pending} pending`);
  process.exit(fails ? 1 : 0);
})();
