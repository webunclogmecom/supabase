-- ROLLBACK of 2026-11-15_0530_ops_visit_grease_frozen_ll_restore_once.sql (the 36 LL visits' Calendar days stored again
-- once with the new rule). From the backup: backups/2026-11-15_visit_grease_frozen_ll_restore.json (md5 5658460769bb16d45ffff00d720869d2); the
-- backed-up rows are also still in the table, superseded and unchangeable, so this copies them from there.
-- The frozen guard forbids a delete or an edit, so the way back is the same shape as the change: the 36 rows stored by the
-- re-store are superseded, and copies of the 36 backed-up rows (their own content and frozen_at) are stored again. The
-- Calendar then shows those days as before (the 36 visits as "not a pumping").

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  -- the backed-up rows are there, superseded, with their content
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
       where f.superseded_at is not null and f.basis = 'not_pumping' and f.pump_kind is null) <> 36 then
    raise exception 'the 36 backed-up rows are not in the table as superseded rows; stop';
  end if;
  -- each of the 36 days has one live row, the grease trap row the re-store stored
  if (select count(*) from ops.visit_grease_frozen f where f.superseded_at is null and (f.visit_id, f.visit_date) in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16'))
        and f.pump_kind = 'grease_trap') <> 36 then
    raise exception 'the 36 live rows are not the re-stored grease trap rows; do not undo blindly';
  end if;
end
$pin$;

create temp table _rs_undo_before as select * from ops.visit_grease_frozen;
create temp table _rs_undo_new as
select f.id from ops.visit_grease_frozen f
 where f.superseded_at is null and (f.visit_id, f.visit_date) in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16')) and f.pump_kind = 'grease_trap';
create temp table _rs_undo_ins (id bigint);

update ops.visit_grease_frozen f set superseded_at = now() where f.id in (select id from _rs_undo_new);

with ins as (
  insert into ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, trap_size_gallons, gallons, basis, readings, frozen_at)
  select f.visit_id, f.visit_date, f.pump_kind, f.pump_kinds, f.vehicle_id, f.trap_size_gallons, f.gallons, f.basis, f.readings, f.frozen_at
    from ops.visit_grease_frozen f where f.id in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679)
  returning id)
insert into _rs_undo_ins select id from ins;

do $verify$
begin
  if (select count(*) from ops.visit_grease_frozen f where f.id in (select id from _rs_undo_new) and f.superseded_at is not null) <> 36
     or (select count(*) from _rs_undo_ins) <> 36 then
    raise exception 'verify_fail: not 36 rows superseded and 36 stored';
  end if;
  if (select count(*) from ops.visit_grease_frozen f
        join ops.visit_grease_frozen o on o.id in (11, 46, 62, 89, 104, 116, 134, 136, 169, 181, 193, 198, 201, 204, 229, 237, 273, 291, 302, 316, 340, 347, 357, 399, 406, 428, 456, 461, 464, 492, 508, 541, 552, 617, 653, 679) and o.visit_id = f.visit_id and o.visit_date = f.visit_date
       where f.id in (select id from _rs_undo_ins) and f.superseded_at is null
         and (f.pump_kind, f.pump_kinds, f.vehicle_id, f.trap_size_gallons, f.gallons, f.basis, f.readings, f.frozen_at)
             is not distinct from (o.pump_kind, o.pump_kinds, o.vehicle_id, o.trap_size_gallons, o.gallons, o.basis, o.readings, o.frozen_at)) <> 36 then
    raise exception 'verify_fail: the 36 days are not stored as they were';
  end if;
  if exists (select * from _rs_undo_before where id not in (select id from _rs_undo_new)
             except select * from ops.visit_grease_frozen)
     or exists (select * from ops.visit_grease_frozen where id not in (select id from _rs_undo_new) and id not in (select id from _rs_undo_ins)
                except select * from _rs_undo_before) then
    raise exception 'verify_fail: another row moved';
  end if;
  if exists (select 1 from ops.fn_grease_estimates_resolved(date '2026-01-04', date '2026-06-16') r
              where (r.visit_id, r.visit_date) in ((1248, date '2026-01-04'), (1285, date '2026-01-15'), (1298, date '2026-01-19'), (1331, date '2026-01-28'), (1342, date '2026-02-02'), (1351, date '2026-02-04'), (1369, date '2026-02-09'), (1375, date '2026-02-10'), (1407, date '2026-02-19'), (1422, date '2026-02-25'), (1434, date '2026-03-03'), (1444, date '2026-03-04'), (1440, date '2026-03-04'), (1438, date '2026-03-04'), (1472, date '2026-03-10'), (1479, date '2026-03-11'), (1516, date '2026-03-19'), (1533, date '2026-03-24'), (1543, date '2026-03-26'), (1564, date '2026-04-01'), (1592, date '2026-04-08'), (1599, date '2026-04-09'), (1609, date '2026-04-10'), (1737, date '2026-04-20'), (1745, date '2026-04-21'), (1782, date '2026-04-26'), (3898, date '2026-04-30'), (3908, date '2026-05-03'), (3909, date '2026-05-04'), (3939, date '2026-05-10'), (5088, date '2026-05-13'), (3900, date '2026-05-19'), (4974, date '2026-05-20'), (5429, date '2026-06-03'), (5771, date '2026-06-09'), (5798, date '2026-06-16')) and (r.basis <> 'not_pumping' or r.source <> 'frozen')) then
    raise exception 'verify_fail: the Calendar does not read the 36 as before';
  end if;
  raise notice 'verify ok: the 36 days are stored as they were before the re-store';
end $verify$;

COMMIT;
