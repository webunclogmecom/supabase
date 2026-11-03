-- ============================================================================
-- 2026-11-03_1848_leads_privacy_fixes  Frozen leads: three places where "kept privately" did not hold
-- ============================================================================
-- THE ASK: Fred 2026-11-03, Trello #165 / #166: CCNs "Keep all, privately"; BSI contacts "Load them privately now".
--   A read-only adversarial check of M1-M3 and the routing (32 findings; a second agent re-measured each and confirmed
--   31) found three places where that promise did not hold. Each is fixed here, and scripts/checks/leads_integrity.sql
--   now tests the VALUES the public views return, not only their column names (the old check passed while wrong).
-- WHAT
--   1. client.entity_source_links (postgres-owned pass-through, SELECT for authenticated) showed every link, so any
--      signed-in staff user could list the 431 BSI record links (BSI ids and restaurant labels; 3 labels equal a BSI
--      contact's name). It now leaves out entity_type 'source_record'. Nothing reads this view today (0 PostgREST
--      calls in pg_stat_statements, no app bundle names it), and the rows it drops were created today by the leads load.
--   2. public.v_frozen_leads and public.v_lead_review: owner_company is BSI's mailing-address name, and for 18 frozen
--      leads that name is a BSI contact person's name (17 the same record's contact). It is now blank (NULL) when it
--      equals any BSI contact name (upper case, spaces collapsed), read from the new private view
--      leads.v_bsi_contact_names. The private matcher (leads.v_client_candidates) still reads the unmasked name.
--      Other owner names stay: the plan keeps the mailing name and leaves out only the mailing street.
--   3. NEW leads.ingest_quiet(source, run_started_at, records, file, dry_run default true). The loader's dry run was a
--      DO block that always raised, and Postgres writes the full text of a failing statement to its server log
--      (log_min_error_statement = error): the 16:41 ET dry run put the whole payload (every CCN and contact) in the
--      server's csvlog, readable only by supabase_admin, rotated out after about a day, and not shipped to Logs
--      Explorer (the line was over the shipper's limit). It cannot be purged. ingest_quiet runs leads.ingest in a
--      sub-block, catches every error and returns it as data ({ok:false, sqlstate, message}); a dry run builds its
--      report and undoes itself inside the function. The outer statement never fails, so nothing is logged.
--      scripts/leads/load_bsi.mjs calls only this now. Residual: auto_explain logs a statement of 10 s or more with
--      its text, and a cancelled statement is logged; a full load takes under 1 s.
--   Comments corrected (live): leads.source_versions and schema leads (see the corrections below), the two public
--   views (owner_company), client.entity_source_links (new).
-- CORRECTIONS TO TODAY'S EARLIER HEADERS (those files record what was applied, so they are corrected here, not edited):
--   - M1 (_1700) and M2 (_1730) say the CCN and contact are "never in a view anyone can read" and v_src_bsi is "never
--     granted". The leads default privileges give db_backup_reader SELECT on every leads view, v_src_bsi included, and
--     Supabase's platform roles (supabase_admin; supabase_read_only_user and supabase_etl_admin through
--     pg_read_all_data) read every table, as for the whole database. No API role (anon, authenticated, service_role)
--     reads any of them. Nothing to revoke: db_backup_reader already reads leads.source_versions for the backup.
--   - M2 calls ingest "the only writer of records and versions" and decide_client "the only writer of decisions and
--     links". ingest is the only creator of records, versions and their source links; decide_client is the only writer
--     of decisions and of establishments.property_id, and it also moves records between restaurants.
--   - M2's header says the candidate rule is "same city AND (same street key OR name score >= 0.8)": that is right;
--     docs/schema.md had it grouped wrongly and is corrected in the same cycle.
--   - M3 (_1800): the 25.9 s measurement was taken between 16:42 and 16:45 ET, not "~16:50", and M3 had no rollback
--     file (now docs/migrations/2026-11-03_rollback_leads_m3.sql). The names _1700 to _1830 are later than the apply
--     times (16:33, 16:40, 16:46 and 16:53 ET).
--   - The routing (_1830) header says derm.visit_gdo_*, fn_record_manual_gdo_report and every other DERM reader take
--     the rule through v_derm_portal_fields. Two do not: derm.gdo_report_status (fixed in the follow-up migration
--     2026-11-03_1848_route_line27_followups) and derm.visit_gdo_manual_eligibility (its can_record_manual does not
--     read the fields view; a decision for Fred, see that follow-up's header).
-- GRANTS: leads.v_bsi_contact_names: postgres + db_backup_reader (the leads default), no API role. leads.ingest_quiet:
--   postgres only (a new function would otherwise be EXECUTE for PUBLIC; the integrity check now lists any leads function
--   an API role can run). client.entity_source_links and the two public views keep their grants (read back below).
-- RULE 8: no table created. RULE 7: no CHECK widened.
-- LOCKS: the three views have no live reader (no app; Viktor has not started); lock_timeout 3s, applied clear of the
--   backup dump (:17 on even UTC hours).
-- VERIFY (inside): before/after snapshots in one transaction: the link view loses exactly the source_record rows and
--   nothing else; the two public views keep every row and every column except owner_company, which changes only where
--   it equalled a contact name (control: that count was above 0 before); 0 contact names after; ingest_quiet's dry run
--   reports and keeps nothing, a refusal comes back as data, a live call keeps its rows (undone here); exact grants.
-- ROLLBACK: docs/migrations/2026-11-03_rollback_leads_privacy_fixes.sql
-- ============================================================================
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;   -- pg_get_viewdef text below is written and re-read under this path

do $pre$
begin
  if md5(pg_get_viewdef('client.entity_source_links'::regclass, false)) <> '3b680c8dc1447ae83fa0fb7653357852' then
    raise exception 'leads privacy: client.entity_source_links changed since this migration was written';
  end if;
  if md5(pg_get_viewdef('public.v_frozen_leads'::regclass, false)) <> '89888a8a3d0696c1414792a3ab8de4f9' then
    raise exception 'leads privacy: public.v_frozen_leads changed since this migration was written';
  end if;
  if md5(pg_get_viewdef('public.v_lead_review'::regclass, false)) <> '89f3ebbba32b43531634cd5f9f1afa0e' then
    raise exception 'leads privacy: public.v_lead_review changed since this migration was written';
  end if;
  if to_regclass('leads.v_bsi_contact_names') is not null
     or to_regprocedure('leads.ingest_quiet(text,timestamptz,jsonb,text,boolean)') is not null then
    raise exception 'leads privacy: an object of this migration already exists';
  end if;
end $pre$;

-- the "before" pictures (one transaction, so now() is one value)
create temp table _p_name_keys on commit drop as
select distinct upper(regexp_replace(btrim(v.payload -> 'search_item' -> 'contact' ->> 'name'), '[[:space:]]+', ' ', 'g')) as k
  from leads.source_versions v
 where coalesce(btrim(v.payload -> 'search_item' -> 'contact' ->> 'name'), '') <> '';
create temp table _p_esl_before on commit drop as
select entity_type, count(*) as n, md5(string_agg(t::text, '|' order by t.id)) as h
  from client.entity_source_links t group by entity_type;
create temp table _p_frozen_before on commit drop as select * from public.v_frozen_leads;
create temp table _p_review_before on commit drop as select * from public.v_lead_review;
create temp table _p_acl_before on commit drop as
select c.oid, c.relacl::text as acl from pg_class c
 where c.oid in ('client.entity_source_links'::regclass, 'public.v_frozen_leads'::regclass, 'public.v_lead_review'::regclass);

-- 1. the private name list
create view leads.v_bsi_contact_names as
select distinct upper(regexp_replace(btrim(v.payload -> 'search_item' -> 'contact' ->> 'name'), '[[:space:]]+', ' ', 'g')) as name_key
  from leads.source_versions v
 where coalesce(btrim(v.payload -> 'search_item' -> 'contact' ->> 'name'), '') <> '';
comment on view leads.v_bsi_contact_names is
  'Every contact-person name BSI has given us (any version), upper case, spaces collapsed. Private. The public lead '
  'views blank a mailing name (owner_company) equal to one of these (2026-11-03_1848).';
revoke all on leads.v_bsi_contact_names from public, anon, authenticated, service_role;

-- 2. the three anchored edits
do $edit$
declare d text; a text; b text; m text;
begin
  m := 'CASE WHEN (upper(regexp_replace(btrim(%1$s.owner_company), ''[[:space:]]+''::text, '' ''::text, ''g''::text)) IN ( SELECT n.name_key FROM leads.v_bsi_contact_names n)) THEN NULL::text ELSE %1$s.owner_company END AS owner_company';

  d := rtrim(btrim(pg_get_viewdef('client.entity_source_links'::regclass, false)), ';');
  a := '   FROM entity_source_links';
  b := E'   FROM entity_source_links\n  WHERE (entity_type <> ''source_record''::text)';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads privacy: link view anchor not found once'; end if;
  execute 'create or replace view client.entity_source_links as ' || replace(d, a, b);

  d := rtrim(btrim(pg_get_viewdef('public.v_frozen_leads'::regclass, false)), ';');
  a := E'    s.owner_company,\n    i.interceptors,';
  b := E'    ' || format(m, 's') || E',\n    i.interceptors,';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads privacy: frozen anchor not found once'; end if;
  execute 'create or replace view public.v_frozen_leads as ' || replace(d, a, b);

  d := rtrim(btrim(pg_get_viewdef('public.v_lead_review'::regclass, false)), ';');
  a := E'    c.owner_company,\n    c.property_id,';
  b := E'    ' || format(m, 'c') || E',\n    c.property_id,';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads privacy: review anchor 1 not found once'; end if;
  d := replace(d, a, b);
  a := E'    s.owner_company,\n    e.property_id,';
  b := E'    ' || format(m, 's') || E',\n    e.property_id,';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads privacy: review anchor 2 not found once'; end if;
  execute 'create or replace view public.v_lead_review as ' || replace(d, a, b);
end $edit$;

comment on view client.entity_source_links is
  'Every cross-system link (public.entity_source_links) for the Client App, except the private frozen-leads links '
  '(entity_type source_record; 2026-11-03_1848, Fred: BSI data kept privately).';
comment on view public.v_frozen_leads is
  'Frozen leads: restaurants we only know from an outside source (BSI Online, City of Boca Raton FOG program), never '
  'contacted, not our client, not a Jobber lead, not waiting for review. One row per restaurant. Overdue = BSI''s next '
  'pump date before today (ET). Read-only, for Viktor (service role; his first read is not tested yet). Never shows a '
  'CCN or a BSI contact (owner_company is blank when it is a contact''s name). Trello #166.';
comment on column public.v_frozen_leads.owner_company is
  'The mailing name BSI lists for the property (often the operator''s LLC; can be the landlord). Blank when it is the '
  'name of a person BSI lists as a contact (private, Fred 2026-11-03).';
comment on view public.v_lead_review is
  'What a person must decide before leads are trusted: client_candidate (an outside record that may be one of our '
  'properties), client_without_source_record (one of our properties in a covered city with no record), '
  'client_record_changed (a linked record whose name or owner changed). Decisions go through leads.decide_client. '
  'Read-only, service role only; owner_company is blank when it is a BSI contact''s name. Trello #166.';
comment on table leads.source_versions is
  'What the source said: a new row only when the content changed; otherwise only last_seen_at moves. fetched_at = '
  'start of the first run that returned this content; last_seen_at = start of the latest run that returned it '
  'unchanged. Private: payloads hold CCNs and BSI contacts (Fred 2026-11-03: keep privately). No API role reads them. '
  'The only view that outputs them is leads.v_src_bsi, readable by postgres, db_backup_reader (the backup) and '
  'Supabase''s platform roles, like every table. scripts/checks/leads_integrity.sql tests the public views'' values.';
comment on schema leads is
  'Frozen leads (Trello #165/#166, 2026-11-03): outside records about restaurants we do not serve yet (BSI Online Boca '
  'Raton first), kept as received with their source and dates. Private: not exposed to the API. For Viktor: the '
  'public.v_frozen_leads / v_lead_interceptors / v_lead_review views (service role; not tested with him yet). Plan '
  'docs/specs/2026-11-03-boca-bsi-leads-and-filing-plan.md.';

-- 3. the quiet load
create function leads.ingest_quiet(p_source text, p_run_started_at timestamptz, p_records jsonb, p_file text,
                                   p_dry_run boolean default true)
returns jsonb
language plpgsql security definer set search_path = ''
as $fn$
-- A failing statement is written to the server log with its full text. The loader sends the payload (CCNs, BSI
-- contacts) as a literal, so that statement must never fail: every error is caught here and returned as data, and a
-- dry run undoes itself inside this function (2026-11-03_1848).
declare v_ingest jsonb; v_report jsonb;
begin
  begin
    v_ingest := leads.ingest(p_source, p_run_started_at, p_records, p_file);
    if p_dry_run is false then
      return jsonb_build_object('ok', true, 'dry_run', false, 'ingest', v_ingest);
    end if;
    v_report := jsonb_build_object('ok', true, 'dry_run', true, 'ingest', v_ingest,
      'states', (select jsonb_object_agg(s.lead_state, s.n)
                   from (select e.lead_state, count(*) as n from leads.v_establishment_state e group by 1) s),
      'frozen_rows', (select count(*) from public.v_frozen_leads),
      'interceptor_rows', (select count(*) from public.v_lead_interceptors),
      'review', (select jsonb_agg(jsonb_build_object('kind', r.kind, 'bsi', r.source_id, 'name', r.source_name,
                   'client', r.client_code, 'property', r.property_id, 'on', r.matched_on, 'score', r.name_score)
                   order by r.kind, r.client_code, r.source_id)
                   from public.v_lead_review r));
    raise exception using errcode = 'P0001', message = 'leads_ingest_quiet_undo';
  exception when others then
    if sqlerrm = 'leads_ingest_quiet_undo' then return v_report; end if;
    return jsonb_build_object('ok', false, 'dry_run', coalesce(p_dry_run, true), 'sqlstate', sqlstate, 'message', sqlerrm);
  end;
end $fn$;
comment on function leads.ingest_quiet(text, timestamptz, jsonb, text, boolean) is
  'The loader''s only entry (scripts/leads/load_bsi.mjs). Calls leads.ingest; never raises: an error comes back as '
  '{ok:false, sqlstate, message}, so the statement carrying the payload is never written to the server log. '
  'p_dry_run (default true) returns what the load would produce and keeps nothing.';
revoke all on function leads.ingest_quiet(text, timestamptz, jsonb, text, boolean) from public, anon, authenticated, service_role;

-- VERIFY
do $verify$
declare v_bad text; v_n int; v_before int; v_r jsonb; v_t timestamptz := now() + interval '1 day';
begin
  -- 1. the link view: exactly the source_record rows are gone, every other row is unchanged
  if not exists (select 1 from _p_esl_before where entity_type = 'source_record' and n > 0) then
    raise exception 'leads privacy VERIFY: CONTROL FAILED, no source_record rows before';
  end if;
  if exists (select 1 from client.entity_source_links where entity_type = 'source_record') then
    raise exception 'leads privacy VERIFY: the link view still shows source_record rows';
  end if;
  select string_agg(b.entity_type, ', ') into v_bad
    from _p_esl_before b
    left join (select entity_type, count(*) as n, md5(string_agg(t::text, '|' order by t.id)) as h
                 from client.entity_source_links t group by entity_type) a on a.entity_type = b.entity_type
   where b.entity_type <> 'source_record' and (a.h is distinct from b.h);
  if v_bad is not null then raise exception 'leads privacy VERIFY: link rows changed for %', v_bad; end if;

  -- 2. the frozen view: same rows, same columns except owner_company, which moved only where it was a contact's name
  select count(*) into v_before from _p_frozen_before f
   where upper(regexp_replace(btrim(f.owner_company), '[[:space:]]+', ' ', 'g')) in (select k from _p_name_keys);
  if v_before = 0 then raise exception 'leads privacy VERIFY: CONTROL FAILED, no contact name in owner_company before'; end if;
  if (select count(*) from _p_frozen_before) <> (select count(*) from public.v_frozen_leads) then
    raise exception 'leads privacy VERIFY: the frozen row count changed';
  end if;
  select count(*) into v_n
    from _p_frozen_before b
    full join public.v_frozen_leads a on a.establishment_id = b.establishment_id
   where a.establishment_id is null or b.establishment_id is null
      or (to_jsonb(a) - 'owner_company') <> (to_jsonb(b) - 'owner_company')
      or (a.owner_company is distinct from b.owner_company
          and not (a.owner_company is null
                   and upper(regexp_replace(btrim(b.owner_company), '[[:space:]]+', ' ', 'g')) in (select k from _p_name_keys)));
  if v_n <> 0 then raise exception 'leads privacy VERIFY: % frozen rows changed in a way not intended', v_n; end if;
  if (select count(*) from _p_frozen_before b join public.v_frozen_leads a using (establishment_id)
       where a.owner_company is distinct from b.owner_company) <> v_before then
    raise exception 'leads privacy VERIFY: blanked % owner names, expected %',
      (select count(*) from _p_frozen_before b join public.v_frozen_leads a using (establishment_id)
        where a.owner_company is distinct from b.owner_company), v_before;
  end if;

  -- 3. the review view: same rows apart from owner_company; no contact name left in either view
  if (select md5(string_agg((to_jsonb(t) - 'owner_company')::text, '|' order by (to_jsonb(t) - 'owner_company')::text)) from _p_review_before t)
     is distinct from (select md5(string_agg((to_jsonb(t) - 'owner_company')::text, '|' order by (to_jsonb(t) - 'owner_company')::text)) from public.v_lead_review t) then
    raise exception 'leads privacy VERIFY: the review rows changed beyond owner_company';
  end if;
  if exists (select 1 from public.v_frozen_leads f
              where upper(regexp_replace(btrim(f.owner_company), '[[:space:]]+', ' ', 'g')) in (select k from _p_name_keys))
     or exists (select 1 from public.v_lead_review r
              where upper(regexp_replace(btrim(r.owner_company), '[[:space:]]+', ' ', 'g')) in (select k from _p_name_keys)) then
    raise exception 'leads privacy VERIFY: a contact name is still shown';
  end if;

  -- 4. grants read back
  if exists (select 1 from _p_acl_before x join pg_class c on c.oid = x.oid where c.relacl::text is distinct from x.acl) then
    raise exception 'leads privacy VERIFY: a view''s grants changed';
  end if;
  if has_table_privilege('service_role', 'leads.v_bsi_contact_names', 'SELECT')
     or has_table_privilege('authenticated', 'leads.v_bsi_contact_names', 'SELECT')
     or not has_table_privilege('service_role', 'public.v_frozen_leads', 'SELECT')
     or has_table_privilege('authenticated', 'public.v_frozen_leads', 'SELECT')
     or not has_table_privilege('authenticated', 'client.entity_source_links', 'SELECT') then
    raise exception 'leads privacy VERIFY: view privileges are not as intended';
  end if;
  if has_function_privilege('service_role', 'leads.ingest_quiet(text,timestamptz,jsonb,text,boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'leads.ingest_quiet(text,timestamptz,jsonb,text,boolean)', 'EXECUTE')
     or has_function_privilege('anon', 'leads.ingest_quiet(text,timestamptz,jsonb,text,boolean)', 'EXECUTE') then
    raise exception 'leads privacy VERIFY: ingest_quiet is open to an API role';
  end if;

  -- 5. ingest_quiet: a dry run reports and keeps nothing (also the 4-argument default)
  v_r := leads.ingest_quiet('bsi', v_t, '[{"source_id":"verify-q1","source_name":"VERIFY Q1","payload":{"search_item":{"label":"VERIFY Q1","physical_address":{"address":"1 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}}]'::jsonb, 'verify');
  if (v_r ->> 'ok')::boolean is not true or (v_r ->> 'dry_run')::boolean is not true
     or (v_r -> 'ingest' ->> 'new_records')::int <> 1 or v_r -> 'states' is null or v_r -> 'frozen_rows' is null then
    raise exception 'leads privacy VERIFY: the dry run did not report: %', v_r;
  end if;
  if exists (select 1 from public.entity_source_links where entity_type = 'source_record' and source_id = 'verify-q1')
     or exists (select 1 from public.sync_log where sync_source = 'leads:bsi' and details ->> 'file' = 'verify') then
    raise exception 'leads privacy VERIFY: the dry run kept something';
  end if;
  -- a refusal comes back as data, not as an error
  v_r := leads.ingest_quiet('nope', v_t, '[{"source_id":"x","payload":{}}]'::jsonb, 'verify', false);
  if (v_r ->> 'ok')::boolean is not false or v_r ->> 'sqlstate' is distinct from '22023' then
    raise exception 'leads privacy VERIFY: a refusal did not come back as data: %', v_r;
  end if;
  -- a live call keeps its rows (undone by this sub-block)
  begin
    v_r := leads.ingest_quiet('bsi', v_t, '[{"source_id":"verify-q2","source_name":"VERIFY Q2","payload":{"search_item":{"label":"VERIFY Q2","physical_address":{"address":"2 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}}]'::jsonb, 'verify', false);
    if (v_r ->> 'ok')::boolean is not true or (v_r ->> 'dry_run')::boolean is not false
       or not exists (select 1 from public.entity_source_links where entity_type = 'source_record' and source_id = 'verify-q2') then
      raise exception 'leads privacy VERIFY: the live call did not keep its record: %', v_r;
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
end $verify$;

notify pgrst, 'reload schema';
commit;
