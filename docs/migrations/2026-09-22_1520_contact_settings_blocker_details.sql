-- 2026-09-22_1520_contact_settings_blocker_details.sql
--
-- Step 17 of the Contacts Role + Communication build: a consistency fix found by the smoke
-- tests, not by reading the code.
--
-- WHAT THE SMOKE TEST MEASURED. Every operator-reachable refusal in this feature was exercised
-- live through the real RPCs and graded on two things: is the MESSAGE plain language, and does
-- a blocker code reach the LOGS. Result: 9 of 9 messages plain, but only 2 of them carried a
-- code -- the two in `client.create_client_contact` / `update_client_contact` that
-- `2026-09-22_1155` patched. The five in `client.save_contact_settings` carried none.
--
-- 🛑 THAT IS AN INCONSISTENCY I INTRODUCED, minutes after establishing the pattern in the
-- sibling functions in the same session. Fred's 2026-09-14 rule has two halves: the MESSAGE is
-- a plain sentence for the operator, and the code / column / row id go to DETAIL, "which the
-- apps never display and the logs keep". This feature shipped the first half everywhere and the
-- second half in one function out of three. A standard applied in one place is not a standard --
-- the same shape as `feedback_a_standard_inside_one_consumer_is_not_a_standard`.
--
-- NOTHING AN OPERATOR SEES CHANGES. DETAIL is not rendered by any app; this only makes a
-- refusal triageable from the logs without grepping the message text, which is the thing that
-- goes stale when a sentence is reworded.
--
-- 🛑 WHAT IS DELIBERATELY LEFT TECHNICAL, and it is not an oversight. The caller-shape checks --
-- `p_source`, `p_patch`, `unsupported field(s)`, `communication must be a list`,
-- `property_id must be a positive integer` -- keep their identifier-bearing messages and get no
-- blocker code. They cannot be produced by a click: they mean the APP sent a malformed payload,
-- so the parameter name IS the useful information and a plain sentence would hide it. This is
-- the same line `2026-09-22_1155` drew, which patched only the role validation.
--
-- Spliced from the live body (md5 e80a4cae0fa9a06de74e5351216f0834), never retyped; each of the
-- 13 anchors is asserted to occur exactly once AT APPLY TIME, so a body that moved refuses
-- rather than half-applying.

begin;

do $splice$
declare
  v_src text; v_new text; v_n int; i int;
  v_pairs constant text[][] := array[
    array[$anc$raise exception 'That contact no longer exists.' using errcode = 'P0002';$anc$, $anc$raise exception 'That contact no longer exists.'
      using errcode = 'P0002', detail = 'blocker=contact_not_found id=' || p_contact_id;$anc$],
    array[$anc$raise exception '% has been removed in Jobber, so its settings cannot be changed here.', v_label
      using errcode = '22023';$anc$, $anc$raise exception '% has been removed in Jobber, so its settings cannot be changed here.', v_label
      using errcode = '22023', detail = 'blocker=jobber_contact_removed id=' || p_contact_id;$anc$],
    array[$anc$raise exception 'Unknown role "%".', v_role using errcode = '22023';$anc$, $anc$raise exception 'Unknown role "%".', v_role
      using errcode = '22023', detail = 'blocker=person_role_unknown value=' || coalesce(v_role,'(null)');$anc$],
    array[$anc$raise exception 'Say what the role is, or pick one from the list.' using errcode = '22023';$anc$, $anc$raise exception 'Say what the role is, or pick one from the list.'
      using errcode = '22023', detail = 'blocker=person_role_other_blank';$anc$],
    array[$anc$raise exception '% has no email address, so it cannot be set to receive anything. Add an email first.', v_label
        using errcode = '22023';$anc$, $anc$raise exception '% has no email address, so it cannot be set to receive anything. Add an email first.', v_label
        using errcode = '22023', detail = 'blocker=contact_has_no_email id=' || p_contact_id;$anc$],
    array[$anc$raise exception 'Unknown communication type "%".', coalesce(v_t,'') using errcode = '22023';$anc$, $anc$raise exception 'Unknown communication type "%".', coalesce(v_t,'')
          using errcode = '22023', detail = 'blocker=communication_type_unknown value=' || coalesce(v_t,'(null)');$anc$],
    array[$anc$raise exception '% holds several addresses in one field ("%"). Split them into separate contacts before ticking anything.', v_label, v_email
          using errcode = '22023';$anc$, $anc$raise exception '% holds several addresses in one field ("%"). Split them into separate contacts before ticking anything.', v_label, v_email
          using errcode = '22023', detail = 'blocker=contact_email_is_a_list id=' || p_contact_id;$anc$],
    array[$anc$raise exception 'City report is set per location. Pick which location % is told about.', v_label
            using errcode = '22023';$anc$, $anc$raise exception 'City report is set per location. Pick which location % is told about.', v_label
            using errcode = '22023', detail = 'blocker=city_report_needs_location';$anc$],
    array[$anc$raise exception 'That location does not belong to this client.' using errcode = '22023';$anc$, $anc$raise exception 'That location does not belong to this client.'
            using errcode = '22023', detail = 'blocker=location_not_on_this_client property_id=' || v_prop;$anc$],
    array[$anc$raise exception 'That communication covers the whole client, not one location.' using errcode = '22023';$anc$, $anc$raise exception 'That communication covers the whole client, not one location.'
          using errcode = '22023', detail = 'blocker=communication_is_client_wide type=' || coalesce(v_t,'(null)');$anc$],
    array[$anc$raise exception 'Only one contact can be marked as the invoice contact, and % already is. Untick it there first.', v_holder
            using errcode = '23505';$anc$, $anc$raise exception 'Only one contact can be marked as the invoice contact, and % already is. Untick it there first.', v_holder
            using errcode = '23505', detail = 'blocker=invoice_already_held';$anc$],
    array[$anc$raise exception 'Only one contact is told per location when we email the city, and % already is for this location. Untick it there first.', v_holder
            using errcode = '23505';$anc$, $anc$raise exception 'Only one contact is told per location when we email the city, and % already is for this location. Untick it there first.', v_holder
            using errcode = '23505', detail = 'blocker=city_report_already_held';$anc$],
    array[$anc$raise exception '% already has that ticked.', v_holder using errcode = '23505';$anc$, $anc$raise exception '% already has that ticked.', v_holder
          using errcode = '23505', detail = 'blocker=duplicate_in_one_submission type=' || coalesce(v_t,'(null)');$anc$]
  ];
