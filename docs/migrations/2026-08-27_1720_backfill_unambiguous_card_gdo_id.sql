-- 2026-08-27_1720_backfill_unambiguous_card_gdo_id.sql
--
-- WHY
-- ---
-- Fred: the nickname badge goes "on every rectangle". The Studio reads it from
-- `derm.v_stamp_rows.gdo_label` = COALESCE(gdos.nickname, location_label, gdo_number), which is
-- resolved through `derm.address_row_map.gdo_id`. That column is NULL on 307 of 677 placed cards, so
-- without this backfill the badge would be blank on 45% of rectangles and the feature would look
-- broken rather than finished.
--
-- Measured 2026-08-27, the 307 unlabelled placed cards split three ways:
--
--   72   client holds EXACTLY ONE active well-formed permit  -> UNAMBIGUOUS, backfilled here
--   232  client holds ZERO active well-formed permits        -> no nickname exists; NULL is correct
--   3    client holds 2+                                     -> genuinely ambiguous, left alone
--
-- 🛑 ONLY THE UNAMBIGUOUS ONES. Where a client holds several permits, deciding which one a card
-- represents is exactly the question the per-permit split work exists to answer, and guessing it
-- would bind a card to a permit it does not represent, then print that permit's nickname on the
-- rectangle a person uses to place a stamp on a regulator-facing form. Those 3 stay NULL.
--
-- 🛑 THE CROSS-CLIENT GUARD IS NOT THEORETICAL. **14 GDO numbers are held by two or more rows**
-- (GDO-13814 is 241-WYN INACTIVE *and* 242-WYN ACTIVE, from the 2026-06-27 re-attribution; CLAUDE.md
-- lists three more still claimed by two clients each). A backfill that matched on the NUMBER would
-- bind a card to another client's permit and label it with a facility that is not theirs. This joins
-- on `g.client_id = r.matched_client_id` and never on the number, and VERIFY 3 asserts that not one
-- written row points at a permit belonging to a different client.
--
-- ⚠ `status = 'ACTIVE'` AND the strict `^GDO-[0-9]+$` shape are both load-bearing, and they are the
-- same predicate the sheet generator uses (`pdf_service/app.py`) and the same one
-- `derm.add_extra_client_card` uses. `public.gdos` also holds junk values like 'Not available' (22
-- rows), 'Needs review' (4) and 'bw'/'BW' (7); matching those would put nonsense on a rectangle.
--
-- ⚠ An EXPIRED permit is still ACTIVE here and that is correct: Fred, 2026-08-24, "even if a GDO
-- expires their numbers doesn't changes on renewal, so even if it's expired keep it". `status`
-- decides inclusion, never `permit_expiration`.
--
-- WHAT ELSE READS gdo_id: only `derm.v_stamp_rows` (the label), `derm.add_extra_client_card` (its
-- "which permits are already claimed" test, which this makes MORE correct, since a NULL there was
-- fail-open and would hand out the first permit twice) and `derm.audit_pack` (reporting). So the
-- blast radius is the label plus a guard that improves.
--
-- RULE 8 (audit trail): `derm.address_row_map` carries audit.log_change, so every row written here
-- is captured with old_row and is individually revertible.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 0. Record the starting point so VERIFY can prove exactly what moved.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _bf_before ON COMMIT DROP AS
SELECT r.id,
       (SELECT g.id FROM public.gdos g
         WHERE g.client_id = r.matched_client_id
           AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$') AS only_permit
  FROM derm.address_row_map r
 WHERE r.gdo_id IS NULL
   AND r.matched_client_id IS NOT NULL
   AND (SELECT count(*) FROM public.gdos g
         WHERE g.client_id = r.matched_client_id
           AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$') = 1;

-- ---------------------------------------------------------------------------
-- PART 1. The backfill.
-- ---------------------------------------------------------------------------
UPDATE derm.address_row_map r
   SET gdo_id = b.only_permit
  FROM _bf_before b
 WHERE r.id = b.id
   AND r.gdo_id IS NULL          -- re-assert: never overwrite a binding that already exists
   AND b.only_permit IS NOT NULL;

-- ---------------------------------------------------------------------------
-- PART 2. Clear TWO stale bindings that VERIFY 6 found, and would have shown a wrong nickname.
-- ---------------------------------------------------------------------------
-- Cards 11 (derm/1236) and 615 (ticket-829216) belong to 241-WYN and point at 241-WYN's GDO-16146
-- row, which is INACTIVE. That is residue from the 2026-08-24 re-attribution (`2026-08-24_1530`),
-- which moved GDO-16146 to 242-WYN after Fred read the Client App; the permit was demoted but these
-- two card bindings were never revisited. 241-WYN now holds ZERO active permits, which CLAUDE.md
-- records as a legal state rather than a gap.
--
-- Left alone they are inert today, because nothing renders gdo_label yet. The moment the nickname
-- badge ships they would print "Main" on 241-WYN's rectangles: a nickname for a permit that client
-- no longer holds, on the screen a person uses to stamp a regulator-facing form. That is precisely
-- the tenant mis-attribution the 2026-08-24 migration existed to correct, so it is fixed here rather
-- than carried into the feature.
--
-- NULL is the honest value: the client holds no active permit, so there is no correct binding. It is
-- also what the 232 permitless cards already have, so this makes them consistent rather than special.
UPDATE derm.address_row_map r
   SET gdo_id = NULL
  FROM public.gdos g
 WHERE g.id = r.gdo_id
   AND r.matched_client_id IS NOT NULL
   AND NOT (g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$');

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_bad integer; v_placed integer;
BEGIN
  -- 1. Sane volume. A runaway here would bind hundreds of cards to a guessed permit.
  SELECT count(*) INTO v_n FROM _bf_before;
  IF v_n = 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: nothing to backfill; the predicate is wrong'; END IF;
  IF v_n > 400 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % rows targeted, far more than expected', v_n; END IF;

  -- 2. Every targeted row is now bound, and to the permit we intended.
  SELECT count(*) INTO v_bad
    FROM _bf_before b JOIN derm.address_row_map r ON r.id = b.id
   WHERE r.gdo_id IS DISTINCT FROM b.only_permit;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % row(s) did not take the intended permit', v_bad; END IF;

  -- 3. 🛑 THE CROSS-CLIENT GUARD. 14 GDO numbers are shared across rows, so a card must never end up
  --    pointing at a permit belonging to a different client. Asserted over the WHOLE table, not just
  --    the rows written, so a pre-existing violation would also surface.
  SELECT count(*) INTO v_bad
    FROM derm.address_row_map r JOIN public.gdos g ON g.id = r.gdo_id
   WHERE r.matched_client_id IS NOT NULL AND g.client_id IS DISTINCT FROM r.matched_client_id;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % card(s) point at another client''s permit', v_bad;
  END IF;

  -- 4. The ambiguous ones were NOT touched: every card whose client holds 2+ active permits and had
  --    no binding still has none.
  SELECT count(*) INTO v_bad
    FROM derm.address_row_map r
   WHERE r.gdo_id IS NOT NULL AND r.matched_client_id IS NOT NULL
     AND r.id IN (SELECT id FROM _bf_before)
     AND (SELECT count(*) FROM public.gdos g
           WHERE g.client_id = r.matched_client_id
             AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$') <> 1;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % ambiguous card(s) were bound', v_bad; END IF;

  -- 5. THE POINT: more rectangles can now show a badge, and none lost one.
  SELECT count(*) FILTER (WHERE gdo_label IS NOT NULL) INTO v_placed
    FROM derm.v_stamp_rows WHERE placed;
  -- was 370, of which 2 were the stale 241-WYN bindings PART 2 clears, so the floor is 368 + the
  -- backfilled ones. Asserting a real increase, not merely "not worse".
  IF v_placed <= 370 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: labelled placed cards is % , expected more than the 370 we started with', v_placed;
  END IF;
  RAISE NOTICE 'labelled placed cards: 370 -> %', v_placed;

  -- 6. The 232 with no active permit still have no binding, which is the correct answer rather than
  --    a gap: there is no nickname to show.
  SELECT count(*) INTO v_bad
    FROM derm.address_row_map r
   WHERE r.gdo_id IS NOT NULL AND r.matched_client_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.gdos g
                      WHERE g.id = r.gdo_id AND g.status = 'ACTIVE'
                        AND g.gdo_number ~ '^GDO-[0-9]+$');
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: % card(s) bound to a non-active or malformed permit', v_bad;
  END IF;

  RAISE NOTICE 'VERIFY ok: % unambiguous cards bound, 0 cross-client, ambiguous and permitless cards untouched.', v_n;
END $do$;

COMMIT;
