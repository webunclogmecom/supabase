-- ============================================================================
-- 2026-11-03_2039_leads_label_mask_and_quiet_load  Frozen leads: the BSI label, the link copy and the load statement
-- ============================================================================
-- THE ASK: Fred 2026-11-03, Trello #165 / #166: BSI contacts "Load them privately now"; CCNs "Keep all, privately".
--   Root CLAUDE.md section 6, card process step 8: fix what the checks find, then run them again. A second read-only
--   adversarial pass re-attacked the 18:48 fixes (7 privacy, 5 routing and 20 documentation findings). This migration
--   fixes the privacy ones; the routing ones are in 2026-11-03_2039_route_line27_alerts.
-- WHAT
--   1. The BSI label (the restaurant name BSI shows) is a BSI contact's name on 3 records (1 reads as a person's name).
--      _1848 blanked owner_company only, so service_role still read those 3 values in public.v_frozen_leads.name,
--      public.v_lead_interceptors.name and public.entity_source_links.source_name. Now:
--      - public.v_frozen_leads.name, public.v_lead_interceptors.name and public.v_lead_review.source_name are blank
--        when the label is a contact's name;
--      - leads.ingest no longer copies the label into public.entity_source_links.source_name (nothing reads it there:
--        leads.v_src_bsi reads the label from the payload, and client.entity_source_links leaves these rows out), and
--        the 431 copies are cleared. That table has no trigger, so no audit row repeats the old values.
--   2. The name test uses leads.fn_name_key (the project's own name key: upper case, punctuation and LLC/INC/THE/...
--      dropped), not "upper case, spaces collapsed". One more mailing name is blanked (19, was 18): a punctuation
--      variant of another record's contact. A contact's name INSIDE a longer business name stays (2 labels, 2 mailing
--      names, e.g. a company named after its owner): the plan keeps the mailing name, a public business name.
--   3. leads.ingest_quiet still let the loader's statement fail, and so be logged with the payload, in three ways:
--      - its arguments were jsonb / timestamptz, so the cast of the loader's literals ran BEFORE the function, outside
--        its handler (a \u0000 in a BSI string fails as 22P05, a lone surrogate as 22P02, a year past 9999 as 22009);
--      - a lock wait longer than deadlock_timeout (1 s) is logged WITH the statement (log_lock_waits = on), even when
--        the statement then succeeds;
--      - a cancel or statement_timeout (57014) is not caught by WHEN OTHERS.
--      The new leads.ingest_quiet(text, text, text, text, boolean) takes the run start and the records as TEXT and
--      casts them inside its handler, runs with lock_timeout 500 ms (a busy lock gives up at 0.5 s, before the 1 s log
--      line, and comes back as 55P03 data) and catches query_canceled by name. The old (timestamptz, jsonb) signature
--      is dropped; scripts/leads/load_bsi.mjs checks that the new one exists before it sends anything.
--      Residuals: auto_explain still logs a statement that runs 10 s or more (a load takes under 1 s), and a deadlock
--      report would carry the first 1 kB of the statement (no cycle is reachable: every leads writer takes the 'leads'
--      advisory lock first, and the source_record links collide with no other writer).
--   Comments corrected (live): leads.ingest (it creates the links; decide_client also moves records), leads.source_versions
--   (two private views output payload values), leads.v_bsi_contact_names (the key), the three public views.
-- CORRECTIONS TO TODAY'S EARLIER HEADERS (those files record what was applied, so they are corrected here, not edited):
--   - _1848_leads_privacy_fixes item 1 gives "3 labels equal a BSI contact's name" as a reason to hide the links from
--     signed-in staff, and its view comments then say the public views never show a contact: the same 3 labels stayed
--     readable by service_role (item 1 above).
--   - _1848_leads_privacy_fixes item 3 says the 16:41 ET line was "not shipped to Logs Explorer (the line was over the
--     shipper's limit)": the ERROR line was shipped, WITHOUT its statement text (3,326 characters, 0 CCN or contact
--     values). The payload never reached Logs Explorer; why the statement was left out is not verified.
--   - _1848_leads_privacy_fixes says the outer statement "never fails, so nothing is logged": item 3 above.
-- GRANTS: leads.ingest_quiet(text,text,text,text,boolean): postgres only. The four views keep their grants (read back).
-- RULE 8: no table created. RULE 7: no CHECK widened.
-- LOCKS: the views have no live reader (no app; Viktor has not started); the 431 link rows have no other writer;
--   lock_timeout 3s, applied clear of the backup dump (:17 on even UTC hours).
-- VERIFY (inside): before/after snapshots in one transaction: the frozen and interceptor views keep every row and every
--   column except name (and owner_company), which change only to blank and only where the value's key is a contact's
--   (control: above 0 before); no cell of the three views is a contact's name after; the 431 links keep everything but
--   source_name, now blank, and no other link moved; grants unchanged; ingest_quiet: a dry run keeps nothing, a
--   refusal, a \u0000, a lone surrogate and a bad run start come back as data (control: each of those three literals
--   fails when cast outside), a live call keeps its record with no label copy, also on its update path (undone here).
-- ROLLBACK: docs/migrations/2026-11-03_rollback_leads_label_mask_and_quiet_load.sql (run it before the _1848 one).
-- APPLIED 2026-11-03 20:38 ET (20:38:03 to 20:38:09), after a rehearsal; named 2039 because the name was already written
--   into stored comments. Checked after: the leads.ingest body equals the old body plus exactly these two edits; a real
--   dry run of the new loader (431 records unchanged, nothing kept) and a busy lock (55P03) and a statement timeout
--   (57014) each came back as data with HTTP 201, and the server log of those windows held 0 errors, 0 lock waits, 0
--   events naming the load and 0 CCN, contact email, phone or contact name (a planted lock wait and a planted failing
--   call were both seen by the same scan, so its zeros are real).
-- ============================================================================
begin;
set local lock_timeout = '3s';
set local search_path = public, extensions;   -- pg_get_viewdef text below is written and re-read under this path