begin
  v_src := pg_get_functiondef('client.save_contact_settings(text,bigint,jsonb)'::regprocedure);
  if md5(v_src) <> 'e80a4cae0fa9a06de74e5351216f0834' then
    raise exception 'save_contact_settings has moved (md5 %). Re-derive the splice.', md5(v_src);
  end if;

  v_new := v_src;
  for i in 1 .. array_length(v_pairs, 1) loop
    v_n := (length(v_new) - length(replace(v_new, v_pairs[i][1], ''))) / length(v_pairs[i][1]);
    if v_n <> 1 then
      raise exception 'anchor % matched % times, expected exactly 1: %', i, v_n, left(v_pairs[i][1], 70);
    end if;
    v_new := replace(v_new, v_pairs[i][1], v_pairs[i][2]);
  end loop;

  if v_new = v_src then raise exception 'splice produced no change'; end if;

  -- the count guard: 13 pairs in, 13 blocker codes out, and none before
  if (length(v_src) - length(replace(v_src, 'detail = ''blocker=', ''))) <> 0 then
    raise exception 'the live body already carries a blocker detail; re-derive';
  end if;
  v_n := (length(v_new) - length(replace(v_new, 'detail = ''blocker=', ''))) / length('detail = ''blocker=');
  if v_n <> array_length(v_pairs, 1) then
    raise exception 'expected % blocker details, found %', array_length(v_pairs, 1), v_n;
  end if;

  execute v_new;
end $splice$;

commit;

-- ============================================================================================
-- VERIFY (run 2026-09-22, after apply)
--
-- Every operator-reachable refusal exercised through the REAL RPCs as a staff user, rolled
-- back, and graded on BOTH halves of the rule:
--
--   1. the MESSAGE is a plain sentence: no snake_case identifier, no kebab-case function name,
--      no raw Postgres array literal. 🛑 The kebab-case arm is not decoration -- the first
--      version of this check passed a message reading "saved through the save-client-contact
--      edge function", which names an edge function to a person. A readability check that only
--      knows snake_case has a hole exactly the width of this estate's function names.
--   2. the DETAIL carries `blocker=<code>`, so a log reader does not have to match on prose.
--
-- 🛑 AND THE FIXTURE IS PART OF THE TEST. The first run of this probe pointed the two role
-- cases at contact 484, which is 112-YA's PRIMARY contact, so `update_client_contact` refused
-- them at an EARLIER guard (42501, "this is the client's main contact") and the role validation
-- was never reached. Both cases returned a plain message and the probe read as a pass. Re-run
-- against 485 (accounting) the real messages appear, with their codes. A refusal that fires
-- before the one you are testing is a false pass, and the control is what exposes it: case 3
-- submits a role the rule still ACCEPTS and must SUCCEED. When the harness was wrong, all
-- three cases returned the same message -- uniform output is the signature of a broken
-- instrument, never of a finding.
-- ============================================================================================
