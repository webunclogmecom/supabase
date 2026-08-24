-- ============================================================================
-- 2026-08-24_0450  The facility-grain slot map: freeze rows_printed, and teach
--                  the auto-stamp gate that one client can occupy several rows
-- ============================================================================
--
-- Fred: generated manifests (top-right sheet number 1000+) must be AI-stamped. 833395 and 312024
-- were not. This file fixes the half of that which is a real defect.
--
-- ---------------------------------------------------------------------------
-- PART 0.  WHAT WAS ACTUALLY WRONG
-- ---------------------------------------------------------------------------
--
-- A DERM address sheet prints ONE ROW PER PERMITTED FACILITY, not one row per client. The
-- generator has always known this. pdf_service/app.py expands a client to one row per ACTIVE,
-- strictly well-formed GDO-<digits> permit, sorted by number, and renders a single row for a
-- client with 0 or 1 permit. That is Fred's own rule for a multi-tenant building such as Wynd 28:
-- one shared trap, one GDO per tenant, every permitted facility documented on its own line.
--
-- The DB knew it in ONE place and not in the other:
--
--   derm.fn_generated_sheet_slot      expands correctly (sums greatest(1, active GDO count) over
--                                     every earlier slot) -> the STAMP lands on the right row
--   derm.fn_sheet_rows_all_confirmed  does NOT. It reads derm.address_sheet_clients.slot, the
--                                     CLIENT ordinal, straight into the printed-row arithmetic:
--                                       page     = ((slot - 1) / 5) + 1
--                                       row_index= ((slot - 1) % 5) + 1
--                                     So for any sheet carrying a multi-permit client, every slot
--                                     beneath that client is compared against the wrong printed
--                                     row, bool_and goes false, and the sheet can never resolve.
--
-- MEASURED ON THE PAPER, ticket-833395 / sheet 1093 (id 131):
--
--   DB slot order    1:242-WYN 2:069-TCE 3:032-LG 4:026-HAP 5:249-LOU 6:077-TCE 7:199-STK 8:226-JER
--   242-WYN          3 ACTIVE GDO-<digits> permits, and 7 properties
--   row OCR, image p2   row1=242-WYN  row2=242-WYN  row3=242-WYN  row4=069-TCE  row5=032-LG
--   row OCR, image p1   row1=026-HAP  row2=249-LOU  row3=077-TCE  row4=199-STK  row5=226-JER
--   scan reads          image p1 = "1093-2", image p2 = "1093-1"   (the images are in reverse order)
--
-- So the printed truth is 10 rows, 242-WYN occupying rows 1-3, and it matches
-- fn_generated_sheet_slot exactly. It is the GDO count that sets the row span, NOT the property
-- count: 3 permits gave 3 rows while the client has 7 properties.
--
-- Under the old gate, slot 2 (069-TCE) was compared against printed row 2, which reads 242-WYN,
-- so derm.fn_sheet_rows_all_confirmed('833395', 131, 'ticket-833395') returned FALSE and
-- fn_resolve_generated_sheet_for_ticket('833395') returned NULL. Verified false before this file.
--
-- ---------------------------------------------------------------------------
-- PART 0b.  WHY THE SPAN IS FROZEN RATHER THAN RE-DERIVED
-- ---------------------------------------------------------------------------
--
-- fn_generated_sheet_slot computed rows_printed from a LIVE count over public.gdos, every time it
-- was called. A printed sheet is a historical artefact and public.gdos is mutable, so adding or
-- deactivating one permit for 242-WYN silently re-indexes the FIVE already-printed sheets that
-- carry it, moving stamps onto other clients' printed rows. Through the Field Portal blackout that
-- is one client shown another client's line on a regulator-facing document, which is the exact
-- harm the whole band pipeline exists to prevent. Nothing would have raised.
--
-- So the span is now stored on derm.address_sheet_clients at generation time and read back
-- unchanged. The backfill uses the same live expression the old code used, and PART 2 asserts the
-- two agree for all 191 rows, so this migration is a no-op for today's data by construction.
--
-- ---------------------------------------------------------------------------
-- PART 0c.  ONE DELIBERATE BEHAVIOUR CHANGE, IN THE FAIL-CLOSED DIRECTION
-- ---------------------------------------------------------------------------
--
-- The old fn_generated_sheet_slot carried the comment "NULL when the order was never recorded:
-- caller must refuse, not guess." Its body did not do that. With a bound manifest on a sheet that
-- has no derm.address_sheet_clients rows at all, the `before` CTE was empty, sum() returned NULL,
-- coalesce made it 0, and the function returned 1: a stamp placed on printed row 1 of a sheet
-- whose printed order is unknown. The new body joins the map and returns NULL, which is what the
-- comment always claimed. Measured before shipping: 0 of the 68 bound manifests are in that state,
-- so this changes no live value, and PART 7 asserts all 68 are byte-identical.
--
-- ---------------------------------------------------------------------------
-- PART 0d.  WHAT THIS FILE DOES NOT FIX
-- ---------------------------------------------------------------------------
--
--   * ticket-312024 is a SEPARATE cause and is untouched here. Page 2 of sheet 1099 was never
--     uploaded (the second image is handwritten pad sheet 421), so fn_sheet_image_position
--     ('ticket-312024', 2) is NULL and the closed-world rule correctly refuses. That is a missing
--     scan, not a code defect.
--   * Nothing schedules ocr-address-sheet-rows. The function is deployed and works, but no cron
--     and no DB function references it, so derm.address_sheet_row_reads only fills when somebody
--     invokes it by hand. Until that is scheduled, this gate has nothing to read for most tickets
--     and a generated sheet still will not auto-resolve. Raised separately, deliberately not
--     bundled into a migration that changes stamp placement.
--
-- ---------------------------------------------------------------------------
-- ADR 010 rule 8 (audit-trail standing check): OPT OUT, and it is unchanged by this file.
-- derm.address_sheet_clients carries no audit trigger today (verified: 0 non-internal triggers).
-- It is a machine-written mirror of a generated PDF's layout, rewritten wholesale by
-- record_generated_sheet_preview on every regeneration, with no human-editable field and no
-- customer, billing or webhook-secret data. It holds no DERM compliance record either: the
-- compliance artefacts are derm_manifests and derm.address_row_map, both audited. Adding a column
-- to a non-audited table needs no trigger work. Grants are unchanged and remain postgres +
-- service_role only; the new view is granted to service_role and explicitly revoked from
-- PUBLIC/anon/authenticated, per the ALTER DEFAULT PRIVILEGES trap in CLAUDE.md.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1.  The stored span
-- ---------------------------------------------------------------------------

