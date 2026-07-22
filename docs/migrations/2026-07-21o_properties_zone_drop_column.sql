-- ============================================================================
-- 2026-07-21o - Collapse properties.zone -> zones.code (step 3: DROP the column)
-- ============================================================================
-- Final step of the properties.zone collapse (see 21n). Fred green-lit it.
--
-- PRE-DROP GUARDS (all verified before running):
--   * pg_depend: ZERO views reference public.properties.zone (my 11 in 21n +
--     ops.v_calendar_visit, which the Building Apps session rewrote + live-verified
--     on calendar.unclogme.app: 206 visits render, zone chip + sidebar dots intact,
--     no regression).
--   * No index / default / generated expr / check-constraint / RLS policy on zone
--     (only properties_zone_id_fkey on zone_id, which STAYS - that FK is the whole
--     point of the collapse).
--   * Writers of zone-text: the only one was handleClientRecord in webhook-airtable
--     (client-enrichment from Airtable). AT is sunset, but that handler is still
--     WIRED, so - per this repo's own "wired != dead" lesson - the zone-text write
--     was removed from the edge fn and redeployed BEFORE this drop (not inferred
--     from "no recent writes"). zone was never authoritative from AT (Rule 4).
--
-- WHAT: drop the bidirectional sync trigger + its function (they existed only to
-- keep the redundant zone text mirrored to zone_id / zones.code), then drop the
-- column. RESTRICT (no CASCADE) so any missed dependency errors loudly instead of
-- silently dropping a view. zones_hard_delete's comment is corrected in the same
-- txn (it referenced the now-gone sync trigger).
--
-- The data is not lost: zone == zones.code, recoverable via zone_id. Snapshot in
-- backups/2026-07-21_properties_zone_column_pre_drop.json (247 rows).
--
-- Canonical zone is now zone_id (FK -> public.zones); read the code/label/colour
-- through the FK (every view already does after 21n). Audit note: dropping a
-- column from the audited `properties` table needs no trigger change (full-row
-- JSONB audit continues on the remaining columns).
-- ============================================================================

begin;

drop trigger if exists properties_sync_zone_columns_trg on public.properties;
drop function if exists public.properties_sync_zone_columns();

-- correct the stale comment (no more zone text column / sync trigger)
create or replace function public.zones_hard_delete(_code text)
 returns table(deleted_zone_code text, unlinked_properties integer)
 language plpgsql security definer set search_path to 'public'
as $function$
declare
  _zone_id bigint;
  _unlinked int;
begin
  select id into _zone_id from public.zones where code = _code;
  if _zone_id is null then
    raise exception 'Zone with code % not found', _code using errcode = 'no_data_found';
  end if;

  -- Unlink properties (zone_id only; the zone text column + its sync trigger were
  -- dropped 2026-07-21o - zone_id is now the single source of truth).
  update public.properties set zone_id = null where zone_id = _zone_id;
  get diagnostics _unlinked = row_count;

  -- Hard delete the zone row. Audit captures the DELETE.
  delete from public.zones where id = _zone_id;

  return query select _code, _unlinked;
end $function$;

alter table public.properties drop column if exists zone;   -- RESTRICT (default)

commit;