do $pre$
begin
  if md5(pg_get_viewdef('leads.v_bsi_contact_names'::regclass, false)) <> 'a5a45c8562ef7813a7dd49f2def1e509' then
    raise exception 'leads label mask: leads.v_bsi_contact_names changed since this migration was written';
  end if;
  if md5(pg_get_viewdef('public.v_frozen_leads'::regclass, false)) <> '40908a98ae7dcc0ac56d72ebb8d7905f' then
    raise exception 'leads label mask: public.v_frozen_leads changed since this migration was written';
  end if;
  if md5(pg_get_viewdef('public.v_lead_interceptors'::regclass, false)) <> '265e3a8f6b250361bcfaa42dd80b96b5' then
    raise exception 'leads label mask: public.v_lead_interceptors changed since this migration was written';
  end if;
  if md5(pg_get_viewdef('public.v_lead_review'::regclass, false)) <> '7a41e50e70e2fa05b15429035c84a81a' then
    raise exception 'leads label mask: public.v_lead_review changed since this migration was written';
  end if;
  if md5((select prosrc from pg_proc where oid = 'leads.ingest(text,timestamptz,jsonb,text)'::regprocedure)) <> 'bbb2644c5d498ed1cef2a2ae52890821' then
    raise exception 'leads label mask: leads.ingest changed since this migration was written';
  end if;
  if md5((select prosrc from pg_proc where oid = 'leads.ingest_quiet(text,timestamptz,jsonb,text,boolean)'::regprocedure)) <> 'cf56ba1d659f9183ae4b6ab1e2c7cc26' then
    raise exception 'leads label mask: leads.ingest_quiet changed since this migration was written';
  end if;
  if to_regprocedure('leads.ingest_quiet(text,text,text,text,boolean)') is not null then
    raise exception 'leads label mask: the new ingest_quiet signature already exists';
  end if;
end $pre$;

-- the "before" pictures (one transaction, so now() is one value)
create temp table _q_keys on commit drop as
select distinct leads.fn_name_key(v.payload -> 'search_item' -> 'contact' ->> 'name') as k
  from leads.source_versions v
 where leads.fn_name_key(v.payload -> 'search_item' -> 'contact' ->> 'name') is not null;
