-- 99-restore.sql — undo any changes from the cross-app integration test.
-- Generated 2026-05-25T08:39:10.660Z
-- Run via Supabase Management API POST /database/query with the contents below.

BEGIN;

-- ============================================================
-- A. Restore properties.grease_trap_manhole_count + notes
-- ============================================================
UPDATE public.properties SET grease_trap_manhole_count = 1, notes = NULL WHERE id = 12;
UPDATE public.properties SET grease_trap_manhole_count = 10, notes = NULL WHERE id = 51;
UPDATE public.properties SET grease_trap_manhole_count = 6, notes = NULL WHERE id = 66;
UPDATE public.properties SET grease_trap_manhole_count = 0, notes = NULL WHERE id = 78;
UPDATE public.properties SET grease_trap_manhole_count = 3, notes = NULL WHERE id = 92;

-- ============================================================
-- B. Restore visits.manhole_count, derm_required
-- ============================================================
UPDATE public.visits SET manhole_count = NULL, derm_required = NULL WHERE id = 3915;
UPDATE public.visits SET manhole_count = NULL, derm_required = NULL WHERE id = 4742;
UPDATE public.visits SET manhole_count = NULL, derm_required = NULL WHERE id = 4901;
UPDATE public.visits SET manhole_count = NULL, derm_required = NULL WHERE id = 5125;
UPDATE public.visits SET manhole_count = NULL, derm_required = NULL WHERE id = 5127;
UPDATE public.visits SET manhole_count = NULL, derm_required = NULL WHERE id = 5128;
UPDATE public.visits SET manhole_count = NULL, derm_required = NULL WHERE id = 5130;

-- ============================================================
-- C. Restore manifest_visits rows exactly as captured
-- ============================================================
DELETE FROM public.manifest_visits WHERE visit_id = ANY (ARRAY[4901,5128,5130,3915,4742,5127,5125]::bigint[]);
INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (976, 3915) ON CONFLICT DO NOTHING;
INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (1046, 4742) ON CONFLICT DO NOTHING;
INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (1055, 5127) ON CONFLICT DO NOTHING;

-- ============================================================
-- D. Restore photo_classifications rows
-- ============================================================
-- Delete any photo_classifications rows for the photo_link_ids we touched...
DELETE FROM public.photo_classifications WHERE photo_link_id = ANY (ARRAY[24840,24841,24842,24843,24844,24845,24846,24847]::bigint[]);
INSERT INTO public.photo_classifications (id, photo_link_id, service_phase) VALUES (4298, 24840, 'internal') ON CONFLICT (id) DO UPDATE SET service_phase = EXCLUDED.service_phase;
INSERT INTO public.photo_classifications (id, photo_link_id, service_phase) VALUES (4299, 24841, 'internal') ON CONFLICT (id) DO UPDATE SET service_phase = EXCLUDED.service_phase;
INSERT INTO public.photo_classifications (id, photo_link_id, service_phase) VALUES (4300, 24842, 'after') ON CONFLICT (id) DO UPDATE SET service_phase = EXCLUDED.service_phase;
INSERT INTO public.photo_classifications (id, photo_link_id, service_phase) VALUES (4301, 24843, 'after') ON CONFLICT (id) DO UPDATE SET service_phase = EXCLUDED.service_phase;
INSERT INTO public.photo_classifications (id, photo_link_id, service_phase) VALUES (4302, 24844, 'after') ON CONFLICT (id) DO UPDATE SET service_phase = EXCLUDED.service_phase;
INSERT INTO public.photo_classifications (id, photo_link_id, service_phase) VALUES (4303, 24845, 'before') ON CONFLICT (id) DO UPDATE SET service_phase = EXCLUDED.service_phase;
INSERT INTO public.photo_classifications (id, photo_link_id, service_phase) VALUES (4304, 24846, 'before') ON CONFLICT (id) DO UPDATE SET service_phase = EXCLUDED.service_phase;
INSERT INTO public.photo_classifications (id, photo_link_id, service_phase) VALUES (4305, 24847, 'before') ON CONFLICT (id) DO UPDATE SET service_phase = EXCLUDED.service_phase;

COMMIT;
