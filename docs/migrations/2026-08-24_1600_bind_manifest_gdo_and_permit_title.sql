-- ============================================================================
-- 2026-08-24_1600  Bind derm_manifests.gdo_id where it is unambiguous, and give a
--                  permit a title a person recognises
-- ============================================================================
--
-- Fred: *"bind the gdo_id for those 21 manifests"* and, on the Client App's GDO section,
-- *"each GDO has a nickname, put it as the title label. In case there is none, then just put the
-- GDO number as the title."*
--
-- ---------------------------------------------------------------------------
-- PART 0.  🛑 I ASKED FOR THE WRONG 21, AND THIS FILE DOES NOT BIND THEM
-- ---------------------------------------------------------------------------
--
-- I told Fred the 21 manifests carrying no `gdo_id` were "the higher-value half". They are the
-- opposite: **they are the 21 that must stay NULL**, and the 224 I did not mention are the ones
-- worth binding.
--
-- The 21 are exactly the manifests of the four MULTI-PERMIT clients (009-CN, 043-MIL, 148-MOR,
-- 242-WYN). A manifest is the record of ONE pump-out of ONE shared grease trap. For Wynd 28 that
-- single pump-out is the evidence for GDO-13814, GDO-14760 AND GDO-16146 together. `gdo_id` is a
-- single FK, so writing one of the three would assert the pump-out evidences only that permit --
-- **false, and the same per-visit-vs-per-permit collapse Fred had fixed twice already that same
-- day**, in `2026-08-24_1215` (DERM Tracker card) and `2026-08-24_1730` (customer.gdo_reports).
--
-- ⇒ AND THE ESTATE ALREADY HAS THE RIGHT PATTERN. `customer.gdo_reports` reaches per-permit grain
-- by EXPANDING -- one row per (visit, ACTIVE permit) -- and the permit binding lives on the
-- `derm_portal_submissions` row, which is genuinely per-permit because the bot files one permit per
-- run. Evidence that covers several permits is expanded at READ time; it is not crammed into one FK.
--
-- ⚠ `derm.audit_pack` already performs this collapse where `gdo_id` is NULL: it falls back to
-- `ORDER BY g2.id LIMIT 1`, i.e. it silently picks the lowest-id permit. For 242-WYN that is
-- GDO-13814. Not changed here -- flagged, because it is a real instance of the same shape.
--
-- **What a per-permit manifest link would take, if it is ever wanted:** a `manifest_id x gdo_id`
-- link table, or read-time expansion like `customer.gdo_reports`. Both are real work and neither is
-- this file.
--
-- ---------------------------------------------------------------------------
-- PART 1.  WHAT IS ACTUALLY BINDABLE: 224, WITH NO JUDGEMENT REQUIRED
-- ---------------------------------------------------------------------------
--
-- Live manifests with `gdo_id IS NULL`, by how many ACTIVE well-formed permits their client holds:
--
--     client holds 1 permit    224   <- BOUND HERE. One client, one permit, nothing to choose.
--     client holds 2 permits     9   <- left NULL (PART 0)
--     client holds 3 permits    12   <- left NULL (PART 0)
--     client holds NO permit    222   <- correctly NULL and must stay so
--
-- After this, `gdo_id` means the same thing everywhere it is set: *the single permit this manifest
-- is evidence for*. It stops meaning "whichever permit somebody happened to record".
--
-- Visible effect: `derm.gdos.manifest_count` (`count(*) WHERE dm.gdo_id = g.id`) becomes non-zero
-- for single-permit clients, which is the point.
--
-- ---------------------------------------------------------------------------
-- PART 2.  THE PERMIT TITLE
-- ---------------------------------------------------------------------------
--
-- `client.gdos.display_label` was `COALESCE(nickname, location_label, gdo_number)`. Fred's rule
-- drops the middle term: **nickname, else the GDO number.**
--
-- Measured: **134 of 135 ACTIVE permits carry a nickname**, so for everything the Client App shows
-- today this is exactly the nickname -- Pasta, Nino Gordo, Pari Pari -- and the fallback is purely
-- defensive. The one exception is `PSO-00025` (057-BAY), a placeholder rather than a real permit,
-- which will title as its own number.
--
-- ⚠ **FIVE PERMITS DO LOSE A BETTER TITLE, AND ALL FIVE ARE INACTIVE.** They have no nickname but a
-- `location_label` that is a trade name rather than an address, so under the new rule they show a
-- number instead:
--     GDO-02118 "SAN LAZARO CAFETERIA" (188-ACA)   GDO-04943 "ADRIANA" (025-GRO)
--     GDO-07382 "MACITAS RESTAURANT" (187-HAI)     GDO-11708 "URBAN BRICKS PIZZA CO" (036-LG)
--     GDO-15303 "Aloft hotels" (233-AH)
-- Recorded rather than quietly kept: if Fred wants those five to keep their labels the fix is to
-- copy `location_label` into `nickname` for them, not to re-add the fallback.
--
-- 🛑 THIS IS THE DATA HALF ONLY. The Client App renders the literal string "Grease trap permit" as
-- each card's heading; nothing in the DB produces that. Switching the heading to `display_label` is
-- a Lovable edit to the Client App and is NOT done here. The contract is documented in
-- `Building Apps/Client App/docs/`.
--
-- ⚠ `display_label` exists ONLY on `client.gdos`. `derm.manifests` and `derm.manifest_recipients`
-- match the string but define their own unrelated columns; neither is touched.
--
-- ---------------------------------------------------------------------------
-- ADR 010 rule 8 (audit): `public.derm_manifests` is already audited, so the 224 UPDATEs are
-- captured with `old_row` intact and are reversible. No schema change; one view replaced.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 3a.  ONE PRE-EXISTING CROSS-CLIENT BINDING, FOUND BY THIS FILE'S OWN CHECK
-- ---------------------------------------------------------------------------
--
-- PART 5.1 asserts that no manifest is bound to another client's permit. It failed on the first
-- run, on a row that predates this migration -- PART 3b's UPDATE joins `g.client_id = m.client_id`
-- and cannot produce one:
--
--     manifest 679   ticket 298064, serviced 2026-02-13, belongs to 144-LTG
--     bound to       gdo 29 "GDO-08912-DUPMERGE-147" [INACTIVE], which belongs to 139-LTG
--
-- The permit's name is a de-duplication artifact, and GDO-08912 is one of the three numbers still
-- claimed by two clients (139-LTG + 144-LTG). So a 144-LTG manifest was attributed to 139-LTG's
-- copy of a disputed permit.
--
-- Cleared HERE, before PART 3b, so the ordinary unambiguous bind then re-points it to **144-LTG's
-- OWN** permit. 144-LTG holds exactly one ACTIVE well-formed permit, so no judgement is involved,
-- and the result is correct however the 139-vs-144 dispute is eventually settled: if 144-LTG's copy
-- is later demoted, the row simply becomes a manifest bound to an inactive permit of its own
-- client, which is the state 14 rows are already in. The defect was the CLIENT boundary, not the
-- permit number.
--
-- ⚠ A first draft cleared it to NULL and left it there, which then tripped PART 5.1's other arm --
-- "a single-permit client's manifest must be bound". Two halves of the same check disagreeing is
-- the signal that the intermediate state was wrong, not that the check was.
--
-- 🛑 Neither arm was weakened to let this pass. That is the point of them.