create temp table _q_frozen_before on commit drop as select * from public.v_frozen_leads;
create temp table _q_inter_before on commit drop as select * from public.v_lead_interceptors;
create temp table _q_review_before on commit drop as select * from public.v_lead_review;
create temp table _q_esl_before on commit drop as
select entity_type, count(*) as n, count(source_name) as named,
       md5(string_agg((to_jsonb(t) - 'source_name')::text, '|' order by t.id)) as h_rest,
       md5(string_agg(t::text, '|' order by t.id)) as h_all
  from public.entity_source_links t group by entity_type;
create temp table _q_acl_before on commit drop as
select c.oid, c.relacl::text as acl from pg_class c
 where c.oid in ('leads.v_bsi_contact_names'::regclass, 'public.v_frozen_leads'::regclass,
                 'public.v_lead_interceptors'::regclass, 'public.v_lead_review'::regclass);

-- 1. the private name list, on the project's name key
create or replace view leads.v_bsi_contact_names as
select distinct leads.fn_name_key(v.payload -> 'search_item' -> 'contact' ->> 'name') as name_key
  from leads.source_versions v
 where leads.fn_name_key(v.payload -> 'search_item' -> 'contact' ->> 'name') is not null;

-- 2. the anchored view edits
do $edit$
declare d text; a text; b text; m text; o text;
begin
  m := 'CASE WHEN (leads.fn_name_key(%1$s) IN ( SELECT n.name_key FROM leads.v_bsi_contact_names n)) THEN NULL::text ELSE %1$s END';
  o := 'upper(regexp_replace(btrim(%1$s.owner_company), ''[[:space:]]+''::text, '' ''::text, ''g''::text))';

  d := rtrim(btrim(pg_get_viewdef('public.v_frozen_leads'::regclass, false)), ';');
  a := E'    s.name,\n    s.street,';
  b := E'    ' || format(m, 's.name') || E' AS name,\n    s.street,';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: frozen name anchor not found once'; end if;
  d := replace(d, a, b);
  a := format(o, 's');
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: frozen owner anchor not found once'; end if;
  execute 'create or replace view public.v_frozen_leads as ' || replace(d, a, 'leads.fn_name_key(s.owner_company)');

  d := rtrim(btrim(pg_get_viewdef('public.v_lead_interceptors'::regclass, false)), ';');
  a := E'    (x.value ->> ''id''::text) AS source_interceptor_id,\n    s.name,\n';
  b := E'    (x.value ->> ''id''::text) AS source_interceptor_id,\n    ' || format(m, 's.name') || E' AS name,\n';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: interceptor name anchor not found once'; end if;
  execute 'create or replace view public.v_lead_interceptors as ' || replace(d, a, b);

  d := rtrim(btrim(pg_get_viewdef('public.v_lead_review'::regclass, false)), ';');
  a := E'    c.name AS source_name,\n';
  b := E'    ' || format(m, 'c.name') || E' AS source_name,\n';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: review name anchor 1 not found once'; end if;
  d := replace(d, a, b);
  a := E'    s.name AS source_name,\n';
  b := E'    ' || format(m, 's.name') || E' AS source_name,\n';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: review name anchor 2 not found once'; end if;
  d := replace(d, a, b);
  a := format(o, 'c');
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: review owner anchor 1 not found once'; end if;
  d := replace(d, a, 'leads.fn_name_key(c.owner_company)');
  a := format(o, 's');
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: review owner anchor 2 not found once'; end if;
  execute 'create or replace view public.v_lead_review as ' || replace(d, a, 'leads.fn_name_key(s.owner_company)');

  -- 3. leads.ingest: no label copy in the link (its two write sites)
  d := pg_get_functiondef('leads.ingest(text,timestamptz,jsonb,text)'::regprocedure);
  a := E'values (''source_record'', v_srid, p_source, v_sid, v_rec ->> ''source_name'', ''api_pull'', 1, p_run_started_at);';
  b := E'values (''source_record'', v_srid, p_source, v_sid, null, ''api_pull'', 1, p_run_started_at);  -- no label copy: it stays in the payload (2026-11-03)';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: ingest insert anchor not found once'; end if;
  d := replace(d, a, b);
  a := E'set source_name = coalesce(v_rec ->> ''source_name'', source_name), synced_at = p_run_started_at';
  b := E'set source_name = null, synced_at = p_run_started_at';
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'leads label mask: ingest update anchor not found once'; end if;
  execute replace(d, a, b);
end $edit$;

