-- =============================================================================
-- 2026-11-15_0530_ops_visit_grease_frozen_ll_restore_once.sql
--
-- WHAT: ONE recorded change to the Calendar's stored grease days (ops.visit_grease_frozen): the 36 visits that LL
--       (2026-11-15_0400) made grease trap pumpings had their day stored as "not a pumping". Their 36 stored rows are
--       superseded (the guard allows setting superseded_at once; nothing is deleted or rewritten), and the stored-day job
--       itself, ops.fn_freeze_grease_estimates(), stores those days again by its own code: it stores every past visit with no
--       live stored row, which is then exactly these 36, from ops.fn_grease_estimates_resolved (the new rule's answer). After
--       this the frozen rule works as before: nothing here changes the job, the rule or any reader.
--
-- WHY: Fred, 2026-11-15 about 4:00 AM ET, asked whether the Calendar's past days holding those 36 visits should be
--      recalculated once so the Calendar and the Clients pages agree, picked "Recalculate once (Recommended)": "one recorded
--      change, the days that hold those 36 visits stored again with the new rule ... after that the frozen rule works as
--      before." (Building Apps/Ops Portal/docs/00-fred-picks-2026-11-13-clients.md, the last lines.)
--
-- BACKUP, taken first: backups/2026-11-15_visit_grease_frozen_ll_restore.json (local, not in this repo): the 36 rows
--   as they were (md5 5658460769bb16d45ffff00d720869d2 of their JSON). The rows stay in the table too, superseded, unchangeable by the guard.
--
-- WHAT MOVES (measured in the rehearsal of 2026-11-15): 36 rows superseded and 36 stored again, one per visit, each now a
--   grease trap row with the trap size on file (basis trap_size), on 34 days from January 4 to June 16, 2026: 25,475 gal in
--   all. Those days' Grease pumped totals rise by exactly those visits' gallons; the Calendar's RPC lists the 36 on their
--   days. The job stores today's answer, so 2 of the 36 (one place, February 9 and April 20) take that place's trap size of
--   1,500 gal, entered after the October store (their old rows held no size); the other 34 sizes are the stored ones.
--   Nothing else: every other row of ops.visit_grease_frozen identical (counted below), every other day's answer, the
--   averages, their view and Admin Review's Grease page identical. The job's own log row (sync_log, calendar_grease_freeze)
--   says frozen 36. Not city-facing: no DERM, manifest, report or email object reads this table.
-- NOT AUDITED: ops.visit_grease_frozen has no audit trigger (append-only by its guard); this file and the job's log row are
--   the record.
-- THE CHECKS: the VERIFY below, rehearsed rolled back. Control: with the old rule body in place the same re-store stores
--   the 36 back as "not a pumping" (no gallons and no day total move; only those 2 rows' size column would) and the VERIFY
--   fails.
-- UNDO: 2026-11-15_rollback_ops_visit_grease_frozen_ll_restore_once.sql (supersedes the 36 new rows and stores copies of the
--   backed-up rows again; the frozen guard allows no other way back).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(replace(pg_get_functiondef('ops.fn_visit_pump_kinds(bigint,bigint)'::regprocedure), chr(13), '')) <> 'c1e484205b1e89b51d366e7d2a4b7e60' then
    raise exception 'ops.fn_visit_pump_kinds(bigint,bigint) is not the body this was rehearsed with; stop';
  end if;
  if md5(replace(pg_get_functiondef('ops.fn_freeze_grease_estimates()'::regprocedure), chr(13), '')) <> 'e5909a08256cd36d529fa415382bd493' then
    raise exception 'ops.fn_freeze_grease_estimates() is not the body this was rehearsed with; stop';
  end if;
  if md5(replace(pg_get_functiondef('ops.fn_grease_estimates_resolved(date,date)'::regprocedure), chr(13), '')) <> '5031b1f2b716f16becbd752ebb377c7f' then
    raise exception 'ops.fn_grease_estimates_resolved(date,date) is not the body this was rehearsed with; stop';
  end if;
  if md5(replace(pg_get_functiondef('ops.fn_grease_estimates_live(date,date)'::regprocedure), chr(13), '')) <> 'fd0fb1d9b1bba2972d2e41b700bbe8f0' then
    raise exception 'ops.fn_grease_estimates_live(date,date) is not the body this was rehearsed with; stop';
  end if;
  -- the 36 rows of the backup: live, "not a pumping", on their visits' days, and nothing else
  if (select count(*) from ops.visit_grease_frozen f
        join (values
    (11, 1248, date '2026-01-04'),
    (46, 1285, date '2026-01-15'),
    (62, 1298, date '2026-01-19'),
    (89, 1331, date '2026-01-28'),
    (104, 1342, date '2026-02-02'),
    (116, 1351, date '2026-02-04'),
    (134, 1369, date '2026-02-09'),
    (136, 1375, date '2026-02-10'),
    (169, 1407, date '2026-02-19'),
    (181, 1422, date '2026-02-25'),
    (193, 1434, date '2026-03-03'),
    (198, 1444, date '2026-03-04'),
    (201, 1440, date '2026-03-04'),
    (204, 1438, date '2026-03-04'),
    (229, 1472, date '2026-03-10'),
    (237, 1479, date '2026-03-11'),
    (273, 1516, date '2026-03-19'),
    (291, 1533, date '2026-03-24'),
    (302, 1543, date '2026-03-26'),
    (316, 1564, date '2026-04-01'),
    (340, 1592, date '2026-04-08'),
    (347, 1599, date '2026-04-09'),
    (357, 1609, date '2026-04-10'),
    (399, 1737, date '2026-04-20'),
    (406, 1745, date '2026-04-21'),
    (428, 1782, date '2026-04-26'),
    (456, 3898, date '2026-04-30'),
    (461, 3908, date '2026-05-03'),
    (464, 3909, date '2026-05-04'),
    (492, 3939, date '2026-05-10'),
    (508, 5088, date '2026-05-13'),
    (541, 3900, date '2026-05-19'),
    (552, 4974, date '2026-05-20'),
    (617, 5429, date '2026-06-03'),
    (653, 5771, date '2026-06-09'),
    (679, 5798, date '2026-06-16')) b(id, visit_id, visit_date) on b.id = f.id and b.visit_id = f.visit_id and b.visit_date = f.visit_date
       where f.superseded_at is null and f.basis = 'not_pumping' and f.pump_kind is null and f.gallons is null) <> 36 then
    raise exception 'the 36 stored rows are not the ones backed up; stop';
  end if;
  if exists (select 1 from ops.visit_grease_frozen f where f.superseded_at is null and (f.visit_id, f.visit_date) in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16'))
              and f.id not in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679)) then
    raise exception 'another live row exists for one of the 36 days; stop';
  end if;
end
$pin$;

-- Every reader's answer before (the VERIFY compares after): the whole table, the resolved estimate over 2026 to yesterday,
-- the Calendar's RPC in 45-day windows and Admin Review's Grease page (both as the first active admin), the averages for
-- every day a visit falls on and tomorrow, and their view.
create temp table _rs_frozen_before as select * from ops.visit_grease_frozen;
create temp table _rs_range as select date '2026-01-01' as f, (now() at time zone 'America/New_York')::date - 1 as t;
create temp table _rs_days as
select distinct cv.visit_date as d from ops.v_calendar_visit cv where cv.visit_date between (select f from _rs_range) and (select t from _rs_range)
union select (now() at time zone 'America/New_York')::date + 1;
create temp table _rs_resolved_before as select * from ops.fn_grease_estimates_resolved((select f from _rs_range), (select t from _rs_range));
create temp table _rs_avg_before as select * from ops.fn_client_sludge_averages((select array_agg(d) from _rs_days));
create temp table _rs_vcsa_before as select * from ops.v_client_sludge_average;
select set_config('request.jwt.claims', (select json_build_object('sub', u.id, 'email', u.email, 'role', 'authenticated')::text
   from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
  where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null order by e.id limit 1), true);
create temp table _rs_cal_before as select * from ops.calendar_grease_estimates(current_date, current_date) limit 0;
create temp table _rs_cal_after as select * from _rs_cal_before limit 0;
create temp table _rs_grease_before as select * from public.get_grease_by_client();
do $cal$
declare w date := (select f from _rs_range);
begin
  while w <= (select t from _rs_range) loop
    insert into _rs_cal_before select * from ops.calendar_grease_estimates(w, least(w + 45, (select t from _rs_range)));
    w := w + 46;
  end loop;
end $cal$;
select set_config('request.jwt.claims', '', true);

-- 1. The one decided change: the 36 stored rows are superseded (their content stays, unchangeable).
update ops.visit_grease_frozen set superseded_at = now() where id in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679);

