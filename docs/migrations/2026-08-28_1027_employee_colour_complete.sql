-- 2026-08-28_1027_employee_colour_complete.sql
--
-- Gives the last two active employees a colour, so `public.employees.color_hex` covers every person
-- who can appear as a visit driver.
--
-- WHY NOW. Fred, 2026-08-28: the "M" avatar for Michael Escobar was sky blue on the Calendar grid
-- chip and RED in the drawer. The grid was right (it reads the canonical colour); the drawer was
-- hardcoding a palette. While fixing the app it turned out two people had no canonical colour at all
-- and would fall through to whatever the fallback is:
--
--     Fred     (Office)  color_hex NULL, driver on 4 visits
--     Yannick  (Owner)   color_hex NULL, driver on 2 visits
--
-- Neither is a technician, but both really do appear as the driver on real rows, so leaving them
-- uncoloured means the one rule ("a person is the same colour everywhere") has two exceptions.
--
-- 🛑 `public.employees.color_hex` IS THE SINGLE SOURCE OF TRUTH for a person's colour across every
-- app. Established 2026-07-17 (`2026-07-17_employees_color_hex.sql`). Never hardcode a per-person
-- colour in an app, and never derive one by hashing a name: a hash silently reassigns everybody the
-- day a new person is added, and it cannot agree with another app that hashes differently.
--
-- COLOURS CHOSEN: amber and emerald, the two Tailwind-500 hues furthest from the seven already in
-- use. Verified distinct below; they are cosmetic and Fred can change them at any time.

begin;

update public.employees set color_hex = '#F59E0B' where id = 2  and color_hex is null;  -- Fred, amber
update public.employees set color_hex = '#10B981' where id = 27 and color_hex is null;  -- Yannick, emerald

-- ─── VERIFY ───────────────────────────────────────────────────────────────────────────────────
do $$
declare
  bad text := '';
  v_active int; v_coloured int; v_dupes int; v_bad_hex int; v_fred text; v_yan text;
begin
  select count(*), count(color_hex) into v_active, v_coloured
    from public.employees where status = 'ACTIVE';

  -- 1. every ACTIVE employee now has a colour
  if v_coloured <> v_active then
    bad := bad || (v_active - v_coloured) || ' active employees still have no colour; ';
  end if;

  -- 2. 🛑 colours must be UNIQUE, or the whole point (tell people apart at a glance) is lost
  select count(*) into v_dupes from (
    select color_hex from public.employees
    where status = 'ACTIVE' and color_hex is not null
    group by color_hex having count(*) > 1
  ) d;
  if v_dupes > 0 then bad := bad || v_dupes || ' colour(s) are shared by more than one person; '; end if;

  -- 3. every value is a real 6-digit hex, not a Tailwind class name or a stray word.
  --    Non-null is NOT the test: 'rose' or 'bg-rose-500' would pass that and break every consumer.
  select count(*) into v_bad_hex from public.employees
   where color_hex is not null and color_hex !~ '^#[0-9A-Fa-f]{6}$';
  if v_bad_hex > 0 then bad := bad || v_bad_hex || ' colour(s) are not #RRGGBB; '; end if;

  -- 4. the two rows this migration exists to set
  select color_hex into v_fred from public.employees where id = 2;
  select color_hex into v_yan  from public.employees where id = 27;
  if v_fred is distinct from '#F59E0B' then bad := bad || 'Fred is ' || coalesce(v_fred,'null') || '; '; end if;
  if v_yan  is distinct from '#10B981' then bad := bad || 'Yannick is ' || coalesce(v_yan,'null') || '; '; end if;

  -- 5. the one that must not have moved: Michael, the colour that started this
  if (select color_hex from public.employees where id = 40) is distinct from '#0EA5E9' then
    bad := bad || 'Michael Escobar is no longer #0EA5E9; ';
  end if;

  if bad <> '' then raise exception 'employee colour verification FAILED: %', bad; end if;
  raise notice 'verified: % active employees, all coloured, all unique, all #RRGGBB', v_active;
end $$;

commit;
