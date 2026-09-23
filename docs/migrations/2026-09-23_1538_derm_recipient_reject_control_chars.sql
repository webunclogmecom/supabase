-- 2026-09-23 15:38 ET
-- 1. client.fn_derm_recipients: TRIM the address it returns, and REFUSE one containing a control
--    character. 2. Clean the 10 stored contact emails carrying stray whitespace.
--
-- 🛑 WHY. `btrim(x)` with one argument strips SPACES ONLY -- it does NOT strip a newline. Measured:
-- length(E'\nabc@x.com\n') is 11 and length(btrim(E'\nabc@x.com\n')) is also 11. Every whitespace
-- guard in this function was `btrim`, so a newline-wrapped address:
--   * passed the non-empty filter,
--   * de-duped as a DIFFERENT value from its own clean form (so one address could be returned
--     twice, once padded and once not),
--   * and was returned RAW into the To list of an email.
-- A newline inside an address is the shape of a mail-header injection, so this is a guard, not
-- tidiness.
--
-- Found from 176-SOU, whose second contact card holds `E'\nWhatsoupmiami@gmail.com\n'` -- legacy
-- import data that exists only on our side (Jobber has zero contacts on that client). Fleet-wide
-- there are TEN such rows in two DISJOINT sets of five: five space-padded (which `btrim` does
-- catch) and five carrying newlines (which it does not). None currently holds a communication
-- preference, so nothing is being mis-sent today; this closes it before one is ticked.
--
-- ⚠ TRIM AND REFUSE ARE DIFFERENT JOBS AND BOTH ARE NEEDED. Trimming fixes a padded address.
-- Refusing catches one with a control character in the MIDDLE, which no amount of trimming makes
-- safe. The existing comma guard (`not like '%,%'`) already refuses the four comma bags and is
-- left exactly as it is.
--
-- ⚠ The four comma bags keep their commas. Splitting one is a human decision about who should
-- receive what, not a cleanup -- 089-COW is both a comma bag AND newline-wrapped, so it is
-- trimmed here and still refused by the comma guard afterwards.
--
-- Body spliced from the live definition (md5 5307a8361937adb58d88bf986eeeade8), never retyped.
-- Every other byte is unchanged; the diff is the four whitespace expressions plus one new
-- conjunct.

begin;

-- ── PART 1: the function ──────────────────────────────────────────────────────────────────────
create or replace function client.fn_derm_recipients(p_client_id bigint, p_override_primary_email text default null::text)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'pg_catalog'
as $function$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.src, t.contact_id), '[]'::jsonb)
  from (
    select distinct on (lower(btrim(email, E' \t\n\r\f\v')))
           src, contact_id, display_name, btrim(email, E' \t\n\r\f\v') as email
    from (
      select 'ours'::text as src, cc.id as contact_id,
             coalesce(nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)),''), cc.name) as display_name,
             case when p_override_primary_email is not null
                   and cc.property_id is null and cc.contact_role = 'primary'
                  then p_override_primary_email else cc.email end as email
        from public.client_communication_prefs p
        join public.client_contacts cc on cc.id = p.contact_id
       where p.client_id = p_client_id and p.comm_type = 'service_report'
      union all
      select 'jobber'::text, jc.id,
             coalesce(nullif(btrim(jc.name),''),
                      nullif(btrim(concat_ws(' ', jc.first_name, jc.last_name)),'')),
             jc.email
        from public.client_communication_prefs p
        join public.client_jobber_contacts jc on jc.id = p.jobber_contact_id
       where p.client_id = p_client_id and p.comm_type = 'service_report'
         and jc.deleted_at is null        -- removed in Jobber = not a recipient
    ) u
    where coalesce(btrim(u.email, E' \t\n\r\f\v'),'') <> ''
      and u.email not like '%,%'
      -- 🛑 a control character ANYWHERE in the address, not just at the ends. Trimming cannot make
      -- an embedded newline safe, and a newline in a To header is how extra headers get injected.
      and u.email !~ '[[:cntrl:]]'
    order by lower(btrim(u.email, E' \t\n\r\f\v')), u.src, u.contact_id
  ) t;
$function$;

-- ── PART 2: the stored values ─────────────────────────────────────────────────────────────────
-- Predicate is value-based, so it cannot fire on a row that is already clean, and re-running is
-- a no-op. Commas and internal structure are untouched.
update public.client_contacts
   set email = btrim(email, E' \t\n\r\f\v')
 where email is not null
   and email <> btrim(email, E' \t\n\r\f\v');

-- ── VERIFY ────────────────────────────────────────────────────────────────────────────────────
do $v$
declare
  n_dirty int; n_nl int; n_ya int; ctrl_bad boolean; ctrl_ok boolean; n_sou int;
begin
  select count(*) into n_dirty from public.client_contacts
   where email is not null and email <> btrim(email, E' \t\n\r\f\v');
  select count(*) into n_nl from public.client_contacts where email ~ '[\n\r]';

  -- BEHAVIOUR PRESERVED on clean data: 112-YA resolved to exactly 1 recipient before this ran.
  select jsonb_array_length(client.fn_derm_recipients(381)) into n_ya;

  -- MUTATION CONTROL: the new conjunct must DISCRIMINATE, not just exist.
  select (E'\nx@y.com' ~ '[[:cntrl:]]') into ctrl_bad;   -- must be TRUE  (refused)
  select ('x@y.com'    ~ '[[:cntrl:]]') into ctrl_ok;    -- must be FALSE (allowed)

  -- the row that started this: 176-SOU's second contact
  select count(*) into n_sou from public.client_contacts
   where id = 260 and email = 'Whatsoupmiami@gmail.com';

  raise notice 'dirty=% newline=% ya_recipients=% ctrl_bad=% ctrl_ok=% sou_clean=%',
    n_dirty, n_nl, n_ya, ctrl_bad, ctrl_ok, n_sou;

  if n_dirty <> 0 then raise exception 'expected 0 contact emails with stray whitespace, found %', n_dirty; end if;
  if n_nl    <> 0 then raise exception 'expected 0 contact emails containing a newline, found %', n_nl; end if;
  if n_ya    <> 1 then raise exception '112-YA resolved to % recipients, expected 1 - the change altered clean data', n_ya; end if;
  if not ctrl_bad then raise exception 'the control-character guard does NOT match a newline address - it is a no-op'; end if;
  if ctrl_ok      then raise exception 'the control-character guard matches a CLEAN address - it would refuse everything'; end if;
  if n_sou   <> 1 then raise exception 'contact 260 (176-SOU) was not cleaned'; end if;
end $v$;

commit;
