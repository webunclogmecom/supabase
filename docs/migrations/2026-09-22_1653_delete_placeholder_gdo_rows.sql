-- 2026-09-22_1653_delete_placeholder_gdo_rows.sql
--
-- WHY. Yan, Slack C0BD3VDPB9S / 1790105631.977219: the Client App list shows "GDO-08341" and
-- "Not available" for 192-FRK, and he cannot find or edit the second one. "Not available" is not a
-- UI string: it is a literal public.gdos.gdo_number on a second row that Airtable's "GDO Number"
-- field carried in before webhook-airtable GUARD 1b existed. Fred: "we need to remove that
-- completely. and from any client as well."
--
-- WHAT. Deletes the 33 public.gdos rows whose gdo_number is a pure placeholder and carries no
-- information: 'Not available' (23), 'Needs review' (4), 'bw'/'BW' (6). All 33 are already INACTIVE
-- and none has a permit PDF. Targeted by EXPLICIT ID so the set cannot drift between review and
-- apply; the value predicate is repeated as a belt-and-braces guard.
--
-- 🛑 DELIBERATELY NOT DELETED, they are NOT placeholders and need a human decision (Fred, pending):
--   id 141  057-BAY  'PSO-00025'                        ACTIVE, has a PDF, and this client has NO
--                                                       other active permit. PSO is not the GDO
--                                                       prefix and may be a different program.
--   id 164  009-CN   'GDO-10877, GDO-15062, GDO-16389'  three REAL permits in one field, has a PDF
--   id 157  043-MIL  'GDO-14117 / GDO-11024'            two REAL permits in one field, has a PDF
--   id 29   139-LTG  'GDO-08912-DUPMERGE-147'           merge artifact carrying a real permit + a row id
--
-- SAFETY, all measured 2026-09-22 before writing this file:
--   * 0 inbound references from every FK that points at gdos: public.derm_manifests (SET NULL),
--     derm.address_row_map (SET NULL), public.derm_portal_leases (NO ACTION),
--     public.derm_portal_submissions (NO ACTION). So nothing is blocked and nothing is silently
--     nulled.
--   * public.derm_portal_requeue carries a gdo_id with NO foreign key; checked separately, 0 of the
--     candidates appear in it (control: the table holds 8 rows, so the probe was live).
--   * The only trigger on gdos that fires on DELETE is audit_gdos. gdos_client_consistency_trg,
--     trg_aa_gdos_guard_demoted, trg_gdo_number_one_address and trg_gdos_updated_at are all
--     BEFORE INSERT/UPDATE only.
--
-- RULE 8 (audit): OPT-IN, already in place. public.gdos carries audit_gdos AFTER INSERT OR DELETE OR
-- UPDATE, so every deleted row lands in audit.logs as a full old-row JSONB and is recoverable there.
-- A JSON backup of all 37 non-canonical rows is also at
-- backups/2026-09-22_gdo_noncanonical_rows_before_delete.json.
--
-- RULE 6 (never hard-delete business data): a placeholder string that was never a permit is an
-- ingestion artifact, not business data, and Fred asked for it to be removed. The 4 rows above that
-- DO carry real permit information are left untouched precisely because rule 6 applies to them.
--
-- RECURRENCE: webhook-airtable GUARD 1b rejects any value that is not ^GDO-\d+$ on the INSERT path
-- itself, so these do not come back. The rows were never what suppressed them.
--
-- EXPECTED: 33 rows deleted. After this, 23 clients have no GDO row at all, which is the truth for
-- them (no permit on file) rather than a fake one.

DELETE FROM public.gdos
WHERE id IN (
  137, 138, 139, 140, 143, 146, 148, 149, 150, 151,
  152, 153, 154, 155, 158, 159, 160, 161, 162, 163,
  165, 166, 167, 168, 173, 175, 176, 202, 203, 204,
  205, 211, 222
)
AND lower(btrim(gdo_number)) IN ('not available', 'needs review', 'bw')
AND status = 'INACTIVE'
AND permit_document_path IS NULL;
