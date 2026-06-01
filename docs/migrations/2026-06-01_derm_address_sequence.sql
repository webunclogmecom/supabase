-- 2026-06-01_derm_address_sequence.sql
--
-- DB-backed sequential sheet number for generated DERM Address PDFs (stamped top-right,
-- like the "257"/"07058" on the paper forms), starting at 1000. The PDF service (Railway)
-- calls next_derm_address_id() on EVERY generation — previews included — so the sequence
-- WILL have gaps (expected). On FINAL generation the app also stores the number on the
-- dump ticket's manifest rows (derm_manifests.derm_address_no) so the filed sheet is
-- searchable.
--
-- The number is per SHEET: one DERM Address sheet = one dump ticket (one
-- white/yellow ticket number) covering MANY clients' manifest rows. It is written to all
-- those sibling derm_manifests rows on final generation — the same per-row pattern that
-- derm_address_url already uses for a shared dump-ticket sheet.

BEGIN;

-- 1. Sequence (starts at 1000)
CREATE SEQUENCE IF NOT EXISTS public.derm_address_seq START WITH 1000 INCREMENT BY 1;

-- 2. RPC wrapper (PostgREST can't call nextval directly)
CREATE OR REPLACE FUNCTION public.next_derm_address_id()
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$ SELECT nextval('public.derm_address_seq') $$;

COMMENT ON FUNCTION public.next_derm_address_id() IS
  'Atomic next DERM Address sheet number (sequence derm_address_seq, starts 1000). Called by the PDF service per generation (previews burn numbers -> gaps). PostgREST: .rpc(''next_derm_address_id'').';

-- Lock execution to the writer roles (PDF service uses service_role). No anon burning.
-- (Supabase default privileges grant anon EXECUTE on public functions, so REVOKE from
-- anon explicitly too — not just PUBLIC.)
REVOKE EXECUTE ON FUNCTION public.next_derm_address_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.next_derm_address_id() FROM anon;
GRANT  EXECUTE ON FUNCTION public.next_derm_address_id() TO service_role, authenticated;

-- 3. Storage for the assigned number on a FILED sheet (searchability)
ALTER TABLE public.derm_manifests ADD COLUMN IF NOT EXISTS derm_address_no bigint;
COMMENT ON COLUMN public.derm_manifests.derm_address_no IS
  'Sequential DERM Address sheet number (from next_derm_address_id(), starts 1000) printed top-right on the generated DERM Address PDF. Per SHEET (one dump ticket): on FINAL generation written to ALL derm_manifests rows sharing that dump ticket, alongside derm_address_url. Searchable. Sequence has gaps (previews burn numbers). NULL until a sheet is filed.';

CREATE INDEX IF NOT EXISTS idx_derm_manifests_derm_address_no
  ON public.derm_manifests (derm_address_no) WHERE derm_address_no IS NOT NULL;

COMMIT;

-- VERIFY:
-- SELECT public.next_derm_address_id();                          -- 1000, then 1001, ...
-- SELECT has_function_privilege('service_role','public.next_derm_address_id()','execute');  -- true
-- SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='derm_manifests' AND column_name='derm_address_no';
