-- 2026-09-22_1213_ops_views_primary_contact_scope.sql
--
-- Step 4 of the Contacts Role + Communication build (the ops half).
-- Plan: Building Apps/Client App/docs/2026-09-22_contacts-implementation-plan.md §2.5.
--
-- WHY. Five ops views LEFT JOIN client_contacts on `contact_role = 'primary'` with NO predicate on
-- property_id. That was harmless while a client could hold only one `primary` row. It is not any
-- more: a PROPERTY-SCOPED primary is a different thing from the client-level mirror row, two
-- clients already hold both, and each such client is silently DUPLICATED in all five views today.
-- The new Contacts model invites more contacts per client, so this only gets worse. One line each:
--
--     AND cc.property_id IS NULL
--
-- 🛑 THE DROP IS DE-DUPLICATION, NOT DATA LOSS, AND THAT IS THE INVARIANT THIS MIGRATION ASSERTS.
-- A row count falling is the SYMPTOM; what must be true is that no CLIENT disappears from any
-- view. The VERIFY below compares the DISTINCT client set before and after and requires it to be
-- identical, which is the assertion that would actually catch a mistake here. Comparing counts
-- alone would pass just as well if the predicate had accidentally excluded real clients.
--
-- 🛑 THE PLAN PREDICTED "v_ar_aging drops by exactly 2" AND THE MEASURED ANSWER IS 3. Recorded
-- because the reasoning behind the wrong number is the reusable part: the prediction assumed one
-- duplicated row per duplicated client. `ops.v_ar_aging` is per INVOICE, not per client, so a
-- client with two `primary` rows and three invoices contributes SIX rows and collapses to three.
-- Measured: client 305 (168-AVA) holds 6 rows there and client 582 (320-MGF) holds 0.
-- ⇒ The delta is a function of the VIEW'S GRAIN, not of the number of duplicated clients. Do not
-- carry a single expected number across views of different grain.
--
-- MEASURED IN A ROLLED-BACK REHEARSAL BEFORE APPLYING:
--
--   view                  dropped   distinct clients
--   ops.v_ar_aging              3   111 -> 111   <- per invoice: client 305, 3 invoices x 2 rows
--   ops.v_derm_compliance       1   178 -> 178
--   ops.v_gdo_expiry            1   127 -> 127
--   ops.v_route_today           0     0 ->   0   <- empty today, so it proves nothing on its own
--   ops.v_service_due           1   172 -> 172
--
-- ⚠ THE DELTA IS PINNED HERE; THE ABSOLUTE ROW COUNTS ARE NOT, ON PURPOSE. Two rehearsals eleven
-- minutes apart read v_ar_aging at 160 and then 161 rows, because invoices are live data. Any
-- absolute count written in prose in this repo is a dated observation, never an invariant - which
-- is exactly why the VERIFY below asserts the distinct CLIENT SET rather than a number.
--
-- ⚠ ops.v_route_today is EMPTY at the time of writing, so its zero delta is not evidence of
-- anything. It is included because the defect is structural, not because it was observed there.
--
-- THE TWO CLIENTS, and they are already documented app-side (Client App CLAUDE.md rule 2g-bis):
--   305  168-AVA   client-level `AVA - 168-AVA` + property-scoped `Blas Bonilla` (property 63)
--   582  320-MGF   client-level + property-scoped `Sivane Billera` (property 1122)
-- Whether those property-scoped rows are mis-roled site contacts is a DATA question, open for
-- Fred. This migration does not touch the data; it stops the views double-counting it.
--
-- 🛑 SPLICED FROM pg_get_viewdef, NEVER RETYPED. The five bodies are 1,374 to 3,495 characters;
-- reproducing them by hand is how a CREATE OR REPLACE silently deletes the half you did not
-- retype. The anchor is asserted to occur EXACTLY ONCE per view, and the loop discovers the views
-- by what they actually join rather than from a hardcoded list, so a sixth view acquiring the same
-- join is picked up instead of being missed.
--   ops.v_ar_aging         md5 72a577b987b6626d7711c8167753aef9
--   ops.v_derm_compliance  md5 285be971be4f7d82323cffaaab18ccd8
--   ops.v_gdo_expiry       md5 576c44987898a582a92209e79e270104
--   ops.v_route_today      md5 db438707ccd322e7db758d0aa149f0b4
--   ops.v_service_due      md5 42556cd19ed251cac12828193de1990e
--
-- No column list changes, so CREATE OR REPLACE keeps every grant and every dependent view.

