-- 2026-08-27_1650_extra_card_binds_permit_in_printed_order.sql
--
-- WHY
-- ---
-- `derm.add_extra_client_card` had TWO defects, and the second was only found because Fred asked for
-- a smoke test ("remember to visually check, and smoke test if possible"). Reading the body found
-- the first; running it found the second.
--
-- DEFECT 1: WRONG ORDER. It picks the client's next unclaimed ACTIVE permit with `ORDER BY g.id`,
-- which is INSERTION order. The sheet prints one row per permit in `gdo_number` order.
--
--   client    permit      nickname       by id   by printed order
--   009-CN    GDO-10877   Kitchen          1           1
--   009-CN    GDO-15062   Bar              2           2
--   009-CN    GDO-16389   Lounge           3           3
--   043-MIL   GDO-11024   Restaurant       2           1     <-- DISAGREES
--   043-MIL   GDO-14117   Bar & Lounge     1           2     <-- DISAGREES
--   148-MOR   GDO-11226   Elastika         2           1     <-- DISAGREES
--   148-MOR   GDO-14769   Club & Hotel     1           2     <-- DISAGREES
--   242-WYN   GDO-13814   Pasta            1           1
--   242-WYN   GDO-14760   Nino Gordo       3           2     <-- DISAGREES
--   242-WYN   GDO-16146   Pari Pari        2           3     <-- DISAGREES
--
-- It disagrees for 3 of the 4 multi-permit clients. 009-CN is the ONLY one where the orders
-- coincide, and 009-CN is the only client the function has ever been used on (2 cards on
-- ticket-820714). So the single production use looked perfectly correct and proved nothing.
--
-- DEFECT 2: FAIL-OPEN ON A NULL gdo_id, AND THE SMOKE TEST IS WHAT FOUND IT. The "not already
-- claimed" test is `NOT EXISTS (... r2.gdo_id = g.id)`. A card with a NULL gdo_id claims nothing, so
-- the function hands out the FIRST permit again and creates a DUPLICATE. The first run of the smoke
-- test below returned `GDO-13814 Pasta` where Nino Gordo was expected, which is exactly that bug.
-- Measured: **all four** multi-permit cards in the estate carry a NULL gdo_id
-- (242-WYN@ticket-833395, 043-MIL@ticket-832194, 009-CN@ticket-312433, 009-CN@ticket-830714), so
-- this was fail-open on 100% of the rows it would ever have been used on. It now refuses.
--
-- 🛑 THE SORT MUST MATCH THE GENERATOR, NOT BE "CORRECT" IN THE ABSTRACT.
-- `pdf_service/app.py` line 142 sorts with `valid.sort(key=lambda g: g["gdo_number"])`, a STRING
-- sort over the whole `GDO-NNNNN` token. Measured: all 134 ACTIVE well-formed permits are
-- zero-padded to exactly 5 digits (GDO-00092 .. GDO-16389), so string and numeric order agree today
-- and `ORDER BY g.gdo_number` reproduces the printed order exactly. A "smarter" numeric sort
-- (`substring(gdo_number from 5)::int`) would be WRONG: it would diverge from the generator the
-- moment a 4- or 6-digit permit appeared, and the card must bind to the row the generator actually
-- PRINTED, whatever ordering that used. Match the generator.
--
-- ⚠ KNOWN AND DELIBERATELY NOT CHANGED: this function creates a card with NO stamp, and an unstamped
-- card fails `fn_blackout_targets`' whole-folder closed-world gate, so the folder stops regenerating
-- until the operator places the chip. That freeze is real but transient, self-healing, inherent to
-- the Studio's add-then-place flow, and visible the whole time as `frozen_closed_world` in
-- `derm.v_blackout_blocked_sheets`. Both existing extra-stamp cards were stamped, so it has never
-- bitten. The permanent answer is a create+stamp+band-in-one-transaction RPC, which belongs with the
-- per-permit card work rather than here.
--
-- 🛑 BODY COPIED FROM pg_get_functiondef AND SPLICED BY SCRIPT: two anchors, each asserted to match
-- exactly once, and the result asserted byte-identical to the original once both changes are
-- reversed. The other ORDER BY in this body (`order by id limit 1`, which picks the client's
-- existing card) is deliberately untouched.
--
-- RULE 8 (audit trail): a function holds no state; opt-out. `derm.address_row_map` is audited.

