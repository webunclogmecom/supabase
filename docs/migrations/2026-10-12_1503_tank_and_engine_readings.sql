-- 2026-10-12 15:03 ET · Raw Samsara observations: tank distance and percent, engine RPM, PTO, site entry/exit (M3)
-- APPLIED to Prod 2026-10-12 (~16:50 ET), after a rolled-back dry run of this file.
-- Plan: docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md (sections 2.4, 4, 7, 10.2 M3).
--
-- WHAT (five append-only tables; the collector, a Railway cron polling Samsara /readings/history, inserts with
-- ON CONFLICT DO NOTHING as service_role; nothing updates or deletes them)
--   public.tank_sensor_distance_readings     LM11 radar distance, metres (Samsara remoteSensingDistance)
--   public.tank_sensor_fill_percent_readings Samsara's own percent: a drift witness only, never used for gallons
--   public.vehicle_engine_rpm_readings       engine RPM per truck (Samsara engineRpm)
--   public.vehicle_pto_readings              power take-off on/off per truck (Samsara ecuPowerTakeoff)
--   public.vehicle_site_events               a truck entering or leaving a dump-site or yard PROPERTY (Samsara
--                                            addressEntry/addressExit, resolved to our property through the existing
--                                            ESL property link of the Samsara address). Corrections set superseded_at once.
--
-- WHY
--   Owner voice note, 2026-10-12: "how long they stayed on that client, how much water was used, how much sludge was
--   pumped out", "how much sludge did we really pump out". Owner, 2026-10-12: "Before showing it on an app, let's work
--   on it to be correct everything in the DB, and to have a collector to gather the data, maybe a webhook or something,
--   remember it comes from Samsara, which we also already periodically gathers it's data." Samsara has no webhook that
--   streams readings (only alert webhooks and event subscriptions), so the collector polls; these tables are what it
--   writes.
--   One table per quantity: the unit is in the column name, the streams run on different clocks (sludge distance median
--   31 s, percent 288 s), and a wide row would need a column-merging upsert (the ignore-duplicates version of that lost
--   76 of 100 stats samples on vehicle_telemetry_readings). Not in vehicle_telemetry_readings: the GPS writer resumes
--   from the newest row whose odometer, fuel and engine fields are null, so engine-only rows would move it.
--
-- 3NF (key = the natural primary key; each column depends on the whole key and nothing else)
--   tank_sensor_distance_readings (tank_sensor_id, recorded_at)
--     distance_meters  the one observed value at that instant; percent and gallons are derived in views, not stored
--     created_at       arrival time (lateness), a fact of this row
--   tank_sensor_fill_percent_readings (tank_sensor_id, recorded_at)
--     fill_percent     Samsara's own value at that instant;  created_at  arrival time
--   vehicle_engine_rpm_readings (vehicle_id, recorded_at)
--     engine_rpm       observed value;  created_at  arrival time
--   vehicle_pto_readings (vehicle_id, recorded_at)
--     pto_engaged      observed value;  created_at  arrival time
--   vehicle_site_events (vehicle_id, recorded_at, property_id, event_kind)
--     created_at       arrival time;  superseded_at  this event was resolved WRONG (set once)
--   The tank a reading belongs to is NOT stored: it is resolved through the installation in force at recorded_at.
--   Known loss: 3 of 104,806 sludge distance timestamps carry two values; the key keeps the first.
--
-- RULE 8, AUDIT
--   vehicle_site_events OPTS IN (audit_vehicle_site_events): about 2 to 10 rows a day, and its corrections are human.
--   The four reading tables OPT OUT: machine-written by the collector, append-only by trigger and grant, same class as
--   vehicle_telemetry_readings (unaudited). Auditing them would double about 5,900 rows a day for no reader.
--   The generated rule-8 query moves from 69 (after M2) to 70.
-- GRANTS, intended literal ACL of each table (asserted below as an aclexplode set):
--   {postgres=arwdDxtm/postgres, service_role=ar/postgres, db_backup_reader=r/postgres}
--   Revoked BY NAME from public, anon, authenticated, service_role (CREATE TABLE in public grants authenticated and
--   service_role everything by default), then SELECT + INSERT to service_role: the collector inserts and reads its own
--   watermark, and can never UPDATE, DELETE or TRUNCATE. No identity columns, so no sequences. RLS on, no policies.
-- FKs: all ON DELETE RESTRICT; every FK is served by an index leading with it (the primary key, or
--   vehicle_site_events_property_idx for property_id).
-- LOCKS: each CREATE TABLE ... REFERENCES takes SHARE ROW EXCLUSIVE on the table it points at until COMMIT:
--   public.vehicles and public.tank_sensors, and public.properties, which the apps write (Client App saves, Jobber poll
--   replays, accept_intake_answers). Behind an open write transaction on properties this file would wait with no limit
--   and every property write would queue behind it. SET LOCAL lock_timeout = '3s' below: on 55P03 the whole file rolls
--   back; retry it. (The 2-hourly backup holds only ACCESS SHARE, which does not conflict with this lock.)
-- VOLUME / RETENTION (rows a day, from the deduplicated discovery cadences of 2026-10-12): distance about 4,473
--   (sludge 1,976 + water 2,497), percent about 648, engine RPM up to about 800, PTO about 7, site events about 2 to 6.
--   About 0.6 MB a day for the new tables. Keep everything: any delete or partition drop is a rule-6 exception (owner
--   decision D9). No partitioning (ponytail: pg_partman monthly on the distance table past 1 GB or a third sensor).
--   Backfill from 2026-08-20 14:00Z: sludge distance 104,803 rows, water 24,816; percent 18,304 and 2,969.
-- VERIFY (below): literal ACL per table; anon and authenticated hold nothing; service_role SELECT and INSERT only;
--   every FK confdeltype 'r' (6 FKs); 0 vendor-prefixed columns; RLS on; each table carries both guard triggers;
--   only vehicle_site_events is audited (positive control: it is found by the rule-8 query, and the 4 readings are not).
--   Behaviour (duplicate insert ignored, UPDATE 42501 as service_role and 55000 as postgres, superseded_at set once,
--   TRUNCATE 55000, authenticated/anon 42501) is proven by the rolled-back probe run before apply.
-- ROLLBACK, after the collector (J1) has run: export the five tables to backups\ and check counts against Prod first
--   (a DROP bypasses the append-only guard and writes no audit row; Samsara retention beyond about 53 days is unknown).
--   drop table public.vehicle_site_events, public.vehicle_pto_readings, public.vehicle_engine_rpm_readings,
--     public.tank_sensor_fill_percent_readings, public.tank_sensor_distance_readings;

