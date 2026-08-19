-- ============================================================================
-- 2026-08-18_2218 - v_visit_city_email: does this visit's city have a regulator inbox?
-- ============================================================================
-- Fred, 2026-08-18, on the Admin Review send section: "let's do like put the button of
-- sending to the city, and disable it, and when hovered show that message instead. Same
-- as if it doesn't have a city email, show the button disabled and put a tooltip that
-- says 'No city email'."
--
-- The app had no way to answer "does this visit have a city email". It never reads
-- public.municipality_regulators, and it CANNOT: authenticated holds no grant on that
-- table (measured). This view is the answer, and the shape is deliberate:
--
--   🛑 IT EXPOSES A BOOLEAN, NEVER THE ADDRESSES. An owner-rights view (NOT
--   security_invoker) launders the table grant, so a signed-in staff browser learns
--   whether an inbox exists without being able to read the regulator emails themselves.
--   Adding a grant on municipality_regulators instead would have handed every staff user
--   the actual inboxes to satisfy a tooltip.
--
-- ⚠ WHAT THIS WILL LOOK LIKE ON DAY ONE, measured before shipping, and Fred chose it
-- with these numbers in hand ("gate it now on real data"): only TWO regulators are on
-- file, Hallandale Beach and Surfside, so of 280 DERM-required completed visits in the
-- last 90 days only 45 (16%) resolve to a city email. The other 235 will render the
-- Send button DISABLED with "No city email". That is the true state of the data, not a
-- defect in this view: the table is simply not filled in yet. Sending is still in test
-- mode (send-visit-photos-email pins IS_TEST = true and a hard-wired recipient), so the
-- gate blocks test sends too. Filling in municipality_regulators is what re-enables them.
--
-- MATCHING: property city = regulator municipality, case- and whitespace-insensitive,
-- ACTIVE only, and the regulator must hold at least one address containing '@'. County
-- is deliberately NOT a fallback: both regulators are Broward/Dade, so a county match
-- would resolve 273 of 280 visits and cheerfully route a Miami visit to the Surfside
-- inbox. A wrong regulator is worse than a missing one.
--
-- AUDIT (rule 8): a VIEW, so nothing to opt in or out of; no table is created here and
-- no existing trigger is touched. public.municipality_regulators is unchanged.
--
-- Reads v_visits_live, so soft-deleted visits never appear (CLAUDE.md canonical base).
-- ============================================================================

create or replace view public.v_visit_city_email as
select v.id                                    as visit_id,
       p.city                                  as property_city,
       r.municipality                          as regulator_municipality,
       (r.municipality is not null)            as city_email_on_file
  from public.v_visits_live v
  left join public.properties p on p.id = v.property_id
  left join lateral (
    select mr.municipality
      from public.municipality_regulators mr
     where mr.status = 'ACTIVE'
       and p.city is not null
       and lower(btrim(mr.municipality)) = lower(btrim(p.city))
       and exists (select 1 from unnest(mr.emails) e where e is not null and position('@' in e) > 0)
     order by mr.municipality
     limit 1
  ) r on true;

comment on view public.v_visit_city_email is
  'Per-visit: does the property city have an ACTIVE municipality_regulators row with a real email? '
  'Boolean only - the addresses are never exposed. Feeds the Admin Review "No city email" tooltip.';

-- Grants. 🛑 Supabase ALTER DEFAULT PRIVILEGES hands new objects in `public` to anon, so
-- the revoke is the load-bearing statement here, not the grant (CLAUDE.md).
revoke all on public.v_visit_city_email from public;
revoke all on public.v_visit_city_email from anon;
grant select on public.v_visit_city_email to authenticated, service_role;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $verify$
declare
  fail text := '';
  v_total int; v_true int; v_surfside int; v_miami_true int;
begin
  -- 1. the view resolves for every alive visit (no row loss vs the base)
  select count(*) into v_total from public.v_visit_city_email;
  if v_total <> (select count(*) from public.v_visits_live) then
    fail := fail || format('row count %s <> v_visits_live; ', v_total);
  end if;

  -- 2. POSITIVE CONTROL: a Surfside visit must read TRUE. Without this, "everything is
  --    false" would look like a working gate while actually being a broken join.
  select count(*) into v_surfside
    from public.v_visit_city_email e
   where lower(btrim(e.property_city)) = 'surfside' and e.city_email_on_file;
  if v_surfside = 0 then
    fail := fail || 'no Surfside visit reads TRUE - the join is not matching; ';
  end if;

  -- 3. NEGATIVE CONTROL: a city with no regulator must read FALSE.
  select count(*) into v_miami_true
    from public.v_visit_city_email e
   where lower(btrim(e.property_city)) = 'miami' and e.city_email_on_file;
  if v_miami_true > 0 then
    fail := fail || format('%s Miami visits read TRUE but Miami has no regulator; ', v_miami_true);
  end if;

  -- 4. the flag is never null (the app branches on it)
  if exists (select 1 from public.v_visit_city_email where city_email_on_file is null) then
    fail := fail || 'city_email_on_file is null somewhere; ';
  end if;

  -- 5. anon must NOT be able to read it; authenticated must
  if has_table_privilege('anon', 'public.v_visit_city_email', 'SELECT') then
    fail := fail || 'anon can read the view; ';
  end if;
  if not has_table_privilege('authenticated', 'public.v_visit_city_email', 'SELECT') then
    fail := fail || 'authenticated cannot read the view; ';
  end if;

  -- 6. and it must still be an OWNER-RIGHTS view, or authenticated would get 42501 on
  --    municipality_regulators, which it holds no grant on.
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname='public' and c.relname='v_visit_city_email'
                and array_to_string(c.reloptions, ',') like '%security_invoker=true%') then
    fail := fail || 'view is security_invoker, so the caller needs a grant it does not have; ';
  end if;

  select count(*) into v_true from public.v_visit_city_email where city_email_on_file;
  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'v_visit_city_email: % visits, % with a city email on file', v_total, v_true;
end
$verify$;

select count(*)                                          as visits,
       count(*) filter (where city_email_on_file)        as with_city_email,
       count(*) filter (where not city_email_on_file)    as without_city_email,
       count(distinct property_city) filter (where city_email_on_file) as cities_covered
  from public.v_visit_city_email;
