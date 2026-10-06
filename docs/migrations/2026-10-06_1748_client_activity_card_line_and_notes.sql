-- ============================================================================
-- 2026-10-06_1748 · client.get_client_activity: no summary line under a card; a note is not "edited"
-- ============================================================================
-- Found rendering the round-2 mockup from the live output of 2026-10-06_1736 (112-YA):
--   1. A status card or a cadence card is an INSERT row, so it also got the one-line summary meant for an added
--      record, which rendered as an empty "Contact:" line under the card. Cards now carry no summary line.
--      Smoke case C4 now asserts the card entry has no change lines, and mutation control "cardline" proves it bites.
--   2. A note (public.notes) came back with long = true, which the app renders as "Note edited". A note is new text:
--      long is false and the app wraps it.
-- The whole function body is replaced from scripts/client-app/tests/client_activity/function.sql (the build file the
-- smoke tests run). Nothing else changes: grants are kept by CREATE OR REPLACE (asserted below).
-- Proven: 20/20 smoke cases and 12 mutation controls on the pg_temp copy, then 20/20 on the live function.
-- Rule 8: no table change. ROLLBACK: re-apply the function from 2026-10-06_1736.
-- ============================================================================
BEGIN;
DO $pre$
BEGIN
  IF md5(pg_get_functiondef('client.get_client_activity(bigint,boolean,integer,jsonb)'::regprocedure)) <> 'f89bc700449cb00842d6ff330c63c833' THEN
    RAISE EXCEPTION 'client.get_client_activity changed since 2026-10-06_1736';
  END IF;
END $pre$;