-- 2. The stored-day job stores those days again by its own code (every past visit with no live stored row: the 36).
select ops.fn_freeze_grease_estimates();

do $verify$
declare
  v_bad bigint; v_n bigint; v_changed bigint; v_msg text; w date;
begin
  -- a. This transaction superseded exactly the 36 backed-up rows and stored exactly 36 new rows, one per visit and day, each a
  --    grease trap row with the new rule's answer (the live estimate's, as the job stores it).
  if (select count(*) from ops.visit_grease_frozen f where f.superseded_at = now()) <> 36
     or exists (select 1 from ops.visit_grease_frozen f where f.superseded_at = now() and f.id not in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679)) then
    raise exception 'verify_fail: the job superseded rows other than the 36';
  end if;
  select (select count(*) from (select * from _rs_resolved_before except select * from ops.fn_grease_estimates_resolved((select f from _rs_range), (select t from _rs_range))) x)
    into v_changed;
  select count(*) into v_n
    from ops.visit_grease_frozen f
    join ops.fn_grease_estimates_live(date '2026-01-04', date '2026-06-16') l on l.visit_id = f.visit_id and l.visit_date = f.visit_date
   where f.frozen_at = now() and f.superseded_at is null and (f.visit_id, f.visit_date) in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16'))
     and f.pump_kind = 'grease_trap' and f.pump_kinds = '{grease_trap}' and f.basis in ('trap_size', 'measured', 'unknown')
     and (f.basis, f.gallons, f.vehicle_id, f.trap_size_gallons, f.readings) is not distinct from (l.basis, l.gallons, l.vehicle_id, l.trap_size_gallons, l.readings);
  if v_n <> 36 or (select count(*) from ops.visit_grease_frozen f where f.frozen_at = now()) <> 36 then
    raise exception 'verify_fail: % of the 36 days stored again as grease trap rows (% rows stored; % resolved rows changed)',
      v_n, (select count(*) from ops.visit_grease_frozen f where f.frozen_at = now()), v_changed;
  end if;

  -- b. Every other row of the table identical, counted.
  select (select count(*) from (select * from _rs_frozen_before where id not in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679)
                                except select * from ops.visit_grease_frozen where id not in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679)) x)
       + (select count(*) from (select * from ops.visit_grease_frozen where id not in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679) and frozen_at <> now()
                                except select * from _rs_frozen_before where id not in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679)) x)
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % other rows of ops.visit_grease_frozen moved', v_bad; end if;
  v_n := (select count(*) from _rs_frozen_before where id not in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679));

  -- c. What the Calendar shows: the resolved estimate and the RPC change only on the 36 visits; their days' totals rise by
  --    exactly their gallons; every other day identical.
  drop table if exists _rs_resolved_after;
  create temp table _rs_resolved_after as select * from ops.fn_grease_estimates_resolved((select f from _rs_range), (select t from _rs_range));
  select (select count(*) from (select * from _rs_resolved_before except select * from _rs_resolved_after) x where (x.visit_id, x.visit_date) not in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16')))
       + (select count(*) from (select * from _rs_resolved_after except select * from _rs_resolved_before) x where (x.visit_id, x.visit_date) not in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16')))
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % resolved rows moved outside the 36', v_bad; end if;
  if (select count(*) from _rs_resolved_after a where (a.visit_id, a.visit_date) in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16')) and a.source = 'frozen' and a.pump_kind = 'grease_trap') <> 36 then
    raise exception 'verify_fail: the 36 do not read as stored grease trap rows';
  end if;
  select count(*) into v_bad
    from (select d.visit_date, sum(d.gallons) as g from _rs_resolved_before d group by 1) b
    full join (select d.visit_date, sum(d.gallons) as g from _rs_resolved_after d group by 1) a using (visit_date)
    left join (select f.visit_date, sum(f.gallons) as g from ops.visit_grease_frozen f where f.frozen_at = now() group by 1) n using (visit_date)
   where coalesce(a.g, 0) is distinct from coalesce(b.g, 0) + coalesce(n.g, 0);
  if v_bad <> 0 then raise exception 'verify_fail: % days'' totals moved by other than the 36 visits', v_bad; end if;
  perform set_config('request.jwt.claims', (select json_build_object('sub', u.id, 'email', u.email, 'role', 'authenticated')::text
     from public.employees e join auth.users u on lower(btrim(u.email)) = lower(btrim(e.email))
    where e.status = 'ACTIVE' and e.access_level = 'admin' and u.email_confirmed_at is not null order by e.id limit 1), true);
  w := (select f from _rs_range);
  while w <= (select t from _rs_range) loop
    insert into _rs_cal_after select * from ops.calendar_grease_estimates(w, least(w + 45, (select t from _rs_range)));
    w := w + 46;
  end loop;
  select (select count(*) from (select * from _rs_cal_before except select * from _rs_cal_after) x)
       + (select count(*) from (select * from _rs_cal_after except select * from _rs_cal_before) x where (x.visit_id, x.visit_date) not in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16')))
       + (select count(*) from (select * from public.get_grease_by_client() except select * from _rs_grease_before) x)
       + (select count(*) from (select * from _rs_grease_before except select * from public.get_grease_by_client()) x)
    into v_bad;
  perform set_config('request.jwt.claims', '', true);
  if v_bad <> 0 then raise exception 'verify_fail: % rows of the Calendar RPC or the Grease page moved outside the 36', v_bad; end if;
  if (select count(*) from _rs_cal_after where (visit_id, visit_date) in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16'))) <> 36 then raise exception 'verify_fail: the Calendar RPC does not list the 36'; end if;

  -- d. The averages and their view identical.
  select (select count(*) from (select * from _rs_avg_before except select * from ops.fn_client_sludge_averages((select array_agg(d) from _rs_days))) x)
       + (select count(*) from (select * from ops.fn_client_sludge_averages((select array_agg(d) from _rs_days)) except select * from _rs_avg_before) x)
       + (select count(*) from (select * from _rs_vcsa_before except select * from ops.v_client_sludge_average) x)
       + (select count(*) from (select * from ops.v_client_sludge_average except select * from _rs_vcsa_before) x)
    into v_bad;
  if v_bad <> 0 then raise exception 'verify_fail: % rows of the averages moved', v_bad; end if;

  -- e. The job's own log row of this run says so.
  if not exists (select 1 from public.sync_log s where s.sync_source = 'calendar_grease_freeze' and s.started_at >= now()
                  and s.status = 'success' and (s.details ->> 'frozen')::int = 36 and (s.details ->> 'truck_corrected')::int = 0) then
    raise exception 'verify_fail: the job''s log row does not say frozen 36, truck_corrected 0';
  end if;

  select format('36 rows superseded and stored again on %s days (%s trap_size, %s measured, %s unknown; %s gal added); %s other rows of the table identical; Calendar RPC %s rows, Grease page %s rows, averages identical',
                (select count(distinct visit_date) from ops.visit_grease_frozen where frozen_at = now()),
                (select count(*) from ops.visit_grease_frozen where frozen_at = now() and basis = 'trap_size'),
                (select count(*) from ops.visit_grease_frozen where frozen_at = now() and basis = 'measured'),
                (select count(*) from ops.visit_grease_frozen where frozen_at = now() and basis = 'unknown'),
                (select coalesce(sum(gallons), 0) from ops.visit_grease_frozen where frozen_at = now()),
                v_n, (select count(*) from _rs_cal_after), (select count(*) from _rs_grease_before))
    into v_msg;
  raise notice 'verify ok: %', v_msg;
end $verify$;

COMMIT;