begin;

do $splice$
declare
  r record; v_src text; v_new text; v_n int; v_done int := 0;
  v_anchor constant text :=
    'LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = ''primary''::text';
  v_repl  constant text :=
    'LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = ''primary''::text AND cc.property_id IS NULL';
begin
  for r in
    select c.oid, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'v' and n.nspname = 'ops'
       and pg_get_viewdef(c.oid, true) ~ 'client_contacts'
     order by c.relname
  loop
    v_src := pg_get_viewdef(r.oid, true);

    -- already narrowed? leave it alone, so this migration is re-runnable
    if v_src ~ 'cc[.]property_id IS NULL' then
      continue;
    end if;

    v_n := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
    if v_n <> 1 then
      raise exception 'join anchor matched % times in ops.%, expected 1 - the body has moved, re-derive it', v_n, r.relname;
    end if;

    v_new := replace(v_src, v_anchor, v_repl);
    execute 'create or replace view ops.' || quote_ident(r.relname) || ' as ' || v_new;
    v_done := v_done + 1;
  end loop;

  -- 🛑 a count, so a loop that silently matched nothing cannot pass as success
  if v_done <> 5 then
    raise exception 'expected to narrow 5 ops views, narrowed %', v_done;
  end if;
end $splice$;

commit;

-- ============================================================================================
-- VERIFY  (run 2026-09-22; the row-count half was measured in a rolled-back rehearsal first)
--
-- 1. EVERY view now carries the predicate, and the count is asserted, not eyeballed:
--      select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
--       where c.relkind='v' and n.nspname='ops'
--         and pg_get_viewdef(c.oid,true) ~ 'client_contacts'
--         and pg_get_viewdef(c.oid,true) ~ 'cc[.]property_id IS NULL';
--      EXPECT 5.
--    🛑 The regex uses a POSIX character class, never a backslash escape: this estate has already
--    produced a silent 0-row false all-clear from a doubled backslash. A positive control that
--    must match is included in the probe.
--
-- 2. 🛑 THE INVARIANT THAT MATTERS: no client left any view.
--      the DISTINCT client set of each view must be IDENTICAL before and after.
--    Rows may fall (they did, by 3/1/1/0/1); a missing client would be a defect. Measured in the
--    rehearsal by snapshotting each view's distinct clients into a temp table before the splice
--    and comparing after: 0 clients added, 0 removed, in all five.
--
-- 2b. 🛑 AND THE BEHAVIOURAL HALF, because the client-set check ALONE IS BLIND to the obvious
--    mistake. These are LEFT JOINs: inverting the predicate keeps every client row and merely
--    NULLs the contact columns, so the distinct client set is IDENTICAL either way. Measured -
--    the first mutation run was caught only by the text check in (1). So the VERIFY also asserts
--    that no client LOSES its resolved contact (contact_name non-null), which is what actually
--    goes red: 96 / 165 / 117 / 160 clients across the four non-empty views.
--
-- 3. MUTATION CONTROL: replace the predicate with `cc.property_id IS NOT NULL` in a rolled-back
--    transaction. Assertion 2b must FAIL. A comparison that cannot go red is not evidence, and a
--    comparison that goes red only on a TEXT check is testing the migration's spelling, not its
--    behaviour.
-- ============================================================================================