begin;
set local lock_timeout = '3s';

create table public.tank_sensor_distance_readings (
  tank_sensor_id  bigint not null references public.tank_sensors(id) on delete restrict,
  recorded_at     timestamptz not null,                                   -- Samsara happenedAtTime
  distance_meters numeric(5,3) not null check (distance_meters >= 0 and distance_meters < 10),
  created_at      timestamptz not null default now(),                     -- arrival time (lateness)
  primary key (tank_sensor_id, recorded_at)
);
create table public.tank_sensor_fill_percent_readings (                   -- Samsara's own percent: drift witness only
  tank_sensor_id bigint not null references public.tank_sensors(id) on delete restrict,
  recorded_at    timestamptz not null,
  fill_percent   numeric(6,3) not null check (fill_percent between 0 and 100),
  created_at     timestamptz not null default now(),
  primary key (tank_sensor_id, recorded_at)
);
create table public.vehicle_engine_rpm_readings (
  vehicle_id  bigint not null references public.vehicles(id) on delete restrict,
  recorded_at timestamptz not null,
  engine_rpm  integer not null check (engine_rpm between 0 and 6000),
  created_at  timestamptz not null default now(),
  primary key (vehicle_id, recorded_at)
);
create table public.vehicle_pto_readings (
  vehicle_id  bigint not null references public.vehicles(id) on delete restrict,
  recorded_at timestamptz not null,
  pto_engaged boolean not null,
  created_at  timestamptz not null default now(),
  primary key (vehicle_id, recorded_at)
);
create table public.vehicle_site_events (
  vehicle_id    bigint not null references public.vehicles(id)   on delete restrict,
  property_id   bigint not null references public.properties(id) on delete restrict,   -- a dump-site or yard property
  recorded_at   timestamptz not null,
  event_kind    text not null check (event_kind in ('entry','exit')),
  created_at    timestamptz not null default now(),
  superseded_at timestamptz,
  primary key (vehicle_id, recorded_at, property_id, event_kind)
);
create index vehicle_site_events_property_idx on public.vehicle_site_events (property_id, recorded_at);