update public.entity_source_links set source_name = null
 where entity_type = 'source_record' and source_name is not null;

comment on view leads.v_bsi_contact_names is
  'Every contact-person name BSI has given us (any version), as leads.fn_name_key (upper case, punctuation and '
  'LLC/INC/THE/... dropped). Private. The public lead views blank a BSI label (name, source_name) or mailing name '
  '(owner_company) whose key is one of these (2026-11-03_1848, _2039).';
comment on view public.v_frozen_leads is
  'Frozen leads: restaurants we only know from an outside source (BSI Online, City of Boca Raton FOG program), never '
  'contacted, not our client, not a Jobber lead, not waiting for review. One row per restaurant. Overdue = BSI''s next '
  'pump date before today (ET). Read-only, for Viktor (service role; his first read is not tested yet). No CCN and no '
  'contact email or phone; name and owner_company are blank when they are a BSI contact''s name (a contact''s name inside '
  'a longer business name stays). Trello #166.';
comment on column public.v_frozen_leads.name is
  'The restaurant name BSI shows (its label). Blank on the few records where it is a BSI contact''s name (private, Fred '
  '2026-11-03).';
comment on column public.v_frozen_leads.owner_company is
  'The mailing name BSI lists for the property (often the operator''s LLC; can be the landlord). Blank when it is the '
  'name of a person BSI lists as a contact (leads.fn_name_key; private, Fred 2026-11-03).';
comment on view public.v_lead_interceptors is
  'One row per BSI interceptor, every state (frozen, needs_review, client, warm, former_client). For a client, '
  'property_id / client_code are ours and source_id / source_interceptor_id are BSI''s property and interceptor ids (the '
  'filing bot, Trello #169). Read-only, service role only. No CCN and no contact email or phone; name is blank when it is '
  'a BSI contact''s name.';
comment on view public.v_lead_review is
  'What a person must decide before leads are trusted: client_candidate (an outside record that may be one of our '
  'properties), client_without_source_record (one of our properties in a covered city with no record), '
  'client_record_changed (a linked record whose name or owner changed). Decisions go through leads.decide_client. '
  'Read-only, service role only; source_name and owner_company are blank when they are a BSI contact''s name. Trello #166.';
comment on table leads.source_versions is
  'What the source said: a new row only when the content changed; otherwise only last_seen_at moves. fetched_at = '
  'start of the first run that returned this content; last_seen_at = start of the latest run that returned it '
  'unchanged. Private: payloads hold CCNs and BSI contacts (Fred 2026-11-03: keep privately). No API role reads them. '
  'Two views output payload values: leads.v_src_bsi (CCN and contact) and leads.v_bsi_contact_names (contact names), '
  'readable by postgres, db_backup_reader (the backup) and Supabase''s platform roles only. The public lead views carry '
  'no CCN, email or phone and blank a name that is a contact''s; scripts/checks/leads_integrity.sql tests their values.';
comment on function leads.ingest(text, timestamptz, jsonb, text) is
  'Creates the source records, their versions and their source links (public.entity_source_links, entity_type '
  'source_record, with no label copy since 2026-11-03_2039); leads.decide_client also moves records between restaurants. '
  'p_records = [{source_id, payload}], one call per run, only through leads.ingest_quiet (scripts/leads/load_bsi.mjs). A '
  'new version only when the payload changed; otherwise last_seen_at moves. Never writes a decision or a status.';

-- 4. the quiet load, with text arguments
drop function leads.ingest_quiet(text, timestamptz, jsonb, text, boolean);
create function leads.ingest_quiet(p_source text, p_run_started_at text, p_records text, p_file text,
                                   p_dry_run boolean default true)