UPDATE public.derm_manifests m
   SET gdo_id = NULL
  FROM public.gdos g
 WHERE m.id = 679
   AND g.id = m.gdo_id
   AND g.client_id <> m.client_id;   -- re-asserts the defect; inert if it was fixed meanwhile

-- ---------------------------------------------------------------------------
-- PART 3b. Bind the unambiguous 224
-- ---------------------------------------------------------------------------

UPDATE public.derm_manifests m
   SET gdo_id = g.id
  FROM public.gdos g
 WHERE m.deleted_at IS NULL
   AND m.gdo_id IS NULL
   AND g.client_id = m.client_id
   AND g.status = 'ACTIVE'
   AND g.gdo_number ~ '^GDO-[0-9]+$'
   -- the whole safety of this statement: bind ONLY where the client has exactly one such permit,
   -- re-asserted inside the statement so it cannot fire if the world changed since PART 1 was
   -- measured.
   AND (SELECT count(*) FROM public.gdos g2
         WHERE g2.client_id = m.client_id
           AND g2.status = 'ACTIVE'
           AND g2.gdo_number ~ '^GDO-[0-9]+$') = 1;

-- ---------------------------------------------------------------------------
-- PART 4.  The title
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW client.gdos AS
 SELECT id,
    client_id,
    gdo_number,
    location_label,
    property_id,
    permit_expiration,
    permit_document_path,
    status,
    notes,
    created_at,
    updated_at,
    max_frequency_days,
    client_location_id,
    permit_thumbnail_path,
    (gdo_number !~ '^GDO-[0-9]+$'::text) AS is_placeholder,
    nickname,
    -- Fred, 2026-08-24: the nickname is the title; with no nickname, the GDO number.
    -- location_label is deliberately NOT a fallback -- it is often just the street address, which
    -- is a poor heading and is identical for every tenant of a multi-tenant building.
    COALESCE(nickname, gdo_number) AS display_label
   FROM gdos;

