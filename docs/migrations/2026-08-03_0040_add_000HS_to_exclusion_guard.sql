-- ============================================================================
-- 2026-08-03_0040 — Add 000-HS to the generation exclusion guard
-- ============================================================================
-- Fred: "Also add 000-HS to that guard of exclusion list."
--
-- The guard is the list of test / non-serviceable accounts that must NEVER
-- auto-generate visits, and it is applied even when the code is named
-- explicitly, so a stray manual run cannot touch them either.
--   was: 112-YA, 777-YA (Yan's test restaurants), 000-DH (Homestead Dump)
--   now: + 000-HS
--
-- ⚠ 000-HS DOES NOT EXIST IN public.clients TODAY. Added anyway, as asked, so
-- the guard is in place before the account is created rather than after it has
-- already generated something. The whole 000- series is currently:
--     000-DH  Homestead Dump   ACTIVE   (excluded)
--     000-DP  DUMP Pompano     ACTIVE   (NOT excluded)
--
-- ⚠ SURFACED FOR FRED, NOT ADDED UNILATERALLY: 000-DP "DUMP Pompano" is a
-- disposal site of exactly the same character as the already-excluded 000-DH,
-- and it is NOT on the guard. Measured today it is harmless - ACTIVE status, no
-- Service Agreement job carrying a frequency, 0 cron visits - so adding it would
-- change nothing now and would only prevent a future surprise. It is a real
-- client row, so the decision is Fred's, not mine.
--
-- The literal appears THREE times in the function (generation scope, cleanup scope,
-- and the scope_note message) and all three are updated. My first attempt asserted
-- TWO and the assertion caught it, which is why the assertion is there: the third
-- site is the user-facing explanation, and leaving it stale would have told a user
-- 000-HS was fine when generation refused it. Generation and cleanup are kept
-- identical so a visit can never be made by one predicate and swept by the other.
-- ============================================================================
begin;

do $mig$
declare
  v_src text;
  v_new text;
  v_hits int;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_generate_sa_visits';

  -- count before, so a silent no-op replacement is impossible
  v_hits := (length(v_src) - length(replace(v_src, '''112-YA'',''777-YA'',''000-DH''', '')))
            / length('''112-YA'',''777-YA'',''000-DH''');
  if v_hits <> 3 then
    raise exception 'expected the exclusion literal exactly 3 times (generation scope, cleanup scope, scope_note message), found % — inspect before editing', v_hits;
  end if;

  v_new := replace(v_src,
                   '''112-YA'',''777-YA'',''000-DH''',
                   '''112-YA'',''777-YA'',''000-DH'',''000-HS''');
  execute v_new;
end
$mig$;

-- prove both call sites moved
do $chk$
declare v_n int;
begin
  select (length(pg_get_functiondef(p.oid))
          - length(replace(pg_get_functiondef(p.oid), '000-HS', ''))) / length('000-HS')
    into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_generate_sa_visits';
  if v_n <> 3 then
    raise exception 'expected 000-HS at 3 call sites after the edit, found %', v_n;
  end if;
end
$chk$;

revoke all on function public.fn_generate_sa_visits(bigint, int, boolean)
  from public, anon, authenticated, service_role;

commit;
