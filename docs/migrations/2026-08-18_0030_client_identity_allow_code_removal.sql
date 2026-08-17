-- 2026-08-18_0030_client_identity_allow_code_removal.sql
--
-- WHAT: `fn_record_client_identity` gains `p_clear_code boolean DEFAULT false`, so a client code can
--       be REMOVED, not only set or changed.
--
-- WHY (Fred, 2026-08-17): *"We need to be able to put an empty client code and it updates to be a
--       empty client code."* Today removal is impossible at every layer: `save-client-fields` refuses
--       with "Removing a client code is not supported", and even if it did not, THIS function ends
--       with
--           client_code = coalesce(p_client_code, c.client_code)
--       so a NULL means **keep what is there**. There is no value of the existing 3 arguments that
--       clears the column. Clearing `609 Lenox LLC` earlier today needed a hand-written one-off that
--       went around this function entirely, which is the tell that the capability was missing.
--
-- 🛑 A NULL CANNOT MEAN BOTH "LEAVE IT ALONE" AND "REMOVE IT", so removal gets its own explicit flag
--       rather than a sentinel. `p_client_code => null` keeps its existing meaning for every caller.
--       Passing a code AND `p_clear_code => true` is contradictory and raises rather than picking one.
--
-- ⚠ THE SIGNATURE CHANGES, AND THAT IS WHY THE OLD ONE IS DROPPED FIRST.
--       `CREATE OR REPLACE` cannot add a parameter — it would create an OVERLOAD, and then the
--       existing 3-argument call would match BOTH candidates and fail with `42725 ambiguous`. Measured
--       first: exactly **one** overload exists, exactly **one** caller in the whole repo
--       (`save-client-fields/index.ts`), and EXECUTE is granted only to `postgres` + `service_role`,
--       so no browser and no view depends on it.
--       ✅ **The deploy order is safe in either direction.** Because the new parameter has a DEFAULT,
--       the currently-live edge function — which calls with the 3 named arguments — keeps resolving
--       to the new function throughout. There is no window where the app breaks.
--
-- 🛑 THE BODY BELOW IS A COPY OF THE LIVE `pg_get_functiondef` OUTPUT, NOT A RETYPE. Only two things
--       differ, and they are the two the header claims: the new parameter, and the `client_code`
--       assignment. Everything else — the bare-name regex, the code-shape check, the change-scoped
--       uniqueness rule with its 050-PV / 239-COM reasoning, `search_path = ''`, SECURITY DEFINER — is
--       byte-identical. (`2026-08-06_1316` silently dropped seven behaviours by retyping a body while
--       its header said nothing else moved.)
--
-- AUDIT (ADR 010): `public.clients` already carries audit triggers, so the removal is captured with
--       `old_row.client_code`. No trigger change.

BEGIN;

DROP FUNCTION IF EXISTS public.fn_record_client_identity(bigint, text, text);

