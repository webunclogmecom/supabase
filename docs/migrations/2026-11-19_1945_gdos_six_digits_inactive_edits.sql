-- 2026-11-19_1945 Trello #227 follow-up: the 6-digit rule also covers a NEW or CHANGED GDO number on an INACTIVE permit.
-- Found in the live check after 2026-11-19_1935: GDO-04156 typed on 112-YA's inactive permit 209 was saved (the trigger
-- skipped every INACTIVE row; that skip exists so history rows 29, 157, 164 keep values nobody edits). Restored by hand in
-- the app at 7:37 PM ET. Now only an inactive row whose number is unchanged is skipped. Rollback beside this file.

begin;
do $g$ begin
  if md5(pg_get_functiondef('public.fn_permit_number_matches_type()'::regprocedure)) <> '142ae6297a8790c3b44bcc6143d6bd57' then
    raise exception 'GUARD: fn_permit_number_matches_type changed since this file was written';
  end if;
end $g$;

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
  v_digits text;        -- 2026-11-19 Trello #227
  v_fix    text;
begin
  -- 2026-11-02 (permits one table). An INACTIVE row is history and keeps whatever it holds (rows 29, 157, 164).
  -- 2026-11-19 Trello #227 follow-up: ... but a NEW or CHANGED GDO number is checked on any status (Fred: "when there
  -- are more or less than 6 digits throw the error mentioning it"). Found live: GDO-04156 typed on the inactive 112-YA
  -- permit was saved. An inactive row whose number is not touched keeps whatever it holds, as before.
  if new.status = 'INACTIVE'
     and not (new.permit_type = 'GDO'
              and (tg_op = 'INSERT' or new.gdo_number is distinct from old.gdo_number)) then
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
      -- 2026-11-19 Trello #227 (Fred: "One form, 6 digits ... when there are more or less than 6 digits throw the
      -- error mentioning it"). The sentence names the count, and the fix when the number fits in 6 digits.
      v_digits := substring(upper(btrim(new.gdo_number)) from '^GDO-?([0-9]+)$');
      if v_digits is not null then
        v_fix := case when length(v_digits) >= 5 and length(ltrim(v_digits, '0')) between 1 and 6
                      then 'GDO-' || lpad(ltrim(v_digits, '0'), 6, '0') end;
        raise exception '%', format('%s has %s digits. A GDO permit number is GDO- and 6 digits, as the county prints it%s.',
            btrim(new.gdo_number), length(v_digits),
            case when v_fix is not null then ': type ' || v_fix else ' (like GDO-014769)' end)
          using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
      end if;
      raise exception 'A GDO permit number is GDO- and 6 digits, as the county prints it (like GDO-014769).'
        using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
    end if;
    raise exception 'The number % is not in the % format.', new.gdo_number, v_name
      using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
  end if;
  return new;
end;
$function$;

do $verify$
begin
  -- an inactive GDO permit given a 5-digit number is refused; the same row saved with its own number passes
  begin
    update public.gdos set gdo_number = 'GDO-04156' where id = 209;
    raise exception 'VERIFY: a 5-digit number on an inactive permit was accepted';
  exception when sqlstate '22023' then
    if sqlerrm not like 'GDO-04156 has 5 digits.%' then raise exception 'VERIFY: wrong sentence: %', sqlerrm; end if;
  end;
  begin   -- history rows, number untouched: pass (undone, so updated_at is not touched)
    update public.gdos set notes = notes where id in (29, 157, 164);
    raise exception using errcode = 'P0099', message = 'undo the history check';
  exception when sqlstate 'P0099' then null;
  end;
end
$verify$;

commit;