ALTER TABLE derm.address_sheet_clients
  ADD COLUMN IF NOT EXISTS rows_printed smallint NOT NULL DEFAULT 1;

ALTER TABLE derm.address_sheet_clients
  DROP CONSTRAINT IF EXISTS address_sheet_clients_rows_printed_chk;
ALTER TABLE derm.address_sheet_clients
  ADD CONSTRAINT address_sheet_clients_rows_printed_chk
  CHECK (rows_printed BETWEEN 1 AND 20);

COMMENT ON COLUMN derm.address_sheet_clients.rows_printed IS
  'How many printed rows this client occupies on the generated sheet: one per ACTIVE GDO-<digits> '
  'permit, minimum 1, matching pdf_service/app.py. FROZEN at generation time on purpose -- '
  'public.gdos is mutable and re-deriving it would silently re-index already-printed sheets. '
  'See docs/migrations/2026-08-24_0450_facility_grain_slot_map.sql PART 0b.';

-- ---------------------------------------------------------------------------
-- PART 2.  Backfill from the expression the old code used, then prove they agree
-- ---------------------------------------------------------------------------

UPDATE derm.address_sheet_clients c
   SET rows_printed = greatest(1, (
         SELECT count(*) FROM public.gdos g
          WHERE g.client_id = c.client_id
            AND g.status = 'ACTIVE'
            AND g.gdo_number ~ '^GDO-[0-9]+$'))::smallint
 WHERE c.rows_printed IS DISTINCT FROM greatest(1, (
         SELECT count(*) FROM public.gdos g
          WHERE g.client_id = c.client_id
            AND g.status = 'ACTIVE'
            AND g.gdo_number ~ '^GDO-[0-9]+$'))::smallint;