returns jsonb
language plpgsql security definer
set search_path = '' set lock_timeout = '500ms'
as $fn$
-- The loader sends the payload (CCNs, BSI contacts) as a literal, and Postgres writes the full text of a failing
-- statement to its server log, so that statement must not fail. The run start and the records arrive as TEXT and are
-- cast here, inside the handler (a cast before the call would fail the statement itself); lock_timeout 500 ms ends a
-- lock wait before log_lock_waits (deadlock_timeout 1 s) writes it with the statement; query_canceled is caught by name
-- (WHEN OTHERS does not catch it). Every error comes back as data; a dry run undoes itself here (2026-11-03_1848, _2039).
declare v_ingest jsonb; v_report jsonb;
begin
  begin
    v_ingest := leads.ingest(p_source, p_run_started_at::timestamptz, p_records::jsonb, p_file);
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
  exception
    when query_canceled then
      return jsonb_build_object('ok', false, 'dry_run', coalesce(p_dry_run, true), 'sqlstate', sqlstate, 'message', sqlerrm);
    when others then
      if sqlstate = 'P0001' and sqlerrm = 'leads_ingest_quiet_undo' then return v_report; end if;
      return jsonb_build_object('ok', false, 'dry_run', coalesce(p_dry_run, true), 'sqlstate', sqlstate, 'message', sqlerrm);
  end;
end $fn$;
comment on function leads.ingest_quiet(text, text, text, text, boolean) is
  'The loader''s only entry (scripts/leads/load_bsi.mjs). Takes the run start and the records as text and casts them '
  'inside; calls leads.ingest with lock_timeout 500 ms; returns every error, a cancel included, as {ok:false, sqlstate, '
  'message}, so the statement carrying the payload does not fail and is not logged (a statement that runs 10 s or more '
  'is still logged by auto_explain). p_dry_run (default true) returns what the load would produce and keeps nothing.';
revoke all on function leads.ingest_quiet(text, text, text, text, boolean) from public, anon, authenticated, service_role;

