-- 2026-10-12_1530 Three Surfside properties get the Town of Surfside city inbox
--
-- THE ASK
--   The 2026-10-12 notification audit found 3 live Surfside properties with no properties.city_emails while 36 other
--   Surfside properties carry the Town of Surfside inbox. All three were created after the bulk inbox load
--   (2026-09-01, 09-17, 09-22). 324-BIB's visit 8112 (Sep 18, pumping, manifest 1964) never reached Surfside because
--   of it. Fred, 2026-10-12: city emails are for "Broward, surfside and hallandale", and for the gap "go ahead".
--
-- WHAT CHANGES
--   public.properties.city_emails on 1113 (324-BIB), 1159 (333-SHA), 1179 (340-MAN), each currently empty, set to the
--   one inbox every other Surfside property carries. Pinned: the UPDATE matches only rows still empty, and the VERIFY
--   requires the peer inbox to be the single value used in Surfside.
--
-- WHAT DOES NOT HAPPEN
--   No email is sent by this. The automatic sweep needs a real Admin Review send first (derm.v_city_email_candidates
--   status awaiting_manual_send); 0 Admin Review sends exist on these properties. Visit 8112 moves from no_city_email to
--   needs_city_email in public.v_visit_city_email_state and appears on the 11 AM list once its photos are sorted.
--   city_emails is not a Jobber field: trg_properties_enqueue_outbound ignores it.
--
-- RULE 8: public.properties is audited (audit_properties); each change lands in audit.logs with its old row.
-- ROLLBACK: update public.properties set city_emails = '{}' where id in (1113, 1159, 1179);

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pre$
DECLARE peer text[]; n_vals int; n_empty int;
BEGIN
  SELECT count(DISTINCT city_emails), min(city_emails::text)::text[] INTO n_vals, peer
    FROM public.properties WHERE deleted_at IS NULL AND city = 'Surfside' AND cardinality(city_emails) > 0;
  IF n_vals <> 1 THEN RAISE EXCEPTION 'PRE: Surfside properties carry % different inboxes, expected 1', n_vals; END IF;
  SELECT count(*) INTO n_empty FROM public.properties
   WHERE id IN (1113, 1159, 1179) AND deleted_at IS NULL AND city = 'Surfside' AND cardinality(coalesce(city_emails, '{}')) = 0;
  IF n_empty <> 3 THEN RAISE EXCEPTION 'PRE: expected 3 empty Surfside targets, found %', n_empty; END IF;
END $pre$;

UPDATE public.properties p
   SET city_emails = (SELECT city_emails FROM public.properties
                       WHERE deleted_at IS NULL AND city = 'Surfside' AND cardinality(city_emails) > 0 LIMIT 1)
 WHERE p.id IN (1113, 1159, 1179) AND p.deleted_at IS NULL AND p.city = 'Surfside'
   AND cardinality(coalesce(p.city_emails, '{}')) = 0;

DO $verify$
DECLARE n int; st text; bad int;
BEGIN
  SELECT count(*) INTO n FROM public.properties
   WHERE id IN (1113, 1159, 1179) AND city_emails = ARRAY['csantos-alborna@townofsurfsidefl.gov','aeugent@townofsurfsidefl.gov'];
  IF n <> 3 THEN RAISE EXCEPTION 'VERIFY: % of 3 properties carry the Surfside inbox', n; END IF;
  SELECT state INTO st FROM public.v_visit_city_email_state WHERE visit_id = 8112;
  IF st <> 'needs_city_email' THEN RAISE EXCEPTION 'VERIFY: visit 8112 reads %, expected needs_city_email', st; END IF;
  -- nothing may become due for the automatic sweep because of this
  SELECT count(*) INTO bad FROM derm.v_city_email_candidates c
    JOIN public.manifest_visits mv ON mv.manifest_id = c.manifest_id
    JOIN public.visits v ON v.id = mv.visit_id AND v.client_id = c.client_id
   WHERE v.property_id IN (1113, 1159, 1179) AND c.status IN ('ready', 'waiting');
  IF bad > 0 THEN RAISE EXCEPTION 'VERIFY: % pairs became due for the automatic sweep', bad; END IF;
END $verify$;

COMMIT;
