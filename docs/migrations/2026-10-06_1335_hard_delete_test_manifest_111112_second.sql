-- ============================================================================
-- 2026-10-06 · Hard delete of the SECOND test manifest 111112 (public.derm_manifests 2019, client 112-YA)
-- ============================================================================
-- Fred, 2026-10-06: "yes go ahead with a hard delete". After the first 111112 (2018) was hard deleted
-- (2026-10-06_1305), it was re-filed from the DERM Tracker at 12:46 ET on visit 8742, banded and completed in the
-- Stamp Studio 12:48-12:49 (one blacked-out document generated), and soft-deleted at 12:51 ET.
-- Found by a sweep of every row in public, derm, ops, client, customer, raw, private for "111112" or "/derm/2019/":
--   public.manifest_visits (8742, 2019) 1 · derm.redacted_manifest_docs 1 · derm.receipt_doc_class 1
--   ticket-111112: address_row_map 1, page_slots 5, page_row_rules 6, page_rule_scans 2,
--   page_reference_attempts 1, page_block_extents 1, stamp_sheet_status 1 · public.derm_manifests 2019 1
-- Storage manifests/derm/2019/{manifest_1,address_1}.jpg and manifests/redacted/m2019p1-d2e5003883.jpg are removed
-- through the Storage API after this file. KEPT: audit.logs. Visit 8742 is not changed (DERM required, locked, set
-- in the DERM Tracker at 12:43 ET). Backup (local): backups/2026-10-06_manifest_111112_2019_*.
-- ============================================================================
BEGIN;
DO $d$
DECLARE n int; t record; left_over jsonb := '{}';
BEGIN
  IF (SELECT count(*) FROM public.derm_manifests WHERE id = 2019 AND white_manifest_number = '111112'
        AND client_id = 381 AND deleted_at IS NOT NULL) <> 1 THEN
    RAISE EXCEPTION 'manifest 2019 is not the soft-deleted 112-YA 111112; stop'; END IF;
  IF EXISTS (SELECT 1 FROM public.derm_manifests WHERE COALESCE(white_manifest_number, yellow_ticket_number) = '111112' AND id <> 2019) THEN
    RAISE EXCEPTION 'another manifest uses 111112; the ticket-111112 rows may be shared, stop'; END IF;

  FOR t IN SELECT * FROM (VALUES
      (1, 'public.manifest_visits',          'manifest_id = 2019',                   1),
      (2, 'derm.redacted_manifest_docs',     'manifest_id = 2019',                   1),
      (3, 'derm.receipt_doc_class',          'url LIKE ''%/manifests/derm/2019/%''', 1),
      (4, 'derm.address_row_map',            'dump_folder = ''ticket-111112''',      1),
      (5, 'derm.page_slots',                 'dump_folder = ''ticket-111112''',      5),
      (6, 'derm.page_row_rules',             'dump_folder = ''ticket-111112''',      6),
      (7, 'derm.page_rule_scans',            'dump_folder = ''ticket-111112''',      2),
      (8, 'derm.page_reference_attempts',    'dump_folder = ''ticket-111112''',      1),
      (9, 'derm.page_block_extents',         'dump_folder = ''ticket-111112''',      1)) v(o, tb, cond, expect) ORDER BY o
  LOOP
    EXECUTE format('DELETE FROM %s WHERE %s', t.tb, t.cond);
    GET DIAGNOSTICS n = ROW_COUNT;
    IF n <> t.expect THEN RAISE EXCEPTION '%: deleted %, expected %', t.tb, n, t.expect; END IF;
  END LOOP;
  -- last: the deletes above may have touched the sheet status (dirty tracking)
  DELETE FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-111112';
  DELETE FROM public.derm_manifests WHERE id = 2019;  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'derm_manifests: % rows', n; END IF;

  -- nothing left (and nothing recreated by a trigger), checked over every derm table + the two public ones
  FOR t IN SELECT c.oid::regclass::text tb FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace
            WHERE c.relkind = 'r' AND (s.nspname = 'derm' OR c.oid IN ('public.derm_manifests'::regclass, 'public.manifest_visits'::regclass))
  LOOP
    EXECUTE format('SELECT count(*) FROM %s x WHERE x::text LIKE ''%%111112%%'' OR x::text LIKE ''%%/derm/2019/%%'' OR x::text LIKE ''%%m2019p%%''', t.tb) INTO n;
    IF n > 0 THEN left_over := left_over || jsonb_build_object(t.tb, n); END IF;
  END LOOP;
  IF left_over <> '{}' THEN RAISE EXCEPTION 'rows left: %', left_over; END IF;
END
$d$;
COMMIT;