-- VERIFY
do $verify$
declare v_n int; v_c int; v_r jsonb; v_t timestamptz := now() + interval '1 day'; v_pay text;
begin
  -- 1. the frozen view: same rows, same columns except name and owner_company, which went blank only where the old
  --    value's key is a contact's
  select count(*) into v_c from _q_frozen_before f where leads.fn_name_key(f.name) in (select k from _q_keys);
  if v_c = 0 then raise exception 'leads label mask VERIFY: CONTROL FAILED, no frozen label was a contact''s name before'; end if;
  if (select count(*) from _q_frozen_before) <> (select count(*) from public.v_frozen_leads) then
    raise exception 'leads label mask VERIFY: the frozen row count changed';
  end if;
  select count(*) into v_n
    from _q_frozen_before b full join public.v_frozen_leads a on a.establishment_id = b.establishment_id
   where a.establishment_id is null or b.establishment_id is null
      or (to_jsonb(a) - 'name' - 'owner_company') <> (to_jsonb(b) - 'name' - 'owner_company')
      or (a.name is distinct from b.name and not (a.name is null and leads.fn_name_key(b.name) in (select k from _q_keys)))
      or (a.owner_company is distinct from b.owner_company
          and not (a.owner_company is null and leads.fn_name_key(b.owner_company) in (select k from _q_keys)));
  if v_n <> 0 then raise exception 'leads label mask VERIFY: % frozen rows changed in a way not intended', v_n; end if;
  if (select count(*) from _q_frozen_before b join public.v_frozen_leads a using (establishment_id) where a.name is distinct from b.name) <> v_c then
    raise exception 'leads label mask VERIFY: blanked a different number of frozen labels than expected (%)', v_c;
  end if;

  -- 2. the interceptor view: same rows, same columns except name, blank only where it was a contact's name
  select count(*) into v_c from _q_inter_before i where leads.fn_name_key(i.name) in (select k from _q_keys);
  if v_c = 0 then raise exception 'leads label mask VERIFY: CONTROL FAILED, no interceptor label was a contact''s name before'; end if;
  if (select count(*) from _q_inter_before) <> (select count(*) from public.v_lead_interceptors) then
    raise exception 'leads label mask VERIFY: the interceptor row count changed';
  end if;
  select count(*) into v_n
    from _q_inter_before b full join public.v_lead_interceptors a
      on a.establishment_id = b.establishment_id and a.source_interceptor_id = b.source_interceptor_id
   where a.establishment_id is null or b.establishment_id is null
      or (to_jsonb(a) - 'name') <> (to_jsonb(b) - 'name')
      or (a.name is distinct from b.name and not (a.name is null and leads.fn_name_key(b.name) in (select k from _q_keys)));
  if v_n <> 0 then raise exception 'leads label mask VERIFY: % interceptor rows changed in a way not intended', v_n; end if;

  -- 3. the review view: same rows apart from source_name / owner_company
  if (select md5(string_agg((to_jsonb(t) - 'source_name' - 'owner_company')::text, '|' order by (to_jsonb(t) - 'source_name' - 'owner_company')::text)) from _q_review_before t)
     is distinct from (select md5(string_agg((to_jsonb(t) - 'source_name' - 'owner_company')::text, '|' order by (to_jsonb(t) - 'source_name' - 'owner_company')::text)) from public.v_lead_review t) then
    raise exception 'leads label mask VERIFY: the review rows changed beyond source_name and owner_company';
  end if;

  -- 4. no cell of the three views is a contact's name after
  select count(*) into v_n
    from (select to_jsonb(t) as j from public.v_frozen_leads t
          union all select to_jsonb(t) from public.v_lead_interceptors t
          union all select to_jsonb(t) from public.v_lead_review t) r
    cross join lateral jsonb_each_text(r.j) kv
   where kv.value is not null and leads.fn_name_key(kv.value) in (select k from _q_keys);
  if v_n <> 0 then raise exception 'leads label mask VERIFY: % view cells are still a contact''s name', v_n; end if;

  -- 5. the links: the 431 keep everything but source_name, now blank; no other link moved
  if not exists (select 1 from _q_esl_before where entity_type = 'source_record' and named > 0) then
    raise exception 'leads label mask VERIFY: CONTROL FAILED, no labelled source_record link before';
  end if;
  select count(*) into v_n
    from _q_esl_before b
    left join (select entity_type, count(*) as n, count(source_name) as named,
                      md5(string_agg((to_jsonb(t) - 'source_name')::text, '|' order by t.id)) as h_rest,
                      md5(string_agg(t::text, '|' order by t.id)) as h_all
                 from public.entity_source_links t group by entity_type) a on a.entity_type = b.entity_type
   where a.n is distinct from b.n
      or (b.entity_type = 'source_record' and (a.named <> 0 or a.h_rest is distinct from b.h_rest))
      or (b.entity_type <> 'source_record' and a.h_all is distinct from b.h_all);
  if v_n <> 0 then raise exception 'leads label mask VERIFY: % link groups changed in a way not intended', v_n; end if;
  if position('v_rec ->> ''source_name''' in (select prosrc from pg_proc where oid = 'leads.ingest(text,timestamptz,jsonb,text)'::regprocedure)) > 0 then
    raise exception 'leads label mask VERIFY: leads.ingest still copies the label';
  end if;

  -- 6. grants read back; the new ingest_quiet is postgres-only and carries its lock_timeout
  if exists (select 1 from _q_acl_before x join pg_class c on c.oid = x.oid where c.relacl::text is distinct from x.acl) then
    raise exception 'leads label mask VERIFY: a view''s grants changed';
  end if;
  if to_regprocedure('leads.ingest_quiet(text,timestamptz,jsonb,text,boolean)') is not null then
    raise exception 'leads label mask VERIFY: the old ingest_quiet signature still exists';
  end if;
  if has_function_privilege('service_role', 'leads.ingest_quiet(text,text,text,text,boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'leads.ingest_quiet(text,text,text,text,boolean)', 'EXECUTE')
     or has_function_privilege('anon', 'leads.ingest_quiet(text,text,text,text,boolean)', 'EXECUTE')
     or has_table_privilege('service_role', 'leads.v_bsi_contact_names', 'SELECT') then
    raise exception 'leads label mask VERIFY: an API role can run ingest_quiet or read the name list';
  end if;
  if not exists (select 1 from pg_proc where oid = 'leads.ingest_quiet(text,text,text,text,boolean)'::regprocedure
                    and proconfig @> array['lock_timeout=500ms']) then
    raise exception 'leads label mask VERIFY: ingest_quiet has no lock_timeout';
  end if;

  -- 7. ingest_quiet: a dry run reports and keeps nothing (also the 4-argument default)
  v_r := leads.ingest_quiet('bsi', v_t::text, '[{"source_id":"verify-q1","payload":{"search_item":{"label":"VERIFY Q1","physical_address":{"address":"1 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}}]', 'verify');
  if (v_r ->> 'ok')::boolean is not true or (v_r ->> 'dry_run')::boolean is not true
     or (v_r -> 'ingest' ->> 'new_records')::int <> 1 or v_r -> 'states' is null or v_r -> 'frozen_rows' is null then
    raise exception 'leads label mask VERIFY: the dry run did not report: %', v_r;
  end if;
  if exists (select 1 from public.entity_source_links where entity_type = 'source_record' and source_id = 'verify-q1')
     or exists (select 1 from public.sync_log where sync_source = 'leads:bsi' and details ->> 'file' = 'verify') then
    raise exception 'leads label mask VERIFY: the dry run kept something';
  end if;
  -- a refusal comes back as data
  v_r := leads.ingest_quiet('nope', v_t::text, '[{"source_id":"x","payload":{}}]', 'verify', false);
  if (v_r ->> 'ok')::boolean is not false or v_r ->> 'sqlstate' is distinct from '22023' then
    raise exception 'leads label mask VERIFY: a refusal did not come back as data: %', v_r;
  end if;
  -- three literals that fail when cast outside a handler (control), and come back as data from ingest_quiet
  foreach v_pay in array array['[{"source_id":"verify-n","payload":{"search_item":{"label":"A\u0000B"}}}]',
                               '[{"source_id":"verify-s","payload":{"search_item":{"label":"A\ud83dB"}}}]'] loop
    begin
      perform v_pay::jsonb;
      raise exception 'leads label mask VERIFY: CONTROL FAILED, a bad literal cast to jsonb';
    exception when others then
      if sqlstate not in ('22P05', '22P02') then raise; end if;
    end;
    v_r := leads.ingest_quiet('bsi', v_t::text, v_pay, 'verify', false);
    if (v_r ->> 'ok')::boolean is not false or v_r ->> 'sqlstate' not in ('22P05', '22P02') then
      raise exception 'leads label mask VERIFY: a bad payload did not come back as data: %', v_r;
    end if;
  end loop;
  begin
    perform '+010000-01-01T00:00:00.000Z'::timestamptz;
    raise exception 'leads label mask VERIFY: CONTROL FAILED, a year past 9999 cast to timestamptz';
  exception when others then
    if left(sqlstate, 2) <> '22' then raise; end if;
  end;
  v_r := leads.ingest_quiet('bsi', '+010000-01-01T00:00:00.000Z', '[{"source_id":"x","payload":{}}]', 'verify', false);
  if (v_r ->> 'ok')::boolean is not false or left(v_r ->> 'sqlstate', 2) <> '22' then
    raise exception 'leads label mask VERIFY: a bad run start did not come back as data: %', v_r;
  end if;
  -- a live call keeps its record, with no label in the link, on the insert and on the update path (undone here)
  begin
    v_r := leads.ingest_quiet('bsi', v_t::text, '[{"source_id":"verify-q2","source_name":"VERIFY Q2","payload":{"search_item":{"label":"VERIFY Q2","physical_address":{"address":"2 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}}]', 'verify', false);
    if (v_r ->> 'ok')::boolean is not true or (v_r ->> 'dry_run')::boolean is not false
       or not exists (select 1 from public.entity_source_links where entity_type = 'source_record' and source_id = 'verify-q2' and source_name is null) then
      raise exception 'leads label mask VERIFY: the live call did not keep its record without a label: %', v_r;
    end if;
    update public.entity_source_links set source_name = 'VERIFY STALE' where entity_type = 'source_record' and source_id = 'verify-q2';
    v_r := leads.ingest_quiet('bsi', (v_t + interval '1 minute')::text, '[{"source_id":"verify-q2","source_name":"VERIFY Q2B","payload":{"search_item":{"label":"VERIFY Q2B","physical_address":{"address":"2 Verify Rd","city":"Verifyville","zip_code":"00001"}},"detail":{"interceptors":[]}}}]', 'verify', false);
    if (v_r ->> 'ok')::boolean is not true or (v_r -> 'ingest' ->> 'new_versions')::int <> 1
       or not exists (select 1 from public.entity_source_links where entity_type = 'source_record' and source_id = 'verify-q2' and source_name is null) then
      raise exception 'leads label mask VERIFY: the update path left a label in the link: %', v_r;
    end if;
    raise exception 'verify_ok';
  exception when others then
    if sqlerrm <> 'verify_ok' then raise; end if;
  end;
end $verify$;

notify pgrst, 'reload schema';
commit;
