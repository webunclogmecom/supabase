-- Rollback of 2026-11-02_2030_retire_pso_permit_type.sql: the trigger body before it (verbatim), PSO active again,
-- row 141 ACTIVE again. The appended note is kept on purpose (it records what happened); remove it by hand if wanted.
begin;
set local lock_timeout = '3s';

CREATE OR REPLACE FUNCTION public.fn_permit_number_matches_type()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pattern text;
  v_name    text;
begin
  -- 2026-11-02 (permits one table). An INACTIVE row is history and keeps whatever it holds (rows 29, 157, 164).
  if new.status = 'INACTIVE' then
    return new;
  end if;
  -- The DERM readers that test gdo_number ~ '^GDO-[0-9]+$' rely on this: only a GDO permit may carry a GDO number.
  if new.permit_type <> 'GDO' and new.gdo_number ~* '^[[:space:]]*GDO' then
    raise exception 'A number starting with GDO is a Miami-Dade GDO permit. Choose the GDO type, or change the number.'
      using errcode = '22023', detail = 'blocker=gdo_number_needs_gdo_type in public.fn_permit_number_matches_type';
  end if;
  select t.number_pattern, t.name into v_pattern, v_name from public.permit_types t where t.code = new.permit_type;
  if v_pattern is not null and new.gdo_number !~ v_pattern then
    if new.permit_type = 'GDO' then
      raise exception 'A GDO permit number looks like GDO-12345: GDO, a dash, then digits.'
        using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
    end if;
    raise exception 'The number % is not in the % format.', new.gdo_number, v_name
      using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
  end if;
  return new;
end;
$function$;

update public.permit_types set status = 'ACTIVE' where code = 'PSO';
-- The appended note is required: trg_aa_gdos_guard_demoted silently keeps a demoted row INACTIVE unless the same write
-- appends to its notes.
update public.gdos set status = 'ACTIVE', notes = notes || E'\n[rollback of 2026-11-02_2030] PSO restored.'
 where id = 141 and permit_type = 'PSO';

do $verify$
begin
  if not exists (select 1 from public.gdos where id = 141 and status = 'ACTIVE') then
    raise exception 'VERIFY: row 141 is not ACTIVE again';
  end if;
  if md5(pg_get_functiondef('public.fn_permit_number_matches_type()'::regprocedure)) <> '37d798b9fe3893cfb9fa48da45e36cdb' then
    raise exception 'VERIFY: the restored body does not match the pre-migration md5';
  end if;
end
$verify$;

commit;
