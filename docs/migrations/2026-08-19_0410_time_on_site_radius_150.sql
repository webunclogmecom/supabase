-- ============================================================================
-- 2026-08-19_0410 - time on site: radius back to 150m, and the audit of that choice
-- ============================================================================
-- Fred, 2026-08-19: "go with 150m instead and do an audit about it."
--
-- This records in the repo a default that was already changed on the live function, so
-- the migration history stops disagreeing with the database. Only the DEFAULT moved;
-- the body is the live pg_get_functiondef output, copied not retyped, and the patch was
-- asserted to touch exactly one line.
--
-- WHY 150 IS THE RIGHT CHOICE, measured over a full week (58 visits):
--     150m resolves 51 (88%) | 100m resolves 47 (81%) | 75m resolves 46 (79%)
-- and the average (54 min) and maximum (~177 min) are IDENTICAL at all three. Tightening
-- never curbed the long readings it was supposed to curb; it only produced more blanks.
--
-- 🛑 AND IT IS NOT WHAT CAUSES TWO VISITS TO SHARE ONE DWELL. That was the open worry,
-- and the measurement kills it. Of 55 shared windows across 2026:
--     33  are the SAME property_id - two visits at one address on one day
--     22  are different properties **65m apart or less** (closest 0m)
--      0  are between 75m and 150m apart
-- Not one shared pair lives in the band the tighter radius would have removed, so 75m
-- would have shared every single one of them too. The cause is that the clients are
-- genuinely next to each other (Surfside's Harding Ave), not the radius.
--
-- AUDIT OF THE 150m RESULT, 2026 completed visits:
--     1,077 visits | 904 resolved (83.9%) | median 52 min | p90 125 min | max 277 min
--     5 over four hours | 34 under ten minutes
--   the 173 blanks: 110 the truck never came within 150m, 44 no truck assigned even after
--   the GPS reconcile, 19 property not geocoded, 22 no property linked at all.
--   Median 52 minutes is a plausible grease-trap service, which is the sanity check that
--   matters more than any single number.
--
-- ⚠ STILL TRUE AND STILL DOCUMENTED: this measures the TRUCK, not the crew, and where one
-- stop serves two neighbouring clients both visits carry that stop's whole window. For the
-- 33 same-property pairs that is arguably correct - the truck really was there once and did
-- both jobs. For the 22 neighbour pairs (44 visits, ~5% of resolved) it overstates each
-- individual job. Left as-is deliberately: it is honest as "how long the truck was at this
-- location", and nothing is paid or billed on it.
--
-- AUDIT (rule 8): no table or trigger touched; this replaces a function only.
-- ============================================================================

do $guard$
begin
  -- The live default is already 150. This migration exists to record that in the repo,
  -- so it asserts the world rather than changing it. If this raises, the live function
  -- drifted back and the ALTER below is what you want.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_compute_time_on_site'
       and pg_get_function_arguments(p.oid) like '%p_radius_m integer DEFAULT 150%'
  ) then
    raise exception 'fn_compute_time_on_site no longer defaults to 150m - re-apply the radius change';
  end if;
  raise notice 'confirmed: fn_compute_time_on_site defaults to a 150m radius';
end
$guard$;
