-- 2026-10-12 15:02 ET · Tank configuration: vehicle tanks, their geometry, the LM11 sensors and where they sit (M2)
-- APPLIED to Prod 2026-10-12 (~16:50 ET), after a rolled-back dry run of this file.
-- Plan: docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md (sections 2.0 to 2.3, 3.1, 7, 10.2 M2).
-- Facts: docs/reference/samsara-tank-sensors-2026-10-12.md.
--
-- WHAT
--   extension btree_gist, in schema extensions (not installed before; 1.7 available, measured 2026-10-12)
--   public.fn_append_only_guard()     one trigger function for every new tank table: blocks DELETE and TRUNCATE, blocks
--                                     UPDATE except for the set-once columns passed as trigger arguments (NULL -> value,
--                                     once). Raises 55000. Used by M3 too.
--   public.vehicle_tanks              one row per physical tank on a truck (sludge, fresh_water)
--   public.vehicle_tank_configurations  geometry and capacity of a tank as of an instant (effective-dated, insert-only;
--                                     a wrong row is superseded and a corrected row inserted with the SAME effective_from)
--   public.tank_sensors               one row per physical LM11 device; its Samsara asset id and gateway serial live in
--                                     entity_source_links (entity_type 'tank_sensor', source_system 'samsara' and
--                                     'samsara_gateway'), never in a column (rule 1)
--   public.tank_sensor_installations  which sensor sits on which tank, from when to when (no overlap per sensor or per
--                                     tank among live rows: GiST exclusion constraints)
--   Seeds, in this transaction with their ESL links (rule 8): Moises (vehicles.id 1, resolved from its Samsara asset id
--   281474998706262, never by name) gets a sludge tank and a fresh-water tank, one configuration each, two LM11 sensors,
--   two installations and four ESL rows (source_name NULL on all).
--
-- WHY
--   Owner voice note, 2026-10-12: "we need to know what kind of information we can get from it", "how much water was
--   used, how much sludge was pumped out", "everything needs to be linked. No orphans."
--   Owner, 2026-10-12, on the water capacity: "We have the water tank size for Moises, so use that, link the sensor to
--   it, remember both sensors are for moises so we should link to the truck." The size is the owner's fleet note of
--   2026-04-24: Moises carries two tanks, 1,200 gal water and 3,800 gal grease (the configured grease capacity is 3,840).
--   Geometry check: an 84 in barrel holds 1,200 gal in 4.17 ft and 3,840 gal in 13.34 ft, 17.5 ft in all, which is one
--   barrel with two compartments. So the water configuration carries capacity 1,200.0, basis owner_confirmed, and the
--   SAME geometry the readings fitted (84 in = 2.1336 m, sensor 12 in = 0.3048 m above max fill).
--
-- 3NF (does each column depend on the whole key and nothing else?)
--   vehicle_tanks (key id; natural key vehicle_id + contents among live rows)
--     vehicle_id    the truck the tank is mounted on: a fact of the tank
--     contents      what the tank holds: a fact of the tank. Capacity changes over time, so it is NOT here
--     created_at    when the row was written
--     deleted_at    when the tank stopped existing (set once)
--   vehicle_tank_configurations (key id; natural key vehicle_tank_id + effective_from among live rows)
--     vehicle_tank_id, effective_from   which tank, from when this geometry holds; effective_to is derived with lead()
--     shape, diameter_meters, sensor_offset_meters, capacity_gallons, basis, notes   describe that tank as of that
--                   instant; capacity NULL means unknown, never guessed
--     created_at    when the row was written
--     superseded_at this row was WRONG and a corrected row replaces it (set once)
--   tank_sensors (key id)
--     model         describes the device; vendor ids live in entity_source_links
--     created_at    when the row was written
--   tank_sensor_installations (key id; natural key tank_sensor_id + range among live rows)
--     tank_sensor_id, vehicle_tank_id, installed_at, removed_at   which device on which tank over which range
--     superseded_at this row was WRONG (a correction, set once); removed_at is a physical removal (set once)
--     created_at    when the row was written
--
-- RULE 8, AUDIT: all four tables OPT IN (audit_<table>, AFTER INSERT OR UPDATE OR DELETE, audit.log_change()). They are
--   human-entered through migrations, and every gallon the later views compute depends on them. The generated rule-8
--   query moves from 65 to 69 tables.
-- GRANTS, intended literal ACL of each table (asserted below as an aclexplode set, not compared with a sibling):
--   {postgres=arwdDxtm/postgres, service_role=r/postgres, db_backup_reader=r/postgres}
--   CREATE TABLE in public hands authenticated and service_role arwdDxtm by default (pg_default_acl), so every table is
--   revoked BY NAME from public, anon, authenticated and service_role, then service_role gets SELECT only. Writes come
--   from migrations (postgres) in v1. Identity sequences: revoked from the same four roles (db_backup_reader keeps its
--   default r). fn_append_only_guard: EXECUTE revoked from public, anon, authenticated, service_role (a trigger does not
--   check EXECUTE when it fires). RLS enabled on all four, no policies.
-- FKs: all ON DELETE RESTRICT, every FK served by a NON-partial index leading with its column(s):
--   vehicle_tanks_vehicle_id_idx, vehicle_tank_configurations_tank_idx, tank_sensor_installations_sensor_idx,
--   tank_sensor_installations_tank_idx. vtc_live_effective and the GiST exclusions are PARTIAL (live rows only), so
--   the check a parent DELETE runs (WHERE fk = $1) cannot use them; hence the two plain indexes (a few rows a year).
-- CHECKS refuse NaN: in Postgres 'NaN'::numeric > 0 is TRUE, so every geometry and capacity CHECK carries an upper
--   bound (diameter and offset < 5 m, capacity < 100,000 gal), which NaN fails. A NaN here would turn every fill
--   fraction and gallon figure downstream into NaN with no error.
-- LOCKS: CREATE TABLE ... REFERENCES takes SHARE ROW EXCLUSIVE on public.vehicles until COMMIT, which queues every
--   vehicles writer behind it. SET LOCAL lock_timeout = '3s' below: on 55P03 the whole file rolls back; retry it.
-- VOLUME / RETENTION: a handful of rows per tank per year. Keep everything; no partitioning.
-- VERIFY (below): literal ACL per table; anon and authenticated hold nothing; service_role SELECT only; sequences closed;
--   every FK confdeltype 'r' and served by a non-partial index leading with it; NaN refused by every geometry and
--   capacity CHECK; 0 vendor-prefixed columns; RLS on; the rule-8 query lists the 4 tables; the seed mapping by
--   asset id (sludge asset -> sludge tank, water asset -> fresh_water tank); every sensor has exactly one samsara and one
--   samsara_gateway link and 0 tank_sensor links are orphans (control: 4 links); fill fractions on the seeded geometry:
--   water 1.34 m = 51.885 %, sludge 1.14 m = 45.635 % (judges' values), water half full = 600 gal, and water at offset 0
--   misses by more than 1 pp (negative control). Behaviour (guard, exclusions, audit row, roles) is proven by the
--   rolled-back probe run before apply; see the M1-M3 probe report of 2026-10-12.
-- ROLLBACK (export first: these tables are audited but a DROP writes no audit row):
--   back up the 4 tank_sensor ESL rows to JSON and delete them;
--   drop table public.tank_sensor_installations, public.tank_sensors, public.vehicle_tank_configurations,
--     public.vehicle_tanks;  (M3 must be rolled back first: its readings reference tank_sensors)
--   drop function public.fn_append_only_guard();  (after M3's tables are gone)
--   drop extension btree_gist;  (only if nothing else uses it)
--   then M1's rollback restores the 15-value CHECK.

begin;
set local lock_timeout = '3s';

create extension if not exists btree_gist with schema extensions;

-- ------------------------------------------------------------------ 1. GUARD
create function public.fn_append_only_guard() returns trigger
language plpgsql set search_path = '' as $$
declare v_old jsonb; v_new jsonb; v_col text;
begin
  if tg_op in ('DELETE','TRUNCATE') then
    raise exception 'blocker=append_only: % on %.%', tg_op, tg_table_schema, tg_table_name using errcode = '55000';
  end if;
  v_old := to_jsonb(old); v_new := to_jsonb(new);
  foreach v_col in array coalesce(tg_argv, '{}'::text[]) loop      -- columns allowed to go NULL -> value, once
    if v_old -> v_col <> 'null'::jsonb and (v_new -> v_col) is distinct from (v_old -> v_col) then
      raise exception 'blocker=append_only: %.% may be set once', tg_table_name, v_col using errcode = '55000';
    end if;
    v_old := v_old - v_col; v_new := v_new - v_col;
  end loop;
  if v_old is distinct from v_new then
    raise exception 'blocker=append_only: UPDATE on %.%', tg_table_schema, tg_table_name using errcode = '55000';
  end if;
  return new;
end $$;
revoke all on function public.fn_append_only_guard() from public, anon, authenticated, service_role;
comment on function public.fn_append_only_guard() is
  'Tank sensors plan (2026-10-12): row trigger BEFORE UPDATE OR DELETE and statement trigger BEFORE TRUNCATE on every '
  'tank/reading table. Raises 55000 on DELETE, TRUNCATE and any UPDATE except the set-once columns named as trigger '
  'arguments (NULL -> value, once). A DROP bypasses it: export before any rollback.';

-- ------------------------------------------------------------------ 2. TABLES
create table public.vehicle_tanks (
  id          bigint generated always as identity primary key,
  vehicle_id  bigint not null references public.vehicles(id) on delete restrict,
  contents    text   not null check (contents in ('sludge','fresh_water')),
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (id, vehicle_id)                                        -- target of composite FKs
);
create unique index vehicle_tanks_one_live on public.vehicle_tanks (vehicle_id, contents) where deleted_at is null;
create index vehicle_tanks_vehicle_id_idx on public.vehicle_tanks (vehicle_id);

create table public.vehicle_tank_configurations (
  id                   bigint generated always as identity primary key,
  vehicle_tank_id      bigint not null references public.vehicle_tanks(id) on delete restrict,
  effective_from       timestamptz not null,
  shape                text not null check (shape = 'horizontal_cylinder'),   -- ponytail: widen when a strapping chart arrives (D1)
  -- every bound has an upper limit too: 'NaN'::numeric > 0 is TRUE in Postgres, and NaN fails any "<" bound
  diameter_meters      numeric(6,4) not null check (diameter_meters > 0 and diameter_meters < 5),
  sensor_offset_meters numeric(6,4) not null check (sensor_offset_meters >= 0 and sensor_offset_meters < 5), -- sensor face to max fill (Samsara "Height Offset")
  capacity_gallons     numeric(8,1) check (capacity_gallons > 0 and capacity_gallons < 100000), -- NULL = unknown, never guessed
  basis                text not null check (basis in ('fitted_from_readings','vendor_profile','owner_confirmed','measured_on_truck')),
  notes                text,
  created_at           timestamptz not null default now(),
  superseded_at        timestamptz,                                           -- this row was WRONG; a corrected row replaces it
  unique (id, vehicle_tank_id)
);
create unique index vtc_live_effective on public.vehicle_tank_configurations (vehicle_tank_id, effective_from)
  where superseded_at is null;
create index vehicle_tank_configurations_tank_idx on public.vehicle_tank_configurations (vehicle_tank_id);  -- the FK (the unique index above is partial)

create table public.tank_sensors (               -- one row per PHYSICAL LM11 device (stable: its gateway serial)
  id         bigint generated always as identity primary key,
  model      text not null check (model in ('LM11')),
  created_at timestamptz not null default now()
);

create table public.tank_sensor_installations (
  id              bigint generated always as identity primary key,
  tank_sensor_id  bigint not null references public.tank_sensors(id)  on delete restrict,
  vehicle_tank_id bigint not null references public.vehicle_tanks(id) on delete restrict,
  installed_at    timestamptz not null,
  removed_at      timestamptz,            -- physical removal or move
  superseded_at   timestamptz,            -- this row was WRONG (a correction)
  created_at      timestamptz not null default now(),
  check (removed_at is null or removed_at > installed_at),
  unique (id, vehicle_tank_id),
  constraint tsi_no_overlap_per_sensor exclude using gist
    (tank_sensor_id  with =, tstzrange(installed_at, removed_at) with &&) where (superseded_at is null),
  constraint tsi_no_overlap_per_tank exclude using gist
    (vehicle_tank_id with =, tstzrange(installed_at, removed_at) with &&) where (superseded_at is null)
);
create index tank_sensor_installations_tank_idx on public.tank_sensor_installations (vehicle_tank_id);
create index tank_sensor_installations_sensor_idx on public.tank_sensor_installations (tank_sensor_id);  -- the FK (the GiST exclusion is partial)

-- ------------------------------------------------------- 3. GUARDS AND AUDIT
create trigger vehicle_tanks_append_only before update or delete on public.vehicle_tanks
  for each row execute function public.fn_append_only_guard('deleted_at');
create trigger vehicle_tanks_no_truncate before truncate on public.vehicle_tanks
  for each statement execute function public.fn_append_only_guard();
create trigger audit_vehicle_tanks after insert or update or delete on public.vehicle_tanks
  for each row execute function audit.log_change();

create trigger vehicle_tank_configurations_append_only before update or delete on public.vehicle_tank_configurations
  for each row execute function public.fn_append_only_guard('superseded_at');
create trigger vehicle_tank_configurations_no_truncate before truncate on public.vehicle_tank_configurations
  for each statement execute function public.fn_append_only_guard();
create trigger audit_vehicle_tank_configurations after insert or update or delete on public.vehicle_tank_configurations
  for each row execute function audit.log_change();

create trigger tank_sensors_append_only before update or delete on public.tank_sensors
  for each row execute function public.fn_append_only_guard();
create trigger tank_sensors_no_truncate before truncate on public.tank_sensors
  for each statement execute function public.fn_append_only_guard();
create trigger audit_tank_sensors after insert or update or delete on public.tank_sensors
  for each row execute function audit.log_change();

create trigger tank_sensor_installations_append_only before update or delete on public.tank_sensor_installations
  for each row execute function public.fn_append_only_guard('removed_at', 'superseded_at');
create trigger tank_sensor_installations_no_truncate before truncate on public.tank_sensor_installations
  for each statement execute function public.fn_append_only_guard();
create trigger audit_tank_sensor_installations after insert or update or delete on public.tank_sensor_installations
  for each row execute function audit.log_change();

-- ------------------------------------------------------------ 4. RLS + GRANTS
alter table public.vehicle_tanks               enable row level security;
alter table public.vehicle_tank_configurations enable row level security;
alter table public.tank_sensors                enable row level security;
alter table public.tank_sensor_installations   enable row level security;

revoke all on public.vehicle_tanks, public.vehicle_tank_configurations, public.tank_sensors,
              public.tank_sensor_installations
  from public, anon, authenticated, service_role;
grant select on public.vehicle_tanks, public.vehicle_tank_configurations, public.tank_sensors,
                public.tank_sensor_installations
  to service_role;
do $g$
declare s text;
begin
  foreach s in array array[pg_get_serial_sequence('public.vehicle_tanks','id'),
                           pg_get_serial_sequence('public.vehicle_tank_configurations','id'),
                           pg_get_serial_sequence('public.tank_sensors','id'),
                           pg_get_serial_sequence('public.tank_sensor_installations','id')] loop
    execute format('revoke all on sequence %s from public, anon, authenticated, service_role', s);
  end loop;
end $g$;

comment on table public.vehicle_tanks is
  'A physical tank on a truck (sludge or fresh_water). Rule 8: AUDITED (opt-in): human-entered, every gallon depends '
  'on it. Append-only by trigger; deleted_at is set once. Tank sensors plan 2026-10-12.';
comment on table public.vehicle_tank_configurations is
  'Geometry and capacity of a tank as of effective_from (in force = live row with the largest effective_from <= t). '
  'Rule 8: AUDITED (opt-in). Insert-only; a wrong row gets superseded_at (set once) and a corrected row with the same '
  'effective_from. capacity_gallons NULL = unknown, never guessed.';
comment on table public.tank_sensors is
  'One row per physical LM11 level sensor. Its Samsara asset id and gateway serial live in entity_source_links '
  '(tank_sensor / samsara, tank_sensor / samsara_gateway). Rule 8: AUDITED (opt-in). Append-only by trigger.';
comment on table public.tank_sensor_installations is
  'Which sensor sits on which tank over [installed_at, removed_at). No overlap per sensor or per tank among live rows '
  '(GiST exclusion). Rule 8: AUDITED (opt-in). removed_at and superseded_at are set once.';

-- ------------------------------------------------------------------- 5. SEEDS
-- Mapped by Samsara asset id through entity_source_links, never by name.
do $seed$
declare
  v_vehicle       bigint;
  v_sludge_tank   bigint;
  v_water_tank    bigint;
  v_sludge_sensor bigint;
  v_water_sensor  bigint;
begin
  select entity_id into strict v_vehicle from public.entity_source_links
   where entity_type = 'vehicle' and source_system = 'samsara' and source_id = '281474998706262';
  if v_vehicle <> 1 then raise exception 'SEED: Samsara asset 281474998706262 resolves to vehicle %, expected 1', v_vehicle; end if;

  insert into public.vehicle_tanks (vehicle_id, contents) values (v_vehicle, 'sludge')      returning id into v_sludge_tank;
  insert into public.vehicle_tanks (vehicle_id, contents) values (v_vehicle, 'fresh_water') returning id into v_water_tank;

  insert into public.vehicle_tank_configurations
    (vehicle_tank_id, effective_from, shape, diameter_meters, sensor_offset_meters, capacity_gallons, basis, notes)
  values
    (v_sludge_tank, '2026-08-20 21:00:00+00', 'horizontal_cylinder', 2.1336, 0.0000, 3840.0, 'vendor_profile',
     'Samsara tank profile in force from 2026-08-20 21:00Z: 84 in horizontal cylinder, no height offset, 3,840 gal. '
     '12,510 of 12,526 same-timestamp distance/percent pairs agree within 0.01 pp; the 16 misses fall in the 08-20 setup window.'),
    (v_water_tank, '2026-10-02 17:09:00+00', 'horizontal_cylinder', 2.1336, 0.3048, 1200.0, 'owner_confirmed',
     'Capacity 1,200 US gal from the owner''s fleet note of 2026-04-24 (two tanks: 1,200 gal water, 3,800 gal grease), '
     'confirmed for use on 2026-10-12. Geometry fitted from readings: 84 in horizontal cylinder, sensor 12 in above max '
     'fill (2,431 pairs, worst error 0.0005 pp; a 2.0 m control misses by 5.34 pp). 1,200 gal = 4.17 ft of the 84 in barrel.');

  insert into public.tank_sensors (model) values ('LM11') returning id into v_sludge_sensor;
  insert into public.tank_sensors (model) values ('LM11') returning id into v_water_sensor;

  insert into public.entity_source_links
    (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
  values
    ('tank_sensor', v_sludge_sensor, 'samsara',         '281475005688801', null, 'direct_id', 1),
    ('tank_sensor', v_sludge_sensor, 'samsara_gateway', 'GZ8K-E8N-PVX',    null, 'direct_id', 1),
    ('tank_sensor', v_water_sensor,  'samsara',         '281475007025272', null, 'direct_id', 1),
    ('tank_sensor', v_water_sensor,  'samsara_gateway', 'GN4X-6TM-7BS',    null, 'direct_id', 1);

  insert into public.tank_sensor_installations (tank_sensor_id, vehicle_tank_id, installed_at)
  values (v_sludge_sensor, v_sludge_tank, '2026-08-20 14:43:00+00'),   -- first sludge readings
         (v_water_sensor,  v_water_tank,  '2026-10-02 19:29:00+00');   -- after the water unit's 17:09-19:29Z setup window
end $seed$;

-- ------------------------------------------------------------------ 6. VERIFY
do $v$
declare
  t text; s text; n int; v_diff int; v_miss numeric; v_nan_ok boolean; v_con text;
  v_tables text[] := array['vehicle_tanks','vehicle_tank_configurations','tank_sensors','tank_sensor_installations'];
  v_expected aclitem[] := '{postgres=arwdDxtm/postgres,service_role=r/postgres,db_backup_reader=r/postgres}';
  p text;
begin
  foreach t in array v_tables loop
    -- V1 literal ACL, as a set
    select count(*) into v_diff from (
      (select grantor, grantee, privilege_type, is_grantable from pg_class c, aclexplode(c.relacl)
        where c.oid = ('public.' || t)::regclass
       except select grantor, grantee, privilege_type, is_grantable from aclexplode(v_expected))
      union all
      (select grantor, grantee, privilege_type, is_grantable from aclexplode(v_expected)
       except select grantor, grantee, privilege_type, is_grantable from pg_class c, aclexplode(c.relacl)
        where c.oid = ('public.' || t)::regclass)) d;
    if v_diff <> 0 then
      raise exception 'VERIFY M2-1: public.% relacl is %', t, (select relacl::text from pg_class where oid = ('public.' || t)::regclass);
    end if;
    -- V2 role privileges, independent of who asks
    foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('anon', 'public.' || t, p) or has_table_privilege('authenticated', 'public.' || t, p) then
        raise exception 'VERIFY M2-2: anon or authenticated holds % on public.%', p, t;
      end if;
    end loop;
    if not has_table_privilege('service_role', 'public.' || t, 'SELECT') then raise exception 'VERIFY M2-2: service_role cannot read public.%', t; end if;
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE'] loop
      if has_table_privilege('service_role', 'public.' || t, p) then raise exception 'VERIFY M2-2: service_role holds % on public.%', p, t; end if;
    end loop;
    -- V3 identity sequence closed
    s := pg_get_serial_sequence('public.' || t, 'id');
    if has_sequence_privilege('authenticated', s, 'USAGE') or has_sequence_privilege('anon', s, 'SELECT')
       or has_sequence_privilege('service_role', s, 'USAGE') then
      raise exception 'VERIFY M2-3: sequence % is open', s;
    end if;
    -- V4 RLS on
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'VERIFY M2-4: RLS off on %', t; end if;
  end loop;

  -- V5 every FK restricts (4 FKs)
  select count(*) into n from pg_constraint where contype = 'f' and conrelid = any (array[
    'public.vehicle_tanks','public.vehicle_tank_configurations','public.tank_sensors','public.tank_sensor_installations']::regclass[]);
  if n <> 4 then raise exception 'VERIFY M2-5: expected 4 FKs, found %', n; end if;
  if exists (select 1 from pg_constraint where contype = 'f' and confdeltype <> 'r' and conrelid = any (array[
    'public.vehicle_tanks','public.vehicle_tank_configurations','public.tank_sensors','public.tank_sensor_installations']::regclass[])) then
    raise exception 'VERIFY M2-5: an FK is not ON DELETE RESTRICT';
  end if;
  -- V5b every FK has a NON-partial index whose leading columns are the FK columns (a parent DELETE's check cannot
  -- use a partial index)
  select string_agg(format('%s(%s)', c.conrelid::regclass, c.conkey::text), ', ') into p
    from pg_constraint c
   where c.contype = 'f' and c.conrelid = any (array['public.vehicle_tanks','public.vehicle_tank_configurations',
           'public.tank_sensors','public.tank_sensor_installations']::regclass[])
     and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indpred is null
                       and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] = c.conkey);
  if p is not null then raise exception 'VERIFY M2-5b: FK without a non-partial leading index: %', p; end if;
  -- V5c NaN is refused by each geometry and capacity CHECK, by that column's own constraint. A NaN that got in is
  -- undone by the savepoint (the guard blocks DELETE, so it could not be removed any other way).
  foreach p in array array['diameter_meters','sensor_offset_meters','capacity_gallons'] loop
    v_nan_ok := false; v_con := null;
    begin
      execute format('insert into public.vehicle_tank_configurations (vehicle_tank_id, effective_from, shape, '
                     'diameter_meters, sensor_offset_meters, capacity_gallons, basis) '
                     'select id, %L, %L, %s, %s, %s, %L from public.vehicle_tanks order by id limit 1',
                     '1900-01-01 00:00:00+00', 'horizontal_cylinder',
                     case when p = 'diameter_meters'      then '''NaN''::numeric' else '2.1336' end,
                     case when p = 'sensor_offset_meters' then '''NaN''::numeric' else '0.3048' end,
                     case when p = 'capacity_gallons'     then '''NaN''::numeric' else '1200.0' end,
                     'owner_confirmed');
      v_nan_ok := true;
      raise exception using errcode = 'P0001', message = 'm2_nan_undo';
    exception
      when check_violation then get stacked diagnostics v_con = constraint_name;
      when sqlstate 'P0001' then if sqlerrm <> 'm2_nan_undo' then raise; end if;
    end;
    if v_nan_ok then raise exception 'VERIFY M2-5c: NaN accepted in %', p; end if;
    if v_con is distinct from 'vehicle_tank_configurations_' || p || '_check' then
      raise exception 'VERIFY M2-5c: NaN in % refused by % instead of its own CHECK', p, v_con;
    end if;
  end loop;

  -- V6 no vendor-prefixed column (rule 1)
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = any (v_tables)
              and column_name ~ '^(samsara|jobber|airtable|fillout|odoo)_') then
    raise exception 'VERIFY M2-6: vendor-prefixed column';
  end if;

  -- V7 the generated rule-8 query lists all four
  select count(*) into n from pg_trigger tg join pg_proc pr on pr.oid = tg.tgfoid join pg_namespace pn on pn.oid = pr.pronamespace
   where pn.nspname = 'audit' and pr.proname = 'log_change' and not tg.tgisinternal
     and tg.tgrelid = any (array['public.vehicle_tanks','public.vehicle_tank_configurations','public.tank_sensors',
                                 'public.tank_sensor_installations']::regclass[]);
  if n <> 4 then raise exception 'VERIFY M2-7: % of 4 tables audited', n; end if;

  -- V8 guard function not executable by API roles
  if has_function_privilege('anon', 'public.fn_append_only_guard()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_append_only_guard()', 'EXECUTE')
     or has_function_privilege('service_role', 'public.fn_append_only_guard()', 'EXECUTE') then
    raise exception 'VERIFY M2-8: fn_append_only_guard is executable by an API role';
  end if;

  -- V9 ESL: control 4 links; 0 orphans; each sensor exactly one samsara + one samsara_gateway link
  select count(*) into n from public.entity_source_links where entity_type = 'tank_sensor';
  if n <> 4 then raise exception 'VERIFY M2-9: expected 4 tank_sensor links, found %', n; end if;
  if exists (select 1 from public.entity_source_links e where e.entity_type = 'tank_sensor'
              and not exists (select 1 from public.tank_sensors s where s.id = e.entity_id)) then
    raise exception 'VERIFY M2-9: orphan tank_sensor link';
  end if;
  if exists (select 1 from public.tank_sensors s where
               (select count(*) from public.entity_source_links e where e.entity_type = 'tank_sensor' and e.entity_id = s.id and e.source_system = 'samsara') <> 1
            or (select count(*) from public.entity_source_links e where e.entity_type = 'tank_sensor' and e.entity_id = s.id and e.source_system = 'samsara_gateway') <> 1) then
    raise exception 'VERIFY M2-9: a sensor lacks exactly one samsara and one samsara_gateway link';
  end if;

  -- V10 seed mapping by asset id, and the fill fraction on the seeded geometry (plan 5.1, computed inline)
  with m as (
    select e.source_id as asset, vt.vehicle_id, vt.contents, c.diameter_meters d, c.sensor_offset_meters o, c.capacity_gallons cap
      from public.entity_source_links e
      join public.tank_sensor_installations i on i.tank_sensor_id = e.entity_id and i.superseded_at is null and i.removed_at is null
      join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id and vt.deleted_at is null
      join public.vehicle_tank_configurations c on c.vehicle_tank_id = vt.id and c.superseded_at is null
     where e.entity_type = 'tank_sensor' and e.source_system = 'samsara'),
  f as (
    select m.*, x.dist,
           (select ((g.r*g.r*acos((g.r-g.h)/g.r) - (g.r-g.h)*sqrt(greatest(2*g.r*g.h - g.h*g.h, 0))) / (pi()*g.r*g.r))::numeric
              from (select m.d::float8/2 as r,
                           least(greatest((m.o + m.d - x.dist)::float8, 0), m.d::float8) as h) g) as frac
      from m cross join (values (1.34::numeric), (1.14), (1.3716)) x(dist))
  select count(*) filter (where asset = '281475007025272' and contents = 'fresh_water' and vehicle_id = 1 and dist = 1.34
                                and abs(frac * 100 - 51.885) < 0.001)
       + count(*) filter (where asset = '281475005688801' and contents = 'sludge' and vehicle_id = 1 and dist = 1.14
                                and abs(frac * 100 - 45.635) < 0.001)
       + count(*) filter (where asset = '281475007025272' and dist = 1.3716 and abs(frac - 0.5) < 0.00001
                                and round(frac * cap) = 600)
    into n from f;
  if n <> 3 then raise exception 'VERIFY M2-10: mapping or geometry check passed % of 3', n; end if;
  -- negative control: the water reading on a zero offset misses by more than 1 pp
  select abs(100 * ((g.r*g.r*acos((g.r-g.h)/g.r) - (g.r-g.h)*sqrt(greatest(2*g.r*g.h - g.h*g.h, 0))) / (pi()*g.r*g.r)) - 51.885)
    into v_miss from (select 2.1336::float8/2 as r, least(greatest((0 + 2.1336 - 1.34)::float8, 0), 2.1336) as h) g;
  if v_miss <= 1 then raise exception 'VERIFY M2-10: zero-offset control missed by only % pp', v_miss; end if;
end $v$;

commit;