DO $$
DECLARE v_bad int; v_rows int; v_multi int;
BEGIN
  SELECT count(*) INTO v_bad
    FROM derm.address_sheet_clients c
   WHERE c.rows_printed <> greatest(1, (
           SELECT count(*) FROM public.gdos g
            WHERE g.client_id = c.client_id AND g.status = 'ACTIVE'
              AND g.gdo_number ~ '^GDO-[0-9]+$'))::smallint;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'backfill disagrees with the live derivation on % rows', v_bad;
  END IF;

  SELECT count(*) INTO v_rows FROM derm.address_sheet_clients;
  SELECT count(*) INTO v_multi FROM derm.address_sheet_clients WHERE rows_printed > 1;
  -- The control: if NOTHING has a span > 1 the backfill is an untested instrument and the whole
  -- premise of this migration is unmeasured. 242-WYN (3 permits, 5 sheets) and 043-MIL (2 permits,
  -- 1 sheet) are the live population.
  IF v_multi = 0 THEN
    RAISE EXCEPTION 'no client on any sheet spans more than one printed row: backfill is untested';
  END IF;
  RAISE NOTICE 'PART 2 OK: % client rows, % of them spanning more than one printed row', v_rows, v_multi;
END $$;

-- ---------------------------------------------------------------------------
-- PART 3.  The facility-grain slot map itself, at PRINTED-ROW grain
-- ---------------------------------------------------------------------------
--
-- One row per printed row. is_first_row marks where the client's stamp goes; the remaining rows of
-- a multi-permit block exist so a reader can be checked against every line the client owns.
--
-- printed_page / row_on_page repeat fn_generated_row_geometry's 5-rows-per-page arithmetic. They
-- are the LOGICAL page, never the image position: callers must still put the result through
-- derm.fn_sheet_image_position, which is what knows the pages of ticket-833395 are stored in
-- reverse order.