-- ------------------------------------------------------- GUARDS AND AUDIT
create trigger tank_sensor_distance_readings_append_only before update or delete on public.tank_sensor_distance_readings
  for each row execute function public.fn_append_only_guard();
create trigger tank_sensor_distance_readings_no_truncate before truncate on public.tank_sensor_distance_readings
  for each statement execute function public.fn_append_only_guard();

create trigger tank_sensor_fill_percent_readings_append_only before update or delete on public.tank_sensor_fill_percent_readings
  for each row execute function public.fn_append_only_guard();
create trigger tank_sensor_fill_percent_readings_no_truncate before truncate on public.tank_sensor_fill_percent_readings
  for each statement execute function public.fn_append_only_guard();

create trigger vehicle_engine_rpm_readings_append_only before update or delete on public.vehicle_engine_rpm_readings
  for each row execute function public.fn_append_only_guard();
create trigger vehicle_engine_rpm_readings_no_truncate before truncate on public.vehicle_engine_rpm_readings
  for each statement execute function public.fn_append_only_guard();

create trigger vehicle_pto_readings_append_only before update or delete on public.vehicle_pto_readings
  for each row execute function public.fn_append_only_guard();
create trigger vehicle_pto_readings_no_truncate before truncate on public.vehicle_pto_readings
  for each statement execute function public.fn_append_only_guard();

create trigger vehicle_site_events_append_only before update or delete on public.vehicle_site_events
  for each row execute function public.fn_append_only_guard('superseded_at');
create trigger vehicle_site_events_no_truncate before truncate on public.vehicle_site_events
  for each statement execute function public.fn_append_only_guard();
create trigger audit_vehicle_site_events after insert or update or delete on public.vehicle_site_events
  for each row execute function audit.log_change();

-- ------------------------------------------------------------ RLS + GRANTS
alter table public.tank_sensor_distance_readings     enable row level security;
alter table public.tank_sensor_fill_percent_readings enable row level security;
alter table public.vehicle_engine_rpm_readings       enable row level security;
alter table public.vehicle_pto_readings              enable row level security;
alter table public.vehicle_site_events               enable row level security;

revoke all on public.tank_sensor_distance_readings, public.tank_sensor_fill_percent_readings,
              public.vehicle_engine_rpm_readings, public.vehicle_pto_readings, public.vehicle_site_events
  from public, anon, authenticated, service_role;
grant select, insert on public.tank_sensor_distance_readings, public.tank_sensor_fill_percent_readings,
                        public.vehicle_engine_rpm_readings, public.vehicle_pto_readings, public.vehicle_site_events
  to service_role;

comment on table public.tank_sensor_distance_readings is
  'LM11 radar distance (metres) per sensor and Samsara happenedAtTime. Written by the Samsara readings collector '
  '(service_role, ON CONFLICT DO NOTHING). Append-only by trigger and grant. Rule 8: NOT audited (opt-out): '
  'machine-written raw feed, same class as vehicle_telemetry_readings. Tank sensors plan 2026-10-12.';
comment on table public.tank_sensor_fill_percent_readings is
  'Samsara''s own fill percent per sensor: a drift witness only, never used to compute gallons. Append-only. '
  'Rule 8: NOT audited (opt-out): machine-written raw feed.';
comment on table public.vehicle_engine_rpm_readings is
  'Engine RPM per truck (Samsara engineRpm). Append-only. Rule 8: NOT audited (opt-out): machine-written raw feed. '
  'Kept out of vehicle_telemetry_readings because the GPS writer resumes from rows with null engine fields.';
comment on table public.vehicle_pto_readings is
  'Power take-off engaged per truck (Samsara ecuPowerTakeoff, on = true). Append-only. Rule 8: NOT audited (opt-out): '
  'machine-written raw feed.';
