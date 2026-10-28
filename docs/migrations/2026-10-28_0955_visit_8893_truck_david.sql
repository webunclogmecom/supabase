-- 2026-10-28_0955_visit_8893_truck_david.sql
--
-- Trello 6M9WvSYp follow-up (Admin Review "Grease by client", Samsara link check). ONE-VISIT HAND REPAIR.
--
-- Fred, 2026-10-28: "go ahead with both recommended" (recommendation 1: set the truck of visit 8893 to David), then,
-- asked about the vpF5PLQj re-check's request for "no SQL truck change on completed visits": "Change it now anyway".
-- The re-check session (303311bd) is told in WORKING-NOW.md in the same cycle.
--
-- WHAT WAS FOUND: opening the visit's Samsara link (Cloggy, Oct 27 06:55 to 08:11 ET) showed Cloggy parked at the
-- yard for the whole window. GPS:
--   David  (vehicle 3) stop 1932, 07:10 to 07:53 ET, 26.0753 / -80.2067, ~110 m from the property (26.0763 / -80.2067);
--          the completion (07:52 ET) is inside it.
--   Cloggy (vehicle 2) at the yard (650 NW 33rd St) 06:21 to 09:21 ET.
-- The visit was created on Moises (Calendar, 2026-10-26 08:59 ET) and moved to Cloggy in the Calendar at 11:23 ET; David
-- went. Its time on site (07:10 to 07:56, 46 min, source gps_150m_any_truck) already came from David's stay.
--
-- WHY BY HAND: the nightly public.fn_infer_visit_vehicle would replace the truck (one truck holds the completion,
-- the stored one has no stop) but refuses any visit filed on a DERM manifest ("Fred decides"). 8893 is filed on
-- manifest 2101 (yellow 316612, Water and Wastewater Services, Broward, Oct 27). No rule covers a filed visit; this is
-- the decision, and 2026-10-28_1010 makes the next one reach a person.
--
-- EFFECTS (measured before applying):
--   - vehicle_id is NOT in trg_push_visit_update's WHEN list nor in fn_mark_visit_sync_pending: nothing goes to Jobber
--     and sync_state does not move. trg_zz_queue_start_recheck acts on today and later only (the visit is Oct 27).
--   - The hourly fn_link_visit_vehicle_stops will link David's stop 1932 to the visit on its next run. David carries
--     no tank sensor, so no tank figure appears (Cloggy had none either).
--   - derm.v_lwt_monthly_rows reads the visit's truck: its row (in_scope FALSE, Broward pickup and dump) turns
--     Cloggy -> David. No Miami-Dade filing is affected.
--   - The time columns are NOT touched (vpF5PLQj hold). No visit_time_on_site_corrections row exists for 8893, so the
--     T7 / T8 drift alarms have nothing to compare.
-- Rule 8: public.visits is audited (audit_visits); the UPDATE is recorded with old_row, app_source truck-fix-by-hand.
-- Rollback: 2026-10-28_rollback_visit_8893_truck_david.sql.

begin;

-- the evidence, re-asserted at the moment of the write
do $pre$
declare v record; s record; m int;
begin
  select id, vehicle_id, visit_status, deleted_at, completed_at, property_id into v from public.visits where id = 8893;
  if v.id is null or v.vehicle_id is distinct from 2 or v.visit_status <> 'completed' or v.deleted_at is not null then
    raise exception 'PRE: visit 8893 is not the completed Cloggy visit this repair was written for (%).', row_to_json(v);
  end if;
  select st.* into s from public.vehicle_stops st where st.id = 1932;
  if s.vehicle_id is distinct from 3
     or v.completed_at not between s.arrived_at - interval '5 minutes' and s.departed_at + interval '15 minutes' then
    raise exception 'PRE: David''s stop 1932 no longer holds the completion of 8893.';
  end if;
  if (select ops.fn_haversine_km(p.latitude, p.longitude, s.latitude, s.longitude) * 1000 from public.properties p where p.id = v.property_id) > 250 then
    raise exception 'PRE: stop 1932 is not within 250 m of the visit''s property.';
  end if;
  select count(*) into m from public.manifest_visits mv join public.derm_manifests dm on dm.id = mv.manifest_id
   where mv.visit_id = 8893 and dm.deleted_at is null;
  if m <> 1 then raise exception 'PRE: expected the visit on exactly one live manifest, found %.', m; end if;
end $pre$;

create temp table _before on commit drop as select * from public.visits where id = 8893;

select set_config('request.headers', jsonb_build_object(
  'x-app-source', 'truck-fix-by-hand',
  'x-change-reason', 'Truck set to David by hand with Fred''s OK (2026-10-28): David was the only truck parked there when the job was marked complete (GPS stop 1932, 07:10 to 07:53 ET) and Cloggy was at the yard. The visit is filed on a DERM manifest, so the nightly truck correction leaves it to a person.'
)::text, true);

update public.visits set vehicle_id = 3
 where id = 8893 and vehicle_id = 2 and visit_status = 'completed' and deleted_at is null;

do $verify$
declare n int; diff text;
begin
  if (select vehicle_id from public.visits where id = 8893) is distinct from 3 then
    raise exception 'VERIFY: vehicle_id is not 3 after the update.';
  end if;
  -- nothing but vehicle_id and updated_at moved
  select string_agg(k, ',') into diff
    from (select key k, value v from jsonb_each((select to_jsonb(b) from _before b))) o
    full join (select key k, value v from jsonb_each((select to_jsonb(x) from public.visits x where x.id = 8893))) nw using (k)
   where o.v is distinct from nw.v and k not in ('vehicle_id', 'updated_at');
  if diff is not null then raise exception 'VERIFY: other columns moved: %', diff; end if;
  select count(*) into n from audit.logs
   where table_name = 'visits' and record_pk = '{"id": 8893}'::jsonb and app_source = 'truck-fix-by-hand'
     and old_row->>'vehicle_id' = '2' and new_row->>'vehicle_id' = '3' and txid = txid_current();
  if n <> 1 then raise exception 'VERIFY: expected 1 audit row for the change, found %.', n; end if;
  raise notice 'VERIFY ok: 8893 vehicle 2 -> 3, only vehicle_id and updated_at changed, audited.';
end $verify$;

commit;
