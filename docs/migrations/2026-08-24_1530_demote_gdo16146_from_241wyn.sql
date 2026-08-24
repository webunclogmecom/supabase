-- ============================================================================
-- 2026-08-24_1530  GDO-16146 belongs to 242-WYN, not 241-WYN. Second time for this pair.
--                  Plus: record the permit-renewal rule, which was nowhere.
-- ============================================================================
--
-- Fred, asked who owns GDO-16146: *"241-WYN has no GDO so far as i can see on the clients app, and
-- the clients app shows it belongs to 242-WYN."*
--
-- And, asked whether an expired permit should keep its printed row: *"even if a GDO expires their
-- numbers doesn't changes on renewal, so even if it's expired keep it until the next GDO updates
-- it, but it's number will not change unless the physical address of the place changes."*
--
-- ---------------------------------------------------------------------------
-- PART 0.  THIS EXACT MISTAKE WAS ALREADY MADE AND ALREADY CORRECTED ONCE
-- ---------------------------------------------------------------------------
--
-- 241-WYN (Wynd 27) and 242-WYN (Wynd 28) are two units of the same building and share a street
-- address: **127 Northwest 27th Street Suite 105, Miami**. Both are ACTIVE clients; 241-WYN is real
-- and serviced (11 alive visits, 2 manifests), not a shell.
--
-- 241-WYN has carried TWO permit rows, and both are 242-WYN's:
--
--   gdo 191  GDO-13814  DEMOTED 2026-06-27 by the GDO bot, note verbatim:
--                       "GDO-13814 is 'WYNWOOD 28 - SHELL' (the permit for unit/dev 28 = client
--                        242-WYN Wynd 28). 241-WYN is Wynd 27, a different unit; not its permit."
--   gdo 216  GDO-16146  still ACTIVE -- this file
--
-- 🛑 **WHY THE AUDIT MISSED THE SECOND ONE, AND IT IS THE REUSABLE PART.** gdo 216's own notes say
-- it was *"adjudicated + skeptic-verified vs the permit PDF address"* and *"[2026-07-18 full-audit
-- verification: DERM permit PDF read; printed Facility Location matches this client's address."*
-- That verification is sound and still cannot work here: **both clients have the same address**, so
-- matching a permit PDF's Facility Location against a client address cannot tell 241-WYN from
-- 242-WYN. The check was pointed at the one field that is identical for both. It is the same trap
-- that produced the GDO-13814 error, and the same audit passed it twice.
-- ⇒ To attribute a permit inside a multi-tenant building, the discriminator has to be the TENANT
-- (the permit's facility/trade name), never the street address.
--
-- WHAT THE DATA SAYS ABOUT WHO OWNS IT, independently of the app:
--   * 242-WYN's copy (gdo 228) is bound to client_location 8 = **"Pari Pari"**, one of five named
--     tenant locations on property 217 (Pasta, Presidente, CU4, Nino Gordo, Pari Pari).
--   * 242-WYN also has a property named "Pari Pari" (1061), and there is a retired client
--     **220-WYN "Pari Pari"** whose property is literally named "Pari Pari (Wynd 28)".
--   * 241-WYN's copy (gdo 216) has nickname **"Main"**, no client_location, and its location_label
--     is just the shared street address -- the generic shape of a placeholder, not a tenant.
--
-- So Pari Pari is unambiguously a Wynd 28 tenant, and Fred's reading of the Client App matches the
-- data. Demoting, exactly as gdo 191 was demoted: the row STAYS on 241-WYN as INACTIVE, so the
-- mistaken claim remains visible rather than being erased.
--
-- ---------------------------------------------------------------------------
-- PART 1.  WHAT THIS CHANGES, MEASURED BEFORE WRITING
-- ---------------------------------------------------------------------------
--
--   * **No printed sheet changes.** 241-WYN is on NO generated sheet at all. 242-WYN's
--     `rows_printed = 3` is frozen on sheets 1087 / 1091 / 1092 / 1093 / 1094 and is untouched --
--     this demotion removes a permit from the OTHER client.
--   * **241-WYN is left with ZERO active well-formed permits**, which is exactly what Fred sees in
--     the Client App. That is a legal state, and the form is built for it: Section B's columns are
--     "GDO #", "Facility Name **(if no GDO#)**", "Complete Facility Address **(if no GDO#)**", and
--     pdf_service renders `greatest(1, permit_count)` = one row carrying name + address.
--   * `public.gdos` IS audited (`audit_gdos`), so this status flip is reversible from
--     `audit.logs.old_row`.
--
-- ⚠ **TWO CARDS STILL LABEL THEMSELVES WITH THIS PERMIT AND ARE DELIBERATELY LEFT ALONE:**
-- card 11 (`derm/1236`) and card 615 (`ticket-829216`), both 241-WYN's own rows on scanned sheets.
-- The permit row keeps its id, so nothing breaks. Whether the writer actually wrote GDO-16146 on
-- those two papers is a question about the paper, and clearing a label to match a database is the
-- wrong direction to reason in. Raised, not acted on.
--
-- ⚠ **THREE OTHER ACTIVE PERMIT NUMBERS ARE CLAIMED BY TWO CLIENTS EACH AND ARE NOT TOUCHED HERE:**
--     GDO-07147  212-TRUE + 213-TRUE
--     GDO-08422  209-TRUE + 214-MYK
--     GDO-08912  139-LTG + 144-LTG
-- Same shape, each needs its own adjudication against the tenant rather than the address. Listed so
-- they are not lost.
--
-- ---------------------------------------------------------------------------
-- PART 2.  THE RENEWAL RULE, WHICH WAS DOCUMENTED NOWHERE
-- ---------------------------------------------------------------------------
--
-- Fred: a GDO number **does not change on renewal**. An expired permit keeps its number and stays
-- in force for our purposes until the renewed permit updates it. The number changes only if the
-- **physical address** of the place changes.
--
-- ⇒ `permit_expiration` in the past is NOT a reason to deactivate a permit, drop its printed row,
-- or withhold it from a sheet. 242-WYN's GDO-14760 (Nino Gordo) expired 2025-12-31 and correctly
-- keeps row 2 of every sheet it appears on. `status` is the flag that decides inclusion;
-- `permit_expiration` is a fact about the paper.
--
-- This is recorded as a column comment because it is the kind of rule a future cleanup would
-- otherwise "fix" by expiring stale permits.
--
-- ---------------------------------------------------------------------------
-- ADR 010 rule 8 (audit): `public.gdos` already carries `audit_gdos`. No schema change; one status
-- flip and two comments.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 3.  Demote, pinned to the id AND re-asserting what makes it demotable
-- ---------------------------------------------------------------------------

UPDATE public.gdos g
   SET status = 'INACTIVE',
       notes = coalesce(g.notes || E'\n', '')
         || '[2026-08-24 Fred] DEMOTED. GDO-16146 is 242-WYN Wynd 28''s permit for its Pari Pari '
         || 'tenant (client_location 8). 241-WYN is Wynd 27, a different unit of the same building; '
         || 'not its permit. The 2026-07-18 audit passed this row because it verified the permit '
         || 'PDF''s Facility Location against the client address, and BOTH clients share '
         || '127 NW 27th St Suite 105 -- the address cannot discriminate them. Same error and same '
         || 'cause as GDO-13814, demoted from this client 2026-06-27. 241-WYN is left with no '
         || 'active permit, which is what the Client App shows.',
       updated_at = now()
 WHERE g.id = 216
   AND g.gdo_number = 'GDO-16146'
   AND g.status = 'ACTIVE'
   -- the predicate that makes it demotable, re-asserted so this cannot fire on a changed world
   AND g.client_id = (SELECT id FROM public.clients WHERE client_code = '241-WYN')
   AND EXISTS (SELECT 1 FROM public.gdos o
                JOIN public.clients oc ON oc.id = o.client_id
               WHERE o.gdo_number = 'GDO-16146' AND oc.client_code = '242-WYN'
                 AND o.status = 'ACTIVE' AND o.client_location_id IS NOT NULL);

-- ---------------------------------------------------------------------------
-- PART 4.  The renewal rule
-- ---------------------------------------------------------------------------

COMMENT ON COLUMN public.gdos.permit_expiration IS
  'The expiry printed on the DERM permit. 🛑 A PAST DATE IS NOT A REASON TO DEACTIVATE THE PERMIT, '
  'drop its printed row on a DERM address sheet, or withhold it from a filing. Fred, 2026-08-24: a '
  'GDO number does NOT change on renewal -- an expired permit keeps its number and stays in force '
  'for our purposes until the renewed permit updates it, and the number changes only if the '
  'PHYSICAL ADDRESS of the place changes. Live example: 242-WYN GDO-14760 (Nino Gordo) expired '
  '2025-12-31 and correctly keeps its row. `status` decides inclusion; this column is a fact about '
  'the paper. See docs/migrations/2026-08-24_1530_demote_gdo16146_from_241wyn.sql.';

COMMENT ON COLUMN public.gdos.client_location_id IS
  'The tenant this permit was issued to, within a multi-tenant building. 🛑 THIS, NOT THE ADDRESS, '
  'IS THE DISCRIMINATOR when attributing a permit: 241-WYN and 242-WYN share 127 NW 27th St Suite '
  '105, so two separate audits attributed two of Wynd 28''s permits to Wynd 27 by matching the '
  'permit PDF address against the client address. See the same migration.';

-- ---------------------------------------------------------------------------
-- PART 5.  VERIFY
-- ---------------------------------------------------------------------------

DO $$
DECLARE v_n int; v_txt text;
BEGIN
  -- 5.1  it actually fired
  IF NOT EXISTS (SELECT 1 FROM public.gdos WHERE id = 216 AND status = 'INACTIVE') THEN
    RAISE EXCEPTION 'gdo 216 was not demoted -- one of the guard predicates did not hold';
  END IF;

  -- 5.2  241-WYN now has no active well-formed permit, which is what the Client App shows
  SELECT count(*) INTO v_n FROM public.gdos g
   WHERE g.client_id = (SELECT id FROM public.clients WHERE client_code = '241-WYN')
     AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$';
  IF v_n <> 0 THEN RAISE EXCEPTION '241-WYN still has % active permits', v_n; END IF;

  -- 5.3  242-WYN KEEPS ALL THREE. This is the assertion that matters: the demotion must not
  --      have taken a permit off the client that owns them.
  SELECT string_agg(g.gdo_number, ' ' ORDER BY g.gdo_number) INTO v_txt FROM public.gdos g
   WHERE g.client_id = (SELECT id FROM public.clients WHERE client_code = '242-WYN')
     AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$';
  IF v_txt IS DISTINCT FROM 'GDO-13814 GDO-14760 GDO-16146' THEN
    RAISE EXCEPTION '242-WYN''s permits changed: %', coalesce(v_txt, 'NONE');
  END IF;

  -- 5.4  no printed layout moved. rows_printed is frozen, but assert it anyway -- this is the
  --      column whose silent re-indexing 2026-08-24_0450 exists to prevent.
  SELECT count(*) INTO v_n FROM derm.address_sheet_clients c
   WHERE c.client_id = (SELECT id FROM public.clients WHERE client_code = '242-WYN')
     AND c.rows_printed <> 3;
  IF v_n <> 0 THEN RAISE EXCEPTION '% of 242-WYN''s sheet rows no longer say 3', v_n; END IF;

  -- 5.5  GDO-16146 is now claimed by exactly one ACTIVE row, and the other three duplicate
  --      pairs are untouched -- if this file quietly resolved them too, that is a bug.
  SELECT count(*) INTO v_n FROM public.gdos g
   WHERE g.gdo_number = 'GDO-16146' AND g.status = 'ACTIVE';
  IF v_n <> 1 THEN RAISE EXCEPTION 'GDO-16146 is ACTIVE on % clients, expected 1', v_n; END IF;

  SELECT count(*) INTO v_n FROM (
    SELECT g.gdo_number FROM public.gdos g WHERE g.status = 'ACTIVE'
     GROUP BY g.gdo_number HAVING count(DISTINCT g.client_id) > 1) q;
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'expected the 3 other duplicate permit numbers to remain, found %', v_n;
  END IF;

  -- 5.6  the two cards that reference this permit still resolve (status flip, not a delete)
  SELECT count(*) INTO v_n FROM derm.address_row_map a
    JOIN public.gdos g ON g.id = a.gdo_id WHERE a.gdo_id = 216;
  IF v_n <> 2 THEN RAISE EXCEPTION 'the 2 cards on gdo 216 no longer resolve'; END IF;

  RAISE NOTICE 'OK: gdo 216 demoted, 241-WYN has 0 permits, 242-WYN keeps 3, 3 duplicate pairs left alone';
END $$;

COMMIT;
