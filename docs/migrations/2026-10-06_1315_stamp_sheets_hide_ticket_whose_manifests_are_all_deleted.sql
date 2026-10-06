-- ============================================================================
-- 2026-10-06 · Stamp Studio: a ticket whose manifests are ALL deleted leaves the sheet list
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-06: "i deleted a manifest at the DERM App, 111112 but at the Stamp App it still shows that
--   manifest. and it says in progress."
--
-- WHY IT STAYED
--   Deleting a manifest in the DERM Tracker is a soft delete (PATCH deleted_at). trg_ad_card_reptr_on_manifest_delete
--   then points its Stamp Studio card (derm.address_row_map) at a live sibling or NULL, and the card change re-opens
--   the sheet (stamp_sheet_status.completed -> false). Both are on purpose: a re-file of the same number re-attaches
--   the card and its bands. But derm.v_stamp_sheets builds its ticket list from live manifests UNION every card's
--   number, so the card alone kept the ticket listed, now "In progress". The same view feeds
--   derm.fn_stamp_open_sheets, so the 10 AM "stamp-sheets-reminder" Slack post would have listed it too.
--
-- WHAT CHANGES
--   derm.v_stamp_sheets: one arm appended to the outer WHERE, spliced from the live text (md5 pinned): drop a ticket
--   when at least one manifest with that number exists, all soft-deleted, and none live. A sheet with NO manifest
--   under its number (scan-first sheets: 820714, 828601, 934861 today, all completed) still shows, as before.
--   Columns, ACL and every other row are unchanged (asserted). Nothing is deleted: re-filing the number brings the
--   sheet back with its bands, re-opened for completion as before.
--
-- MEASURED 2026-10-06 ~13:05 ET (151 sheets): live manifest 147; no manifest at all 3; only deleted manifests 1
-- (111112, manifest 2019 filed 12:46 and deleted 12:51 ET from the DERM Tracker, test client 112-YA). So exactly
-- one row leaves the list and the open-sheets list.
--
-- NOT CHANGED: the delete triggers, the card, the re-open, derm.fn_stamp_open_sheets (it reads this view),
-- derm.v_stamp_placement_health (still lists the card; a health view, not shown to the operator as a sheet).
-- 🛑 Do not SET search_path in this file: pg_get_viewdef leaves names unqualified that resolve on the current path.
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table changes.
-- ROLLBACK: the same splice in reverse (remove the "2026-10-06 all-deleted" arm), or re-run the md5-pinned text
--           captured in _vss_before below from a prior dump.
-- ============================================================================
BEGIN;

DO $pre$
BEGIN
  IF md5(pg_get_viewdef('derm.v_stamp_sheets'::regclass)) <> 'd64500fa47ecfba9673844d3c6f53279' THEN
    RAISE EXCEPTION 'derm.v_stamp_sheets changed since this migration was built; rebuild it'; END IF;
END
$pre$;

CREATE TEMP TABLE _vss_before ON COMMIT DROP AS SELECT to_jsonb(s) AS j, s.white_manifest_number AS wm FROM derm.v_stamp_sheets s;
CREATE TEMP TABLE _acl_before ON COMMIT DROP AS SELECT relacl::text AS acl FROM pg_class WHERE oid = 'derm.v_stamp_sheets'::regclass;

DO $splice$
DECLARE
  d text := rtrim(btrim(pg_get_viewdef('derm.v_stamp_sheets'::regclass)), ';');
  arm text := $arm$
  AND (NOT ((EXISTS ( SELECT 1
           FROM public.derm_manifests m
          WHERE ((COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number) AND (m.deleted_at IS NOT NULL)))) AND (NOT (EXISTS ( SELECT 1
           FROM public.derm_manifests m
          WHERE ((COALESCE(m.white_manifest_number, m.yellow_ticket_number) = ss.white_manifest_number) AND (m.deleted_at IS NULL)))))))$arm$;
BEGIN
  IF right(d, 40) NOT LIKE '%BROWARD''::text)))))))' THEN
    RAISE EXCEPTION 'view text does not end with the Broward arm as expected: %', right(d, 60); END IF;
  EXECUTE 'CREATE OR REPLACE VIEW derm.v_stamp_sheets AS ' || d || arm;
END
$splice$;

COMMENT ON VIEW derm.v_stamp_sheets IS
  'Stamp Studio sheet list (one row per ticket). 2026-10-06: a ticket whose manifests are all soft-deleted (at least one, none live) is left out; a ticket with no manifest under its number still shows. Read by derm.fn_stamp_open_sheets (the 10 AM reminder).';

DO $v$
DECLARE n_gone int; n_changed int; n_new int;
BEGIN
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'derm.v_stamp_sheets'::regclass) IS DISTINCT FROM (SELECT acl FROM _acl_before) THEN
    RAISE EXCEPTION 'VERIFY: ACL changed'; END IF;
  SELECT count(*) INTO n_gone FROM _vss_before b WHERE NOT EXISTS (SELECT 1 FROM derm.v_stamp_sheets s WHERE s.white_manifest_number = b.wm);
  IF n_gone <> 1 OR EXISTS (SELECT 1 FROM derm.v_stamp_sheets WHERE white_manifest_number = '111112') THEN
    RAISE EXCEPTION 'VERIFY: expected exactly 111112 to leave, % left', n_gone; END IF;
  SELECT count(*) INTO n_changed FROM _vss_before b
   WHERE b.wm <> '111112' AND NOT EXISTS (SELECT 1 FROM derm.v_stamp_sheets s WHERE to_jsonb(s) = b.j);
  SELECT count(*) INTO n_new FROM derm.v_stamp_sheets s WHERE NOT EXISTS (SELECT 1 FROM _vss_before b WHERE b.j = to_jsonb(s));
  IF n_changed <> 0 OR n_new <> 0 THEN RAISE EXCEPTION 'VERIFY: % rows changed, % new', n_changed, n_new; END IF;
  IF derm.fn_stamp_open_sheets()::text LIKE '%111112%' THEN RAISE EXCEPTION 'VERIFY: still in the open-sheets list'; END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.v_stamp_sheets WHERE white_manifest_number IN ('820714','828601','934861') HAVING count(*) = 3) THEN
    RAISE EXCEPTION 'VERIFY: a scan-first sheet (no manifest) disappeared'; END IF;
  RAISE NOTICE 'VERIFY ok';
END
$v$;

COMMIT;