-- client.get_client_activity: every change at one client, newest first (spec 2026-10-06-client-activity-history-design.md).
-- client.get_client_activity = client.get_client_activity, audit = audit, audit.entity_render_config = audit.entity_render_config (migration);
-- pg_temp equivalents in the rolled-back test copy.
CREATE OR REPLACE FUNCTION client.get_client_activity(p_client_id bigint, p_include_system boolean DEFAULT false, p_limit integer DEFAULT NULL, p_cursor jsonb DEFAULT NULL)
 RETURNS TABLE(key text, at timestamptz, area text, area_label text, subject text, title text, actor_label text, actor_kind text,
               is_system boolean, changes jsonb, status_card jsonb, cadence_card jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_cid   text := p_client_id::text;
  v_inc   boolean := coalesce(p_include_system, false);
begin
  if v_uid is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_client_activity';
  end if;
  if v_email not like '%@ayache.com' and v_email not like '%@unclogme.com' then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_client_activity';
  end if;
  if p_client_id is null then
    raise exception 'No client was chosen. Go back to the list and pick one.' using errcode = '22023',
      detail = 'blocker=no_client in client.get_client_activity';
  end if;

  return query
  with
  -- every job the client has or had, so line items of a deleted or moved job still count
  job_ids as (
    select j.id::text as id from public.jobs j where j.client_id = p_client_id
    union
    select l.record_pk ->> 'id' from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'jobs'
       and (l.new_row ->> 'client_id' = v_cid or l.old_row ->> 'client_id' = v_cid)
  ),
  cfg as (
    select c.table_name, c.column_name,
           -- the Calendar's clients labels stay as they are for get_record_history; this reader says it in full
           case when c.table_name = 'clients' and c.column_name = 'client_code' then 'Client code' else c.label end,
           c.render_type, c.fk_table, c.fk_label_col, c.sort_order, c.is_system
      from audit.entity_render_config c
     where c.table_name in ('clients','properties','jobs','gdos','client_contacts','client_jobber_contacts',
                            'client_locations','invoices','line_items')
    union all
    -- rendered by the function, never a config row: get_record_history('clients') renders every clients row
    select 'clients', 'primary_contact_ref', 'Primary contact', 'contact_ref', null, null, 70, false
  ),
  -- 1. the audit rows of this client. An explicit table list: never "every row with a client_id".
  --    Every arm stays on this client's rows; nothing below joins back to all of audit.logs.
  raw as (
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'clients' and l.record_pk ->> 'id' = v_cid
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public'
       and l.table_name in ('properties','jobs','gdos','client_contacts','client_jobber_contacts','client_locations',
                            'client_communication_prefs','invoices')
       and (l.new_row ->> 'client_id' = v_cid or l.old_row ->> 'client_id' = v_cid)
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name in ('client_status_changes','job_frequency_changes')
       and l.operation = 'INSERT' and l.new_row ->> 'client_id' = v_cid
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'line_items'
       and coalesce(l.new_row, l.old_row) ->> 'job_id' in (select ji.id from job_ids ji)
       and coalesce(l.new_row, l.old_row) ->> 'visit_id' is null
       and coalesce(l.new_row, l.old_row) ->> 'invoice_id' is null
    union all
    select l.id, l.table_name, l.operation, l.old_row, l.new_row, l.changed_at, l.txid, l.app_source, l.request_context, l.jwt_claims
      from audit.logs l
     where l.table_schema = 'public' and l.table_name = 'property_intake_accepts' and l.operation = 'INSERT'
       and l.new_row ->> 'property_id' in (select pr.id::text from public.properties pr where pr.client_id = p_client_id)
  ),
  -- the Client App creation ledger (not audited): matched by client_id, or by the Jobber gid when client_id is empty
  creation as (
    select a.requested_by from public.client_create_attempts a
     where a.status = 'created'
       and (a.client_id = p_client_id
            or (a.client_id is null and exists (
                  select 1 from public.entity_source_links e
                   where e.entity_type = 'client' and e.source_system = 'jobber'
                     and e.entity_id = p_client_id and e.source_id = a.jobber_client_gid)))
     order by a.created_at limit 1
  ),
  src as (
    select r.id, r.table_name as tbl, r.operation as op, r.old_row as o, r.new_row as n,
           coalesce(r.new_row, r.old_row) as rec, r.changed_at as at, coalesce(r.txid, -r.id) as tx,
           coalesce(r.app_source, '') as app, r.request_context ->> 'path' as path,
           -- who: the JWT email; the intent row's email; actor_name only behind service_role (a free header otherwise);
           -- the creation ledger's requester for the client INSERT
           coalesce(
             nullif(btrim(r.jwt_claims ->> 'email'), ''),
             case when r.table_name in ('client_status_changes','job_frequency_changes') then nullif(btrim(r.new_row ->> 'changed_by_email'), '')
                  when r.table_name = 'property_intake_accepts' then nullif(btrim(r.new_row ->> 'actor'), '') end,
             case when r.jwt_claims ->> 'role' = 'service_role' and coalesce(r.app_source, '') <> 'jobber'
                  then nullif(btrim(r.request_context ->> 'actor_name'), '') end,
             case when r.table_name = 'clients' and r.operation = 'INSERT' then (select cr.requested_by from creation cr) end
           ) as person,
           case when r.app_source = 'jobber' then nullif(btrim(r.request_context ->> 'actor_name'), '') end as jobber_name,
           coalesce(r.app_source, '') in ('jobber','jobber-custom-field-sync') as is_jobber,
           coalesce(r.app_source, '') ~ '(backfill|import|probe|migration|revert|uitest|smoke)' as is_script,
           (coalesce(r.app_source, '') in ('','sql') and r.request_context ->> 'path' is null) as is_direct_sql
      from raw r
  ),
  -- 2. replace-style saves cancel (rule 3.3.1): a DELETE and an INSERT of equal rows, minus id / created_at /
  --    updated_at (and total_price on line items), paired one to one inside a transaction
  di as (
    select s.id, s.tbl, s.op, s.tx, s.at, s.person, s.rec ->> 'job_id' as job_key,
           s.rec - array['id','created_at','updated_at','total_price']::text[] as body
      from src s
     where s.op in ('INSERT','DELETE')
       and s.tbl in ('properties','jobs','gdos','client_contacts','client_jobber_contacts','client_locations',
                     'client_communication_prefs','line_items','invoices')
  ),
  di_rank as (
    select d.*, row_number() over (partition by d.tbl, d.tx, md5(d.body::text), d.op order by d.id) as rn from di d
  ),
  cancelled as (
    select a.id from di_rank a
      join di_rank b on b.tbl = a.tbl and b.tx = a.tx and b.body = a.body and b.op <> a.op and b.rn = a.rn
    union
    -- line items also cancel across transactions: the Jobber sync rewrites them in separate requests
    select a.id from di a
      join di b on a.tbl = 'line_items' and b.tbl = 'line_items' and b.job_key = a.job_key and b.body = a.body
             and b.op <> a.op and b.tx <> a.tx and a.person is null and b.person is null
             and b.at between a.at - interval '2 minutes' and a.at + interval '2 minutes'
  ),
  -- what is left of a line-item replace that DID change something pairs up into one "changed" row
  li_left as (
    select d.*, row_number() over (partition by d.tx, d.job_key, d.body ->> 'name', d.op order by d.id) as rn
      from di d where d.tbl = 'line_items' and d.id not in (select c.id from cancelled c)
  ),
  li_pairs as (
    select del.id as del_id, ins.id as ins_id
      from li_left del
      join li_left ins on del.op = 'DELETE' and ins.op = 'INSERT' and ins.tx = del.tx and ins.job_key = del.job_key
                      and ins.body ->> 'name' = del.body ->> 'name' and ins.rn = del.rn
  ),
  members as (
    select s.id, s.tbl,
           case when lp.ins_id is not null then 'UPDATE' else s.op end as op,
           case when lp.ins_id is not null then dd.rec else s.o end as o,
           s.n, s.rec, s.at, s.tx, s.app, s.path, s.person, s.jobber_name, s.is_jobber, s.is_script, s.is_direct_sql,
           (s.tbl = 'invoices' and s.op = 'UPDATE' and s.o ->> 'client_id' is null and s.n ->> 'client_id' is not null) as is_inv_created
      from src s
      left join li_pairs lp on lp.ins_id = s.id
      left join src dd on dd.id = lp.del_id
     where s.id not in (select c.id from cancelled c)
       and s.id not in (select lp2.del_id from li_pairs lp2)
  ),
  -- a person-less writer that touched 20 or more clients in the hour around this row is bookkeeping
  burst as (
    select m.id from members m
     where m.person is null and m.op <> 'DELETE' and not m.is_script and not m.is_direct_sql
       and m.tbl not in ('client_status_changes','job_frequency_changes','property_intake_accepts')
       and (select count(distinct case l.table_name
                                    when 'clients' then l.record_pk ->> 'id'
                                    when 'line_items' then (select jj.client_id::text from public.jobs jj
                                                             where jj.id = (coalesce(l.new_row, l.old_row) ->> 'job_id')::bigint)
                                    else coalesce(l.new_row, l.old_row) ->> 'client_id' end)
              from audit.logs l
             where l.table_name = m.tbl
               and l.changed_at between m.at - interval '30 minutes' and m.at + interval '30 minutes'
               and coalesce(l.app_source, '') = m.app
               and coalesce(l.request_context ->> 'path', '') = coalesce(m.path, '')) >= 20
  ),
  -- 3. field changes of UPDATE rows (composites compare all their columns)
  upd as (
    select m.id as mid, f.column_name as col, f.label, f.render_type, f.fk_table, f.fk_label_col, f.sort_order,
           coalesce(f.is_system, false) as cfg_sys,
           case f.render_type
             when 'address'  then jsonb_build_array(m.o -> 'address', m.o -> 'city', m.o -> 'zip')
             when 'pin'      then jsonb_build_array(m.o -> 'latitude', m.o -> 'longitude')
             when 'geofence' then jsonb_build_array(m.o -> 'geofence_type', m.o -> 'geofence_radius_meters')
             when 'role'     then jsonb_build_array(m.o -> 'person_role', m.o -> 'person_role_other')
             else m.o -> f.column_name end as ov,
           case f.render_type
             when 'address'  then jsonb_build_array(m.n -> 'address', m.n -> 'city', m.n -> 'zip')
             when 'pin'      then jsonb_build_array(m.n -> 'latitude', m.n -> 'longitude')
             when 'geofence' then jsonb_build_array(m.n -> 'geofence_type', m.n -> 'geofence_radius_meters')
             when 'role'     then jsonb_build_array(m.n -> 'person_role', m.n -> 'person_role_other')
             else m.n -> f.column_name end as nv
      from members m join cfg f on f.table_name = m.tbl
     where m.op = 'UPDATE'
  ),
  ch0 as (
    select u.*, m.tbl, m.at, m.person, m.rec
      from upd u join members m on m.id = u.mid
     where audit.fn_activity_norm(u.ov) is distinct from audit.fn_activity_norm(u.nv)
       -- the status card carries the same move with its reason and person
       and not (m.tbl = 'clients' and u.col = 'status' and exists (
             select 1 from public.client_status_changes c
              where c.client_id = p_client_id and c.changed_at between m.at - interval '10 seconds' and m.at + interval '10 seconds'))
       -- the cadence card carries the same change (the client.job_activity rule)
       and not (m.tbl = 'jobs' and u.col = 'frequency_days' and exists (
             select 1 from public.job_frequency_changes f
              where f.job_id = (m.rec ->> 'id')::bigint and f.changed_at between m.at - interval '10 seconds' and m.at + interval '10 seconds'))
  ),
  -- 4. job status chains (rule 3.3.4): person-less legs on one job, each within 2 minutes of the last, become
  --    one net change on the first leg; a chain that ends where it began disappears
  js as (
    select c.mid, c.at, c.rec ->> 'id' as job_id, c.ov, c.nv,
           case when lag(c.at) over w is null or c.at - lag(c.at) over w > interval '2 minutes' then 1 else 0 end as brk
      from ch0 c where c.tbl = 'jobs' and c.col = 'job_status' and c.person is null
    window w as (partition by c.rec ->> 'id' order by c.at, c.mid)
  ),
  js2 as (select js.*, sum(js.brk) over (partition by js.job_id order by js.at, js.mid) as chain from js),
  js3 as (
    select js2.mid, js2.job_id, js2.chain,
           first_value(js2.ov) over cw as chain_ov, last_value(js2.nv) over cw as chain_nv,
           row_number() over (partition by js2.job_id, js2.chain order by js2.at, js2.mid) as leg
      from js2
    window cw as (partition by js2.job_id, js2.chain order by js2.at, js2.mid rows between unbounded preceding and unbounded following)
  ),
  ch as (
    select c.mid, c.col, c.label, c.render_type, c.fk_table, c.fk_label_col, c.sort_order, c.cfg_sys,
           coalesce(j.chain_ov, c.ov) as ov, coalesce(j.chain_nv, c.nv) as nv
      from ch0 c
      left join js3 j on j.mid = c.mid and c.col = 'job_status' and c.tbl = 'jobs'
     where j.mid is null
        or (j.leg = 1 and audit.fn_activity_norm(j.chain_ov) is distinct from audit.fn_activity_norm(j.chain_nv))
  ),
  -- 5. each change rendered, and whether it is bookkeeping (rule 3.4)
  crow as (
    select c.mid, c.col, c.label, c.sort_order, c.render_type,
           audit.fn_activity_value(c.ov, c.render_type, c.fk_table, c.fk_label_col) as old_txt,
           audit.fn_activity_value(c.nv, c.render_type, c.fk_table, c.fk_label_col) as new_txt,
           c.col in ('notes','access_notes') as long,
           c.ov #>> '{}' as ov_s, c.nv #>> '{}' as nv_s,
           case
             when m.person is not null then false
             -- never background: key moves of a job, invoice key events, the creation of an invoice
             when m.tbl = 'jobs' and c.col = 'job_status'
                  and (coalesce(c.ov #>> '{}', '') in ('archived','closed','destroyed','active')
                       or coalesce(c.nv #>> '{}', '') in ('archived','closed','destroyed','active')) then false
             when m.tbl = 'invoices' and c.col = 'invoice_status'
                  and (c.nv #>> '{}' in ('paid','voided','bad_debt','destroyed')
                       or (c.nv #>> '{}' = 'awaiting_payment' and coalesce(c.ov #>> '{}', 'draft') = 'draft')) then false
             when m.is_inv_created and c.col in ('invoice_status','total') then false
             when m.is_script or m.is_direct_sql or m.id in (select b.id from burst b) then true
             when c.cfg_sys then true
             when m.tbl = 'jobs' and c.col = 'job_status'
                  and c.ov #>> '{}' in ('upcoming','today','late','action_required','requires_invoicing')
                  and c.nv #>> '{}' in ('upcoming','today','late','action_required','requires_invoicing') then true
             when m.tbl = 'invoices' and c.col = 'invoice_status' then true
             when m.tbl = 'invoices' and m.o ->> 'invoice_status' = 'draft' and m.n ->> 'invoice_status' = 'draft' then true
             else false
           end as sys
      from ch c join members m on m.id = c.mid
     where c.render_type <> 'removed'
  ),
  rem as (
    select c.mid, audit.fn_activity_norm(c.nv) is not null as removed_now from ch c where c.render_type = 'removed'
  ),
  cagg as (
    select c.mid, count(*) as n_ch,
           (array_agg(c.label order by c.sort_order))[1] as first_label,
           (array_agg(c.long order by c.sort_order))[1] as first_long,
           (array_agg(c.old_txt is null order by c.sort_order))[1] as first_old_empty,
           (array_agg(c.render_type order by c.sort_order))[1] as first_type,
           (array_agg(c.col order by c.sort_order))[1] as first_col,
           max(c.nv_s) filter (where c.col = 'job_status') as js_new,
           max(c.ov_s) filter (where c.col = 'job_status') as js_old,
           bool_and(c.sys) as all_sys
      from crow c group by c.mid
  ),
  pia as (
    select m.id, m.at, m.tx, m.n ->> 'property_id' as property_id, (m.n ->> 'intake_id')::bigint as intake_id
      from members m where m.tbl = 'property_intake_accepts'
  ),
  -- 6. one row per kept record change: area, subject, title, bookkeeping flag
  mrow as (
    select m.id as mid, m.tbl, m.op, m.at, m.tx, m.app, m.person, m.jobber_name, m.is_jobber,
           case when m.tbl in ('clients','client_status_changes') then 'client'
                when m.tbl = 'properties' then 'property'
                when m.tbl in ('jobs','line_items','job_frequency_changes') then 'job'
                when m.tbl = 'gdos' then 'gdo'
                when m.tbl = 'invoices' then 'invoice'
                else 'contacts' end as area,
           case m.tbl when 'client_status_changes' then 1 when 'jobs' then 2 when 'line_items' then 2
                      when 'job_frequency_changes' then 2 when 'properties' then 3 when 'client_contacts' then 4
                      when 'client_jobber_contacts' then 4 when 'client_communication_prefs' then 4
                      when 'client_locations' then 4 when 'gdos' then 5 when 'invoices' then 6 else 7 end as rank,
           case when m.tbl = 'client_communication_prefs'
                then 'contact:' || coalesce(m.rec ->> 'contact_id', 'j' || (m.rec ->> 'jobber_contact_id'), m.id::text)
                else m.tbl || ':' || coalesce(case when m.tbl = 'line_items' then m.rec ->> 'job_id' else m.rec ->> 'id' end, m.id::text)
           end as rec_key,
           case
             when m.tbl = 'clients' then null
             when m.tbl = 'client_status_changes' then null
             when m.tbl = 'properties' then coalesce(nullif(btrim(m.rec ->> 'address'), ''), nullif(btrim(m.rec ->> 'name'), ''), 'Property #' || (m.rec ->> 'id'))
                                            || coalesce(' (' || nullif(btrim(m.rec ->> 'name'), '') || ')', '')
             when m.tbl = 'jobs' then '#' || coalesce(m.rec ->> 'job_number', m.rec ->> 'id') || coalesce(' ' || nullif(btrim(m.rec ->> 'title'), ''), '')
             when m.tbl in ('line_items','job_frequency_changes') then (
                    select '#' || coalesce(jj.job_number, jj.id::text) || coalesce(' ' || nullif(btrim(jj.title), ''), '')
                      from public.jobs jj where jj.id = (m.rec ->> 'job_id')::bigint)
             when m.tbl = 'gdos' then coalesce(nullif(btrim(m.rec ->> 'gdo_number'), ''), 'GDO permit #' || (m.rec ->> 'id'))
             when m.tbl = 'invoices' then 'Invoice #' || coalesce(m.rec ->> 'invoice_number', m.rec ->> 'id')
             when m.tbl in ('client_contacts','client_jobber_contacts') then coalesce(nullif(btrim(m.rec ->> 'name'), ''), m.rec ->> 'email', 'Contact #' || (m.rec ->> 'id'))
             when m.tbl = 'client_locations' then coalesce(nullif(btrim(m.rec ->> 'name'), ''), 'Location #' || (m.rec ->> 'id'))
             when m.tbl = 'client_communication_prefs' then coalesce(
                    (select coalesce(nullif(btrim(cc.name), ''), cc.email) from public.client_contacts cc where cc.id = (m.rec ->> 'contact_id')::bigint),
                    (select coalesce(nullif(btrim(jc.name), ''), jc.email) from public.client_jobber_contacts jc where jc.id = (m.rec ->> 'jobber_contact_id')::bigint),
                    'A contact no longer on file')
           end as subject,
           case
             when m.tbl = 'client_status_changes' then
               case m.n ->> 'event' when 'archived' then 'Client archived' when 'archived_here_only' then 'Client archived here only'
                                    when 'deleted_in_jobber' then 'Client deleted in Jobber' else 'Status changed' end
             when m.tbl = 'job_frequency_changes' then 'Frequency changed'
             when m.tbl = 'client_communication_prefs' then 'Who receives what changed'
             when m.op = 'INSERT' then
               case m.tbl when 'clients' then 'Client created' when 'properties' then 'Property added' when 'jobs' then 'Job added'
                          when 'gdos' then 'GDO permit added' when 'client_locations' then 'Location added'
                          when 'line_items' then 'Line item added' when 'invoices' then 'Invoice created' else 'Contact added' end
             when m.op = 'DELETE' then
               case m.tbl when 'clients' then 'Client removed' when 'properties' then 'Property removed' when 'jobs' then 'Job removed'
                          when 'gdos' then 'GDO permit removed' when 'client_locations' then 'Location removed'
                          when 'line_items' then 'Line item removed' when 'invoices' then 'Invoice removed' else 'Contact removed' end
             when r.mid is not null then
               case m.tbl when 'properties' then 'Property' when 'client_jobber_contacts' then 'Contact' else 'Record' end
               || case when r.removed_now then ' removed' else ' restored' end
             when m.is_inv_created then 'Invoice created'
             when m.tbl = 'properties' and pa.intake_id is not null then 'Accepted from Site survey form #' || pa.intake_id
             when m.tbl = 'invoices' and a.js_new is null and (m.o ->> 'invoice_status') is distinct from (m.n ->> 'invoice_status') then
               case when m.n ->> 'invoice_status' = 'paid' then 'Invoice paid'
                    when m.n ->> 'invoice_status' = 'awaiting_payment' and coalesce(m.o ->> 'invoice_status', 'draft') = 'draft' then 'Invoice sent'
                    when m.n ->> 'invoice_status' = 'voided' then 'Invoice voided'
                    when m.n ->> 'invoice_status' = 'bad_debt' then 'Invoice marked bad debt'
                    when m.n ->> 'invoice_status' = 'destroyed' then 'Invoice deleted in Jobber'
                    else 'Invoice status changed' end
             when a.js_new is not null then
               case when a.js_new = 'archived' then 'Archived' when a.js_new = 'closed' then 'Closed'
                    when a.js_new = 'destroyed' then 'Deleted in Jobber'
                    when a.js_old in ('archived','closed','destroyed') then 'Reopened'
                    else 'Status changed' end
             when m.tbl = 'line_items' and m.op = 'UPDATE' then 'Line item changed'
             when a.n_ch = 1 and a.first_type = 'changed' then a.first_label || case when a.first_col = 'permit_document_path' then ' replaced' else ' changed' end
             when a.n_ch = 1 then a.first_label || case when a.first_long then ' edited' when a.first_old_empty then ' set' else ' changed' end
             else case m.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                             when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'invoices' then 'Invoice'
                             else 'Contact' end || ' details changed'
           end as title,
           -- bookkeeping at the record level
           case
             when m.tbl in ('client_status_changes','job_frequency_changes') then false
             when m.op = 'DELETE' then false
             when r.mid is not null then false
             when m.is_inv_created then false
             when m.op = 'INSERT' then
               case when m.tbl in ('clients','invoices') then false
                    when m.person is not null then false
                    when m.tbl = 'client_jobber_contacts' then true
                    when m.is_script or m.is_direct_sql or m.id in (select b.id from burst b) then true
                    else false end
             else coalesce(a.all_sys, true)
           end as member_sys,
           case when m.tbl = 'client_status_changes' then (
             select jsonb_build_object('id', sc.id, 'event', sc.event, 'old_status', sc.old_status, 'new_status', sc.new_status,
                                       'reason', sc.reason, 'visits_removed', sc.visits_removed, 'photo_count', sc.photo_count,
                                       'changed_by_label', case when sc.changed_by_email is null then 'Jobber'
                                                                when public.fn_page_staff_name(sc.changed_by_email) like '%@%' then 'Staff (no name on file)'
                                                                else public.fn_page_staff_name(sc.changed_by_email) end)
               from client.status_changes sc where sc.id = (m.n ->> 'id')::bigint) end as status_card,
           case when m.tbl = 'job_frequency_changes' then (
             select jsonb_build_object('id', fc.id, 'job_id', fc.job_id, 'old_frequency_days', fc.old_frequency_days,
                                       'new_frequency_days', fc.new_frequency_days, 'reason', fc.reason, 'proof_count', fc.proof_count,
                                       'changed_by_label', case when fc.changed_by_email is null then 'System'
                                                                when public.fn_page_staff_name(fc.changed_by_email) like '%@%' then 'Staff (no name on file)'
                                                                else public.fn_page_staff_name(fc.changed_by_email) end)
               from client.job_frequency_changes fc where fc.id = (m.n ->> 'id')::bigint) end as cadence_card,
           a.n_ch
      from members m
      left join cagg a on a.mid = m.id
      left join rem r on r.mid = m.id
      left join lateral (
        select p.intake_id from pia p
         where m.tbl = 'properties' and m.op = 'UPDATE' and p.property_id = m.rec ->> 'id'
           and (p.tx = m.tx or p.at between m.at - interval '10 seconds' and m.at + interval '10 seconds')
         order by p.id limit 1) pa on true
     where m.tbl <> 'property_intake_accepts'
       -- an UPDATE with nothing left to show is not an entry (a card, an insert, a delete or a removal always is)
       and (m.op <> 'UPDATE' or m.tbl in ('client_status_changes','job_frequency_changes')
            or coalesce(a.n_ch, 0) > 0 or r.mid is not null or m.is_inv_created)
  ),
  -- the card rows exist through their audit INSERT, so the live card must still be there
  mrow_live as (
    select * from mrow mr
     where not (mr.tbl = 'client_status_changes' and mr.status_card is null)
       and not (mr.tbl = 'job_frequency_changes' and mr.cadence_card is null)
  ),
  -- 7. the change lines: field changes, plus one summary line for an insert or a delete
  lines as (
    select c.mid, c.sort_order as ord, c.sys, c.label, mr.subject,
           jsonb_build_object('subject', mr.subject, 'label', c.label,
                              'old', case when c.render_type = 'changed' then null else coalesce(c.old_txt, 'Not set') end,
                              'new', case when c.render_type = 'changed' then null else coalesce(c.new_txt, 'Not set') end,
                              'is_system', c.sys, 'long', c.long) as line,
           c.old_txt, c.new_txt, mr.tbl, c.col
      from crow c join mrow_live mr on mr.mid = c.mid
     where mr.op = 'UPDATE'
    union all
    select mr.mid, 0, mr.member_sys,
           case when mr.tbl = 'client_communication_prefs' then case mr.op when 'INSERT' then 'Now receives' else 'No longer receives' end
                else case mr.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                                 when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'line_items' then 'Line item'
                                 when 'invoices' then 'Invoice' else 'Contact' end end,
           mr.subject,
           jsonb_build_object('subject', mr.subject,
             'label', case when mr.tbl = 'client_communication_prefs' then case mr.op when 'INSERT' then 'Now receives' else 'No longer receives' end
                           else case mr.tbl when 'clients' then 'Client' when 'properties' then 'Property' when 'jobs' then 'Job'
                                            when 'gdos' then 'GDO permit' when 'client_locations' then 'Location' when 'line_items' then 'Line item'
                                            when 'invoices' then 'Invoice' else 'Contact' end end,
             'old', case when mr.op = 'DELETE' then sm.summary end,
             'new', case when mr.op = 'INSERT' then sm.summary end,
             'is_system', mr.member_sys, 'long', false),
           null::text, null::text, mr.tbl, null::text
      from mrow_live mr
      join members m on m.id = mr.mid
      cross join lateral (
        select case mr.tbl
                 when 'clients' then concat_ws(' ', m.rec ->> 'client_code', m.rec ->> 'name')
                 when 'properties' then concat_ws(', ', nullif(btrim(m.rec ->> 'address'), ''), nullif(btrim(m.rec ->> 'city'), ''))
                 when 'jobs' then concat_ws(' ', '#' || (m.rec ->> 'job_number'), m.rec ->> 'title')
                 when 'gdos' then concat_ws(' ', m.rec ->> 'gdo_number', nullif(btrim(m.rec ->> 'location_label'), ''))
                 when 'client_locations' then m.rec ->> 'name'
                 when 'line_items' then concat(m.rec ->> 'name', ' (', coalesce(m.rec ->> 'quantity', '1'), ' x ',
                                               coalesce(audit.render_value(m.rec -> 'unit_price', 'money', null, null), '$0.00'), ')')
                 when 'client_communication_prefs' then
                   case m.rec ->> 'comm_type' when 'invoice' then 'Invoices' when 'quote_approval' then 'Quote approvals'
                                              when 'service_report' then 'Service reports' when 'city_report' then 'City reports'
                                              else m.rec ->> 'comm_type' end
                   || coalesce(' (' || (select coalesce(nullif(btrim(pp.address), ''), pp.name) from public.properties pp
                                         where pp.id = (m.rec ->> 'property_id')::bigint) || ')', '')
                 when 'invoices' then concat_ws(' ', 'Invoice #' || (m.rec ->> 'invoice_number'))
                 else concat_ws(' · ', nullif(btrim(m.rec ->> 'name'), ''), nullif(btrim(m.rec ->> 'email'), ''), nullif(btrim(m.rec ->> 'phone'), ''))
               end as summary) sm
     where mr.op in ('INSERT','DELETE')
       -- a status or cadence card is the whole entry: no summary line under it
       and mr.tbl not in ('client_status_changes','job_frequency_changes')
  ),
  -- 8. one save is one entry (rule 3.3.2): a transaction is a group; groups of the same writer starting within
  --    5 s of each other chain; two groups naming different people never chain
  g as (
    select mr.tx, min(mr.at) as start, min(mr.app) as app,
           (array_agg(mr.person order by mr.at, mr.mid) filter (where mr.person is not null))[1] as person,
           min(mr.mid) as first_mid
      from mrow_live mr group by mr.tx
  ),
  g1 as (
    select g.*, lag(g.start) over o as prev_start, lag(g.app) over o as prev_app
      from g window o as (order by g.start, g.first_mid)
  ),
  g2 as (
    select g1.*, sum(case when g1.prev_start is null or g1.app <> g1.prev_app or g1.start - g1.prev_start > interval '5 seconds'
                          then 1 else 0 end) over (order by g1.start, g1.first_mid) as tchain
      from g1
  ),
  g3 as (
    select g2.*, array_remove(array_agg(g2.person) over (partition by g2.tchain order by g2.start, g2.first_mid
                                                         rows between unbounded preceding and 1 preceding), null) as prev_persons
      from g2
  ),
  g4 as (
    select g3.tx, g3.tchain, g3.person,
           sum(case when g3.person is not null and g3.prev_persons is not null and cardinality(g3.prev_persons) > 0
                         and g3.prev_persons[cardinality(g3.prev_persons)] <> g3.person then 1 else 0 end)
             over (partition by g3.tchain order by g3.start, g3.first_mid) as sub
      from g3
  ),
  ent_of as (select g4.tx, g4.tchain || '.' || g4.sub as eid from g4),
  -- the same zone move on several properties of one entry reads "on N sites" (rule 3.3.5)
  lines_e as (
    select e.eid, l.*,
           count(*) over (partition by e.eid, l.tbl, l.col, l.old_txt, l.new_txt) as same_n,
           row_number() over (partition by e.eid, l.tbl, l.col, l.old_txt, l.new_txt order by l.mid) as same_rn
      from lines l join mrow_live mr on mr.mid = l.mid join ent_of e on e.tx = mr.tx
  ),
  lines_z as (
    select le.eid, le.mid, le.ord, le.sys,
           case when le.tbl = 'properties' and le.col = 'zone_id' and le.same_n > 1
                then jsonb_set(jsonb_set(le.line, '{new}', to_jsonb(coalesce(le.new_txt, 'Not set') || ' on ' || le.same_n || ' sites')),
                               '{subject}', 'null'::jsonb)
                else le.line end as line
      from lines_e le
     where not (le.tbl = 'properties' and le.col = 'zone_id' and le.same_n > 1 and le.same_rn > 1)
  ),
  ent as (
    select e.eid,
           min(mr.at) as at,
           (array_agg(case when mr.tbl = 'client_status_changes' then 'csc:' || (mr.status_card ->> 'id')
                           when mr.tbl = 'job_frequency_changes' then 'jfc:' || (mr.cadence_card ->> 'id')
                           else 'a:' || mr.mid end order by mr.at, mr.mid))[1] as key,
           (array_agg(mr.area order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as area,
           (array_agg(mr.subject order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as subject1,
           (array_agg(mr.title order by mr.member_sys, mr.rank, mr.at, mr.mid))[1] as title,
           count(distinct mr.rec_key) filter (where v_inc or not mr.member_sys) as n_records,
           (array_agg(mr.person order by mr.at, mr.mid) filter (where mr.person is not null))[1] as person,
           bool_or(mr.is_jobber) as any_jobber,
           max(mr.jobber_name) as jobber_name,
           (array_agg(mr.app order by mr.at, mr.mid) filter (where mr.app in ('client-app','picture-planner')))[1] as app_nobody,
           bool_and(mr.member_sys) as is_system,
           (array_agg(mr.status_card order by mr.at, mr.mid) filter (where mr.status_card is not null))[1] as status_card,
           (array_agg(mr.cadence_card order by mr.at, mr.mid) filter (where mr.cadence_card is not null))[1] as cadence_card
      from mrow_live mr join ent_of e on e.tx = mr.tx
     group by e.eid
  ),
  ent_lines as (
    select lz.eid, jsonb_agg(lz.line order by mr.member_sys, mr.rank, mr.at, lz.mid, lz.ord) as changes
      from lines_z lz join mrow_live mr on mr.mid = lz.mid
     where v_inc or not lz.sys
     group by lz.eid
  ),
  audit_entries as (
    select en.key, en.at, en.area,
           en.subject1 || case when en.n_records > 1 then ' and ' || (en.n_records - 1) || ' more' else '' end as subject,
           en.title,
           case when en.person is not null then
                  case when public.fn_page_staff_name(en.person) like '%@%' then 'Staff (no name on file)' else public.fn_page_staff_name(en.person) end
                when en.any_jobber then 'Jobber' || coalesce(' · ' || en.jobber_name, '')
                when en.app_nobody = 'client-app' then 'Client App (person not recorded)'
                when en.app_nobody = 'picture-planner' then 'Picture Planner (person not recorded)'
                else 'System' end as actor_label,
           case when en.person is not null then 'person' when en.any_jobber then 'jobber'
                when en.app_nobody is not null then 'app' else 'system' end as actor_kind,
           en.is_system, coalesce(el.changes, '[]'::jsonb) as changes, en.status_card, en.cadence_card
      from ent en left join ent_lines el on el.eid = en.eid
  ),
  -- 9. property events (forms, site file) from the property reader; an accepted answer is already the property diff
  prop_events as (
    select 'pe:' || pr.id || ':' || (ev ->> 'kind') || ':' || coalesce(ev ->> 'intake_id', ev ->> 'version', '') || ':' || (ev ->> 'at') as key,
           (ev ->> 'at')::timestamptz as at, 'property' as area,
           coalesce(nullif(btrim(pr.address), ''), nullif(btrim(pr.name), ''), 'Property #' || pr.id) as subject,
           case ev ->> 'kind'
             when 'form_requested' then 'Site survey form #' || (ev ->> 'intake_id') || ' requested'
             when 'form_link_shown' then 'Link to site survey form #' || (ev ->> 'intake_id') || ' shown'
             when 'form_filled' then 'Site survey form #' || (ev ->> 'intake_id') || ' filled in'
             when 'form_cancelled' then 'Site survey form #' || (ev ->> 'intake_id') || ' cancelled'
             when 'page_submitted' then 'Version ' || (ev ->> 'version') || ' of the site file submitted for approval'
             when 'page_approved' then 'Version ' || (ev ->> 'version') || ' of the site file approved'
             when 'driver_link_created' then 'Site file link created'
             when 'driver_link_replaced' then 'Site file link replaced'
             else ev ->> 'text' end as title,
           case when ev ->> 'kind' = 'form_filled' then coalesce(nullif(btrim(ev ->> 'who'), ''), 'Someone') || ' (name typed on the form)'
                when nullif(btrim(ev ->> 'who'), '') is null then 'System'
                when ev ->> 'who' like '%@%' then 'Staff (no name on file)'
                else ev ->> 'who' end as actor_label,
           case when ev ->> 'kind' = 'form_filled' then 'form'
                when nullif(btrim(ev ->> 'who'), '') is null then 'system' else 'person' end as actor_kind,
           (ev ->> 'kind') = 'form_link_shown' as is_system,
           '[]'::jsonb as changes, null::jsonb as status_card, null::jsonb as cadence_card
      from public.properties pr
      cross join lateral jsonb_array_elements(client.get_property_activity(pr.id)) ev
     where pr.client_id = p_client_id and ev ->> 'kind' <> 'intake_accepted'
  ),
  -- 10. notes not tied to a visit (Jobber), at their own date
  note_entries as (
    select 'note:' || nt.id as key, coalesce(nt.note_date, nt.created_at) as at, 'note' as area, null::text as subject,
           'Note added' as title, 'Jobber' || coalesce(' · ' || nullif(btrim(nt.author_name), ''), '') as actor_label,
           'jobber' as actor_kind, false as is_system,
           case when nullif(btrim(nt.body), '') is null then '[]'::jsonb
                -- a note is new text, never "edited": long stays false and the app wraps it
                else jsonb_build_array(jsonb_build_object('subject', null, 'label', 'Note', 'old', null, 'new', nt.body,
                                                          'is_system', false, 'long', false)) end as changes,
           null::jsonb as status_card, null::jsonb as cadence_card
      from public.notes nt
     where nt.client_id = p_client_id and nt.visit_id is null
  ),
  all_entries as (
    select ae.key, ae.at, ae.area, ae.subject, ae.title, ae.actor_label, ae.actor_kind, ae.is_system, ae.changes, ae.status_card, ae.cadence_card
      from audit_entries ae
    union all
    select pe.key, pe.at, pe.area, pe.subject, pe.title, pe.actor_label, pe.actor_kind, pe.is_system, pe.changes, pe.status_card, pe.cadence_card
      from prop_events pe
    union all
    select ne.key, ne.at, ne.area, ne.subject, ne.title, ne.actor_label, ne.actor_kind, ne.is_system, ne.changes, ne.status_card, ne.cadence_card
      from note_entries ne
  )
  select x.key, x.at, x.area,
         case x.area when 'client' then 'Client' when 'property' then 'Property' when 'job' then 'Job' when 'contacts' then 'Contacts'
                     when 'gdo' then 'GDO permit' when 'invoice' then 'Invoice' when 'note' then 'Note' else initcap(x.area) end,
         x.subject, x.title, x.actor_label, x.actor_kind, x.is_system, x.changes, x.status_card, x.cadence_card
    from all_entries x
   where (v_inc or not x.is_system)
     and (p_cursor is null or (x.at, x.key) < ((p_cursor ->> 'at')::timestamptz, p_cursor ->> 'key'))
   order by x.at desc, x.key desc
   limit p_limit;
end $function$;

DO $verify$
BEGIN
  IF NOT has_function_privilege('authenticated', 'client.get_client_activity(bigint,boolean,integer,jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'authenticated lost EXECUTE'; END IF;
  IF has_function_privilege('anon', 'client.get_client_activity(bigint,boolean,integer,jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'anon can execute'; END IF;
  IF has_function_privilege('service_role', 'client.get_client_activity(bigint,boolean,integer,jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'service_role can execute'; END IF;
  IF position('no summary line under it' in pg_get_functiondef('client.get_client_activity(bigint,boolean,integer,jsonb)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'the new body did not land';
  END IF;
END $verify$;
NOTIFY pgrst, 'reload schema';
COMMIT;
