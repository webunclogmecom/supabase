-- ============================================================================
-- 2026-10-26_2000 · Personal addresses, step 1: ONE staff-email rule for the database (public.fn_is_staff_email)
-- ============================================================================
-- Fred, 2026-10-26: "remember we can also use personal emails too, some user @yahoo or @hotmail even not just @gmail",
-- then "go ahead with personal addresses" (Trello zRTbWvXn; plan Building Apps/HR App/docs/specs/
-- 2026-10-26-invite-followups-plan.md part A, with the measured scope).
--
-- Measured before: 42 functions open with their own "staff" test, the caller's email ending in @ayache.com or
-- @unclogme.com (8 spellings of it: Client App, Picture Planner, DERM, Calendar, the HR bonus reads, the reason-photo
-- storage rule). A person whose HR email is a personal mailbox could be invited and sign in, then be refused everywhere
-- as "not staff".
--
--  1. NEW public.fn_is_staff_email(p_email): TRUE for the two company domains (as before) OR an address that belongs to
--     exactly ONE Active employee (case and spaces ignored). NULL in, NULL out, so every caller keeps its exact old
--     behaviour for a missing email (a test of "NULL not like ..." is NULL, which an IF treats as false). '' is FALSE.
--     SECURITY DEFINER (reads public.employees), search_path pinned; EXECUTE authenticated + service_role (the edge
--     functions call it), never anon. Staff can already read the employee list, so it reveals nothing new.
--  2. Each of the 42 functions: the domain test becomes NOT public.fn_is_staff_email(<the same email expression>), every
--     other byte of the body unchanged. Applied to the live body with the old md5 AND the expected new md5 pinned per
--     function (computed outside from the same literal replacements), so a body that changed since, or a replacement that
--     lands differently, stops the migration. Privileges asserted unchanged.
-- Not here (later steps): the 17 edge functions, the 8 app logins, then the sign-up rule
-- (public.fn_restrict_signup_domains), hr.fn_invite_refusal's sentence and log_access_health's outside-domain line.
-- Order: until the sign-up rule changes no sign-in exists at a personal address, so this step widens nothing anyone can
-- use today.
-- Rollback: 2026-10-26_rollback_staff_email_rule.sql (the 42 previous bodies, md5 pinned).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE FUNCTION public.fn_is_staff_email(p_email text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $f$
  -- 2026-10-26_2000: the ONE staff-email rule. Company domains, or the email of exactly one Active employee.
  select case when p_email is null then null
              else lower(btrim(p_email)) like '%@ayache.com' or lower(btrim(p_email)) like '%@unclogme.com'
                   or (select count(*) from public.employees e
                        where e.status = 'ACTIVE' and lower(btrim(e.email)) = lower(btrim(p_email))) = 1
         end
$f$;
REVOKE ALL ON FUNCTION public.fn_is_staff_email(text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fn_is_staff_email(text) TO authenticated, service_role;
COMMENT ON FUNCTION public.fn_is_staff_email(text) IS
  'Staff email rule (2026-10-26_2000): @ayache.com / @unclogme.com, or the email of exactly one Active employee. NULL -> NULL.';

CREATE TEMP TABLE se_targets (sig text, m_old text, m_new text) ON COMMIT DROP;
INSERT INTO se_targets VALUES
  ('client.generate_visits_for_client(bigint)', '640f1c7ce92d00f416d76f40a6ed8f43', '715d35e03b9e3a4cde792270d4aabcb1'),
  ('client.update_property_site_map(bigint,jsonb,integer)', '49d321a16d09cf4a96f0e37efb38a428', 'a9ec8b23aaf7338aae60e24d150d4037'),
  ('client.get_intake_link(bigint)', 'bad7be13927c08904fa986a602fb5b9a', '0281ae89d4546602a287ba495af952d3'),
  ('client.get_page_builder_forms(bigint)', '0fddbf3de8aff35149919d1fc93f8e3f', 'd12b8a55532b550592f8b0f4266f071a'),
  ('client.update_client_contact(bigint,jsonb)', '83feb14c5dd3df0e57c3cc2642921bca', '04f1fb460b208bfa0de9adc0a48fffd0'),
  ('hr.get_person_bonus_amounts(bigint[])', 'a78e629d34912c2c30a859b5899d6bdf', 'd43f684eb0006b83cc711e1eb3288467'),
  ('client.get_intake(bigint)', '98a0368262201490e0d0c0999608b943', 'ada2cdca09de8410246ad2e502f5b6c0'),
  ('client.get_page_builder(bigint)', 'b2a20853d380b920417e7a4848955a68', '886c391e5e710a5a2d4ae2cd26881f0a'),
  ('client.update_property_capacity(bigint,integer)', '1a08a7ea703301541a7abce2da5db064', '06ce39fc754f289742e2b21d4db81428'),
  ('client.rotate_driver_link(bigint)', '528a1e615cf6e96894cfe91dee8246eb', '33a03d0157ceb6df869f76411df0a5a9'),
  ('client.approve_property_page(bigint)', '33b9b43d7c8e0349397f3947f49b114b', '46fa450b4365a5f552208bf7ae37d857'),
  ('client.get_intake_compare(bigint)', '874df89236419cd32d4dc76d8c37738b', 'ded16ded3733b1468f0becb58dc1feaf'),
  ('hr.get_review_bonuses(bigint[],jsonb)', '531b8658b32b2572f0efb02c554c57e1', 'f76c01ce1aff59ee2a78bd5d0af06669'),
  ('derm_unlink_visit(bigint,bigint)', '39bd40ac7cd824195826a31e12bcdfc6', '57ac4153c091d48384d5e938bc0cff19'),
  ('client.get_property_activity(bigint)', 'b528ac274d4ffb0c33bb2cd825042c76', '72e7d1834663ae7d3154a6d3614bcaee'),
  ('client.update_property_operational(bigint,jsonb)', 'b73c8f580efe00d68b5ad3d549b7c783', '0a0ddfb36a728e48087f109078312b01'),
  ('client.upsert_gdo_permit(bigint,bigint,jsonb)', 'c049407fdc52ef3c598eeb15b46ca76e', 'af1cca9b28b89453e2705d4da81f133b'),
  ('client.create_client_contact(bigint,jsonb)', '1ab778dfaaa21f87ce60d66548925556', 'be32c51a158ef7e9e7e312667a9f86a3'),
  ('client.accept_intake_answers(bigint,text[],jsonb)', 'a72a08a0d2bb168b93a72c0137b2af9f', 'd867976bd432b742b718ce3c8df45898'),
  ('client.update_client_status(bigint,text,text)', '7821e887a36119cdad6ed4622cbc9535', 'a63e8edda289611f3ca24be7154b7d5d'),
  ('client.save_contact_settings(text,bigint,jsonb)', '74ae15a2387d6d7d2da7f176ff6a5e27', 'bafae1ec02cde85a52b1ed7e71a29501'),
  ('derm_delete_manifests(bigint[])', 'a4d896cff104ccfe8eaa2f96e511b947', '80df507b5b7af25962cbcfff024856a3'),
  ('client.submit_property_page(bigint,jsonb,integer,integer,jsonb,integer)', '0d07ff9a86420c2cee6c3e6af03cc222', '642e703ba0d020532b97e428f88dab14'),
  ('client.fn_reason_photo_path_ok(text)', '2486c77e2793494b460a456661e413d6', '60a172cf31b58c42e3d7f41d9d012916'),
  ('client.get_client_activity(bigint,boolean,integer,jsonb)', '80fc2de59c0b529a6169e704c87ff923', '2ce0d107e8db3342f760ddd57ed8d617'),
  ('client.fn_reason_photo_object_removable(text)', '6a7235d425d17fec30b29b5d1a3c722e', '7189a0958f30a4076752b76c032c3e73'),
  ('client.attach_reason_photo(text,bigint,text,text,integer,integer)', '77f76b6699ba31c2463a19f5d93359b9', '543c98ca909ba5b10137bcf0030812a7'),
  ('client.remove_reason_photo(bigint,text)', 'b4eb17252deab1ea62965459f817f751', '13c5edd7f54bdd35b899dc11c2c41671'),
  ('client.reject_property_page(bigint,text)', 'ceaa4459b03500840246b2955c1dbe5b', 'b0345a408b7b76852a52b2daa333bdd1'),
  ('derm.get_visit_report(bigint)', 'c96f2d3cb1175f838f12ce95527b4245', '496e4fe9ca43641e8bb9f85bd4c22a8a'),
  ('client.schedule_property_intake(bigint,text[],jsonb,text)', '9eb7ee555c958bf1dc9af252270c4466', '31e0bea77455f44d141de45ac05b3613'),
  ('client.page_builder_list()', '3ef567b9cc0697b881cefbe8f6bff7e7', 'd683094a89d44de0c8795d8d725e5d03'),
  ('client.get_page_versions(bigint)', 'd88274d110ee3b06772f94a38b4683df', '944b46969a1dbea4ac660503f82aa047'),
  ('client.cancel_intake(bigint)', '8066015873538f8a5bbbb62f8c617516', '6bd93ebe34b074f0bddb9d00678450a7'),
  ('derm_link_visits(bigint,bigint[])', '7c18955b347863cecc3b6e69a2be0df6', '97e10d063363114489039f27ce2ce280'),
  ('derm_set_manifest_photos(bigint,text,text,text[],text[])', '6dc881d23d2492de3acf2af5ff4b17fa', '607b0adc2e43345e6097a44b517851ab'),
  ('client.delete_client_contact(bigint)', '05d819b6f17e92a9e93ca9c6178d356e', '919357004d593b3d8671934d3d6fd52c'),
  ('client.update_client_fields(bigint,jsonb)', '45f7cd0f2c413675e1aa4eacb38c96ba', '544d6bfcb178e5c4add68b151065ee10'),
  ('client.update_client_zone(bigint,bigint)', 'bef564934f1686435e5fc998f13e18ba', '21c26db2a0b07f2b39ca93484a3aeb38'),
  ('client.preview_client_status_change(bigint,text)', 'c29cc26015e228808c4596e2f7049c71', '999fd7c7ecd7e303ecc940d4b8f95f9f'),
  ('set_visit_status(bigint,text,text)', 'da2537ed992ce9ec3eced7dc8e71145c', 'c69367b74ebdb18820560cdb2ebc5bbe'),
  ('ops.link_day_marker_dump_visit(bigint,bigint)', 'bc7391423dda4c71fa904d9e083af941', '1bb51bbfaad27de6762ec301c931fd56');

CREATE TEMP TABLE se_acl_before ON COMMIT DROP AS
  SELECT t.sig, p.proacl::text a FROM se_targets t JOIN pg_proc p ON p.oid = t.sig::regprocedure;

-- Probes: derm.get_visit_report's first check is the staff test ("not a staff account"); the reason-photo storage rule
-- answers true or false. Michael Escobar (40) is Active with a personal Gmail.
CREATE FUNCTION pg_temp.se_probe(p_email text) RETURNS jsonb LANGUAGE plpgsql AS $p$
DECLARE r jsonb := '{}'; v_path text := 'client-app/client_status_change/146/00000000-0000-4000-8000-000000000000.jpg';
BEGIN
  -- Fred's sign-in id (so the app-access checks that some bodies run first pass) with the email under test
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', p_email, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM derm.get_visit_report(-1);
    r := r || jsonb_build_object('report', 'passed');
  EXCEPTION WHEN OTHERS THEN
    r := r || jsonb_build_object('report', SQLERRM);
  END;
  r := r || jsonb_build_object('photo_path_ok', client.fn_reason_photo_path_ok(v_path));
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN r;
END $p$;

DO $c$ DECLARE r jsonb; BEGIN
  r := pg_temp.se_probe('michaelescobar1606@gmail.com');
  IF r->>'report' <> 'not a staff account' OR (r->>'photo_path_ok')::boolean THEN
    RAISE EXCEPTION 'control: the old bodies already accept a personal address %', r; END IF;
  r := pg_temp.se_probe('fred@ayache.com');
  IF r->>'report' = 'not a staff account' OR NOT (r->>'photo_path_ok')::boolean THEN
    RAISE EXCEPTION 'control: a company address is refused by the old bodies %', r; END IF;
END $c$;

DO $s$
DECLARE t record; d text;
BEGIN
  FOR t IN SELECT * FROM se_targets LOOP
    d := pg_get_functiondef(t.sig::regprocedure);
    IF md5(d) <> t.m_old THEN RAISE EXCEPTION 'guard: % changed since it was measured', t.sig; END IF;
    d := replace(d, $a$v_email not like '%@ayache.com' and v_email not like '%@unclogme.com'$a$, $b$not public.fn_is_staff_email(v_email)$b$);
    d := replace(d, $a$lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com' and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com'$a$, $b$not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', '')))$b$);
    d := replace(d, $a$v_email NOT LIKE '%@ayache.com' AND v_email NOT LIKE '%@unclogme.com'$a$, $b$NOT public.fn_is_staff_email(v_email)$b$);
    d := replace(d, $a$not (v_email like '%@unclogme.com' or v_email like '%@ayache.com')$a$, $b$not public.fn_is_staff_email(v_email)$b$);
    d := replace(d, $a$lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'$a$, $b$not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email','')))$b$);
    d := replace(d, $a$and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com'$a$, $b$$b$);
    d := replace(d, $a$lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@ayache.com'$a$, $b$not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', '')))$b$);
    d := replace(d, $a$and lower(coalesce(auth.jwt() ->> 'email', '')) not like '%@unclogme.com'$a$, $b$$b$);
    d := replace(d, $a$lower(coalesce(v_actor,'')) not like '%@ayache.com'$a$, $b$not public.fn_is_staff_email(lower(coalesce(v_actor,'')))$b$);
    d := replace(d, $a$and lower(coalesce(v_actor,'')) not like '%@unclogme.com'$a$, $b$$b$);
    d := replace(d, $a$lower(coalesce(auth.jwt() ->> 'email', '')) NOT LIKE '%@ayache.com'$a$, $b$NOT public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', '')))$b$);
    d := replace(d, $a$AND lower(coalesce(auth.jwt() ->> 'email', '')) NOT LIKE '%@unclogme.com'$a$, $b$$b$);
    IF md5(d) <> t.m_new THEN RAISE EXCEPTION 'splice: % did not produce the expected body', t.sig; END IF;
    EXECUTE d;
  END LOOP;
END $s$;

DO $v$ DECLARE r jsonb; BEGIN
  IF EXISTS (SELECT 1 FROM se_acl_before b JOIN pg_proc p ON p.oid = b.sig::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'verify: privileges moved'; END IF;
  IF EXISTS (SELECT 1 FROM se_targets t WHERE md5(pg_get_functiondef(t.sig::regprocedure)) <> t.m_new) THEN
    RAISE EXCEPTION 'verify: a body is not the expected one'; END IF;
  IF has_function_privilege('anon', 'public.fn_is_staff_email(text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.fn_is_staff_email(text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.fn_is_staff_email(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'verify: helper grants'; END IF;
  -- the rule
  IF public.fn_is_staff_email(NULL) IS NOT NULL OR public.fn_is_staff_email('')
     OR NOT public.fn_is_staff_email('fred@ayache.com') OR NOT public.fn_is_staff_email(' Someone@UNCLOGME.com ')
     OR public.fn_is_staff_email('x@evil-ayache.com') OR public.fn_is_staff_email('x@ayache.com.evil.net')
     OR NOT public.fn_is_staff_email('MichaelEscobar1606@gmail.com')           -- Active, personal
     OR public.fn_is_staff_email('webunclogme@gmail.com')                      -- Inactive (45)
     OR public.fn_is_staff_email('nobody.at.all.zz@gmail.com') THEN            -- no employee
    RAISE EXCEPTION 'verify: the rule'; END IF;
  -- behaviour: a personal address on an Active employee now passes the staff test; a stranger and a company address as before
  r := pg_temp.se_probe('michaelescobar1606@gmail.com');
  IF r->>'report' = 'not a staff account' OR NOT (r->>'photo_path_ok')::boolean THEN RAISE EXCEPTION 'verify: personal %', r; END IF;
  r := pg_temp.se_probe('nobody.at.all.zz@gmail.com');
  IF r->>'report' <> 'not a staff account' OR (r->>'photo_path_ok')::boolean THEN RAISE EXCEPTION 'verify: stranger %', r; END IF;
  r := pg_temp.se_probe('fred@ayache.com');
  IF r->>'report' = 'not a staff account' OR NOT (r->>'photo_path_ok')::boolean THEN RAISE EXCEPTION 'verify: company %', r; END IF;
  RAISE NOTICE 'staff-email rule in place in % functions', (SELECT count(*) FROM se_targets);
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
