-- ROLLBACK of 2026-11-03_1700_leads_schema_m1 (frozen leads, step M1).
-- Valid ONLY before the first load (no rows in leads.*, no 'source_record' links). After a load it destroys data:
-- back up the leads tables and the source_record links to the workspace backups/ folder and get Fred's OK first.
-- Undo M2 (2026-11-03_rollback_leads_m2.sql) before this one, and revert backup.sh's SCHEMAS line first, or every
-- backup dump fails its --strict-names check.
begin;
set local lock_timeout = '3s';

do $pre$
begin
  if exists (select 1 from public.entity_source_links where entity_type = 'source_record') then
    raise exception 'leads M1 rollback: source_record links exist; back them up and remove them first (Fred''s OK)';
  end if;
  if exists (select 1 from leads.source_records) or exists (select 1 from leads.establishments) then
    raise exception 'leads M1 rollback: leads holds data; back it up first (Fred''s OK)';
  end if;
  if md5((select prosrc from pg_proc where oid = 'public.rls_auto_enable()'::regprocedure)) <> '89ec942fa505043d284b59455fa8e797' then
    raise exception 'leads M1 rollback: rls_auto_enable changed since M1; edit by hand';
  end if;
end $pre$;

drop schema leads cascade;

do $rls$
declare d text; a text := $a$'customer', 'hr', 'leads')$a$; b text := $b$'customer', 'hr')$b$;
begin
  select pg_get_functiondef('public.rls_auto_enable()'::regprocedure) into d;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'anchor not found once'; end if;
  execute replace(d, a, b);
  if md5((select prosrc from pg_proc where oid = 'public.rls_auto_enable()'::regprocedure)) <> '408c99c84a11a1e4acba0cc60c9bdace' then
    raise exception 'leads M1 rollback: rls_auto_enable not restored';
  end if;
end $rls$;

alter table public.entity_source_links drop constraint entity_source_links_entity_type_chk;
alter table public.entity_source_links add constraint entity_source_links_entity_type_chk check (entity_type = any (array[
  'client','derm_manifest','employee','inspection','invoice','job','line_item','note','photo','property','quote',
  'vehicle','visit','calendar_day_marker','calendar_task','tank_sensor','time_entry']));

do $verify$
begin
  if md5((select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.entity_source_links'::regclass
            and conname = 'entity_source_links_entity_type_chk')) <> '7f67c04c71e907fb4ed1ed7443c24dee' then
    raise exception 'leads M1 rollback VERIFY: CHECK not restored to the 17 values';
  end if;
  if exists (select 1 from pg_namespace where nspname = 'leads') then raise exception 'schema leads still exists'; end if;
end $verify$;

commit;
