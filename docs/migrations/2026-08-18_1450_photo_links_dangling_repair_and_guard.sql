-- ============================================================================
-- 2026-08-18_1450 - soft-delete the 28 dangling visit links, then make the class impossible
-- ============================================================================
-- From the August photo audit (Fred: "check their pictures in jobber to make sure it's
-- correct what we have") and its adversarial review.
--
-- THE DEFECT. photo_links.entity_id has no existence check of any kind (a real FK is
-- impossible on a polymorphic column), and 28 ALIVE links point at visits that do not
-- exist: 1795 (14 links), 4326 (4), 4717 (10). The attribution audit found the first
-- group and wrote "all other visit links resolve"; the adversarial review of tonight's
-- plan re-measured and found the other two, both jobber_migration-sourced from May.
--
-- ORDER INSIDE THIS FILE IS LOAD-BEARING: repair FIRST, guard SECOND. And the guard is
-- 🛑 BEFORE **INSERT** ONLY - soft-delete itself is an UPDATE, so an INSERT-OR-UPDATE
-- guard would have made these very repairs impossible, and would break any future
-- sanctioned soft-delete of a link whose visit was hard-deleted with sign-off (the
-- 5146-class repair). The review caught this before it shipped, not after.
--
-- Backup (the only restore path for full rows, though photo_links IS audited since
-- 2026-08-14): backups/2026-08-18_photo_links_dangling_visits.json (28 rows, outside
-- the repo).
--
-- AUDIT (rule 8): photo_links carries audit_photo_links, so the 28 soft-deletes are
-- captured with old_row/new_row. No trigger work needed for the repair; the new guard
-- trigger is a validation trigger, not an audit change.
-- ============================================================================

do $repair$
declare v_n int;
begin
  -- Soft-delete via UPDATE (the sanctioned shape; soft_delete_photo_link does one link at
  -- a time - this is the same statement it runs, set-based, with the same audit capture).
  -- Pinned to the exact ids AND re-asserting the orphan predicate, so this fires on
  -- nothing if the world changed since the backup.
  update public.photo_links pl
     set deleted_at = now(),
         deleted_reason = 'entity does not exist: visit '||pl.entity_id||' has no visits row (August photo audit 2026-08-18)'
   where pl.entity_type = 'visit'
     and pl.entity_id in (1795, 4326, 4717)
     and pl.deleted_at is null
     and not exists (select 1 from public.visits v where v.id = pl.entity_id);
  get diagnostics v_n = row_count;
  if v_n <> 28 then
    raise exception 'expected to soft-delete 28 dangling links, got % - re-measure before proceeding', v_n;
  end if;
end
$repair$;

-- The guard: a visit link may only be CREATED against a visit that exists and is alive.
create or replace function public.fn_photo_link_target_exists()
returns trigger
language plpgsql
set search_path to ''
as $fn$
begin
  if new.entity_type = 'visit' then
    if not exists (select 1 from public.visits v
                    where v.id = new.entity_id and v.deleted_at is null) then
      raise exception 'photo_links: visit % does not exist or is soft-deleted', new.entity_id
        using errcode = '23503';
    end if;
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_aa_photo_link_target_exists on public.photo_links;
create trigger trg_aa_photo_link_target_exists
  before insert on public.photo_links
  for each row execute function public.fn_photo_link_target_exists();

-- ============================================================================
-- VERIFY - both directions, in a rolled-back sub-block: an insert to a dead visit must
-- FAIL, and a soft-delete-shaped UPDATE of an existing link must still SUCCEED.
-- ============================================================================
do $verify$
declare fail text := ''; v_photo bigint; v_link bigint; v_raised boolean;
begin
  if exists (select 1 from public.photo_links pl where pl.entity_type='visit' and pl.deleted_at is null
              and not exists (select 1 from public.visits v where v.id=pl.entity_id)) then
    fail := fail || 'dangling alive links remain; ';
  end if;

  select id into v_photo from public.photos order by id limit 1;

  -- 1. insert to a nonexistent visit must raise
  v_raised := false;
  begin
    insert into public.photo_links (photo_id, entity_type, entity_id, role) values (v_photo, 'visit', -424242, 'attachment');
  exception when others then v_raised := (sqlerrm like 'photo_links: visit%');
  end;
  if not v_raised then fail := fail || 'guard did not block a dead-visit insert; '; end if;

  -- 2. CONTROL: insert to a real alive visit must succeed (otherwise the guard blocks
  --    everything and check 1 proves nothing). Cleaned up in this block.
  begin
    insert into public.photo_links (photo_id, entity_type, entity_id, role)
    values (v_photo, 'visit', (select id from public.v_visits_live order by id limit 1), 'attachment')
    returning id into v_link;
    delete from public.photo_links where id = v_link;  -- sentinel row, never observed by anyone
  exception when others then fail := fail || format('guard blocks a LEGITIMATE insert: %s; ', sqlerrm);
  end;

  -- 3. a soft-delete-shaped UPDATE must still be possible on a link whose visit is gone
  --    (the guard is INSERT-only). All 28 were just updated above, which proves it live.
  if (select count(*) from public.photo_links where entity_type='visit'
       and entity_id in (1795, 4326, 4717) and deleted_at is not null) <> 28 then
    fail := fail || 'the 28 repairs did not persist; ';
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'repaired 28, guard blocks dead-visit inserts, legitimate inserts and soft-deletes unaffected';
end
$verify$;

select (select count(*) from public.photo_links pl where pl.entity_type='visit' and pl.deleted_at is null
         and not exists (select 1 from public.visits v where v.id=pl.entity_id))   as dangling_alive_must_be_0,
       (select count(*) from public.photo_links where deleted_reason like 'entity does not exist%') as repaired,
       (select count(*) from pg_trigger where tgrelid='public.photo_links'::regclass
         and tgname='trg_aa_photo_link_target_exists')                              as guard_installed;
