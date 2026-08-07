-- ============================================================================
-- 2026-08-07_1649: backfill public.properties.access_schedule from the legacy
--                  access_hours_start / access_hours_end / access_days trio
-- ============================================================================
-- Fred, 2026-08-07: "we need to change that legacy access hours, and make it so, if they
-- have the new access hours then those dominate, if not but they have legacy access hours,
-- then copy those access hours to all the days in the new access hours, and if it doesn't
-- have either then just remove the legacy one. The idea is to migrate from the legacy
-- access hours to the new access hours, and for it to be applied on all the apps."
--
-- THIS FILE IS STEP 1 OF THAT, AND IT IS DELIBERATELY ADDITIVE ONLY.
-- It fills access_schedule. It does NOT clear the legacy trio for migrated rows, and it
-- does NOT change any view. Nothing on any screen moves. See "why" at the bottom.
--
-- ---------------------------------------------------------------------------
-- WHY "COPY TO ALL THE DAYS" IS NOT WHAT THIS DOES, AND FRED AGREED
-- ---------------------------------------------------------------------------
-- Taken literally, every migrated property would become accessible seven days a week.
-- Measured first: of the 200 legacy-only properties, **31 record FEWER than seven
-- accessible days** (8 have four, 16 have five, 2 have six, 5 have none at all). For those
-- 26 with a real restriction, writing all seven days would tell a driver a site is open on
-- days the office recorded as closed, and would disagree with what the app already renders
-- (a day absent from access_days shows as "Closed").
-- ⇒ Fred chose RECORDED DAYS. For the 169 properties that already list all seven this is
--   identical to the literal reading, so the divergence only ever protects the 26.
-- ⇒ The 2 properties with hours but NO days recorded do get all seven, because nothing is
--   restricted there and one window with no day list means "these hours, any day".
--
-- ---------------------------------------------------------------------------
-- WHAT HAPPENS TO EACH ROW (dry-run measured before applying; 0 fell through)
-- ---------------------------------------------------------------------------
--   1 property   already has access_schedule      -> UNTOUCHED, it dominates (Fred's rule 1)
-- 197 properties valid legacy hours               -> access_schedule written
--   3 properties access_hours_start = 'REQ'       -> legacy pair CLEARED (Fred: "just clear them")
-- 655 properties neither                          -> nothing to do, legacy already NULL
--
-- ⚠ 20 of the 197 carried an UNPADDED hour ("9:00" rather than "09:00"). The legacy columns
-- are plain text and were never validated; access_schedule IS validated as HH:MM by
-- client.update_property_operational, so those are padded on the way in. Without that they
-- would write a schedule the RPC would later refuse to accept back.
--
-- ⚠ 114 of the 197 are OVERNIGHT windows (open > close, e.g. 22:00 to 06:00). That is legal
-- and meaningful here, and the app already renders it with a "+1" marker. Do not "fix" them.
--
-- 🛑 THE 3 'REQ' ROWS (ids 189, 213, 231) held the literal text "REQ" in a time field, with
-- no end time and no days. It cannot become a schedule. Fred chose to clear it outright
-- rather than preserve it as a note. Their `old_row` is in audit.logs if anyone wants it back.
--
-- ---------------------------------------------------------------------------
-- WHY THE LEGACY COLUMNS ARE NOT CLEARED FOR THE 197
-- ---------------------------------------------------------------------------
-- FIVE views still read them, and they read them as PLAIN PASS-THROUGH COLUMNS with no
-- logic attached: client.properties, ops.properties, ops.v_calendar_visit,
-- ops.v_route_today, ops.v_service_due. Only client.properties also exposes access_schedule.
-- Clearing the trio today would blank access hours on the Calendar, the route view and the
-- Field Portal in the same instant.
-- ⇒ After this file, access_schedule is COMPLETE and authoritative, and the legacy trio is a
--   compatibility mirror. The remaining steps, each its own change:
--     (a) expose access_schedule on the four ops views that lack it
--     (b) move each app to render from access_schedule
--     (c) stop deriving the legacy pair in client.update_property_operational
--     (d) drop the three legacy columns
--   Step (a) onward is where a screen can actually change, which is why none of it is here.
--
-- ⚠ NOT AT RISK FROM THE HOURLY JOBBER PROPERTY POLL. That poll writes address, city, state,
-- zip, name, client_id, latitude and longitude. It touches no access column, so this backfill
-- cannot be clobbered by it. (Client App CLAUDE.md, the two-write-sets-are-disjoint rule.)
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.properties already carries audit_properties, so
-- all 200 writes are captured with old_row intact and are individually revertible. No table is
-- added or renamed and no trigger changes.
-- ============================================================================

-- ---- STEP 1: fill access_schedule from the legacy trio -----------------------
with src as (
  select p.id,
         p.access_hours_start as raw_s,
         case when p.access_hours_start ~ '^[0-9]:[0-5][0-9]$' then '0'||p.access_hours_start
              else p.access_hours_start end as hs,
         case when p.access_hours_end ~ '^[0-9]:[0-5][0-9]$' then '0'||p.access_hours_end
              else p.access_hours_end end as he,
         case when p.access_days is null or array_length(p.access_days,1) is null
              then array['mon','tue','wed','thu','fri','sat','sun']
              else array(select distinct unnest(p.access_days)) end as days
    from public.properties p
   where p.access_schedule is null          -- an existing schedule DOMINATES, never overwritten
     and p.access_hours_start is not null
),
valid as (
  select * from src
   where hs ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     and he ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
)
update public.properties p
   set access_schedule = (select jsonb_object_agg(d, jsonb_build_object('open', v.hs, 'close', v.he))
                            from unnest(v.days) d)
  from valid v
 where p.id = v.id;

-- ---- STEP 2: clear the 3 rows whose "time" was the word REQ ------------------
update public.properties
   set access_hours_start = null,
       access_hours_end   = null
 where access_schedule is null
   and access_hours_start = 'REQ';

-- ---------------------------------------------------------------------------
-- ASSERT THE OUTCOME. A backfill that silently did nothing looks identical to one
-- that worked, so this fails loudly rather than reporting a clean run.
-- ---------------------------------------------------------------------------
do $$
declare
  v_sched      int;
  v_legacy_left int;
  v_req        int;
  v_bad_shape  int;
  v_bad_time   int;
  v_days_kept  int;
begin
  select count(*) into v_sched       from public.properties where access_schedule is not null;
  select count(*) into v_req         from public.properties where access_hours_start = 'REQ';
  select count(*) into v_legacy_left from public.properties
    where access_hours_start is not null and access_schedule is null;

  -- every schedule value must be {open,close} with HH:MM strings and a valid day key
  select count(*) into v_bad_shape from public.properties p, jsonb_each(p.access_schedule) e
   where p.access_schedule is not null
     and (e.key not in ('mon','tue','wed','thu','fri','sat','sun')
          or e.value->>'open' is null or e.value->>'close' is null);
  select count(*) into v_bad_time from public.properties p, jsonb_each(p.access_schedule) e
   where p.access_schedule is not null
     and (e.value->>'open'  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
       or e.value->>'close' !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$');

  -- the 26 restricted properties must NOT have gained days
  select count(*) into v_days_kept from public.properties p
   where p.access_schedule is not null
     and p.access_days is not null
     and (select count(*) from jsonb_object_keys(p.access_schedule)) <> array_length(array(select distinct unnest(p.access_days)),1);

  if v_sched <> 198 then
    raise exception 'expected 198 properties with a schedule (197 backfilled + 1 pre-existing), got %', v_sched;
  end if;
  if v_req <> 0 then raise exception 'REQ rows not cleared: %', v_req; end if;
  if v_legacy_left <> 0 then
    raise exception '% properties still hold legacy hours with no schedule', v_legacy_left;
  end if;
  if v_bad_shape <> 0 then raise exception '% schedule entries have a bad shape', v_bad_shape; end if;
  if v_bad_time  <> 0 then raise exception '% schedule times are not HH:MM', v_bad_time; end if;
  if v_days_kept <> 0 then
    raise exception '% properties have a schedule whose day count differs from access_days', v_days_kept;
  end if;

  raise notice 'access hours migrated: % properties now carry a schedule, 0 legacy-only left, day sets preserved', v_sched;
end
$$;