BEGIN;

CREATE OR REPLACE FUNCTION derm.add_extra_client_card(p_dump_folder text, p_client_id bigint, p_page integer DEFAULT 1)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare
  v_wm text; v_existing derm.address_row_map%rowtype;
  v_next int; v_new_id bigint; v_gdo bigint;
begin
  perform derm._require_stamp_key();
  if p_client_id is null then raise exception 'p_client_id required'; end if;

  select max(white_manifest_number) into v_wm
    from derm.address_row_map where dump_folder = p_dump_folder;
  if v_wm is null then raise exception 'unknown sheet %', p_dump_folder; end if;

  select * into v_existing from derm.address_row_map
   where dump_folder = p_dump_folder and matched_client_id = p_client_id
   order by id limit 1;
  if not found then
    raise exception 'client % is not on sheet % yet — use add_client_card_and_link first',
      p_client_id, p_dump_folder;
  end if;

  -- 🛑 The permit-selection below decides what is UNCLAIMED by looking for cards that already
  -- carry a gdo_id. If any of this client's existing cards on this sheet has a NULL gdo_id we
  -- cannot know which permit it represents, and the "next unclaimed" answer is a guess that
  -- silently hands out the FIRST permit again. Measured 2026-08-27: that is the state of all four
  -- multi-permit cards in the estate (242-WYN@ticket-833395, 043-MIL@ticket-832194,
  -- 009-CN@ticket-312433, 009-CN@ticket-830714), so this was fail-OPEN on 100% of the rows it
  -- would ever be used on. Refuse instead: bind the existing card first.
  if exists (select 1 from derm.address_row_map r0
              where r0.dump_folder = p_dump_folder
                and r0.matched_client_id = p_client_id
                and r0.gdo_id is null) then
    raise exception 'client % on sheet % has a card with no gdo_id; bind it to its permit before '
                    'adding another, or the next card would duplicate the first permit',
      p_client_id, p_dump_folder;
  end if;

  -- the client's next ACTIVE permit not already claimed by a card on this sheet
  select g.id into v_gdo
    from public.gdos g
   where g.client_id = p_client_id
     and g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$'
     and not exists (select 1 from derm.address_row_map r2
                      where r2.dump_folder = p_dump_folder and r2.gdo_id = g.id)
   order by g.gdo_number
   limit 1;

  select coalesce(max(row_index), 0) + 1 into v_next
    from derm.address_row_map
   where dump_folder = p_dump_folder and page = coalesce(p_page, 1);

  insert into derm.address_row_map
    (dump_folder, white_manifest_number, page, row_index, image_url,
     matched_client_id, matched_manifest_id, gdo_id, assignment_status, confidence, source, flags)
  values
    (p_dump_folder, v_wm, coalesce(p_page, 1), v_next, v_existing.image_url,
     p_client_id, v_existing.matched_manifest_id, v_gdo, 'matched', 'high',
     'extra-stamp', '{"extra_stamp":true}'::jsonb)
  returning id into v_new_id;

  return v_new_id;
end $function$;

-- ---------------------------------------------------------------------------
-- VERIFY  (the smoke test Fred asked for, with the OLD body kept as a control)
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_client bigint; v_new bigint; v_gdo text; v_card bigint; v_pasta bigint;
  v_ctrl text; v_guard_ok boolean := false; v_ok boolean := false;
