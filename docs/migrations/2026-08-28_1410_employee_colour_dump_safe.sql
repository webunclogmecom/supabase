-- 2026-08-28_1410_employee_colour_dump_safe.sql
--
-- CORRECTS `2026-08-28_1210` (mine, 2 hours earlier), which made every driver's name UNREADABLE in
-- the DUMP Schedule. Third and final colour migration of the day; read this one, not that one.
--
-- WHAT I BROKE. `2026-08-28_1210` re-picked the nine employee colours to maximise separation while
-- requiring 4.5:1 for the WHITE INITIAL drawn ON the colour in the Visit Calendar avatar. That
-- forces every colour DARK. But the DUMP Schedule renders `color_hex` the other way round: it is
-- the driver's NAME, 24-30px bold, drawn on a near-black night screen
-- (`dump-visit-create` -> `color: he(e.color_hex)`), and `he` is a pure hex VALIDATOR
-- (`e => e && me.test(e) ? e : 'var(--dump-ink)'`) with no contrast adaptation whatsoever.
-- So whatever is stored is exactly what a driver reads at 2 AM, in the rain, one-handed.
--
--     driver name as text on the DUMP night screen     BEFORE 1210   AFTER 1210
--     failures at WCAG AA (4.5:1)                        0 of 9       9 of 9
--
-- 🛑 THE TWO USES ARE MATHEMATICALLY INCOMPATIBLE AT 4.5:1, so this is a real trade and not a bug
-- to fix by trying harder. White-on-colour >= 4.5:1 requires relative luminance L <= 0.183;
-- colour-on-black >= 4.5:1 requires L >= 0.190. The interval is EMPTY. One bar has to yield, and it
-- must be the avatar's: the initial sits in a white-ringed chip (a UI component, WCAG SC 1.4.11,
-- 3:1) and is redundant with the element's `title` and the name printed beside it, whereas the DUMP
-- name is the only thing on that screen and a mis-read sends a truck 45 miles to the wrong county.
--
-- ⚠ WHAT MADE IT SOLVABLE: the two contexts do not cover the same people. DUMP's picker is
-- `role='Technician' OR id IN (1,26,28)` (`dump-visit-create/index.ts` line 745-749), i.e.
-- **Grecia, Aaron, Diego, Mark, Anthony, Michael Escobar**. Fred (Office), Yannick (Owner) and
-- Serena (Admin) never render there at all, so they are free to be dark. Same for the load-bearing
-- hues: amber/cyan/green/orange only MEAN Homestead/Pompano/GO/selection INSIDE the DUMP Schedule,
-- so only those six can be confused with them. Constraining the other three bought nothing and cost
-- most of the candidate pool.
--
-- CONSTRAINTS ACTUALLY APPLIED (`scratchpad/pick5.js`)
--   all nine    white initial on the chip >= 2.15:1 (today's own minimum, so no regression)
--               at least dE 18 from the grey "no colour" fallback
--               at least dE 10 from every `public.zones.color_hex` (the avatar is drawn ON the
--               zone-tinted chip; Aaron's old #3B82F6 was dE 1.1 from the SOUTH fill #2D7FF9)
--               one hue family per person
--   the six     name-as-text on black >= 4.5:1  AND  at least dE 15 from the four load-bearing hues
--   objective   maximise the MINIMUM pairwise CIEDE2000 distance, then among the sets achieving
--               that floor, minimise how far each person moves
--
-- RESULT, every axis measured, none regressed
--   worst pair                 dE 10.7  ->  14.7
--   Aaron vs Michael (Fred's)  dE 14.8  ->  > 22    (pink vs sky)
--   DUMP name on black        0 failing ->  0 failing, minimum 4.97:1
--   load-bearing (the six)     dE  0.0  ->  16.3    (0.0 was Fred BEING Homestead amber)
--   zone colours               dE  1.1  ->  14.3    (1.1 was Aaron BEING the SOUTH chip fill)
--   avatar white text         2.15:1    ->  2.46:1
--
-- ⚠ 14.7 is the CEILING while the avatar draws white text unconditionally, not a target I settled
-- for. The band that serves both apps is only L in [0.19, 0.30] and it cannot hold nine
-- well-separated hues. **Letting the avatar choose black-or-white text by luminance removes the
-- constraint entirely and raises the achievable floor to 26.4.** That is an app change, it is small,
-- and it is the right next step; it is deliberately NOT bundled into a database migration.
--
-- ⚠ Michael Escobar returns to #0EA5E9, the value he has had all along.
--
-- Rule 8 (audit): `public.employees` carries `audit_employees`; every row below is captured.

begin;

update public.employees set color_hex = '#E879F9' where id = 1;   -- Grecia          fuchsia-400  DUMP
update public.employees set color_hex = '#3F6212' where id = 2;   -- Fred            lime-800     office only
update public.employees set color_hex = '#EC4899' where id = 26;  -- Aaron           pink-500     DUMP, off Michael's blue
update public.employees set color_hex = '#CA8A04' where id = 27;  -- Yannick         yellow-600   office only
update public.employees set color_hex = '#A855F7' where id = 28;  -- Diego           purple-500   DUMP
update public.employees set color_hex = '#F87171' where id = 35;  -- Mark            red-400      DUMP
update public.employees set color_hex = '#14B8A6' where id = 37;  -- Anthony         teal-500     DUMP
update public.employees set color_hex = '#0EA5E9' where id = 40;  -- Michael Escobar sky-500      DUMP, unchanged from the start
update public.employees set color_hex = '#164E63' where id = 42;  -- Serena Natali   cyan-900     office only

-- VERIFY ---------------------------------------------------------------------------------------
do $$
declare
  bad text := '';
  v_active int; v_coloured int; v_dupes int; v_bad_hex int; v_load int; v_grey int;
  -- the six who actually render in the DUMP Schedule driver picker
  dump_ids int[] := array[1, 26, 28, 35, 37, 40];
  expected jsonb := '{"1":"#E879F9","2":"#3F6212","26":"#EC4899","27":"#CA8A04","28":"#A855F7",
                      "35":"#F87171","37":"#14B8A6","40":"#0EA5E9","42":"#164E63"}'::jsonb;
  k text;
  v_lum numeric; r numeric; g numeric; b numeric; rec record;
begin
  select count(*), count(color_hex) into v_active, v_coloured
    from public.employees where status = 'ACTIVE';
  if v_coloured <> v_active then
    bad := bad || (v_active - v_coloured) || ' active employees have no colour; ';
  end if;

  for k in select jsonb_object_keys(expected) loop
    if (select color_hex from public.employees where id = k::int)
         is distinct from (expected ->> k) then
      bad := bad || 'employee ' || k || ' is not ' || (expected ->> k) || '; ';
    end if;
  end loop;

  select count(*) into v_dupes from (
    select color_hex from public.employees
    where status = 'ACTIVE' and color_hex is not null
    group by color_hex having count(*) > 1) d;
  if v_dupes > 0 then bad := bad || v_dupes || ' colour(s) shared by more than one person; '; end if;

  select count(*) into v_bad_hex from public.employees
   where color_hex is not null and color_hex !~ '^#[0-9A-Fa-f]{6}$';
  if v_bad_hex > 0 then bad := bad || v_bad_hex || ' colour(s) are not #RRGGBB; '; end if;

  -- 🛑 THE ASSERTION THIS MIGRATION EXISTS FOR. Every DUMP-visible driver's name must clear 4.5:1
  --    as text on the near-black night screen. Relative luminance per WCAG, sRGB gamma expanded.
  --    `2026-08-28_1210` had no check of this kind and shipped 9 of 9 unreadable.
  for rec in select id, full_name, color_hex from public.employees
              where id = any(dump_ids) and color_hex is not null loop
    r := ('x' || substr(rec.color_hex, 2, 2))::bit(8)::int / 255.0;
    g := ('x' || substr(rec.color_hex, 4, 2))::bit(8)::int / 255.0;
    b := ('x' || substr(rec.color_hex, 6, 2))::bit(8)::int / 255.0;
    r := case when r <= 0.04045 then r / 12.92 else power((r + 0.055) / 1.055, 2.4) end;
    g := case when g <= 0.04045 then g / 12.92 else power((g + 0.055) / 1.055, 2.4) end;
    b := case when b <= 0.04045 then b / 12.92 else power((b + 0.055) / 1.055, 2.4) end;
    v_lum := 0.2126 * r + 0.7152 * g + 0.0722 * b;
    -- against pure black the ratio is (L + 0.05) / 0.05
    if (v_lum + 0.05) / 0.05 < 4.5 then
      bad := bad || rec.full_name || ' (' || rec.color_hex || ') is unreadable as DUMP name text, '
                 || round((v_lum + 0.05) / 0.05, 2) || ':1; ';
    end if;
  end loop;

  -- no DUMP-visible driver may wear a load-bearing hue (exact match; dE 15 enforced at pick time)
  select count(*) into v_load from public.employees
   where id = any(dump_ids) and upper(color_hex) in ('#F59E0B','#22D3EE','#16A34A','#F14714');
  if v_load > 0 then bad := bad || v_load || ' DUMP driver(s) wear a load-bearing hue; '; end if;

  -- nobody is grey (grey means "no colour assigned"), and nobody wears a zone colour
  select count(*) into v_grey from public.employees
   where status = 'ACTIVE' and upper(color_hex) in ('#9CA3AF','#6B7280','#64748B','#94A3B8');
  if v_grey > 0 then bad := bad || v_grey || ' employee(s) are grey; '; end if;
  if exists (select 1 from public.employees e join public.zones z
               on upper(z.color_hex) = upper(e.color_hex) where e.status = 'ACTIVE') then
    bad := bad || 'an employee wears a zone colour; ';
  end if;

  if bad <> '' then raise exception 'DUMP-safe colour verification FAILED: %', bad; end if;
  raise notice 'verified: % active employees; all 6 DUMP drivers readable on black; none grey, none on a zone or load-bearing hue', v_active;
end $$;

commit;
