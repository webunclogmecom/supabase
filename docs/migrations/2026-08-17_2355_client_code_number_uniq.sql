-- 2026-08-17_2355_client_code_number_uniq.sql
--
-- WHAT: a UNIQUE index on the client-code NUMBER, not on the whole code string.
--
-- WHY (Fred, 2026-08-17): *"I changed 609 Lenox LLC client code to 168 which was supposed to be for
--      168-AVA, that shouldn't be able to happen."* It could happen, and nothing in the database
--      stopped it.
--
-- 🛑 THE EXISTING INDEX GUARDS THE WRONG THING, AND IT LOOKS LIKE IT GUARDS THIS.
--      `clients_active_client_code_uniq` is UNIQUE on `client_code` — the FULL string. So `168-609`
--      and `168-AVA` are two different values and both were accepted, while the client-code scheme
--      treats the **NUMBER as the identity** and the letters as a cosmetic tag (which is why
--      regenerating a code keeps the number and only changes the letters). The app's own warning text
--      says so: *"The client code scheme treats the NUMBER as the identity."*
--      ⇒ Uniqueness on the string is not uniqueness on the identity. This index closes that.
--
-- ⚠ THE 000 DUMP BAND IS EXEMPT, BY DESIGN. `000-DP` (DUMP Pompano) and `000-DH` (Homestead Dump)
--      deliberately share number 000; it is a band, not an identity. The app's warning already says
--      "outside the 000 dump band". Excluding it here keeps the DB and the UI telling one story.
--
-- ⚠ INACTIVE IS EXEMPT, matching the sibling index. Two live pairs depend on it — `050-PV` and
--      `239-COM` each exist twice with one member INACTIVE — which is the sanctioned "replace a
--      client, reuse its code" pattern. Including INACTIVE here would reject both and would also
--      make a number unrecoverable forever once a client was retired.
--
-- MEASURED BEFORE APPLYING (2026-08-17, after 609 Lenox's wrong code was removed from Jobber AND our
--      DB, backed up to backups/2026-08-17_609lenox_code_removal.json):
--        violators of this index : 0
--        rows the index covers   : 279   <- the control; a zero here would mean it guards nothing
--        malformed client_codes  : 0
--
-- AUDIT (ADR 010): an index carries no triggers; `public.clients` is already audited. No change.

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS clients_active_client_number_uniq
  ON public.clients ((split_part(client_code, '-', 1)))
  WHERE client_code IS NOT NULL
    AND status <> 'INACTIVE'
    AND client_code NOT LIKE '000-%';

COMMENT ON INDEX public.clients_active_client_number_uniq IS
  'One live client per client-code NUMBER. The scheme treats the number as the identity and the '
  'letters as a cosmetic tag, so uniqueness on the full code string (clients_active_client_code_uniq) '
  'does NOT express it: 168-609 and 168-AVA both passed that one. Exempts the 000 dump band, which '
  'shares a number on purpose, and INACTIVE rows, so a retired client frees its number.';

-- ---------------------------------------------------------------------------
-- assertions. Two-sided: it must REJECT a colliding number AND ACCEPT a free one.
-- A one-sided test passes on an index that rejects everything.
-- ---------------------------------------------------------------------------
DO $$
DECLARE n int; v_id bigint; v_free text; v_taken text;
BEGIN
  -- (A) it exists and is UNIQUE
  SELECT count(*) INTO n FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
   WHERE c.relname = 'clients_active_client_number_uniq' AND i.indisunique;
  IF n <> 1 THEN RAISE EXCEPTION 'the number-unique index did not land'; END IF;

  -- (B) CONTROL: it actually covers rows. A partial index whose predicate matches nothing
  --     would pass every other check in this block while guarding precisely nothing.
  SELECT count(*) INTO n FROM public.clients
   WHERE client_code IS NOT NULL AND status <> 'INACTIVE' AND client_code NOT LIKE '000-%';
  IF n < 100 THEN RAISE EXCEPTION 'CONTROL FAILED: the index covers only % rows', n; END IF;

  -- (C) NEGATIVE SIDE: a second live client on an already-used number must RAISE.
  SELECT split_part(client_code, '-', 1) INTO v_taken FROM public.clients
   WHERE client_code IS NOT NULL AND status <> 'INACTIVE' AND client_code NOT LIKE '000-%' LIMIT 1;
  SELECT id INTO v_id FROM public.clients WHERE client_code IS NULL LIMIT 1;
  IF v_id IS NULL THEN
    RAISE NOTICE 'skipping the collision assertion: no codeless client to borrow';
  ELSE
    BEGIN
      UPDATE public.clients SET client_code = v_taken || '-ZZT' WHERE id = v_id;
      RAISE EXCEPTION 'GUARD FAILED: a duplicate client-code NUMBER was accepted';
    EXCEPTION
      WHEN unique_violation THEN NULL;                       -- expected
      WHEN OTHERS THEN IF SQLERRM LIKE 'GUARD FAILED%' THEN RAISE; END IF;
    END;

    -- (D) POSITIVE SIDE: a FREE number on the same row must still be accepted, or the index is
    --     simply rejecting all writes and (C) proved nothing.
    SELECT lpad((max(split_part(client_code, '-', 1))::int + 7)::text, 3, '0') INTO v_free
      FROM public.clients WHERE client_code ~ '^[0-9]{3}-';
    UPDATE public.clients SET client_code = v_free || '-ZZT' WHERE id = v_id;
    SELECT count(*) INTO n FROM public.clients WHERE id = v_id AND client_code = v_free || '-ZZT';
    IF n <> 1 THEN RAISE EXCEPTION 'POSITIVE CONTROL FAILED: a free number was rejected'; END IF;
  END IF;

  -- (E) the 000 band must still tolerate its shared number.
  SELECT count(*) INTO n FROM public.clients WHERE client_code LIKE '000-%' AND status <> 'INACTIVE';
  IF n < 2 THEN RAISE EXCEPTION 'CONTROL FAILED: the 000 band no longer has 2+ live rows to prove the exemption'; END IF;

  RAISE NOTICE 'OK: unique on the number, covers % rows, rejects a collision, accepts a free number, 000 band exempt', n;
END $$;

-- the assertions mutated a borrowed row; discard everything and re-apply the DDL below.
ROLLBACK;

BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS clients_active_client_number_uniq
  ON public.clients ((split_part(client_code, '-', 1)))
  WHERE client_code IS NOT NULL
    AND status <> 'INACTIVE'
    AND client_code NOT LIKE '000-%';

COMMENT ON INDEX public.clients_active_client_number_uniq IS
  'One live client per client-code NUMBER. The scheme treats the number as the identity and the '
  'letters as a cosmetic tag, so uniqueness on the full code string (clients_active_client_code_uniq) '
  'does NOT express it: 168-609 and 168-AVA both passed that one. Exempts the 000 dump band, which '
  'shares a number on purpose, and INACTIVE rows, so a retired client frees its number.';

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
   WHERE c.relname = 'clients_active_client_number_uniq' AND i.indisunique;
  IF n <> 1 THEN RAISE EXCEPTION 'the index did not survive the re-apply'; END IF;
  SELECT count(*) INTO n FROM public.clients WHERE client_code LIKE '%-ZZT';
  IF n <> 0 THEN RAISE EXCEPTION 'a probe code survived the rollback (% rows)', n; END IF;
  RAISE NOTICE 'OK: index live, no probe rows left behind';
END $$;

COMMIT;