BEGIN
  SELECT id INTO v_client FROM public.clients WHERE client_code = '242-WYN';
  -- 🛑 SCOPE THE FIXTURE BY CLIENT. GDO-13814 exists TWICE: id191 (241-WYN, INACTIVE) and id190
  --    (242-WYN, ACTIVE), from the 2026-06-27 re-attribution. Looking it up by number alone picked
  --    the wrong client's row, bound a foreign gdo_id, left 242-WYN's real Pasta unclaimed, and made
  --    VERIFY 3 report the function as broken when it was not. 14 GDO numbers are held by 2+ rows.
  SELECT id INTO v_pasta  FROM public.gdos
   WHERE gdo_number = 'GDO-13814' AND client_id = v_client AND status = 'ACTIVE';
  IF (SELECT count(*) FROM public.gdos
       WHERE gdo_number = 'GDO-13814' AND client_id = v_client AND status = 'ACTIVE') <> 1 THEN
    RAISE EXCEPTION 'VERIFY: the Pasta fixture is ambiguous; the test would prove nothing';
  END IF;
  SELECT id INTO v_card   FROM derm.address_row_map
   WHERE dump_folder='ticket-833395' AND matched_client_id = v_client;
  IF v_client IS NULL OR v_pasta IS NULL OR v_card IS NULL THEN
    RAISE EXCEPTION 'VERIFY: fixtures missing (client %, pasta %, card %)', v_client, v_pasta, v_card;
  END IF;

  -- 1. Grants survived CREATE OR REPLACE.
  IF NOT has_function_privilege('authenticated',
        'derm.add_extra_client_card(text,bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: authenticated lost EXECUTE';
  END IF;

  -- 2. DEFECT 2 GUARD BITES. 242-WYN's card on ticket-833395 has a NULL gdo_id today, so the
  --    function must REFUSE rather than hand out Pasta a second time.
  BEGIN
    v_new := derm.add_extra_client_card('ticket-833395', v_client, 1);
    v_guard_ok := false;              -- reached only if it did NOT raise
    RAISE EXCEPTION 'guard_rollback';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'guard_rollback' THEN
        RAISE EXCEPTION 'VERIFY 2 FAILED: a card with NULL gdo_id was ACCEPTED; it would duplicate the first permit';
      END IF;
      v_guard_ok := (SQLERRM LIKE '%no gdo_id%');
  END;
  IF NOT v_guard_ok THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: expected the NULL-gdo_id refusal, got a different error';
  END IF;

  -- 3. DEFECT 1 FIX. Bind the existing card to Pasta (its first printed row) and the NEXT permit
  --    must be GDO-14760 "Nino Gordo", which is what sheet 1093 prints second. Rolled back.
  BEGIN
    UPDATE derm.address_row_map SET gdo_id = v_pasta WHERE id = v_card;
    v_new := derm.add_extra_client_card('ticket-833395', v_client, 1);
    SELECT g.gdo_number INTO v_gdo
      FROM derm.address_row_map r JOIN public.gdos g ON g.id = r.gdo_id WHERE r.id = v_new;
    v_ok := (v_gdo = 'GDO-14760');
    RAISE EXCEPTION 'smoke_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'smoke_rollback' THEN RAISE; END IF;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: bound %, expected GDO-14760 Nino Gordo', COALESCE(v_gdo,'<null>');
  END IF;

  -- 4. 🛑 THE POSITIVE CONTROL. Prove the OLD selection picks the WRONG permit under the same
  --    conditions, so VERIFY 3 is a real assertion and not one that cannot fail.
  CREATE OR REPLACE FUNCTION derm._tmp_old_permit_pick(p_dump_folder text, p_client_id bigint, p_claimed bigint)
    RETURNS text LANGUAGE sql STABLE SET search_path TO 'derm','public' AS $f$
    SELECT g.gdo_number FROM public.gdos g
     WHERE g.client_id = p_client_id
       AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$'
       AND g.id <> p_claimed
     ORDER BY g.id LIMIT 1;
  $f$;
  SELECT derm._tmp_old_permit_pick('ticket-833395', v_client, v_pasta) INTO v_ctrl;
  DROP FUNCTION derm._tmp_old_permit_pick(text,bigint,bigint);
  IF v_ctrl IS DISTINCT FROM 'GDO-16146' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: control picked %, expected the old ORDER BY g.id to pick GDO-16146 Pari Pari. VERIFY 3 proves nothing.',
                    COALESCE(v_ctrl,'<null>');
  END IF;

  -- 5. Nothing persisted: still exactly one 242-WYN card, still NULL gdo_id.
  IF (SELECT count(*) FROM derm.address_row_map
       WHERE dump_folder='ticket-833395' AND matched_client_id = v_client) <> 1 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the smoke test did not roll back';
  END IF;
  IF (SELECT gdo_id FROM derm.address_row_map WHERE id = v_card) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the gdo_id write did not roll back';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
              WHERE n.nspname='derm' AND p.proname='_tmp_old_permit_pick') THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the temp control still exists';
  END IF;

  RAISE NOTICE 'VERIFY ok: NULL-gdo_id refused; with Pasta bound the next permit is GDO-14760 Nino Gordo; the old body would have picked GDO-16146 Pari Pari; everything rolled back.';
END $do$;

COMMIT;
