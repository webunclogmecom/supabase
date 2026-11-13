-- 2026-11-13_1600  Broward per-visit sheets follow their manifest's life: a delete or an unlink retires the sheet, and a
--                  re-filed visit keeps its sheet number (Trello #192 s8ZiPr02; DERM Tracker known issue 20f)
--
-- WHY. Diego (Slack #new-app-issues, 2026-11-13 2:53 PM ET, manifest 317956, Broward, 9 clients): "I delete and try
-- again and this happen ... And now I see it's saved the document but it says it's incomplete. I don't understand
-- what's going on". The form said "Can't file: duplicate manifest number(s)" for all nine clients, and the saved
-- record showed Missing Docs and "No address photo".
--
-- ROOT CAUSE, measured (audit.logs + the gateway log, 2026-11-13):
--   Nov 12 5:45 PM ET  the first filing wrote 11 manifest rows (2171-2181) and their photos, then the per-visit sheets
--                      for 5 visits (9190, 6285, 6314, 6358, 7867), and stopped: no request for the 6th sheet ever
--                      reached the server (a dropped connection or an image the browser could not read; not knowable
--                      from here). The form then listed every client it had just saved as "already filed".
--   Nov 13 2:46 PM ET  Diego deleted the record: public.derm_delete_manifests soft-deleted the 11 rows, and NOTHING
--                      retired their 5 sheet rows in derm.manifest_visit_sheets. They stayed live, still holding
--                      sheet numbers 10113, 10103, 10104, 10105, 10107 in manifest_visit_sheets_sheet_no_uniq.
--   Nov 13 2:52 PM ET  the re-file wrote 9 rows (2186-2194) and the manifest photo; the first sheet, 106-ALC visit 6285
--                      on 2190, adopted its printed number 10103 (derm.generated_visit_sheets, correctly) and got 409
--                      (23505) because the deleted manifest's row still held 10103. The form stopped and again listed
--                      every client as "already filed". 0 of 9 sheets saved: that is the Missing Docs.
--   Every retry wedges the same way for 4 of the 9 visits (6285, 6314, 6358, 7867), and so would the Edit dialog's
--   "Attach photo", which calls the same function.
--
-- WHAT (the rule: a per-visit sheet documents ONE visit on ONE live manifest).
--   1. NEW derm.fn_retire_visit_sheets() + two AFTER triggers:
--        trg_zs_retire_visit_sheets_on_delete  on public.derm_manifests, when deleted_at goes from NULL to a time:
--          that manifest's live sheets get the same deleted_at.
--        trg_zs_retire_visit_sheet_on_unlink   on public.manifest_visits, AFTER DELETE: that (manifest, visit) sheet
--          gets deleted_at = now(). Same defect, second door: public.derm_unlink_visit, derm.unlink_row_visit,
--          set_visits_derm_required_manual(p_unlink) and the Move flow all delete links and left the sheet live
--          (0 such rows today).
--      The row stays (rule 6) and its photo stays in storage; only the number is freed. derm_delete_manifests is the
--      only function that soft-deletes a manifest and nothing restores one (measured), so a restore is not handled: a
--      restored manifest would show its sheets missing and they would be attached again.
--   2. public.record_manifest_visit_sheet: built from the LIVE pg_get_functiondef (md5 4339ddcc46f82cbea933da9097907a1b,
--      the 2026-10-20_1700 body), never retyped; ONE anchored insert before "-- Still null means genuinely
--      un-generated": when the visit has no sheet on this manifest and no generated sheet, it takes the number of its
--      own latest RETIRED sheet before minting. Without it a blank-pad sheet re-filed after a delete would get a
--      second number for the same paper (the other half of known issue 20f). Grants unchanged (CREATE OR REPLACE).
--   3. The rule applied to the rows already in that state: exactly the 5 sheet rows of the deleted 317956 rows, pinned
--      by (manifest, visit) below. 0 live sheets sit on an unlinked visit.
-- REACH: 91 sheet rows, 5 change (all on deleted manifests, so every reader already hid them). The rehearsal compared
-- derm.v_manifest_visit_sheets, derm.manifest_health, public.v_visit_city_email_state, derm.v_city_email_candidates and
-- derm.manifest_row_states() before and after the backfill: identical.
-- Diego's recovery after this: open #317956 in Manifests and attach the 9 sheets (or delete it and file it again).
-- Rule 8 (audit): no new table. derm.manifest_visit_sheets already carries audit_manifest_visit_sheets, so every
-- retire is an audited UPDATE. The trigger function is SECURITY DEFINER (owner postgres, search_path empty) so a
-- delete by any staff path retires the sheets; EXECUTE is revoked from everyone, a trigger does not need it.
-- Locks: CREATE TRIGGER takes SHARE ROW EXCLUSIVE on derm_manifests and manifest_visits (writes wait, reads do not).
-- ROLLBACK: 2026-11-13_rollback_derm_visit_sheets_follow_manifest_life.sql. Check: scripts/checks/derm_visit_sheets_live_only_on_live_links.sql

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(pg_get_functiondef('public.record_manifest_visit_sheet(bigint,bigint,text,text)'::regprocedure)) <> '4339ddcc46f82cbea933da9097907a1b' then
    raise exception 'public.record_manifest_visit_sheet changed since this migration was generated; rebuild it from the live body';
  end if;
  if to_regprocedure('derm.fn_retire_visit_sheets()') is not null then
    raise exception 'derm.fn_retire_visit_sheets() already exists';
  end if;
  -- The rows the backfill retires must still be exactly the five measured ones.
  if (select coalesce(string_agg(s.manifest_id || ':' || s.visit_id, ',' order by s.manifest_id, s.visit_id), '')
        from derm.manifest_visit_sheets s join public.derm_manifests m on m.id = s.manifest_id
       where s.deleted_at is null and m.deleted_at is not null)
     <> '2171:9190,2177:6314,2178:7867,2179:6285,2181:6358' then
    raise exception 'The live sheets on deleted manifests are no longer the five measured on 2026-11-13; re-measure';
  end if;
  if exists (select 1 from derm.manifest_visit_sheets s
              where s.deleted_at is null
                and not exists (select 1 from public.manifest_visits mv where mv.manifest_id = s.manifest_id and mv.visit_id = s.visit_id)) then
    raise exception 'A live sheet now sits on an unlinked visit; re-measure';
  end if;
end
$pin$;

CREATE OR REPLACE FUNCTION public.record_manifest_visit_sheet(p_manifest_id bigint, p_visit_id bigint, p_photo_bucket text, p_photo_path text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'derm', 'pg_temp'
AS $function$
declare
  v_client  bigint;
  v_bucket  text;
  v_sheet   bigint;
begin
  perform hr.fn_check_app('derm_tracker', 'edit', 'record a visit address sheet');   -- 2026-10-20_1700 access phase 4
  if p_manifest_id is null or p_visit_id is null then
    raise exception 'A manifest and a visit are both required to record an address sheet.'
      using errcode = '22023';
  end if;

  if coalesce(btrim(p_photo_bucket), '') = '' or coalesce(btrim(p_photo_path), '') = '' then
    raise exception 'The uploaded sheet needs both a storage bucket and a path. Got bucket %, path %.',
      coalesce(quote_literal(p_photo_bucket), 'NULL'), coalesce(quote_literal(p_photo_path), 'NULL')
      using errcode = '22023';
  end if;

  select m.client_id into v_client
    from public.derm_manifests m
   where m.id = p_manifest_id and m.deleted_at is null;

  if v_client is null then
    raise exception 'Manifest % does not exist or has been deleted.', p_manifest_id
      using errcode = '22023';
  end if;

  -- The visit must be ON this manifest. See refusal 2 in the header.
  if not exists (select 1 from public.manifest_visits mv
                  where mv.manifest_id = p_manifest_id and mv.visit_id = p_visit_id) then
    raise exception 'Visit % is not linked to manifest %, so a sheet cannot be attached to it. Link the visit first.',
      p_visit_id, p_manifest_id
      using errcode = '22023';
  end if;

  v_bucket := derm.fn_manifest_dump_bucket(p_manifest_id);
  if v_bucket <> 'BROWARD' then
    raise exception 'Manifest % was dumped at a % site. One address sheet per visit is the Broward FDEP form only; a Miami-Dade sheet covers several clients at once.',
      p_manifest_id, v_bucket
      using errcode = '22023';
  end if;

  -- Allocate a number only the first time. See the header: the paper is already printed.
  select s.sheet_no into v_sheet
    from derm.manifest_visit_sheets s
   where s.manifest_id = p_manifest_id and s.visit_id = p_visit_id;

  -- ===================== ADOPTION (2026-09-07_2240) =======================
  -- If the office GENERATED a sheet for this visit, the driver is holding paper
  -- with that number on it. Adopt it. Minting here instead would put a second,
  -- different number in the register for the same physical sheet, and nothing
  -- in the schema could see the divergence: the unique index on sheet_no is
  -- per-row within this table and cannot reach the generation register.
  if v_sheet is null then
    select g.sheet_no into v_sheet
      from derm.generated_visit_sheets g
     where g.visit_id = p_visit_id and g.deleted_at is null;
  end if;
  -- ========================================================================

  -- ============ RE-FILED AFTER A DELETE OR AN UNLINK (2026-11-13_1600, Trello #192) ============
  -- A sheet row is retired when its manifest is soft-deleted or its visit is unlinked from it
  -- (derm.fn_retire_visit_sheets). If this visit had a sheet on such a manifest, it is the same
  -- paper filed again: keep that number instead of minting a second one.
  if v_sheet is null then
    select s.sheet_no into v_sheet
      from derm.manifest_visit_sheets s
     where s.visit_id = p_visit_id
       and s.deleted_at is not null
       and s.sheet_no is not null
     order by s.deleted_at desc, s.created_at desc
     limit 1;
  end if;
  -- ============================================================================================

  -- Still null means genuinely un-generated: a sheet filled on a blank pad the
  -- office never printed. That is how every Broward manifest in history was
  -- filed, so it stays supported rather than refused.
  if v_sheet is null then
    v_sheet := nextval('public.derm_broward_address_seq');
  end if;

  insert into derm.manifest_visit_sheets
    (manifest_id, visit_id, client_id, sheet_no, photo_bucket, photo_path, uploaded_at, deleted_at)
  values
    (p_manifest_id, p_visit_id, v_client, v_sheet, btrim(p_photo_bucket), btrim(p_photo_path), now(), null)
  on conflict (manifest_id, visit_id) do update
    set photo_bucket = excluded.photo_bucket,
        photo_path   = excluded.photo_path,
        uploaded_at  = excluded.uploaded_at,
        deleted_at   = null;
        -- sheet_no deliberately NOT updated: the number is on paper the driver carried.

  return v_sheet;
end;
$function$
;

create function derm.fn_retire_visit_sheets()
 returns trigger
 language plpgsql
 security definer
 set search_path to ''
as $fn$
-- 2026-11-13_1600 (Trello #192). A per-visit Broward sheet documents ONE visit on ONE live manifest. When the manifest
-- is soft-deleted, or the visit is unlinked from it, the sheet documents nothing any more, so it is retired
-- (deleted_at). That frees its number in manifest_visit_sheets_sheet_no_uniq. The row and the photo stay (rule 6);
-- public.record_manifest_visit_sheet takes the number back when the visit is filed again.
begin
  if tg_table_name = 'derm_manifests' then
    update derm.manifest_visit_sheets s
       set deleted_at = new.deleted_at
     where s.manifest_id = new.id
       and s.deleted_at is null;
  else
    update derm.manifest_visit_sheets s
       set deleted_at = now()
     where s.manifest_id = old.manifest_id
       and s.visit_id = old.visit_id
       and s.deleted_at is null;
  end if;
  return null;
end
$fn$;
revoke all on function derm.fn_retire_visit_sheets() from public, anon, authenticated, service_role;

create trigger trg_zs_retire_visit_sheets_on_delete
  after update of deleted_at on public.derm_manifests
  for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function derm.fn_retire_visit_sheets();

create trigger trg_zs_retire_visit_sheet_on_unlink
  after delete on public.manifest_visits
  for each row
  execute function derm.fn_retire_visit_sheets();

-- The rule, applied to the rows already in that state (the five sheets of the deleted 317956 rows).
update derm.manifest_visit_sheets s
   set deleted_at = m.deleted_at
  from public.derm_manifests m
 where m.id = s.manifest_id
   and m.deleted_at is not null
   and s.deleted_at is null;

do $verify$
declare v_def text := pg_get_functiondef('public.record_manifest_visit_sheet(bigint,bigint,text,text)'::regprocedure);
begin
  -- Nothing but the inserted block moved.
  if md5(replace(v_def, $blk$  -- ============ RE-FILED AFTER A DELETE OR AN UNLINK (2026-11-13_1600, Trello #192) ============
  -- A sheet row is retired when its manifest is soft-deleted or its visit is unlinked from it
  -- (derm.fn_retire_visit_sheets). If this visit had a sheet on such a manifest, it is the same
  -- paper filed again: keep that number instead of minting a second one.
  if v_sheet is null then
    select s.sheet_no into v_sheet
      from derm.manifest_visit_sheets s
     where s.visit_id = p_visit_id
       and s.deleted_at is not null
       and s.sheet_no is not null
     order by s.deleted_at desc, s.created_at desc
     limit 1;
  end if;
  -- ============================================================================================

$blk$, '')) <> '4339ddcc46f82cbea933da9097907a1b' then
    raise exception 'VERIFY: record_manifest_visit_sheet differs from the live body by more than the inserted block';
  end if;
  if not has_function_privilege('authenticated', 'public.record_manifest_visit_sheet(bigint,bigint,text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.record_manifest_visit_sheet(bigint,bigint,text,text)', 'EXECUTE') then
    raise exception 'VERIFY: record_manifest_visit_sheet grants moved';
  end if;
  if has_function_privilege('authenticated', 'derm.fn_retire_visit_sheets()', 'EXECUTE')
     or has_function_privilege('anon', 'derm.fn_retire_visit_sheets()', 'EXECUTE')
     or has_function_privilege('service_role', 'derm.fn_retire_visit_sheets()', 'EXECUTE') then
    raise exception 'VERIFY: derm.fn_retire_visit_sheets() is executable by an API role';
  end if;
  if (select count(*) from pg_trigger
       where tgname in ('trg_zs_retire_visit_sheets_on_delete', 'trg_zs_retire_visit_sheet_on_unlink')
         and tgenabled = 'O' and not tgisinternal) <> 2 then
    raise exception 'VERIFY: the two triggers are not both present and enabled';
  end if;
  if exists (select 1 from derm.manifest_visit_sheets s join public.derm_manifests m on m.id = s.manifest_id
              where s.deleted_at is null and m.deleted_at is not null) then
    raise exception 'VERIFY: a live sheet still sits on a deleted manifest';
  end if;
  if (select string_agg(s.manifest_id || ':' || s.visit_id, ',' order by s.manifest_id, s.visit_id)
        from derm.manifest_visit_sheets s where s.deleted_at is not null)
     <> '2171:9190,2177:6314,2178:7867,2179:6285,2181:6358' then
    raise exception 'VERIFY: the retired sheets are not exactly the five';
  end if;
end
$verify$;

COMMIT;
