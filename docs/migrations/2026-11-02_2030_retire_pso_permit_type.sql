-- 2026-11-02_2030_retire_pso_permit_type.sql
-- Fred, 2026-11-02 evening, on the Client App Add permit dialog: "we don't have a PSO miami remove it, i know some
-- clients have it, so we need to fix that."
--
-- MEASURED before writing: exactly ONE row uses PSO, public.gdos 141, 057-BAY (Bayshore Executive Plaza, a lift
-- station), PSO-00025, ACTIVE, with a PDF. Its own notes: "newest doc 2018, expired 2019-09-30; written per Fred
-- 2026-07-08". No other row holds a PSO-looking number (checked every non-GDO number, any status).
--
-- THE RULE, not just the row (root CLAUDE.md section 7):
--   1. public.permit_types PSO -> status INACTIVE. client.permit_types (the app's type picker) already shows only
--      ACTIVE types, and client.upsert_gdo_permit already refuses a type that is not ACTIVE. Not deleted: row 141 keeps
--      its FK, and the history keeps its meaning.
--   2. public.fn_permit_number_matches_type: a permit that is not INACTIVE must have an ACTIVE type
--      (blocker=permit_type_retired). Without it a direct write could put 141 back to ACTIVE as a PSO, measured below
--      with the old body as the control.
--   3. gdos 141 -> INACTIVE (soft delete, rule 6), reason appended to its notes. customer.permits (Field Portal) shows
--      only ACTIVE permits, so 057-BAY's portal stops showing it. The PDF stays in storage.
-- Not touched: client.gdos (every status, so the Client App can still show the retired row as inactive history),
-- fn_gdo_permit_label_targets (reads_pdf, PSO never read), every DERM reader (GDO only).
-- Rollback: 2026-11-02_rollback_retire_pso_permit_type.sql.
begin;
set local lock_timeout = '3s';

do $guard$
begin
  if md5(pg_get_functiondef('public.fn_permit_number_matches_type()'::regprocedure)) <> '37d798b9fe3893cfb9fa48da45e36cdb' then
    raise exception 'fn_permit_number_matches_type changed since this migration was written; stop and look';
  end if;
  if (select count(*) from public.gdos where permit_type = 'PSO') <> 1
     or not exists (select 1 from public.gdos where id = 141 and permit_type = 'PSO' and gdo_number = 'PSO-00025' and status = 'ACTIVE')
     or not exists (select 1 from public.permit_types where code = 'PSO' and status = 'ACTIVE') then
    raise exception 'PSO is not in the measured state (one ACTIVE row, id 141); stop and look';
  end if;
end
$guard$;

-- 3. the one PSO permit
update public.gdos
   set status = 'INACTIVE',
       notes = notes || E'\n[2026-11-02] Retired: UnclogMe does not handle PSO permits (Fred: "we don''t have a PSO miami remove it"). The permit expired 2019-09-30; the PDF stays on file.'
 where id = 141 and permit_type = 'PSO' and status = 'ACTIVE';

-- 1. the type
update public.permit_types set status = 'INACTIVE' where code = 'PSO';

-- CONTROL, old body: a direct write CAN still bring 141 back as an ACTIVE PSO (so step 2 is needed)
do $control$
begin
  begin
    update public.gdos set status = 'ACTIVE', notes = notes || ' [test] deliberate reactivation' where id = 141;  -- appended note: the demotion guard (trg_aa_gdos_guard_demoted, fires first) silently keeps the status otherwise
    if (select status from public.gdos where id = 141) <> 'ACTIVE' then
      raise exception 'control: the write did not change the status (a guard kept it), so this control tests nothing';
    end if;
    raise exception 'control_passed';
  exception when others then
    if sqlerrm <> 'control_passed' then
      raise exception 'CONTROL: the old body was expected to allow the write, got: %', sqlerrm;
    end if;
  end;
end
$control$;

-- 2. the rule (copied from the live body, md5 pinned above; three lines added, marked)
CREATE OR REPLACE FUNCTION public.fn_permit_number_matches_type()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pattern text;
  v_name    text;
  v_type_status text;   -- 2026-11-02_2030
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
  select t.number_pattern, t.name, t.status into v_pattern, v_name, v_type_status from public.permit_types t where t.code = new.permit_type;
  -- 2026-11-02_2030 (Fred: "we don't have a PSO miami remove it"): a retired type stays only on INACTIVE rows.
  if v_type_status is not null and v_type_status <> 'ACTIVE' then
    raise exception 'We no longer use % permits. Pick another permit type, or mark this permit inactive.', v_name
      using errcode = '22023', detail = 'blocker=permit_type_retired in public.fn_permit_number_matches_type';
  end if;
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

do $verify$
declare v_err text;
begin
  -- the type list the app shows
  if (select string_agg(code, ',' order by code) from client.permit_types) is distinct from 'CCN,GDO' then
    raise exception 'VERIFY: client.permit_types is %, expected CCN,GDO', (select string_agg(code, ',' order by code) from client.permit_types);
  end if;
  -- the row
  if not exists (select 1 from public.gdos where id = 141 and status = 'INACTIVE' and notes like '%[2026-06-28 cleanup]%' and notes like '%[2026-11-02] Retired%') then
    raise exception 'VERIFY: row 141 is not INACTIVE with its old notes kept and the reason appended';
  end if;
  if exists (select 1 from public.gdos where permit_type = 'PSO' and status <> 'INACTIVE') then
    raise exception 'VERIFY: a live PSO permit remains';
  end if;
  if exists (select 1 from customer.permits where permit_type = 'PSO') then
    raise exception 'VERIFY: the Field Portal still shows a PSO permit';
  end if;
  if not exists (select 1 from client.gdos where id = 141) then
    raise exception 'VERIFY: client.gdos lost row 141 (it must stay visible as inactive history)';
  end if;
  -- the rule: the same write as the control now fails with the new blocker
  begin
    update public.gdos set status = 'ACTIVE', notes = notes || ' [test] deliberate reactivation' where id = 141;  -- appended note: the demotion guard (trg_aa_gdos_guard_demoted, fires first) silently keeps the status otherwise
    v_err := 'none';
  exception when others then
    get stacked diagnostics v_err = pg_exception_detail;
  end;
  if v_err is distinct from 'blocker=permit_type_retired in public.fn_permit_number_matches_type' then
    raise exception 'VERIFY: reactivating 141 as a PSO was not refused by the new rule (got %)', v_err;
  end if;
  -- an active type still saves (the CCN test permit on 112-YA, a no-op write)
  begin
    update public.gdos set notes = notes where id = 294;
  exception when others then
    raise exception 'VERIFY: an ACTIVE CCN permit can no longer be saved: %', sqlerrm;
  end;
end
$verify$;

commit;