CREATE OR REPLACE VIEW derm.v_sheet_printed_rows AS
WITH span AS (
  SELECT c.sheet_id,
         c.slot,
         c.client_id,
         c.visit_id,
         c.rows_printed,
         (1 + COALESCE(SUM(c.rows_printed) OVER (PARTITION BY c.sheet_id ORDER BY c.slot
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0))::int AS first_row
    FROM derm.address_sheet_clients c
)
SELECT s.sheet_id,
       s.slot,
       s.client_id,
       s.visit_id,
       s.rows_printed,
       s.first_row,
       (s.first_row + s.rows_printed - 1)          AS last_row,
       g.n                                          AS printed_row,
       (((g.n - 1) / 5) + 1)                        AS printed_page,
       (((g.n - 1) % 5) + 1)                        AS row_on_page,
       (g.n = s.first_row)                          AS is_first_row
  FROM span s
  CROSS JOIN LATERAL generate_series(s.first_row, s.first_row + s.rows_printed - 1) AS g(n);

COMMENT ON VIEW derm.v_sheet_printed_rows IS
  'The facility-grain slot map: one row per PRINTED ROW of a generated DERM address sheet. A '
  'client occupies one row per ACTIVE GDO permit (address_sheet_clients.rows_printed), so slot '
  'and printed_row diverge below any multi-permit client. printed_page is the LOGICAL page -- put '
  'it through derm.fn_sheet_image_position before touching an image.';

REVOKE ALL ON derm.v_sheet_printed_rows FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON derm.v_sheet_printed_rows FROM anon';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'REVOKE ALL ON derm.v_sheet_printed_rows FROM authenticated';
  END IF;
END $$;
GRANT SELECT ON derm.v_sheet_printed_rows TO service_role;

-- ---------------------------------------------------------------------------
-- PART 4.  Freeze the span at generation time
-- ---------------------------------------------------------------------------
--
-- Body copied from the live pg_get_functiondef output, per the CREATE OR REPLACE rule in
-- CLAUDE.md. The ONLY change is rows_printed in the INSERT. The signature is deliberately
-- unchanged: adding a defaulted parameter would create a second overload and make the app's
-- existing 2-argument call ambiguous.

CREATE OR REPLACE FUNCTION derm.record_generated_sheet_preview(
  p_sheet_no bigint, p_client_ids bigint[], p_visit_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare v_sheet_id bigint;
begin
  if p_sheet_no is null or p_client_ids is null or array_length(p_client_ids,1) is null then
    raise exception 'sheet_no and client_ids are required';
  end if;

  insert into derm.address_sheets (sheet_no, pdf_bucket, pdf_path)
  values (p_sheet_no, 'preview', 'preview/' || p_sheet_no::text)
  on conflict (sheet_no) where deleted_at is null
  do update set last_generated_at = now()
  returning id into v_sheet_id;

  -- a regeneration of the same sheet number replaces its printed order
  delete from derm.address_sheet_clients where sheet_id = v_sheet_id;
  insert into derm.address_sheet_clients (sheet_id, slot, client_id, visit_id, rows_printed)
  select v_sheet_id, t.ord, t.cid,
         (select p_visit_ids[t.ord] where p_visit_ids is not null),
         -- FROZEN HERE, at the moment the sheet is generated, because this is the same count
         -- pdf_service/app.py uses to lay the sheet out. Re-deriving it later re-indexes a sheet
         -- that is already on paper. See PART 0b.
         greatest(1, (select count(*) from public.gdos g
                       where g.client_id = t.cid and g.status = 'ACTIVE'
                         and g.gdo_number ~ '^GDO-[0-9]+$'))::smallint
    from unnest(p_client_ids) with ordinality as t(cid, ord);

  return v_sheet_id;
end $function$;

-- ---------------------------------------------------------------------------
-- PART 5.  fn_generated_sheet_slot reads the frozen map
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION derm.fn_generated_sheet_slot(p_manifest_id bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  -- The printed row this manifest's stamp belongs on. NULL when the printed order was never
  -- recorded: the caller must refuse, not guess. (The pre-2026-08-24 body returned 1 in that case,
  -- which is a stamp on row 1 of a sheet whose layout is unknown.)
  select r.first_row
    from public.derm_manifests m
    join derm.address_sheet_manifests l on l.manifest_id = m.id
    join derm.address_sheets s on s.id = l.sheet_id and s.deleted_at is null
    join derm.v_sheet_printed_rows r
      on r.sheet_id = l.sheet_id and r.slot = l.slot and r.is_first_row
   where m.id = p_manifest_id and m.deleted_at is null
   order by l.slot nulls last
   limit 1;
$function$;

-- ---------------------------------------------------------------------------
-- PART 6.  The gate: check EVERY printed row the ticket's clients own
-- ---------------------------------------------------------------------------
--
-- Stricter than before as well as correct: a 3-permit client must have all three of its printed
-- rows read as its own code, not just the first. That also handles the two live blocks that
-- straddle a page boundary (sheet 70 / 043-MIL rows 5-6, sheet 125 / 242-WYN rows 5-7), because
-- each printed row resolves its own logical page independently.

CREATE OR REPLACE FUNCTION derm.fn_sheet_rows_all_confirmed(
  p_ticket text, p_sheet_id bigint, p_dump_folder text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  select coalesce(bool_and(
           derm.fn_row_read_confirms(
             p_dump_folder,
             derm.fn_sheet_image_position(p_dump_folder, r.printed_page),
             r.row_on_page,
             c.client_code) is true
         ), false)
    from derm.v_sheet_printed_rows r
    join public.clients c on c.id = r.client_id
   where r.sheet_id = p_sheet_id
     and r.client_id in (
           select m.client_id
             from public.derm_manifests m
            where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
              and m.deleted_at is null);
$function$;

-- ---------------------------------------------------------------------------
-- PART 7.  VERIFY
-- ---------------------------------------------------------------------------
--
-- The old bodies are re-created under temp names and must FAIL exactly where the new ones pass.
-- A matrix reporting 0 failures is an untested instrument (CLAUDE.md, 2026-08-05).

CREATE OR REPLACE FUNCTION derm._ctl_old_rows_all_confirmed(
  p_ticket text, p_sheet_id bigint, p_dump_folder text)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'derm', 'public'
AS $function$
  select coalesce(bool_and(
           derm.fn_row_read_confirms(
             p_dump_folder,
             derm.fn_sheet_image_position(p_dump_folder, ((asc2.slot - 1) / 5) + 1),
             ((asc2.slot - 1) % 5) + 1,
             c.client_code) is true
         ), false)
    from derm.address_sheet_clients asc2
    join public.clients c on c.id = asc2.client_id
   where asc2.sheet_id = p_sheet_id
     and asc2.client_id in (
           select m.client_id from public.derm_manifests m
            where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
              and m.deleted_at is null);
$function$;

DO $$
DECLARE
  v_old boolean; v_new boolean; v_int int; v_txt text; v_n int;
BEGIN
  ----------------------------------------------------------------------------
  -- 7.1  The map matches the paper for ticket-833395 / sheet 1093, row by row.
  --      This is the only assertion here backed by an actual scan of the sheet.
  ----------------------------------------------------------------------------
  SELECT string_agg(c.client_code || '@' || r.printed_row, ' ' ORDER BY r.printed_row)
    INTO v_txt
    FROM derm.v_sheet_printed_rows r
    JOIN public.clients c ON c.id = r.client_id
   WHERE r.sheet_id = 131;
  IF v_txt IS DISTINCT FROM
     '242-WYN@1 242-WYN@2 242-WYN@3 069-TCE@4 032-LG@5 026-HAP@6 249-LOU@7 077-TCE@8 199-STK@9 226-JER@10'
  THEN
    RAISE EXCEPTION 'sheet 131 printed order does not match the row OCR: %', v_txt;
  END IF;

  -- and every one of those printed rows must agree with what the reader actually read
  SELECT count(*) INTO v_n
    FROM derm.v_sheet_printed_rows r
    JOIN public.clients c ON c.id = r.client_id
    JOIN derm.address_sheet_row_reads rd
      ON rd.dump_folder = 'ticket-833395'
     AND rd.page      = derm.fn_sheet_image_position('ticket-833395', r.printed_page)
     AND rd.row_index = r.row_on_page
   WHERE r.sheet_id = 131
     AND upper(trim(rd.client_code_read)) = upper(trim(c.client_code));
  IF v_n <> 10 THEN
    RAISE EXCEPTION 'only % of 10 printed rows on sheet 131 match the row reads', v_n;
  END IF;

  ----------------------------------------------------------------------------
  -- 7.2  The gate flips, and the OLD body must still refuse. Without the second
  --      half the first proves nothing.
  ----------------------------------------------------------------------------
  v_new := derm.fn_sheet_rows_all_confirmed('833395', 131, 'ticket-833395');
  v_old := derm._ctl_old_rows_all_confirmed('833395', 131, 'ticket-833395');
  IF v_new IS NOT TRUE THEN
    RAISE EXCEPTION 'new gate still refuses ticket 833395 on sheet 131';
  END IF;
  IF v_old IS NOT FALSE THEN
    RAISE EXCEPTION 'control failed: the OLD gate accepts 833395, so it was never the defect';
  END IF;

  ----------------------------------------------------------------------------
  -- 7.3  The gate is not a rubber stamp. Perturb the frozen span and it must refuse again.
  ----------------------------------------------------------------------------
  UPDATE derm.address_sheet_clients SET rows_printed = 2
   WHERE sheet_id = 131 AND client_id = (SELECT id FROM public.clients WHERE client_code = '242-WYN');
  IF derm.fn_sheet_rows_all_confirmed('833395', 131, 'ticket-833395') IS NOT FALSE THEN
    RAISE EXCEPTION 'gate accepted a sheet whose span is wrong: it is not reading the map';
  END IF;
  UPDATE derm.address_sheet_clients SET rows_printed = 3
   WHERE sheet_id = 131 AND client_id = (SELECT id FROM public.clients WHERE client_code = '242-WYN');
  IF derm.fn_sheet_rows_all_confirmed('833395', 131, 'ticket-833395') IS NOT TRUE THEN
    RAISE EXCEPTION 'restore of the 242-WYN span did not restore the verdict';
  END IF;

  ----------------------------------------------------------------------------
  -- 7.4  A sheet whose printed ORDER differs must be refused. Sheet 132 (no 1094)
  --      swaps 026-HAP and 032-LG, so the ticket's 032-LG lands on printed row 6,
  --      whose reader says 026-HAP.
  --
  --      🛑 The first draft of this file asserted sheet 129 (no 1091) here and the
  --      VERIFY rejected it, correctly. 1091, 1092 and 1093 are PROGRESSIVE
  --      REGENERATIONS: 1091's printed order is a strict prefix of 1092's, which is
  --      a strict prefix of 1093's. The three ticket clients occupy the SAME printed
  --      rows on all of them, so the row reads confirm all three and cannot possibly
  --      tell them apart. That is not a hole in this gate -- separating them is the
  --      sheet-number scan read's job, and fn_resolve_generated_sheet_for_ticket
  --      applies it in the same WHERE clause. Do not ever weaken that scan-read
  --      requirement on the grounds that "the row reads already confirm the sheet":
  --      on this family of sheets they confirm four sheets at once.
  ----------------------------------------------------------------------------
  IF derm.fn_sheet_rows_all_confirmed('833395', 132, 'ticket-833395') IS NOT FALSE THEN
    RAISE EXCEPTION 'gate accepted sheet 132, whose printed order puts 026-HAP where 032-LG is read';
  END IF;

  ----------------------------------------------------------------------------
  -- 7.5  Every currently bound manifest keeps the printed row it already had.
  --      The placement of every existing AI stamp depends on this, so the
  --      comparison is against the 68 values MEASURED off the old body before
  --      this file was written, not against a re-derivation of it. A
  --      re-derivation shares whatever assumption the rewrite got wrong.
  ----------------------------------------------------------------------------
  CREATE TEMP TABLE _baseline(manifest_id bigint PRIMARY KEY, slot int) ON COMMIT DROP;
  INSERT INTO _baseline VALUES
    (1644,1),(1645,2),(1646,7),(1647,6),(1648,5),(1649,3),(1650,4),(1651,2),(1652,1),(1667,1),
    (1668,2),(1669,4),(1670,3),(1671,4),(1672,1),(1673,2),(1674,5),(1675,6),(1676,7),(1677,9),
    (1678,8),(1680,7),(1681,8),(1682,6),(1683,3),(1684,2),(1685,4),(1686,5),(1687,1),(1691,4),
    (1692,5),(1693,7),(1694,3),(1695,8),(1696,2),(1697,1),(1698,1),(1699,2),(1700,7),(1701,5),
    (1702,10),(1703,6),(1704,9),(1705,8),(1706,2),(1707,3),(1708,4),(1709,1),(1710,3),(1711,4),
    (1712,2),(1713,1),(1714,5),(1715,7),(1716,6),(1717,10),(1718,8),(1719,9),(1725,7),(1726,10),
    (1727,9),(1728,6),(1729,8),(1730,2),(1731,3),(1732,4),(1733,5),(1734,1);

  SELECT count(*) INTO v_int FROM _baseline b
    FULL JOIN derm.address_sheet_manifests l ON l.manifest_id = b.manifest_id
   WHERE b.manifest_id IS NULL OR l.manifest_id IS NULL;
  IF v_int <> 0 THEN
    RAISE EXCEPTION 'the bound-manifest set moved since the baseline was taken (% rows differ)', v_int;
  END IF;

  SELECT count(*) INTO v_int FROM _baseline b
   WHERE derm.fn_generated_sheet_slot(b.manifest_id) IS DISTINCT FROM b.slot;
  IF v_int <> 0 THEN
    RAISE EXCEPTION '% of the 68 bound manifests changed printed row', v_int;
  END IF;

  ----------------------------------------------------------------------------
  -- 7.6  The straddling blocks are real and are modelled, not swallowed.
  --      Measured: sheet 70 / 043-MIL rows 5-6 and sheet 125 / 242-WYN rows 5-7.
  ----------------------------------------------------------------------------
  SELECT count(*) INTO v_int FROM (
    SELECT r.sheet_id, r.slot FROM derm.v_sheet_printed_rows r
     GROUP BY r.sheet_id, r.slot HAVING count(DISTINCT r.printed_page) > 1) q;
  IF v_int < 1 THEN
    RAISE EXCEPTION 'no page-straddling block found: the per-row page resolution is untested';
  END IF;

  ----------------------------------------------------------------------------
  -- 7.7  The map covers every client row exactly once, and never loses one.
  ----------------------------------------------------------------------------
  SELECT count(*) INTO v_int FROM derm.address_sheet_clients;
  SELECT count(*) INTO v_n FROM derm.v_sheet_printed_rows WHERE is_first_row;
  IF v_int <> v_n THEN
    RAISE EXCEPTION 'map has % first rows for % client rows', v_n, v_int;
  END IF;

  RAISE NOTICE 'PART 7 OK: sheet 1093 matches the paper 10/10, gate flips false->true with the old body still refusing, all 68 bound manifests unchanged';
END $$;

DROP FUNCTION derm._ctl_old_rows_all_confirmed(text, bigint, text);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.proname = '_ctl_old_rows_all_confirmed') THEN
    RAISE EXCEPTION 'the control function survived the drop';
  END IF;
END $$;

COMMIT;
