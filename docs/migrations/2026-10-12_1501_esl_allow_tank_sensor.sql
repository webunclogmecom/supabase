-- 2026-10-12 15:01 ET · entity_source_links: allow entity_type 'tank_sensor' (tank sensors plan, step M1)
-- APPLIED to Prod 2026-10-12 (~16:50 ET), after a rolled-back dry run of this file.
-- docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md (sections 3.1, 10.2 M1).
--
-- WHAT
--   Widens entity_source_links_entity_type_chk from its 15 live values to 16 by adding 'tank_sensor', so each LM11
--   level sensor (a row of public.tank_sensors, created in M2) can carry its Samsara asset id and its gateway serial in
--   the bridge table instead of in a vendor column (rule 1). Every live value is kept, copied from
--   pg_get_constraintdef on 2026-10-12, not retyped from memory.
--   source_system has NO check constraint (measured 2026-10-12: the only constraints on the table are the PK and this
--   CHECK; no trigger, no domain), so 'samsara_gateway' needs no change here. Live source_system values today:
--   jobber, airtable, samsara, fillout, manual.
--
-- WHY
--   Owner voice note, 2026-10-12: "we need to know what kind of information we can get from it" and "everything needs to
--   be linked. No orphans." The unique index (entity_type, entity_id, source_system) allows one samsara link per
--   entity, and a vehicle's samsara slot already holds the truck gateway, so a sensor needs its own entity type.
--
-- 3NF: no column added or changed.
-- RULE 7 (widening a CHECK can switch on a dormant reader), measured 2026-10-12 on Prod:
--   function bodies naming 'tank_sensor' 0, view definitions 0; 'samsara_gateway' 0 and 0.
--   Positive control: function bodies naming 'calendar_task' (a value already in the list) = 2.
--   Re-run at apply; a non-zero count on 'tank_sensor' means a reader already waits for these rows: stop and read it.
-- RULE 8: no table created; entity_source_links stays unaudited (zero triggers, unchanged). A DELETE of a tank_sensor
--   link therefore leaves no record: back it up to JSON first (rule 6 note).
-- GRANTS: unchanged (ALTER TABLE does not touch relacl).
-- VOLUME: one constraint, about 34,000 rows re-checked under the lock (milliseconds). lock_timeout 3s: retry if the
--   2-hourly backup dump (HH:17 UTC, even hours) holds the table.
-- VERIFY (below, inside the transaction): a 'tank_sensor' row inserts and is removed again (savepoint), 'bogus_type'
--   fails 23514 (positive control that the CHECK still binds), and the new definition is exactly the 15 live
--   values plus 'tank_sensor' (md5 of the full text, so an extra or misspelled value fails as well).
-- ROLLBACK: only after M2's tank_sensor ESL rows are backed up and deleted:
--   alter table public.entity_source_links drop constraint entity_source_links_entity_type_chk;
--   alter table public.entity_source_links add constraint entity_source_links_entity_type_chk check (entity_type = any
--     (array['client','derm_manifest','employee','inspection','invoice','job','line_item','note','photo','property',
--            'quote','vehicle','visit','calendar_day_marker','calendar_task']));

begin;
set local lock_timeout = '3s';

do $pre$
declare v_def text;
begin
  select pg_get_constraintdef(oid) into v_def from pg_constraint
   where conrelid = 'public.entity_source_links'::regclass and conname = 'entity_source_links_entity_type_chk';
  if md5(v_def) <> md5('CHECK ((entity_type = ANY (ARRAY[''client''::text, ''derm_manifest''::text, ''employee''::text, ''inspection''::text, ''invoice''::text, ''job''::text, ''line_item''::text, ''note''::text, ''photo''::text, ''property''::text, ''quote''::text, ''vehicle''::text, ''visit''::text, ''calendar_day_marker''::text, ''calendar_task''::text])))') then
    raise exception 'entity_source_links_entity_type_chk changed since this migration was written: %', v_def;
  end if;
  if exists (select 1 from pg_constraint where conrelid = 'public.entity_source_links'::regclass and contype = 'c'
              and conname <> 'entity_source_links_entity_type_chk') then
    raise exception 'entity_source_links gained another CHECK since 2026-10-12; read it before widening';
  end if;
end $pre$;

alter table public.entity_source_links drop constraint entity_source_links_entity_type_chk;
alter table public.entity_source_links add constraint entity_source_links_entity_type_chk check (entity_type = any (array[
  'client','derm_manifest','employee','inspection','invoice','job','line_item','note','photo','property','quote',
  'vehicle','visit','calendar_day_marker','calendar_task',
  'tank_sensor']));

-- VERIFY
do $v$
declare v_def text; v_ok boolean := false;
begin
  select pg_get_constraintdef(oid) into v_def from pg_constraint
   where conrelid = 'public.entity_source_links'::regclass and conname = 'entity_source_links_entity_type_chk'
     and convalidated;
  if v_def is null then raise exception 'VERIFY M1-1: constraint missing or not validated'; end if;
  -- exactly the 15 live values plus tank_sensor, in this order: pinned by md5 like the $pre$ block, so a stray or
  -- misspelled extra value fails too (a presence count would pass it)
  if md5(v_def) <> md5('CHECK ((entity_type = ANY (ARRAY[''client''::text, ''derm_manifest''::text, ''employee''::text, ''inspection''::text, ''invoice''::text, ''job''::text, ''line_item''::text, ''note''::text, ''photo''::text, ''property''::text, ''quote''::text, ''vehicle''::text, ''visit''::text, ''calendar_day_marker''::text, ''calendar_task''::text, ''tank_sensor''::text])))') then
    raise exception 'VERIFY M1-2: constraint is not exactly the 15 live values plus tank_sensor: %', v_def;
  end if;
  begin                                                     -- a tank_sensor row is accepted
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
    values ('tank_sensor', -1, 'samsara', 'verify-m1-' || txid_current());
    v_ok := true;
    raise exception using errcode = 'P0001', message = 'm1_undo';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'm1_undo' then raise; end if;
  end;
  if not v_ok then raise exception 'VERIFY M1-3: tank_sensor row was not accepted'; end if;
  begin                                                     -- positive control: the CHECK still binds
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id)
    values ('bogus_type', -1, 'samsara', 'verify-m1-bogus');
    raise exception 'VERIFY M1-4: bogus_type was accepted';
  exception when check_violation then null;
  end;
end $v$;

commit;
