-- ============================================================================
-- 2026-08-12_1615: assign client_code to the 6 coded-less clients that are actually live
-- ============================================================================
-- Fred, 2026-08-12: "give the 6 clients codes."
--
-- CONTEXT. 160 ACTIVE clients carry a NULL client_code, but that number badly overstates the
-- problem: only 6 have an open job and only 5 have ever had a visit. The other 154 are one-off
-- Jobber customers (120 have an invoice, 40 have nothing at all) plus obvious non-clients
-- (Doug Test, Example None, Truck Maintenance, Parking, "NOT USE" rows, and four competing
-- plumbers). Those 154 are NOT touched here and are not assumed to be a defect; see
-- docs/audits/2026-08-12_sc_job_duplicate_review_and_close.md.
--
-- THE ASSIGNMENTS, in client-id order (id ascending is the onboarding-order proxy):
--     id  83  PineTree Holding Corp   -> 301-PT     last visit 2026-08-07
--     id 100  Allison Sarbin          -> 302-SAR    last visit 2026-08-05
--     id 263  Federico Hinojosa       -> 303-HIN    last visit 2026-08-05
--     id 351  Laura odette            -> 304-ODE    no visit yet, 1 open job, 1 invoice
--     id 518  Habib Elghrissi         -> 305-HE     last visit 2026-07-29
--     id 525  16 Handles              -> 306-16     last visit 2026-08-04
--
-- NUMBERS, per docs/reference/client_code_scheme.md.
-- Highest normal number (<700) across ALL statuses is 300 (300-EC Excelsior Condo, renumbered
-- by session 1 earlier today), so the next six are 301-306. Gaps are deliberately NOT
-- backfilled. 777-YA is the reserved/vanity band and is excluded from the max, as the scheme
-- requires. The max was computed over every row including INACTIVE, because
-- clients_active_client_code_uniq is a PARTIAL index (WHERE status <> 'INACTIVE') and will not
-- defend a number held by an inactive row.
--
-- 🛑 THE GOLDEN RULE, CHECKED: THE NUMBER MUST BE FREE IN BOTH SYSTEMS.
-- A DB-only check is not enough, because Jobber can hold a code never written back to us (the
-- Jerusalem Pizza incident). Measured against raw.jobber_pull_clients (the 5-minute mirror of
-- Jobber's companyName): ZERO Jobber clients carry a 301-306 prefix, and in fact zero carry any
-- 3xx prefix at all. Control: 465 Jobber client rows were scanned, so the check is not silently
-- reading an empty set. DB side: zero rows match '^30[1-6]-' across all statuses.
--
-- TAGS, and the two collisions this avoided.
--   * "AS" for Allison Sarbin would have collided with 251-AS Andrew Saka, an unrelated person.
--     Used the surname instead: SAR. The scheme allows a shared tag only for locations of the
--     SAME brand, which these are not.
--   * Habib Elghrissi shares a surname with 119-ME Mosche Elghrissi. They are two different
--     people, not two locations of a chain, so HE gets its own tag rather than reusing ME.
--     ⚠ If Fred says they are one household/business, merge them instead; do not assume.
--   * 306-16 follows the documented leading-number precedent (002-41 "41 Pizza and Bakery").
--     Numeric tags 17, 41 and 1265 already exist, so this is in keeping.
--   * PT, SAR, HIN, HE, ODE, 16 were each confirmed absent from the 191 tags in use.
--
-- WHY A DIRECT UPDATE IS SAFE HERE (it is not obvious, and the opposite is true elsewhere).
-- webhook-jobber's handleClient self-heals client_code ONLY when it is missing and explicitly
-- does NOT overwrite an existing value ("Yan frequently typos/truncates it there"). So unlike
-- frequency_days, which lives in a Jobber custom field and silently reverts a DB-only write
-- within the hour, a client_code written here will stick. Airtable was the original owner and
-- is fully retired (2026-07-24), so the DB is now the master for this column.
--
-- 🛑 WHAT THIS DOES NOT DO: it does not rename these clients in Jobber. Yan's convention is to
-- type the code into Jobber's Company Name too, and none of these six will carry it there. That
-- is an outward-facing rename that shows up on invoices, so it needs Fred's say-so. Note that
-- codes 289-300 are ALSO absent from every Jobber name today, so this is the existing norm, not
-- a new gap.
--
-- ⚠ PARALLEL SESSION: session 1 built create-client and still owns that function plus
-- public.client_create_attempts and test client 547 (299-AIC, left alone). This migration does
-- not touch any of them. It also does not go through create-client's reservation, which guards
-- two concurrent CREATES; there is no create here, only a code assigned to clients that already
-- exist in both systems. Checked client_create_attempts: no in-flight attempt holds 301-306.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.clients carries its audit trigger, so all six
-- writes land in audit.logs with old_row intact and are individually revertible.
-- ============================================================================

do $do$
declare v_n int; v_taken int; v_audited boolean; v_max int;
begin
  -- (a) all six exist, are ACTIVE, and have NO code today
  select count(*) into v_n from public.clients
   where id in (83,100,263,351,518,525) and client_code is null and status = 'ACTIVE';
  if v_n <> 6 then
    raise exception 'expected 6 ACTIVE clients with a NULL code among (83,100,263,351,518,525), found %', v_n;
  end if;

  -- (b) the numbers are free in the DB across ALL statuses (the partial index will not do this)
  select count(*) into v_taken from public.clients where client_code ~ '^30[1-6]-';
  if v_taken <> 0 then raise exception '% clients already hold a code in 301-306', v_taken; end if;

  -- (c) the sequence has not moved under us. If session 1 minted 301 while this was being
  -- written, the max is no longer 300 and these numbers are stale -> refuse rather than collide.
  select max((substring(client_code from '^(\d{3})'))::int) into v_max
    from public.clients
   where client_code ~ '^\d{3}-' and (substring(client_code from '^(\d{3})'))::int < 700;
  if v_max <> 300 then
    raise exception 'highest normal client number is now %, expected 300 -- recompute 301-306', v_max;
  end if;

  -- (d) the writes must be recoverable
  select exists (select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid
                  join pg_proc pr on pr.oid=t.tgfoid join pg_namespace pn on pn.oid=pr.pronamespace
                 where c.relname='clients' and pn.nspname='audit' and pr.proname='log_change'
                   and not t.tgisinternal) into v_audited;
  if not v_audited then
    raise exception 'public.clients is NOT audited -- these writes would leave no trail';
  end if;
end
$do$;

update public.clients c
   set client_code = v.code
  from (values
    ( 83, '301-PT'),
    (100, '302-SAR'),
    (263, '303-HIN'),
    (351, '304-ODE'),
    (518, '305-HE'),
    (525, '306-16')
  ) as v(id, code)
 where c.id = v.id
   and c.client_code is null;   -- never overwrite a code that appeared in the meantime

do $do$
declare v_ok int; v_ctl text; v_nullcode int; v_dupe int; v_audit int;
begin
  -- (a) all six carry exactly the intended code
  select count(*) into v_ok from public.clients c
    join (values (83,'301-PT'),(100,'302-SAR'),(263,'303-HIN'),
                 (351,'304-ODE'),(518,'305-HE'),(525,'306-16')) v(id,code)
      on v.id = c.id and c.client_code = v.code;
  if v_ok <> 6 then raise exception 'only % of 6 clients took the intended code', v_ok; end if;

  -- (b) the null-code ACTIVE population dropped by exactly 6
  select count(*) into v_nullcode from public.clients where client_code is null and status='ACTIVE';
  if v_nullcode <> 154 then
    raise exception '% ACTIVE clients still have no code, expected 154 (160 - 6)', v_nullcode;
  end if;

  -- (c) no duplicate NUMBER anywhere, which is the identity the scheme actually protects.
  -- The unique index is on the whole code string, so 247-EC and 247-LOU both satisfy it --
  -- that is exactly how two live clients shared 247 for five weeks. Check the number itself.
  --
  -- 🛑 000 IS A SECOND RESERVED BAND AND THE SCHEME DOC DOES NOT MENTION IT. This check fired
  -- on the first run against a PRE-EXISTING pair: 000-DP (DUMP Pompano, id 76) and 000-DH
  -- (Homestead Dump, id 365), both ACTIVE. They are the disposal facilities we haul TO, carried
  -- as clients so they can be scheduled and invoiced against, not customers occupying a
  -- sequence number. So 000 is a sentinel exactly like the 700+ vanity band, and excluding it
  -- is correct rather than a workaround. Everything else must still be unique.
  -- ⚠ Do NOT "fix" 000-DP / 000-DH by renumbering them. See the note at the foot of this file.
  select count(*) into v_dupe from (
    select (substring(client_code from '^(\d{3})'))::int n
      from public.clients where client_code ~ '^\d{3}-' and status <> 'INACTIVE'
       and (substring(client_code from '^(\d{3})'))::int between 1 and 699
     group by 1 having count(*) > 1) t;
  if v_dupe <> 0 then raise exception '% client NUMBERS are held by more than one active client', v_dupe; end if;

  -- (d) POSITIVE CONTROL. Every check above passes on an UPDATE that rewrote every row. Assert
  -- a client that must NOT have moved: 300-EC is session 1's renumber from earlier today and is
  -- the row immediately adjacent to this range, so a fencepost error would land on it.
  select client_code into v_ctl from public.clients where id =
    (select id from public.clients where client_code = '300-EC');
  if v_ctl is distinct from '300-EC' then
    raise exception 'control client 300-EC now reads % -- the update hit rows it should not have', v_ctl;
  end if;

  -- (e) recoverable
  select count(*) into v_audit from audit.logs
   where table_name='clients' and operation='UPDATE' and changed_at > now() - interval '5 minutes';
  if v_audit < 6 then raise exception 'only % audit rows captured for 6 updates', v_audit; end if;

  raise notice '6 clients coded 301-306; 154 null-code ACTIVE remain (intentional); 300-EC intact';
end
$do$;

-- ============================================================================
-- 🛑 000 IS A RESERVED SENTINEL FOR THE DUMP FACILITIES. DO NOT RENUMBER THEM.
-- ============================================================================
-- Found because the duplicate-number assertion above REFUSED this migration on its first run
-- and rolled the whole thing back. The offender was not one of the six; it was pre-existing:
--
--     id  76   000-DP   DUMP Pompano      ACTIVE
--     id 365   000-DH   Homestead Dump    ACTIVE
--
-- These are the disposal facilities we haul grease TO. They are carried as clients so work can
-- be scheduled and costed against them, and they were deliberately parked on 000 rather than
-- consuming a customer number. That makes 000 a reserved band in exactly the way 700+ is.
--
-- ⚠ docs/reference/client_code_scheme.md documents the 700+ vanity band and says nothing about
-- 000, so a future "find duplicate client numbers" sweep written from that document will flag
-- this pair as a collision and someone will renumber a dump site. It is not a collision.
-- Whoever next edits that scheme doc should add 000 alongside 700+.
--
-- ⚠ It also means "the number is globally unique" is FALSE as literally written, and any code
-- that enforces uniqueness on the number (create-client's reservation, for one) must exclude
-- the sentinel bands or it will misreport. This check now bounds itself to 1..699.
-- ============================================================================
