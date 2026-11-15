-- 2026-11-14_2140_derm_manifest_archive_restore.sql
--
-- WHAT
-- ----
-- "Archive manifest" with a reason, and Restore, for the Ops Portal's Manifests list (Stage C, step 2).
--   1. public.derm_manifests + archive_reason (CHECK: test_data | duplicate | not_ours | other, the Monthly page's four),
--      archive_note (the real ticket's number for a duplicate, the words for "other"), archived_by (the signed-in email).
--      Nullable, no default: a catalog-only change. Read only by the two functions below and the reader.
--   2. public.derm_archive_manifests(p_manifest_ids bigint[], p_reason text, p_note text DEFAULT NULL) RETURNS integer:
--      the SAME soft delete as public.derm_delete_manifests (deleted_at = now(), nothing removed, every table trigger
--      fires exactly as for a delete) with the same three checks word for word (signed in, staff, DERM Tracker Edit),
--      plus the reason. Rows already archived are left alone.
--   3. public.derm_restore_manifests(p_manifest_ids bigint[]) RETURNS integer: clears deleted_at and the three archive
--      columns of archived rows, the same three checks. The table's own triggers put the stamp cards back
--      (derm.fn_resolve_card_manifest fires on deleted_at). The per-visit forms that the archive retired come back with
--      their row (derm.fn_retire_visit_sheets stamped them with the row's own deleted_at), unless their visit was
--      unlinked since or their number was taken again. Refused, in plain words, when a visit of the row now sits on
--      another live ticket, when the client is already on the ticket again, or when the row no longer passes the table's
--      checks.
--   4. derm.archived_manifest_rows() RETURNS jsonb: the "Archived" list of the page. One element per archive, i.e. per
--      ticket and deleted_at (the rows archived together, as the old host's Delete also does): manifest_ids, number,
--      county, dump date, clients, live (rows of the ticket still live), at, reason, note, by (the person's name, never
--      an email). Gate: word for word derm.manifest_row_states() (DERM Tracker View, then the staff check). Read only.
--   5. derm.fn_dirty_on_card_change (trg_zz_dirty_on_card_change): one added test, before its UPDATE. A card whose ONLY
--      change is its manifest link, inside a statement of the two writers above (they set the transaction setting
--      derm.card_link_only = 'on' around their UPDATE and clear it after), no longer reopens its completed sheet.
--      Measured in the rehearsal before this part existed: archive + restore of test ticket #111111 left its completed
--      sheet REOPENED ("Stamps to place"), because the stamp card moves to no manifest and back. Nothing on the paper
--      moved, and a Restore must bring the ticket back as it was. Every other writer, the old host's Delete included,
--      never sets the setting, so it reopens exactly as before; a card whose stamp, band, page, client or permit also
--      changed reopens the sheet as before.
-- Grants by name: authenticated + service_role on the three functions, never PUBLIC or anon.
-- Audit (rule 8): public.derm_manifests is audited (audit_derm_manifests); the new columns are captured with the row.
--
-- "Every sheet has a row" (the plan's check): a ticket whose every row is archived takes its address sheet with it.
-- derm.v_stamp_sheets already hides the sheet of a ticket that has deleted rows and no live row (its last WHERE), so the
-- sheet leaves the sheet list and the check together, and comes back with Restore. No door is needed in the Archived list.
--
-- WHY
-- ---
-- Fred, 2026-11-12, "go ahead with all the recommendations" for the Manifests page, default 7 (`archive`):
-- "'Delete manifest' becomes 'Archive manifest', with a reason, and can be restored. Today it asks no reason and cannot
-- be undone on screen. The Monthly page already works this way. As today, nothing is really deleted."
-- (Building Apps/Ops Portal/docs/specs/2026-11-12-manifests-and-stamping-page-data.mjs, DEFAULTS.)
--
-- REACH
-- -----
-- Old DERM Tracker host: none. Its "Delete manifest" keeps calling public.derm_delete_manifests, unchanged (md5 pinned
-- below); a row it deletes has no reason and shows in the portal's Archived list as such, and can be restored there.
-- Nothing reads the new columns but this file's functions. 38 rows were soft-deleted before this (16 tickets, all since
-- 2026-06-29).
--
-- REHEARSED (rolled back) before applying: rows2/rehearse_m1.mjs in mockups/2026-11-14-stamping-build (results in the
-- commit message and the Ops Portal changelog). Rollback: 2026-11-14_rollback_derm_manifest_archive_restore.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'derm_manifests'
              AND column_name IN ('archive_reason', 'archive_note', 'archived_by'))
    THEN RAISE EXCEPTION 'GUARD: an archive column already exists on public.derm_manifests'; END IF;
  IF to_regprocedure('public.derm_archive_manifests(bigint[], text, text)') IS NOT NULL
     OR to_regprocedure('public.derm_restore_manifests(bigint[])') IS NOT NULL
     OR to_regprocedure('derm.archived_manifest_rows()') IS NOT NULL
    THEN RAISE EXCEPTION 'GUARD: an archive function already exists'; END IF;
  -- the checks copied into the two writers, and the old host's delete that must stay as it is
  IF md5(replace(pg_get_functiondef('public.derm_delete_manifests(bigint[])'::regprocedure), chr(13), '')) <> '80df507b5b7af25962cbcfff024856a3'
    THEN RAISE EXCEPTION 'GUARD: public.derm_delete_manifests changed since it was read'; END IF;
  -- the gate copied into the reader
  IF md5(replace(pg_get_functiondef('derm.manifest_row_states()'::regprocedure), chr(13), '')) <> 'ff7778cd3fb4ec915a6dd56ce2629a1c'
    THEN RAISE EXCEPTION 'GUARD: derm.manifest_row_states (the gate copied here) changed since it was read'; END IF;
  -- the body edited in part 5
  IF md5(replace(pg_get_functiondef('derm.fn_dirty_on_card_change()'::regprocedure), chr(13), '')) <> '5689022eea0d35122774914a1abc56de'
    THEN RAISE EXCEPTION 'GUARD: derm.fn_dirty_on_card_change changed since it was read'; END IF;
END $g$;

-- Part 5: the live body of derm.fn_dirty_on_card_change, copied, with ONE block added after its folder test.
CREATE OR REPLACE FUNCTION derm.fn_dirty_on_card_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_folder text;
BEGIN
  v_folder := COALESCE(NEW.dump_folder, OLD.dump_folder);
  IF v_folder IS NULL THEN RETURN NULL; END IF;
  -- 2026-11-14 (Ops Portal Stage C step 2): a card whose ONLY change is its manifest link, inside an Archive or a Restore
  -- (public.derm_archive_manifests / public.derm_restore_manifests set derm.card_link_only around their UPDATE), does
  -- not reopen the sheet: nothing on the paper moved. Every other writer reopens exactly as before.
  IF TG_OP = 'UPDATE' AND current_setting('derm.card_link_only', true) = 'on'
     AND (NEW.stamp_x_pct, NEW.stamp_y_pct, NEW.stamp_page, NEW.stamp_placed_at, NEW.band_y0_pct, NEW.band_y1_pct,
          NEW.matched_client_id, NEW.gdo_id)
         IS NOT DISTINCT FROM
         (OLD.stamp_x_pct, OLD.stamp_y_pct, OLD.stamp_page, OLD.stamp_placed_at, OLD.band_y0_pct, OLD.band_y1_pct,
          OLD.matched_client_id, OLD.gdo_id) THEN
    RETURN NULL;
  END IF;

  -- Clearing `completed` is enough: derm.fn_stamp_sheet_reopen_pin (trg_aa_reopen_pin) stamps
  -- reopened_at/by on the true->false flip, and that pin is what stops a machine re-completing it.
  UPDATE derm.stamp_sheet_status s
     SET completed = false, completed_at = NULL, completed_by = NULL, updated_at = now()
   WHERE s.dump_folder = v_folder AND s.completed;

  RETURN NULL;
END $function$;

ALTER TABLE public.derm_manifests
  ADD COLUMN archive_reason text,
  ADD COLUMN archive_note text,
  ADD COLUMN archived_by text;
ALTER TABLE public.derm_manifests ADD CONSTRAINT derm_manifests_archive_reason_chk
  CHECK (archive_reason IS NULL OR archive_reason IN ('test_data', 'duplicate', 'not_ours', 'other'));
COMMENT ON COLUMN public.derm_manifests.archive_reason IS 'Why the row was archived (2026-11-14): test_data | duplicate | not_ours | other. Written only by public.derm_archive_manifests, cleared by public.derm_restore_manifests. NULL on a row deleted by the old host''s Delete. Meaningful only while deleted_at is set.';
COMMENT ON COLUMN public.derm_manifests.archive_note IS 'With archive_reason: the real ticket''s number for a duplicate, the words for other (2026-11-14).';
COMMENT ON COLUMN public.derm_manifests.archived_by IS 'With archive_reason: the signed-in email of the person who archived it (2026-11-14). Never returned to an app: derm.archived_manifest_rows() gives the name.';

CREATE FUNCTION public.derm_archive_manifests(p_manifest_ids bigint[], p_reason text, p_note text DEFAULT NULL)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-14 (Ops Portal Stage C step 2, Fred's default 7 "archive"): the portal's "Archive manifest". The same soft
-- delete as public.derm_delete_manifests, with its checks word for word, plus a required reason (the Monthly page's
-- four). SECURITY DEFINER widens nothing: the delete it mirrors already runs this way. Every table trigger fires as for
-- a delete (the stamp cards move to a live sibling of the same client and ticket, or to none; per-visit forms retire).
declare
  v_n integer;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in public.derm_archive_manifests';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in public.derm_archive_manifests';
  end if;
  perform hr.fn_check_app('derm_tracker', 'edit', 'archive a manifest');
  if p_reason is null or p_reason not in ('test_data', 'duplicate', 'not_ours', 'other') then
    raise exception 'Pick a reason.' using errcode = '22023', detail = 'blocker=no_reason in public.derm_archive_manifests';
  end if;
  if p_reason = 'duplicate' and coalesce(v_note, '') !~ '^[0-9]{6}$' then
    raise exception 'Type the real ticket''s number (six digits).' using errcode = '22023', detail = 'blocker=no_real_ticket in public.derm_archive_manifests';
  end if;
  if p_reason = 'other' and v_note is null then
    raise exception 'Say why in a few words.' using errcode = '22023', detail = 'blocker=no_words in public.derm_archive_manifests';
  end if;
  if char_length(coalesce(v_note, '')) > 300 then
    raise exception 'Keep the reason under 300 characters.' using errcode = '22023', detail = 'blocker=too_long in public.derm_archive_manifests';
  end if;
  -- the stamp cards only lose their manifest link: their sheet is not reopened for it (derm.fn_dirty_on_card_change)
  perform set_config('derm.card_link_only', 'on', true);
  update public.derm_manifests
     set deleted_at = now(),
         archive_reason = p_reason,
         archive_note = v_note,
         archived_by = lower(nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), ''))
   where id = any (coalesce(p_manifest_ids, '{}'::bigint[]))
     and deleted_at is null;
  get diagnostics v_n = row_count;
  perform set_config('derm.card_link_only', '', true);
  return v_n;
end $function$;

CREATE FUNCTION public.derm_restore_manifests(p_manifest_ids bigint[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-14 (Ops Portal Stage C step 2, Fred's default 7 "archive"): Restore of an archived (or deleted) manifest row.
-- The same checks as public.derm_delete_manifests. Clearing deleted_at fires the table's own triggers, which put the
-- stamp cards back on the row (derm.fn_resolve_card_manifest). Refuses in plain words, naming a ticket only.
declare
  v_n integer := 0;
  v_clash text;
  v_con text;
  r record;
begin
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in public.derm_restore_manifests';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in public.derm_restore_manifests';
  end if;
  perform hr.fn_check_app('derm_tracker', 'edit', 'restore a manifest');

  -- A visit of an archived row that now sits on ANOTHER live ticket: bringing the row back would put the visit on two
  -- tickets (public.trg_ab_link_one_white guards a new link, not a restore).
  select coalesce(o.white_manifest_number, o.yellow_ticket_number) into v_clash
    from public.derm_manifests a
    join public.manifest_visits mv on mv.manifest_id = a.id
    join public.manifest_visits ov on ov.visit_id = mv.visit_id and ov.manifest_id <> a.id
    join public.derm_manifests o on o.id = ov.manifest_id and o.deleted_at is null
   where a.id = any (coalesce(p_manifest_ids, '{}'::bigint[]))
     and a.deleted_at is not null
     and coalesce(o.white_manifest_number, o.yellow_ticket_number) is distinct from coalesce(a.white_manifest_number, a.yellow_ticket_number)
   order by 1
   limit 1;
  if v_clash is not null then
    raise exception 'A visit of this manifest is now on #%. Unlink it there first, or leave this one archived.', v_clash
      using errcode = '22023', detail = 'blocker=visit_on_another_ticket in public.derm_restore_manifests';
  end if;

  for r in
    select dm.id, dm.deleted_at, coalesce(dm.white_manifest_number, dm.yellow_ticket_number) as num
      from public.derm_manifests dm
     where dm.id = any (coalesce(p_manifest_ids, '{}'::bigint[]))
       and dm.deleted_at is not null
     order by dm.id
       for update
  loop
    begin
      -- the stamp cards only regain their manifest link: their sheet is not reopened for it (derm.fn_dirty_on_card_change)
      perform set_config('derm.card_link_only', 'on', true);
      update public.derm_manifests
         set deleted_at = null, archive_reason = null, archive_note = null, archived_by = null
       where id = r.id;
    exception
      when unique_violation then
        raise exception 'This client is already on #% again, so the archived row cannot come back. Leave it archived.', r.num
          using errcode = '22023', detail = 'blocker=client_on_ticket_again in public.derm_restore_manifests';
      when check_violation then
        get stacked diagnostics v_con = constraint_name;
        if v_con = 'derm_manifests_dump_fields_present_chk' then
          raise exception 'This row of #% has no dump date or facility on file, so it cannot come back as it is.', r.num
            using errcode = '22023', detail = 'blocker=dump_fields_missing in public.derm_restore_manifests';
        end if;
        raise exception 'This row of #% no longer passes the manifest rules, so it cannot come back as it is.', r.num
          using errcode = '22023', detail = 'blocker=' || coalesce(v_con, 'check') || ' in public.derm_restore_manifests';
      when raise_exception then
        get stacked diagnostics v_con = message_text;
        -- public.fn_derm_ticket_key_unambiguous: the number is now another ticket's key
        if v_con like '%collides with an existing%' then
          raise exception 'The number #% now belongs to another ticket, so this row cannot come back.', r.num
            using errcode = '22023', detail = 'blocker=ticket_key_taken in public.derm_restore_manifests';
        end if;
        raise exception 'This row of #% no longer passes the manifest rules, so it cannot come back as it is.', r.num
          using errcode = '22023', detail = 'blocker=trigger_refused in public.derm_restore_manifests';
    end;
    perform set_config('derm.card_link_only', '', true);
    v_n := v_n + 1;
    -- The per-visit forms this archive retired (derm.fn_retire_visit_sheets set their deleted_at to the row's), while
    -- their visit is still linked and their number is free.
    update derm.manifest_visit_sheets s
       set deleted_at = null
     where s.manifest_id = r.id
       and s.deleted_at = r.deleted_at
       and exists (select 1 from public.manifest_visits mv where mv.manifest_id = s.manifest_id and mv.visit_id = s.visit_id)
       and (s.sheet_no is null
            or not exists (select 1 from derm.manifest_visit_sheets o where o.sheet_no = s.sheet_no and o.deleted_at is null));
  end loop;
  return v_n;
end $function$;

CREATE FUNCTION derm.archived_manifest_rows()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-14 (Ops Portal Stage C step 2): the Manifests page's "Archived" list, newest first. One element per archive
-- (a ticket and a deleted_at: the rows archived together). No email address is returned: "by" is the person's name.
-- The address sheet of a ticket with no live row left is hidden by derm.v_stamp_sheets itself, and comes back with
-- Restore, so the list carries no sheet.
declare
  v_out jsonb;
begin
  -- The gate, word for word the one of derm.manifest_row_states().
  perform hr.fn_require_app('derm_tracker', 'view');
  if nullif(current_setting('request.jwt.claims', true), '') is not null
     and coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    if auth.uid() is null then
      raise exception 'authentication required' using errcode = '28000';
    end if;
    if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
      raise exception 'not a staff account' using errcode = '42501';
    end if;
  end if;

  with a as (
    select dm.id,
           coalesce(dm.white_manifest_number, dm.yellow_ticket_number, '') as num,
           -- the list's own row key (derm.fn_manifest_row_states_core)
           case when coalesce(dm.white_manifest_number, dm.yellow_ticket_number, '') = '' then 'No number'
                when coalesce(dm.yellow_ticket_number, '') <> '' then 'Broward #' || coalesce(dm.white_manifest_number, dm.yellow_ticket_number)
                else 'Miami-Dade #' || coalesce(dm.white_manifest_number, dm.yellow_ticket_number) end as key,
           coalesce(dm.yellow_ticket_number, '') <> '' as is_yellow,
           coalesce(dm.dump_ticket_date, dm.service_date) as dump_date,
           dm.deleted_at, dm.archive_reason, dm.archive_note, dm.archived_by
      from public.derm_manifests dm
     where dm.deleted_at is not null
  ),
  live as (
    select coalesce(dm.white_manifest_number, dm.yellow_ticket_number, '') as num, count(*) as n
      from public.derm_manifests dm
     where dm.deleted_at is null
     group by 1
  ),
  ev as (
    select a.key, a.num, a.deleted_at as at,
           bool_or(a.is_yellow) as is_yellow,
           max(a.dump_date) as dump_date,
           array_agg(a.id order by a.id) as ids,
           count(*) as n,
           min(a.archive_reason) as reason,
           min(a.archive_note) as note,
           min(a.archived_by) as by_email
      from a
     group by a.key, a.num, a.deleted_at
  )
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'key', ev.key,
           'manifest_ids', to_jsonb(ev.ids),
           'number', nullif(ev.num, ''),
           'county', case when ev.is_yellow then 'broward' else 'dade' end,
           'dump_date', ev.dump_date,
           'clients', ev.n,
           'live', coalesce(l.n, 0),
           'at', ev.at,
           'reason', ev.reason,
           'note', ev.note,
           'by', (select e.full_name from public.employees e
                   where ev.by_email is not null and lower(btrim(e.email)) = ev.by_email
                   order by e.id limit 1)
         )) order by ev.at desc, ev.key)
    into v_out
    from ev
    left join live l on l.num = ev.num;

  return coalesce(v_out, '[]'::jsonb);
end
$function$;

REVOKE ALL ON FUNCTION public.derm_archive_manifests(bigint[], text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.derm_restore_manifests(bigint[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION derm.archived_manifest_rows() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.derm_archive_manifests(bigint[], text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.derm_restore_manifests(bigint[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION derm.archived_manifest_rows() TO authenticated, service_role;
COMMENT ON FUNCTION public.derm_archive_manifests(bigint[], text, text) IS 'Archive manifest rows with a reason (2026-11-14, Ops Portal Stage C step 2): the soft delete of derm_delete_manifests plus archive_reason / archive_note / archived_by. DERM Tracker Edit + staff.';
COMMENT ON FUNCTION public.derm_restore_manifests(bigint[]) IS 'Restore archived manifest rows (2026-11-14, Ops Portal Stage C step 2). DERM Tracker Edit + staff. Refuses in words on a visit now on another ticket, the client on the ticket again, or a row that fails the table checks.';
COMMENT ON FUNCTION derm.archived_manifest_rows() IS 'The Manifests page''s Archived list (2026-11-14): one element per archive, with the sheets of a ticket with no live row. DERM Tracker View + staff. No email returned.';

DO $v$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.derm_archive_manifests(bigint[], text, text)', 'public.derm_restore_manifests(bigint[])', 'derm.archived_manifest_rows()'] LOOP
    IF (SELECT array_agg(x ORDER BY x) FROM (SELECT coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') || ':' || a.privilege_type AS x
          FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a WHERE p.oid = f::regprocedure) acl)
       IS DISTINCT FROM ARRAY['authenticated:EXECUTE','postgres:EXECUTE','service_role:EXECUTE']
      THEN RAISE EXCEPTION 'VERIFY: % grants are not authenticated + service_role', f; END IF;
    IF NOT (SELECT prosecdef AND proconfig = array['search_path=""'] FROM pg_proc WHERE oid = f::regprocedure)
      THEN RAISE EXCEPTION 'VERIFY: % is not SECURITY DEFINER with an empty search_path', f; END IF;
  END LOOP;
  IF md5(replace(pg_get_functiondef('public.derm_delete_manifests(bigint[])'::regprocedure), chr(13), '')) <> '80df507b5b7af25962cbcfff024856a3'
    THEN RAISE EXCEPTION 'VERIFY: public.derm_delete_manifests moved'; END IF;
  IF EXISTS (SELECT 1 FROM public.derm_manifests WHERE archive_reason IS NOT NULL OR archive_note IS NOT NULL OR archived_by IS NOT NULL)
    THEN RAISE EXCEPTION 'VERIFY: an archive column holds a value right after it was added'; END IF;
  -- part 5 is the old body plus the one block, nothing else
  IF md5(regexp_replace(replace(pg_get_functiondef('derm.fn_dirty_on_card_change()'::regprocedure), chr(13), ''),
           '  -- 2026-11-14 \(Ops Portal Stage C step 2\).*?    RETURN NULL;\n  END IF;\n', '', 's')) <> '5689022eea0d35122774914a1abc56de'
    THEN RAISE EXCEPTION 'VERIFY: derm.fn_dirty_on_card_change is not its old body plus the one block'; END IF;
END $v$;

COMMIT;
