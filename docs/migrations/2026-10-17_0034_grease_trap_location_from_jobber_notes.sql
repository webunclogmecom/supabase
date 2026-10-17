-- ============================================================================
-- 2026-10-17_0034_grease_trap_location_from_jobber_notes Grease trap location from the Jobber notes (Viktor's list)
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-16: "load viktor list"; 2026-10-17: "i will send you viktor CSV" (82 rows from Jobber client notes and
--   job instructions: 20 Inside, 4 Inside and Outside, 58 Outside, 12 of the Outside marked "Check" by Viktor).
-- HOW IT WAS CHECKED (read only, 2026-10-17)
--   Every row was matched to its client's live, non-billing property (349-EPS by address: property 333) and every
--   quoted note was looked up in Jobber (client notes + job instructions): 73 word for word, 7 paraphrased (read by eye),
--   2 not supporting a location. A row loads only if the note itself says where the trap is.
-- WHAT IT DOES
--   Sets public.properties.grease_trap_location on 59 properties that hold no value yet
--   (16 Inside, 4 Inside and Outside, 39 Outside). Never over a value: the 7 survey-backed
--   properties are untouched. Audit label x-app-source = jobber-notes-import (full-row audit on properties).
-- NOT LOADED (23; the list with reasons went to Fred): 052-PV, 104-PV, 168-AVA, 222-SPE, 027-HER, 040-MV, 042-MT, 059-SK, 065-TCE, 067-TCE, 141-NEY, 171-CAF, 175-PV, 196-PV, 198-ARY, 221-YAS, 225-PV, 239-COM, 245-MAYU, 287-NKK, 288-PER, 318-CAP, 332-MCM.
--   Reasons: already set from a site survey (052-PV, 318-CAP); the note is about access, parking or a gate rather than
--   where the trap is; the quote is not in Jobber (104-PV); a garage or "inside the gate" (168-AVA, 222-SPE, 067-TCE).
-- The note texts are NOT in this public file (some carry gate or lock box codes): the decisions with notes are in the
--   workspace backup backups/2026-10-17_grease_trap_location_viktor_list_decisions.json (git-ignored).
-- Rule 8: no table. ROLLBACK: 2026-10-17_rollback_grease_trap_location_from_jobber_notes.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE TEMP TABLE gtl_load (code text, property_id bigint, value text) ON COMMIT DROP;
INSERT INTO gtl_load VALUES
    ('002-41', 147, 'Inside'),
    ('004-BAO', 164, 'Inside'),
    ('035-LG', 79, 'Inside'),
    ('046-OKI', 277, 'Inside'),
    ('064-TCE', 62, 'Inside'),
    ('069-TCE', 59, 'Inside'),
    ('082-TFC', 126, 'Inside'),
    ('091-SB', 86, 'Inside'),
    ('099-PV', 145, 'Inside'),
    ('134-SC', 231, 'Inside'),
    ('235-LOU', 987, 'Inside'),
    ('236-LOU', 1014, 'Inside'),
    ('246-LOUI', 985, 'Inside'),
    ('291-PER', 980, 'Inside'),
    ('309-KEB', 1084, 'Inside'),
    ('349-EPS', 333, 'Inside'),
    ('043-MIL', 51, 'Inside and Outside'),
    ('188-ACA', 27, 'Inside and Outside'),
    ('197-BGT', 115, 'Inside and Outside'),
    ('200-PALO', 128, 'Inside and Outside'),
    ('005-BUB', 181, 'Outside'),
    ('009-CN', 42, 'Outside'),
    ('010-CS', 134, 'Outside'),
    ('024-GRO', 137, 'Outside'),
    ('028-HUM', 25, 'Outside'),
    ('047-PAM', 61, 'Outside'),
    ('056-STM', 122, 'Outside'),
    ('063-TCE', 152, 'Outside'),
    ('072-TCE', 127, 'Outside'),
    ('073-TCE', 149, 'Outside'),
    ('077-TCE', 153, 'Outside'),
    ('078-TCE', 101, 'Outside'),
    ('081-TCE', 68, 'Outside'),
    ('092-TCE', 78, 'Outside'),
    ('094-MOZ', 362, 'Outside'),
    ('103-BWC', 85, 'Outside'),
    ('105-CU', 210, 'Outside'),
    ('108-ROA', 348, 'Outside'),
    ('114-CI', 11, 'Outside'),
    ('116-HIK', 82, 'Outside'),
    ('117-BH', 135, 'Outside'),
    ('127-PC', 36, 'Outside'),
    ('133-MUT', 124, 'Outside'),
    ('147-OST', 272, 'Outside'),
    ('149-RUS', 35, 'Outside'),
    ('150-KOS', 34, 'Outside'),
    ('177-PV', 166, 'Outside'),
    ('178-LG', 6, 'Outside'),
    ('180-PV', 209, 'Outside'),
    ('182-PAL', 118, 'Outside'),
    ('234-PV', 1058, 'Outside'),
    ('238-PV', 1018, 'Outside'),
    ('247-LOU', 989, 'Outside'),
    ('249-LOU', 973, 'Outside'),
    ('289-PER', 983, 'Outside'),
    ('290-PER', 982, 'Outside'),
    ('308-LOU', 1082, 'Outside'),
    ('317-PER', 1111, 'Outside'),
    ('326-PER', 1151, 'Outside');

DO $g$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM gtl_load g JOIN public.properties p ON p.id = g.property_id JOIN public.clients c ON c.id = p.client_id
   WHERE c.client_code = g.code AND p.deleted_at IS NULL AND NOT coalesce(p.is_billing, false) AND p.grease_trap_location IS NULL;
  IF n <> 59 THEN RAISE EXCEPTION 'only % of 59 rows match a live, empty property of their client: build again', n; END IF;
END $g$;
CREATE TEMP TABLE gtl_before ON COMMIT DROP AS SELECT id, grease_trap_location FROM public.properties WHERE grease_trap_location IS NOT NULL;

SELECT set_config('request.headers', '{"x-app-source":"jobber-notes-import"}', true);
UPDATE public.properties p SET grease_trap_location = g.value
  FROM gtl_load g WHERE p.id = g.property_id AND p.grease_trap_location IS NULL;
SELECT set_config('request.headers', '', true);

DO $v$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM gtl_load g JOIN public.properties p ON p.id = g.property_id WHERE p.grease_trap_location = g.value;
  IF n <> 59 THEN RAISE EXCEPTION 'VERIFY: % of 59 set', n; END IF;
  SELECT count(*) INTO n FROM gtl_before b JOIN public.properties p ON p.id = b.id WHERE p.grease_trap_location IS DISTINCT FROM b.grease_trap_location;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % values that existed before changed', n; END IF;
  SELECT count(*) INTO n FROM public.properties WHERE grease_trap_location IS NOT NULL;
  IF n <> (SELECT count(*) FROM gtl_before) + 59 THEN RAISE EXCEPTION 'VERIFY: % properties hold a value', n; END IF;
  SELECT count(*) INTO n FROM audit.logs WHERE table_name = 'properties' AND app_source = 'jobber-notes-import' AND changed_at >= now() - interval '1 minute';
  IF n <> 59 THEN RAISE EXCEPTION 'VERIFY: % audit rows labelled jobber-notes-import', n; END IF;
  RAISE NOTICE 'VERIFY passed: 59 set';
END $v$;
COMMIT;