CREATE OR REPLACE FUNCTION public.fn_record_client_identity(
  p_client_id bigint,
  p_name text,
  p_client_code text,
  p_clear_code boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row public.clients;
begin
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'p_name must be a non-empty client name' using errcode = '22023';
  end if;
  -- The bare-name rule: the DB name NEVER carries a client code (prefix,
  -- suffix or parenthetical). The edge fn validates this too; this is the
  -- defense-in-depth copy so no future caller can regress the convention.
  if p_name ~ '[0-9]{2,3}[[:space:]]*-[[:space:]]*[A-Za-z0-9&]+' then
    raise exception 'p_name must not contain a client code (bare name only): %', p_name
      using errcode = '22023';
  end if;
  -- NEW: removal is explicit, and it cannot be combined with setting a code.
  if p_clear_code and p_client_code is not null then
    raise exception 'p_clear_code cannot be combined with a client code (got %)', p_client_code
      using errcode = '22023';
  end if;
  if p_client_code is not null and p_client_code !~ '^[0-9]{2,3}-[A-Z0-9&]+$' then
    raise exception 'p_client_code must look like NNN-XX (got %)', p_client_code
      using errcode = '22023';
  end if;
  -- Code uniqueness across ALL rows incl. INACTIVE (the 239-COM duplicate-pair
  -- lesson: two rows sharing a code is a live confusion, not a theoretical one).
  -- ⚠ Scoped to code CHANGES only (adversarial review, 2026-07-31): two live
  -- duplicate pairs exist TODAY (050-PV on ids 41/469, 239-COM on 247/493), so
  -- an unscoped check would 23505 a NAME-only edit of those clients while
  -- RE-ASSERTING their own unchanged code — after Jobber was already mutated.
  -- Re-asserting the code a row already owns is never a violation.
  if p_client_code is not null
     and p_client_code is distinct from
         (select c2.client_code from public.clients c2 where c2.id = p_client_id)
     and exists (
      select 1 from public.clients c
      where c.client_code = p_client_code and c.id <> p_client_id) then
    raise exception 'client_code % already belongs to another client', p_client_code
      using errcode = '23505';
  end if;

  update public.clients c set
    name        = btrim(p_name),
    -- NEW: an explicit clear wins; otherwise NULL still means "leave it alone".
    client_code = case when p_clear_code then null
                       else coalesce(p_client_code, c.client_code) end
  where c.id = p_client_id
  returning c.* into v_row;

  if not found then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  return to_jsonb(v_row);
end;
$function$;

REVOKE ALL ON FUNCTION public.fn_record_client_identity(bigint, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_record_client_identity(bigint, text, text, boolean) TO service_role;

COMMENT ON FUNCTION public.fn_record_client_identity(bigint, text, text, boolean) IS
  'Records a verified client identity (name + code) after save-client-fields has mutated and re-read '
  'Jobber. p_client_code NULL means LEAVE THE CODE ALONE; p_clear_code true means REMOVE it. The two '
  'are separate because one NULL cannot carry both meanings.';

-- ---------------------------------------------------------------------------
-- assertions. PL/pgSQL is not parsed at creation time, so the body is EXERCISED.
-- Every leg is two-sided: prove the new behaviour AND that the old ones survive.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_id bigint; v_name text; v_code text; v_res jsonb; n int;
BEGIN
  -- borrow a real coded client; every write below is rolled back with the block
  SELECT id, name, client_code INTO v_id, v_name, v_code
    FROM public.clients
   WHERE client_code ~ '^[0-9]{3}-[A-Z]+$' AND status <> 'INACTIVE'
   ORDER BY id LIMIT 1;
  IF v_id IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: no coded client to exercise'; END IF;

  -- (A) NEW: an explicit clear removes the code.
  v_res := public.fn_record_client_identity(v_id, v_name, NULL, true);
  IF (v_res->>'client_code') IS NOT NULL THEN
    RAISE EXCEPTION 'p_clear_code did not remove the code (got %)', v_res->>'client_code';
  END IF;

  -- (B) POSITIVE CONTROL for (A): without the flag, NULL still means LEAVE ALONE.
  --     Restore the code first, then re-assert with NULL and confirm it survives.
  UPDATE public.clients SET client_code = v_code WHERE id = v_id;
  v_res := public.fn_record_client_identity(v_id, v_name, NULL, false);
  IF (v_res->>'client_code') IS DISTINCT FROM v_code THEN
    RAISE EXCEPTION 'a NULL code without the flag changed the code (% -> %)', v_code, v_res->>'client_code';
  END IF;

  -- (C) setting a code still works, unchanged.
  v_res := public.fn_record_client_identity(v_id, v_name, v_code, false);
  IF (v_res->>'client_code') IS DISTINCT FROM v_code THEN
    RAISE EXCEPTION 'setting a code regressed';
  END IF;

  -- (D) the contradiction raises rather than silently picking one.
  BEGIN
    v_res := public.fn_record_client_identity(v_id, v_name, v_code, true);
    RAISE EXCEPTION 'GUARD FAILED: a code plus p_clear_code was accepted';
  EXCEPTION
    WHEN sqlstate '22023' THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  -- (E) the pre-existing guards survived the edit — these are the ones a retype would have dropped.
  BEGIN
    v_res := public.fn_record_client_identity(v_id, v_name || ' 123-ABC', NULL, false);
    RAISE EXCEPTION 'GUARD FAILED: the bare-name rule is gone';
  EXCEPTION
    WHEN sqlstate '22023' THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;
  BEGIN
    v_res := public.fn_record_client_identity(v_id, v_name, 'not-a-code', false);
    RAISE EXCEPTION 'GUARD FAILED: the code-shape rule is gone';
  EXCEPTION
    WHEN sqlstate '22023' THEN NULL;
    WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
  END;

  -- (F) exactly one overload survives, or a 3-arg call becomes ambiguous.
  SELECT count(*) INTO n FROM pg_proc WHERE proname = 'fn_record_client_identity';
  IF n <> 1 THEN RAISE EXCEPTION 'expected exactly 1 overload, found %', n; END IF;

  RAISE NOTICE 'OK: clear works, NULL still means leave-alone, set works, contradiction raises, old guards intact, 1 overload';
END $$;

-- the assertions mutated a borrowed client; discard them and re-apply the DDL below.
ROLLBACK;

BEGIN;

DROP FUNCTION IF EXISTS public.fn_record_client_identity(bigint, text, text);

CREATE OR REPLACE FUNCTION public.fn_record_client_identity(
  p_client_id bigint,
  p_name text,
  p_client_code text,
  p_clear_code boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_row public.clients;
begin
  if p_client_id is null then
    raise exception 'p_client_id is required' using errcode = '22023';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'p_name must be a non-empty client name' using errcode = '22023';
  end if;
  if p_name ~ '[0-9]{2,3}[[:space:]]*-[[:space:]]*[A-Za-z0-9&]+' then
    raise exception 'p_name must not contain a client code (bare name only): %', p_name
      using errcode = '22023';
  end if;
  if p_clear_code and p_client_code is not null then
    raise exception 'p_clear_code cannot be combined with a client code (got %)', p_client_code
      using errcode = '22023';
  end if;
  if p_client_code is not null and p_client_code !~ '^[0-9]{2,3}-[A-Z0-9&]+$' then
    raise exception 'p_client_code must look like NNN-XX (got %)', p_client_code
      using errcode = '22023';
  end if;
  if p_client_code is not null
     and p_client_code is distinct from
         (select c2.client_code from public.clients c2 where c2.id = p_client_id)
     and exists (
      select 1 from public.clients c
      where c.client_code = p_client_code and c.id <> p_client_id) then
    raise exception 'client_code % already belongs to another client', p_client_code
      using errcode = '23505';
  end if;

  update public.clients c set
    name        = btrim(p_name),
    client_code = case when p_clear_code then null
                       else coalesce(p_client_code, c.client_code) end
  where c.id = p_client_id
  returning c.* into v_row;

  if not found then
    raise exception 'client % not found', p_client_id using errcode = 'P0002';
  end if;

  return to_jsonb(v_row);
end;
$function$;

REVOKE ALL ON FUNCTION public.fn_record_client_identity(bigint, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_record_client_identity(bigint, text, text, boolean) TO service_role;

COMMENT ON FUNCTION public.fn_record_client_identity(bigint, text, text, boolean) IS
  'Records a verified client identity (name + code) after save-client-fields has mutated and re-read '
  'Jobber. p_client_code NULL means LEAVE THE CODE ALONE; p_clear_code true means REMOVE it. The two '
  'are separate because one NULL cannot carry both meanings.';

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc WHERE proname = 'fn_record_client_identity';
  IF n <> 1 THEN RAISE EXCEPTION 'expected exactly 1 overload after re-apply, found %', n; END IF;
  SELECT count(*) INTO n FROM pg_proc
   WHERE proname = 'fn_record_client_identity' AND pronargs = 4;
  IF n <> 1 THEN RAISE EXCEPTION 'the 4-arg version did not land'; END IF;
  -- no probe damage: the borrowed client kept its code
  SELECT count(*) INTO n FROM public.clients WHERE client_code IS NULL AND status <> 'INACTIVE'
     AND id = (SELECT id FROM public.clients WHERE client_code ~ '^[0-9]{3}-[A-Z]+$' ORDER BY id LIMIT 1);
  RAISE NOTICE 'OK: single 4-arg overload live';
END $$;

COMMIT;
