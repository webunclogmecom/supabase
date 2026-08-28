-- 2026-08-28_1210_employee_colour_separation.sql
--
-- Re-picks all 9 ACTIVE employee colours so no two are confusable at avatar size, and repairs a
-- rule violation this same session introduced three hours earlier in `2026-08-28_1027`.
--
-- WHY. Fred, 2026-08-28: "Also please make the colors to not be close to each other like the case
-- of Aaron and Michael that looks close to each other."
--
-- He named one pair. Measured in CIEDE2000 (perceptual distance; under ~15 is confusable in a 14px
-- circle) there were FOUR, and the one he spotted was the worst-but-three:
--
--     Yannick  #10B981 vs Serena   #14B8A6   dE 10.7   <- worst, both teal-green
--     Diego    #D946EF vs Anthony  #8B5CF6   dE 13.4
--     Grecia   #EC4899 vs Mark     #F43F5E   dE 14.6
--     Aaron    #3B82F6 vs Michael  #0EA5E9   dE 14.8   <- the one Fred reported
--
-- THE RULE `2026-08-28_1027` BROKE, which is the more important half of this migration.
-- That migration (mine) gave Fred **#F59E0B, which IS the DUMP Schedule "Homestead" amber**,
-- dE 0.0, byte-identical. That app's rule #10 is "one hue, one job", and its rule #16 states the
-- driver colours were picked specifically to avoid the load-bearing hues. A driver row and the
-- Homestead door reading the same colour at 2 AM through water is a 45-mile drive into the wrong
-- county. Yannick's #10B981 was also only dE 10.1 from the "GO" green.
-- Neither was caught because `2026-08-28_1027` verified UNIQUENESS AMONG EMPLOYEES and never asked
-- whether a colour collided with a hue that already means something else somewhere else.
-- ⇒ Uniqueness inside your own set is not separation. Check the neighbours too. Assertion 5 below
--   is that missing check, and it is the reason this file exists rather than a tweak to the last one.
--
-- HOW THESE WERE CHOSEN (not by eye; `scratchpad/pick3.js`):
--   candidates  Tailwind 400-900 across the 17 chromatic ramps. Greys are excluded: neutral grey is
--               the "no colour assigned" fallback, so no person may ever be grey.
--   constraints white-text contrast >= 4.5:1 · at least dE 20 from every DUMP load-bearing hue
--               (Homestead #F59E0B, Pompano #22D3EE, GO #16A34A, selection #F14714)
--               · at least dE 20 from the grey fallback · at least dE 10 from every
--               `public.zones.color_hex` · one hue family per person
--
--   objective   maximise the MINIMUM pairwise distance; then among the sets achieving that floor,
--               minimise how far each person moves, so identities survive the change
--   pinned      Michael Escobar stays in the sky family. He is the reference Fred has been looking
--               at all day and #0EA5E9 is written into five documents, so moving him to the brown
--               the unpinned optimiser preferred (dE 56.5) was the maximum-churn answer. Aaron
--               leaves the blue family instead. Michael moves dE 22.0, still plainly the same blue
--               identity, and his white-text contrast improves from 2.77:1 to 5.93:1.
--
-- THE ZONE CONSTRAINT IS THE ONE NOBODY HAD CHECKED, AND IT WAS ALREADY VIOLATED.
-- The avatar is drawn ON the zone-tinted chip. Aaron's old **#3B82F6 was dE 1.1 from the SOUTH
-- zone fill #2D7FF9**: on a SOUTH chip his avatar was very nearly the colour of the chip behind it.
-- Michael's old #0EA5E9 was dE 14.3 from WEST #77D1F3.
-- ⚠ The zone bar is 10, not 20, and that number is evidence-based rather than arbitrary: the avatar
-- carries `ring-1 ring-white/60`, a white ring that already separates it from whatever it sits on.
-- So zone proximity only has to avoid NEAR-IDENTITY; person-vs-person is the binding constraint.
-- Requiring 20 here forced Aaron to a brown and cost more than it bought.
-- ⚠ Note the live `public.zones.color_hex` values are PALE TINTS (#C0F0F0, #FFEAB6, ...), NOT the
-- saturated hexes printed in `Building Apps/03-brand-and-design-system.md`. That doc is stale on
-- this point; query the table.
--
-- RESULT
--   worst pair             dE 10.7  ->  17.8    (1.7x)
--   Aaron vs Michael       dE 14.8  ->  17.8    (the pair Fred reported; now the closest pair,
--                                     but navy vs sky differ in lightness as well as hue)
--   nearest load-bearing   dE  0.0  ->  21.5    (0.0 was Fred BEING Homestead amber)
--   nearest zone colour    dE  1.1  ->  14.0    (1.1 was Aaron BEING the SOUTH chip fill)
--   white-text contrast   2.15:1    ->  4.60:1 minimum; colours below 3:1 went from 4 to 0.
--                                     every one of the 9 now clears WCAG AA for normal text.
--
-- Every person keeps a NAMEABLE hue family (pink, yellow, blue, lime, fuchsia, red, purple, sky,
-- teal), because "the blue one" is how people actually refer to these. A set optimised on distance
-- alone scored better and read worse: it produced nine muddy darks.
--
-- Rule 8 (audit): `public.employees` already carries the `audit_employees` trigger, so every row
-- below is captured with its old value. Opt-in already in place, no change needed.

begin;

update public.employees set color_hex = '#DB2777' where id = 1;   -- Grecia          pink-600
update public.employees set color_hex = '#A16207' where id = 2;   -- Fred            yellow-700  (was Homestead amber)
update public.employees set color_hex = '#1E3A8A' where id = 26;  -- Aaron           blue-900    (moved off Michael's blue)
update public.employees set color_hex = '#3F6212' where id = 27;  -- Yannick         lime-800    (was near the GO green)
update public.employees set color_hex = '#701A75' where id = 28;  -- Diego           fuchsia-900
update public.employees set color_hex = '#991B1B' where id = 35;  -- Mark            red-800
update public.employees set color_hex = '#9333EA' where id = 37;  -- Anthony         purple-600
update public.employees set color_hex = '#0369A1' where id = 40;  -- Michael Escobar sky-700     (kept blue, deepened)
update public.employees set color_hex = '#0F766E' where id = 42;  -- Serena Natali   teal-700

-- VERIFY ---------------------------------------------------------------------------------------
do $$
declare
  bad text := '';
  v_active int; v_coloured int; v_dupes int; v_bad_hex int; v_load int; v_grey int;
  expected jsonb := '{"1":"#DB2777","2":"#A16207","26":"#1E3A8A","27":"#3F6212","28":"#701A75",
                      "35":"#991B1B","37":"#9333EA","40":"#0369A1","42":"#0F766E"}'::jsonb;
  k text;
begin
  select count(*), count(color_hex) into v_active, v_coloured
    from public.employees where status = 'ACTIVE';

  -- 1. every ACTIVE employee still has a colour: this migration must not blank anyone
  if v_coloured <> v_active then
    bad := bad || (v_active - v_coloured) || ' active employees have no colour; ';
  end if;

  -- 2. every intended value actually landed
  for k in select jsonb_object_keys(expected) loop
    if (select color_hex from public.employees where id = k::int)
         is distinct from (expected ->> k) then
      bad := bad || 'employee ' || k || ' is not ' || (expected ->> k) || '; ';
    end if;
  end loop;

  -- 3. still unique
  select count(*) into v_dupes from (
    select color_hex from public.employees
    where status = 'ACTIVE' and color_hex is not null
    group by color_hex having count(*) > 1) d;
  if v_dupes > 0 then bad := bad || v_dupes || ' colour(s) shared by more than one person; '; end if;

  -- 4. a real #RRGGBB, not a Tailwind class name. Non-null is NOT the test: 'bg-rose-500' would
  --    pass a null check and break every consumer.
  select count(*) into v_bad_hex from public.employees
   where color_hex is not null and color_hex !~ '^#[0-9A-Fa-f]{6}$';
  if v_bad_hex > 0 then bad := bad || v_bad_hex || ' colour(s) are not #RRGGBB; '; end if;

  -- 5. THE CHECK `2026-08-28_1027` DID NOT HAVE, and the reason this migration exists.
  --    No person may wear a hue that already means something else in the DUMP Schedule.
  --    Exact match only; the dE >= 20 clearance was enforced when the palette was chosen.
  select count(*) into v_load from public.employees
   where status = 'ACTIVE'
     and upper(color_hex) in ('#F59E0B','#22D3EE','#16A34A','#F14714');
  if v_load > 0 then
    bad := bad || v_load || ' employee(s) wear a DUMP load-bearing hue (Homestead/Pompano/GO/selection); ';
  end if;

  -- 6. nobody is grey: grey is reserved to mean "this person has no colour assigned"
  select count(*) into v_grey from public.employees
   where status = 'ACTIVE'
     and upper(color_hex) in ('#9CA3AF','#6B7280','#64748B','#94A3B8');
  if v_grey > 0 then bad := bad || v_grey || ' employee(s) are grey, which is the no-colour fallback; '; end if;

  -- 7. no person may wear a ZONE colour: the avatar sits ON the zone-tinted chip, and Aaron's old
  --    #3B82F6 was dE 1.1 from the SOUTH fill. Exact match here; dE >= 10 enforced at pick time.
  if exists (select 1 from public.employees e join public.zones z on upper(z.color_hex) = upper(e.color_hex)
              where e.status = 'ACTIVE') then
    bad := bad || 'an employee wears a zone colour; ';
  end if;

  if bad <> '' then raise exception 'employee colour separation FAILED: %', bad; end if;
  raise notice 'verified: % active employees, all coloured, unique, #RRGGBB, no load-bearing hue, none grey', v_active;
end $$;

commit;
