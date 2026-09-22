-- 2026-09-22_1245_derm_recipient_set.sql
--
-- Step 6 of the Contacts Role + Communication build: the DERM service report becomes a SET of
-- recipients, driven by the configuration seeded in 2026-09-22_1230, and every consumer of
-- "who receives this" is repointed at ONE definition in the same transaction.
-- Plan: Building Apps/Client App/docs/2026-09-22_contacts-implementation-plan.md §2.10.
--
-- ============================================================================================
-- 🛑 THE ONE THING THAT WILL BREAK THIS IF IT IS GOT WRONG: SECURITY DEFINER.
--
-- A SECURITY INVOKER function called INSIDE A VIEW BODY is privilege-checked against the
-- CALLER, not the view owner. An owner-run view launders a TABLE grant; it does not launder a
-- function's EXECUTE-and-read. Proven on a throwaway schema, both directions.
--
-- `client.fn_derm_recipient` is `prosecdef = false` TODAY and is called inside `derm.visits`.
-- After this migration it reads `public.client_communication_prefs`, which is REVOKED from
-- `authenticated`. Leave it INVOKER and every authenticated SELECT on `derm.visits` AND
-- `derm.manifest_recipients` raises 42501, taking the DERM Tracker dark estate-wide WHILE SENDS
-- KEEP WORKING, because service_role has rolbypassrls. Mail fine, app dead, and the migration
-- looks perfectly clean from the psql session that applied it because that session is postgres.
--
-- ⇒ Both functions are SECURITY DEFINER with a pinned search_path, the table stays revoked, and
--   the VERIFY runs `set local role authenticated` because nothing else can see this.
-- ============================================================================================
--
-- BEHAVIOUR TODAY IS UNCHANGED, AND THAT IS TESTABLE RATHER THAN HOPED FOR. 2026-09-22_1230
-- seeded `service_report` to exactly the contact `fn_derm_recipient` already returns, so the
-- rewrite is a provable no-op on all 473 clients. The equivalence test is the gate.
--
-- ============================================================================================
-- THE RETURNED JSON CHANGES SHAPE, AND THAT WAS SWEPT BEFORE DOING IT.
-- old keys: contact_id, contact_role, email, property_id
-- new keys: src, contact_id, display_name, email
-- `contact_role` and `property_id` are DROPPED. Measured across the whole repo and catalogue:
--   * the only DB consumer is `derm.visits`, which reads `->> 'email'`
--   * `save-client-contact` and `send-derm-email` read `.email` only
--   * every `->> 'contact_role'` occurrence in the tree is inside a COMMENT in an
--     already-applied migration; there is no live reader
--   * `contact_id` IS read (2026-09-22_1230's VERIFY) and is KEPT
-- This is the "a whole-row return emits every column and names none" trap from the repo manual,
-- run deliberately in reverse: the shape is changing, so the consumers were enumerated first.
-- ============================================================================================

begin;

-- ------------------------------------------------------------------ 1. the set
create or replace function client.fn_derm_recipients(
  p_client_id bigint, p_override_primary_email text default null
) returns jsonb
language sql stable security definer set search_path to 'public','pg_catalog' as $$
  select coalesce(jsonb_agg(to_jsonb(t) order by t.src, t.contact_id), '[]'::jsonb)
  from (
    select distinct on (lower(btrim(email)))
           src, contact_id, display_name, email
    from (
      select 'ours'::text as src, cc.id as contact_id,
             coalesce(nullif(btrim(concat_ws(' ', cc.first_name, cc.last_name)),''), cc.name) as display_name,
             case when p_override_primary_email is not null
                   and cc.property_id is null and cc.contact_role = 'primary'
                  then p_override_primary_email else cc.email end as email
        from public.client_communication_prefs p
        join public.client_contacts cc on cc.id = p.contact_id
       where p.client_id = p_client_id and p.comm_type = 'service_report'
      union all
      select 'jobber'::text, jc.id,
             coalesce(nullif(btrim(jc.name),''),
                      nullif(btrim(concat_ws(' ', jc.first_name, jc.last_name)),'')),
             jc.email
        from public.client_communication_prefs p
        join public.client_jobber_contacts jc on jc.id = p.jobber_contact_id
       where p.client_id = p_client_id and p.comm_type = 'service_report'
         and jc.deleted_at is null        -- removed in Jobber = not a recipient
    ) u
    where coalesce(btrim(u.email),'') <> '' and u.email not like '%,%'
    order by lower(btrim(u.email)), u.src, u.contact_id
  ) t;
$$;
-- lower(btrim(...)) is not cosmetic: 112-YA held 'Yan@ayache.com ' with a trailing space, so a
-- raw DISTINCT would have mailed the same person twice.
-- The comma filter is the same guard the RPC applies at write time, repeated at read time,
-- because Resend would accept a comma bag as one malformed address and report success.

comment on function client.fn_derm_recipients(bigint,text) is
  'Everyone configured to receive the DERM service report for this client, deduped by lowercased '
  'address. SECURITY DEFINER because it reads client_communication_prefs, which is revoked from '
  'authenticated, and it is called inside derm.visits and derm.manifest_recipients: an INVOKER '
  'function inside a view body is privilege-checked against the CALLER.';

-- ------------------------------------------- 2. the singular becomes a VIEW onto the set
-- 🛑 ONE DEFINITION. The button gate, the promote dialog and the actual send can never disagree,
-- because there is now only one thing to disagree with. Signature and return type are unchanged,
-- so derm.visits keeps compiling. `-> 0` on '[]' returns NULL, which matches today's "no row".
create or replace function client.fn_derm_recipient(
  p_client_id bigint, p_override_primary_email text default null
) returns jsonb
language sql stable security definer set search_path to 'public','pg_catalog' as $$
  select client.fn_derm_recipients(p_client_id, p_override_primary_email) -> 0;
$$;

revoke all on function client.fn_derm_recipients(bigint,text) from public, anon;
revoke all on function client.fn_derm_recipient(bigint,text)  from public, anon;
grant execute on function client.fn_derm_recipients(bigint,text) to authenticated, service_role;
grant execute on function client.fn_derm_recipient(bigint,text)  to authenticated, service_role;

-- ------------------------------------------------------- 3. the five consumers, spliced
-- 🛑 EVERY BODY IS SPLICED FROM pg_get_viewdef WITH ITS md5 PINNED AND ITS ANCHOR ASSERTED TO
-- OCCUR EXACTLY ONCE. derm.visits alone is 19,209 characters; retyping it is how a
-- CREATE OR REPLACE silently deletes the half nobody reproduced.
do $splice$
declare
  v_src text; v_new text; v_n int;
begin
  ---------------------------------------------------------------- 3a. manifest_recipients
  -- Today the gate is "any contact of this client has any email" while the send picks ONE
  -- specific contact. They agree on 0 of 760 rows today, so this is a no-op at ship time and
  -- diverges the moment a human unticks somebody. Sharing the literal function is the only fix
  -- that cannot drift back apart.
  v_src := pg_get_viewdef('derm.manifest_recipients'::regclass, true);
  if md5(v_src) <> 'c2b872fb6b5455534cedb5f498eb341b' then
    raise exception 'derm.manifest_recipients has moved (md5 %). Re-derive the splice.', md5(v_src);
  end if;
  v_n := (length(v_src) - length(replace(v_src, $a1$                    (EXISTS ( SELECT 1
                           FROM client_contacts cc
                          WHERE cc.client_id = r.client_id AND cc.email IS NOT NULL AND cc.email <> ''::text)) AS has_email,$a1$, ''))) / length($a1$                    (EXISTS ( SELECT 1
                           FROM client_contacts cc
                          WHERE cc.client_id = r.client_id AND cc.email IS NOT NULL AND cc.email <> ''::text)) AS has_email,$a1$);
  if v_n <> 1 then raise exception 'manifest_recipients anchor matched %, expected 1', v_n; end if;
  v_new := replace(v_src, $a1$                    (EXISTS ( SELECT 1
                           FROM client_contacts cc
                          WHERE cc.client_id = r.client_id AND cc.email IS NOT NULL AND cc.email <> ''::text)) AS has_email,$a1$,
    $b1$                    (jsonb_array_length(client.fn_derm_recipients(r.client_id)) > 0) AS has_email,$b1$);
  execute 'create or replace view derm.manifest_recipients as ' || v_new;

  ---------------------------------------------------------------- 3b/3c. derm.visits
  v_src := pg_get_viewdef('derm.visits'::regclass, true);
  if md5(v_src) <> '584d5f26a0354eeace6791adb392dff4' then
    raise exception 'derm.visits has moved (md5 %). Re-derive the splice.', md5(v_src);
  end if;

  -- 3b. client_last_email_to: `ORDER BY sent_at DESC LIMIT 1` returns ONE of N arbitrarily once
  -- the sender writes a row per recipient. Aggregate the rows belonging to the SAME send instead,
  -- identified by resend_email_id. coalesce(...,'row:'||id) so the 3 rows with a NULL
  -- resend_email_id match only themselves rather than each other.
  v_n := (length(v_src) - length(replace(v_src, $a2$    ( SELECT es.recipient_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false
          ORDER BY es.sent_at DESC
         LIMIT 1) AS client_last_email_to,$a2$, ''))) / length($a2$    ( SELECT es.recipient_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false
          ORDER BY es.sent_at DESC
         LIMIT 1) AS client_last_email_to,$a2$);
  if v_n <> 1 then raise exception 'visits last_email_to anchor matched %, expected 1', v_n; end if;
  v_new := replace(v_src, $a2$    ( SELECT es.recipient_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false
          ORDER BY es.sent_at DESC
         LIMIT 1) AS client_last_email_to,$a2$,
    $b2$    ( SELECT string_agg(DISTINCT es.recipient_email, ', '::text)
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false
            AND COALESCE(es.resend_email_id, 'row:'::text || es.id::text) = ( SELECT COALESCE(es2.resend_email_id, 'row:'::text || es2.id::text)
                   FROM manifest_visits mv2
                     JOIN derm_email_sends es2 ON es2.manifest_id = mv2.manifest_id
                  WHERE mv2.visit_id = w3.id AND es2.client_id = w3.client_id AND es2.recipient_type = 'client'::text AND es2.status = 'sent'::text AND es2.is_test = false
                  ORDER BY es2.sent_at DESC
                 LIMIT 1)) AS client_last_email_to,$b2$);

  -- 3c. APPEND client_emails. `client_email` (singular) is KEPT and unchanged: CREATE OR REPLACE
  -- VIEW cannot retype an existing column and the DERM Tracker bundle reads it today.
  v_n := (length(v_new) - length(replace(v_new, $a3$    ty.recipient_email AS city_last_test_to
   FROM ( SELECT w2.id,$a3$, ''))) / length($a3$    ty.recipient_email AS city_last_test_to
   FROM ( SELECT w2.id,$a3$);
  if v_n <> 1 then raise exception 'visits tail anchor matched %, expected 1', v_n; end if;
  v_new := replace(v_new, $a3$    ty.recipient_email AS city_last_test_to
   FROM ( SELECT w2.id,$a3$,
    $b3$    ty.recipient_email AS city_last_test_to,
    ARRAY( SELECT r.value ->> 'email'::text
             FROM jsonb_array_elements(client.fn_derm_recipients(w3.client_id)) r(value)) AS client_emails
   FROM ( SELECT w2.id,$b3$);
  execute 'create or replace view derm.visits as ' || v_new;

  ---------------------------------------------------------------- 3d. v_derm_portal_fields
  -- A THIRD, DIFFERENT definition of "the client's email" lived here: the lowest-id emailed
  -- contact. Leaving it is a guaranteed future contradiction between the portal bot and the
  -- sender, so it is repointed and its now-dead LATERAL removed.
  v_src := pg_get_viewdef('public.v_derm_portal_fields'::regclass, true);
  if md5(v_src) <> 'f7c90e3ee0f7f0b170a923633fce1945' then
    raise exception 'v_derm_portal_fields has moved (md5 %). Re-derive the splice.', md5(v_src);
  end if;
  v_n := (length(v_src) - length(replace(v_src, $a4$    ce.email AS client_email,$a4$, ''))) / length($a4$    ce.email AS client_email,$a4$);
  if v_n <> 1 then raise exception 'portal client_email anchor matched %, expected 1', v_n; end if;
  v_new := replace(v_src, $a4$    ce.email AS client_email,$a4$,
                          $b4$    client.fn_derm_recipient(c.id) ->> 'email'::text AS client_email,$b4$);
  v_n := (length(v_new) - length(replace(v_new, $a5$     LEFT JOIN LATERAL ( SELECT cc.email
           FROM client_contacts cc
          WHERE cc.client_id = c.id AND cc.email IS NOT NULL AND cc.email <> ''::text
          ORDER BY cc.id
         LIMIT 1) ce ON true
$a5$, ''))) / length($a5$     LEFT JOIN LATERAL ( SELECT cc.email
           FROM client_contacts cc
          WHERE cc.client_id = c.id AND cc.email IS NOT NULL AND cc.email <> ''::text
          ORDER BY cc.id
         LIMIT 1) ce ON true
$a5$);
  if v_n <> 1 then raise exception 'portal dead-lateral anchor matched %, expected 1', v_n; end if;
  v_new := replace(v_new, $a5$     LEFT JOIN LATERAL ( SELECT cc.email
           FROM client_contacts cc
          WHERE cc.client_id = c.id AND cc.email IS NOT NULL AND cc.email <> ''::text
          ORDER BY cc.id
         LIMIT 1) ce ON true
$a5$, '');
  execute 'create or replace view public.v_derm_portal_fields as ' || v_new;
end $splice$;

notify pgrst, 'reload schema';

commit;

-- ============================================================================================
-- VERIFY  (run 2026-09-22; rehearsed rolled-back with mutation controls before applying)
--
-- 1. EQUIVALENCE, the gate. Must be 0 across all clients:
--      select count(*) from public.clients cl
--       where coalesce(client.fn_derm_recipient(cl.id) ->> 'email','')
--         is distinct from coalesce(client.fn_derm_recipients(cl.id) -> 0 ->> 'email','');
--    MUTATION CONTROL: tick a SECOND service_report contact on one client; the singular and the
--    plural's element 0 still agree, so instead compare against a SNAPSHOT of today's answer
--    taken before the DDL. That snapshot comparison must go red when a recipient is repointed.
--
-- 2. THE GATE AND THE SENDER SHARE ONE PREDICATE. Must be 0:
--      select count(*) from derm.manifest_recipients mr
--       where mr.has_email <> (jsonb_array_length(client.fn_derm_recipients(mr.client_id)) > 0);
--    ⚠ Tautological AFTER this migration (the view IS that expression), so it is asserted
--    against the PRE-change has_email snapshot instead: 725 true / 760 rows, unchanged.
--
-- 3. 🛑 THE PRIVILEGE TEST, AND IT IS THE ONE THAT MATTERS:
--      begin; set local role authenticated;
--        select count(*) from derm.manifest_recipients;   -- must be 760, not 42501
--        select count(*) from derm.visits;                -- must not raise
--      rollback;
--    The migration runs as postgres and looks clean either way.
--    MUTATION CONTROL: flip fn_derm_recipients to SECURITY INVOKER in a rolled-back transaction
--    and re-run; it must raise 42501 permission denied for table client_communication_prefs.
--    A privilege assertion run as a role that already holds the privilege asserts nothing.
--
--    🛑 AND THE FILTER IN THAT TEST IS MANDATORY, WHICH THE MUTATION IS HOW I FOUND OUT.
--    `select count(*) from derm.manifest_recipients` does NOT evaluate the view's columns, so
--    Postgres never calls the function and the probe PASSES ON A BROKEN MIGRATION. Measured:
--    with the function flipped to INVOKER, bare count(*) on BOTH views succeeded and only the
--    direct function call raised. The test must force evaluation:
--        select count(*) from derm.manifest_recipients where has_email;
--        select count(*) from derm.visits where cardinality(client_emails) > 0;
--    With the filters, the same mutation reports three failures instead of one.
--    ⚠ Note `derm.visits.client_email` (singular) does NOT fail under that mutation, and that is
--    correct rather than a gap: it calls fn_derm_recipient, which stays SECURITY DEFINER, and a
--    DEFINER function's body runs as the definer even when it calls an INVOKER one. The column
--    that exposes the break is the new `client_emails`, which calls the plural directly.
--
-- 4. NO-OP ON TODAY'S DATA, asserted rather than assumed:
--      derm.visits.client_email        unchanged on all 1243 rows
--      derm.visits.client_last_email_to unchanged on all 1243 rows (0 sends currently share a
--                                       resend_email_id, so the rewrite must be inert today)
--      v_derm_portal_fields.client_email unchanged on all 75 rows
--      derm.visits.has_client_email     unchanged on all 1243 rows
--
-- 5. SHAPE: derm.visits gains client_emails as its LAST column and every other ordinal holds.
--    v_derm_portal_fields keeps its column list byte-identical.
-- ============================================================================================