COMMENT ON VIEW client.gdos IS
  'Client App permit list. display_label is the card TITLE: the permit''s nickname (Pasta, Nino '
  'Gordo, Pari Pari), falling back to the GDO number when there is none. Fred, 2026-08-24. '
  'location_label is exposed but is NOT the title -- it is often the street address, which is '
  'identical for every tenant of a multi-tenant building. '
  'See docs/migrations/2026-08-24_1600_bind_manifest_gdo_and_permit_title.sql.';

-- ---------------------------------------------------------------------------
-- PART 5.  VERIFY
-- ---------------------------------------------------------------------------

DO $verify$
DECLARE v_n int; v_txt text;
BEGIN
  ------------------------------------------------------------------------
  -- 5.1  Every single-permit manifest is now bound, and bound to THAT client's permit.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL AND m.gdo_id IS NULL
     AND (SELECT count(*) FROM public.gdos g WHERE g.client_id = m.client_id
           AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$') = 1;
  IF v_n <> 0 THEN RAISE EXCEPTION '% single-permit manifests are still unbound', v_n; END IF;

  -- 🛑 the binding must never cross a client boundary
  SELECT count(*) INTO v_n FROM public.derm_manifests m
    JOIN public.gdos g ON g.id = m.gdo_id
   WHERE m.deleted_at IS NULL AND g.client_id <> m.client_id;
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% manifests are bound to a permit belonging to a DIFFERENT client', v_n;
  END IF;

  ------------------------------------------------------------------------
  -- 5.2  THE ONE THAT MATTERS MOST: the ambiguous 21 must still be NULL. If this file
  --      quietly bound them it has committed the collapse PART 0 exists to refuse.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL AND m.gdo_id IS NOT NULL
     AND (SELECT count(*) FROM public.gdos g WHERE g.client_id = m.client_id
           AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$') > 1;
  IF v_n <> 2 THEN
    -- 2 pre-existing rows were bound before today and are left as found; anything more means
    -- this migration bound a multi-permit manifest.
    RAISE EXCEPTION 'expected the 2 pre-existing multi-permit bindings, found % -- a shared-trap manifest was bound to one permit', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL AND m.gdo_id IS NULL
     AND (SELECT count(*) FROM public.gdos g WHERE g.client_id = m.client_id
           AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$') > 1;
  IF v_n <> 21 THEN RAISE EXCEPTION 'expected the 21 shared-trap manifests to stay NULL, found %', v_n; END IF;

  ------------------------------------------------------------------------
  -- 5.3  Clients with NO permit must not have acquired one.
  ------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL AND m.gdo_id IS NULL
     AND (SELECT count(*) FROM public.gdos g WHERE g.client_id = m.client_id
           AND g.status = 'ACTIVE' AND g.gdo_number ~ '^GDO-[0-9]+$') = 0;
  IF v_n <> 222 THEN RAISE EXCEPTION 'expected 222 no-permit manifests to stay NULL, found %', v_n; END IF;

  ------------------------------------------------------------------------
  -- 5.4  The title, on the live example Fred was looking at.
  ------------------------------------------------------------------------
  SELECT string_agg(display_label, ' | ' ORDER BY gdo_number) INTO v_txt
    FROM client.gdos
   WHERE client_id = (SELECT id FROM public.clients WHERE client_code = '242-WYN')
     AND status = 'ACTIVE';
  IF v_txt IS DISTINCT FROM 'Pasta | Nino Gordo | Pari Pari' THEN
    RAISE EXCEPTION '242-WYN''s permit titles are "%", expected the three nicknames', coalesce(v_txt, 'NULL');
  END IF;

  -- CONTROL: the fallback must actually be the NUMBER, not the location_label. Without this the
  -- change could be a no-op and 5.4 would still pass, since every active permit has a nickname.
  SELECT display_label INTO v_txt FROM client.gdos WHERE gdo_number = 'GDO-02118';
  IF v_txt IS DISTINCT FROM 'GDO-02118' THEN
    RAISE EXCEPTION 'a nickname-less permit titles as "%", so location_label is still a fallback', coalesce(v_txt, 'NULL');
  END IF;

  -- and nothing lost a title it should have kept: every ACTIVE permit still shows a nickname
  SELECT count(*) INTO v_n FROM client.gdos
   WHERE status = 'ACTIVE' AND nickname IS NOT NULL AND display_label <> nickname;
  IF v_n <> 0 THEN RAISE EXCEPTION '% active permits are not titled by their nickname', v_n; END IF;

  RAISE NOTICE 'OK: 224 manifests bound, 21 shared-trap manifests deliberately left NULL, titles are nicknames';
END $verify$;

COMMIT;