comment on table public.vehicle_site_events is
  'A truck entering or leaving a dump-site or yard property (Samsara addressEntry/addressExit resolved to our property '
  'through the ESL link of the Samsara address). Append-only; superseded_at is set once when a resolution was wrong. '
  'Rule 8: AUDITED (opt-in): a few rows a day, corrections are human.';

-- ------------------------------------------------------------------ VERIFY
do $v$
declare
  t text; n int; v_diff int; p text;
  v_tables text[] := array['tank_sensor_distance_readings','tank_sensor_fill_percent_readings',
                           'vehicle_engine_rpm_readings','vehicle_pto_readings','vehicle_site_events'];
  v_expected aclitem[] := '{postgres=arwdDxtm/postgres,service_role=ar/postgres,db_backup_reader=r/postgres}';
begin
  foreach t in array v_tables loop
    select count(*) into v_diff from (
      (select grantor, grantee, privilege_type, is_grantable from pg_class c, aclexplode(c.relacl)
        where c.oid = ('public.' || t)::regclass
       except select grantor, grantee, privilege_type, is_grantable from aclexplode(v_expected))
      union all
      (select grantor, grantee, privilege_type, is_grantable from aclexplode(v_expected)
       except select grantor, grantee, privilege_type, is_grantable from pg_class c, aclexplode(c.relacl)
        where c.oid = ('public.' || t)::regclass)) d;
    if v_diff <> 0 then
      raise exception 'VERIFY M3-1: public.% relacl is %', t, (select relacl::text from pg_class where oid = ('public.' || t)::regclass);
    end if;
    foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('anon', 'public.' || t, p) or has_table_privilege('authenticated', 'public.' || t, p) then
        raise exception 'VERIFY M3-2: anon or authenticated holds % on public.%', p, t;
      end if;
    end loop;
    if not has_table_privilege('service_role', 'public.' || t, 'SELECT')
       or not has_table_privilege('service_role', 'public.' || t, 'INSERT') then
      raise exception 'VERIFY M3-2: service_role lacks SELECT or INSERT on public.%', t;
    end if;
    foreach p in array array['UPDATE','DELETE','TRUNCATE'] loop
      if has_table_privilege('service_role', 'public.' || t, p) then raise exception 'VERIFY M3-2: service_role holds % on public.%', p, t; end if;
    end loop;
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'VERIFY M3-3: RLS off on %', t; end if;
    select count(*) into n from pg_trigger where tgrelid = ('public.' || t)::regclass and not tgisinternal
       and tgfoid = 'public.fn_append_only_guard()'::regprocedure;
    if n <> 2 then raise exception 'VERIFY M3-4: public.% has % guard triggers, expected 2', t, n; end if;
  end loop;

  select count(*) into n from pg_constraint where contype = 'f' and conrelid = any (
    array(select ('public.' || x)::regclass from unnest(v_tables) x));
  if n <> 6 then raise exception 'VERIFY M3-5: expected 6 FKs, found %', n; end if;
  if exists (select 1 from pg_constraint where contype = 'f' and confdeltype <> 'r'
              and conrelid = any (array(select ('public.' || x)::regclass from unnest(v_tables) x))) then
    raise exception 'VERIFY M3-5: an FK is not ON DELETE RESTRICT';
  end if;

  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = any (v_tables)
              and column_name ~ '^(samsara|jobber|airtable|fillout|odoo)_') then
    raise exception 'VERIFY M3-6: vendor-prefixed column';
  end if;

  select count(*) into n from pg_trigger tg join pg_proc pr on pr.oid = tg.tgfoid join pg_namespace pn on pn.oid = pr.pronamespace
   where pn.nspname = 'audit' and pr.proname = 'log_change' and not tg.tgisinternal
     and tg.tgrelid = any (array(select ('public.' || x)::regclass from unnest(v_tables) x));
  if n <> 1 or not exists (select 1 from pg_trigger where tgrelid = 'public.vehicle_site_events'::regclass
                                                        and tgname = 'audit_vehicle_site_events') then
    raise exception 'VERIFY M3-7: expected exactly vehicle_site_events audited, found % audited', n;
  end if;
end $v$;

commit;
