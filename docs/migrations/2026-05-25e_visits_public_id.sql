-- 2026-05-25e_visits_public_id.sql
--
-- IDOR fix Layer 1: replace predictable visit IDs in customer-facing URLs
-- with short, unguessable random tokens.
--
-- BACKGROUND
-- ----------
-- Field Portal URLs currently look like:
--   /092-tce/visit/00000000-0000-0000-0000-000000003915
-- The "UUID" is actually customer.uuid_from_bigint(v.id) — i.e. the BIGINT
-- visit id (3915) zero-padded into UUID shape. Visit IDs are sequential, so
-- anyone with one URL can guess all neighboring visits by incrementing.
-- Combined with FP's client-side-only ownership check, this is an IDOR
-- (Insecure Direct Object Reference) waiting to happen.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
-- 1. Adds a `gen_short_id(n_chars INT DEFAULT 10)` helper that returns a
--    cryptographically-random base62 string. 10 chars at base62 gives
--    62^10 ≈ 8.4 × 10^17 combinations — brute-force enumeration is
--    impractical.
-- 2. Adds `visits.public_id TEXT NOT NULL UNIQUE` with that default. The
--    ADD COLUMN with VOLATILE DEFAULT triggers a table rewrite in PG 12+,
--    populating every existing visit with a fresh token. Row-level audit
--    triggers do NOT fire on table rewrites (the rewrite is metadata-level,
--    not a logical UPDATE), so the 974 existing rows won't generate 974
--    audit entries.
--
-- Companion migration 2026-05-25f updates the customer.* views to expose
-- v.public_id as the URL identifier. Companion 2026-05-25g adds the
-- ownership-enforced RPC.
--
-- IDEMPOTENT (Rule 5): re-running fails on the UNIQUE constraint if
-- public_id already exists. Use ALTER TABLE … IF NOT EXISTS guards to make
-- safely re-runnable.
--
-- AUDIT (Rule 8): visits is audited. New INSERTs going forward will carry
-- public_id in the new_row JSONB automatically (full-row JSONB capture).
-- No trigger change needed.

BEGIN;

-- ============================================================
-- 1. Helper function — generate short cryptographically-random IDs
-- ============================================================
CREATE OR REPLACE FUNCTION public.gen_short_id(n_chars INT DEFAULT 10)
RETURNS TEXT
LANGUAGE plpgsql VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  alphabet CONSTANT TEXT :=
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  bytes BYTEA;
  result TEXT := '';
  i INT;
BEGIN
  -- gen_random_bytes lives in the extensions schema (pgcrypto).
  bytes := extensions.gen_random_bytes(n_chars);
  FOR i IN 0..(n_chars - 1) LOOP
    -- Modulo 62 introduces a slight bias (256 % 62 = 8), but for
    -- 60-bit-equivalent unguessability that's irrelevant. We're not
    -- using this as a cryptographic primitive — just a URL token.
    result := result || pg_catalog.substr(alphabet, (pg_catalog.get_byte(bytes, i) % 62) + 1, 1);
  END LOOP;
  RETURN result;
END;
$function$;

COMMENT ON FUNCTION public.gen_short_id(INT) IS
  'Generate a short, cryptographically-random base62 token (default 10 chars). Used for URL-facing public IDs (e.g. visits.public_id) to prevent IDOR enumeration.';

-- ============================================================
-- 2. Add visits.public_id column
-- ============================================================
ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS public_id TEXT NOT NULL DEFAULT public.gen_short_id();

-- Unique constraint AFTER population so we can detect any astronomical
-- collision at constraint-validation time rather than per-row.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'visits_public_id_unique'
  ) THEN
    ALTER TABLE public.visits
      ADD CONSTRAINT visits_public_id_unique UNIQUE (public_id);
  END IF;
END $$;

-- Index is auto-created by UNIQUE constraint; no need for explicit CREATE INDEX.

COMMENT ON COLUMN public.visits.public_id IS
  'Short cryptographically-random token (10-char base62) exposed in customer-facing URLs. Replaces the predictable customer.uuid_from_bigint(id) pattern that allowed IDOR enumeration. Set automatically on INSERT via gen_short_id() default.';

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- After apply:
--   SELECT COUNT(*) FILTER (WHERE public_id IS NULL)::int AS still_null,
--          COUNT(DISTINCT public_id)::int AS distinct_ids,
--          COUNT(*)::int AS total
--   FROM public.visits;
--   Expected: still_null=0, distinct_ids=total
--
-- Spot-check format:
--   SELECT id, public_id FROM public.visits ORDER BY id DESC LIMIT 5;
--   Expected: each public_id matches /^[0-9A-Za-z]{10}$/
