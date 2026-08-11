-- ============================================================================
-- 2026-08-11_1240: GDO online reporting becomes ONE FILING PER ACTIVE PERMIT
-- ============================================================================
-- Fred, 2026-08-10: we pump BOTH traps on a visit. So a client holding N active
-- GDO permits owes Miami-Dade N reports per qualifying dump ticket. Our queue has
-- been offering ONE since it went live. That is under-reporting, and it is why
-- visit 6617 (043-MIL, ticket 832194) filed under GDO-14117 on 2026-08-07 while
-- GDO-11024 is still owed.
--
-- WHY THIS IS SMALL, WHEN THE ORIGINAL PLAN WAS SEVEN STAGED STEPS.
-- The original design asked the bot for two new fields (`gdo_id`, `gdo_number`),
-- which forced a coordinated rollout: the endpoint 400s on unknown fields, so it
-- needed a deploy order, two go-signals, and a flip day on which a second county
-- filing could be in flight within seconds. Fred pushed back on the scope, and he
-- was right. The permit is something WE know, because WE chose which one to serve.
--
-- 🛑 THE KEY MOVE: SERVE ONE PERMIT PER TICKET AT A TIME, AND THE EXISTING LEASE
-- BECOMES THE "ONLY ONE IN FLIGHT" GUARANTEE FOR FREE.
-- `derm_portal_leases` is keyed by visit and already blocks the whole manifest for
-- 20 hours. If the queue emits at most one (manifest, permit) pair per manifest per
-- batch, then at most one permit of a ticket is ever outstanding, so a result that
-- comes back can only mean that one. The endpoint recomputes which pair it served.
--
-- ⇒ The BOT'S CONTRACT DOES NOT CHANGE. No new required fields, no new run_id rule,
--   no dedupe-key change, no batch-splitting concern, no go-signal, no flip day.
-- ⇒ `derm_portal_leases` IS NOT TOUCHED. That deletes the single most dangerous item
--   in the original plan: re-keying the lease PK while the queue function still says
--   `onConflict:'visit_id'`, which raises 42P10, is logged and SWALLOWED, and then
--   serves every batch unleased.
-- ⇒ The UNIQUE constraint is NOT touched either. `UNIQUE (visit_id, run_id)` still
--   holds; the bot mints a fresh run_id per attempt, and two permits on one visit are
--   two attempts, so it never collides. No NULLS NOT DISTINCT semantics to reason about.
--
-- COST, stated plainly: a three-permit client files over about two days rather than
-- at once, because each permit waits out the previous one's 20-hour lease. The DERM
-- filing deadline is the 15th of the FOLLOWING month, so this is immaterial. Casa Neos
-- (009-CN, three permits) is the first client this will apply to, on 2026-08-17.
--
-- 🛑 THE DUPLICATE-FILING RULE THAT GOVERNS EVERY GATE BELOW.
-- A missed filing is recoverable. A duplicate filing with the county is not. So every
-- gate resolves an unknown by UNDER-serving:
--   a live submission whose gdo_id is NULL retires the WHOLE manifest, not nothing.
-- If the endpoint ever fails to resolve a permit, the ticket goes quiet and the
-- watchdog below reports it. The opposite reading (a null permit retires no pair)
-- would leave every pair queued and re-file the lot with Miami-Dade.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): `derm_portal_submissions` keeps its existing
-- `audit_derm_portal_submissions` trigger. Adding a column to an audited table is
-- captured automatically (full-row JSONB), so no trigger change is required.
-- ============================================================================

-- ------------------------------------------------- PART 1: store the permit
alter table public.derm_portal_submissions
  add column if not exists gdo_id bigint references public.gdos(id);

comment on column public.derm_portal_submissions.gdo_id is
  'Which GDO permit this filing covered. Resolved server-side in rpa-derm-result from '
  'the pair the queue served; the bot does not send it. NULL means unresolved, which '
  'the queue treats as retiring the whole manifest (under-serve, never double-file).';

-- Bound to the four live ids EXPLICITLY, never a predicate: a predicate would also
-- relabel future null-permit rows and turn a safe under-report into a duplicate.
update public.derm_portal_submissions s
   set gdo_id = v.gdo_id
  from (values (67, 60), (570, 69), (571, 2), (572, 156)) as v(id, gdo_id)
 where s.id = v.id and s.gdo_id is null;

-- ------------------------------------------------- PART 2: fields, one row per permit
-- Only the permit lateral changes. Every other column, join and predicate is copied
-- verbatim from the live definition. LEFT JOIN is preserved deliberately: a code-27
-- client with no ACTIVE permit still yields one row with a null permit, exactly as
-- the old LIMIT 1 lateral did, rather than vanishing from the queue unnoticed.
create or replace view public.v_derm_portal_fields as
 SELECT v.id AS visit_id,
    v.visit_date,
    v.client_id,
    c.client_code,
    c.name AS client_name,
    ce.email AS client_email,
    pp.address,
    pp.city,
    pp.zip,
    pp.county,
    gd.gdo_number,
    m.id AS manifest_id,
    m.white_manifest_number,
    m.dump_ticket_date,
    df.name AS disposal_facility,
    m.derm_address_url,
    m.derm_address_extra_urls,
    m.derm_manifest_url,
    m.derm_manifest_extra_urls,
    GREATEST(v.updated_at, mv_link.linked_at) AS updated_at,
    mv_link.linked_at,
        CASE
            WHEN m.yellow_ticket_number IS NOT NULL THEN m.yellow_ticket_number
            WHEN m.white_manifest_number IS NOT NULL AND length(m.white_manifest_number) >= 5 THEN m.white_manifest_number
            ELSE NULL::text
        END AS ticket_number,
        CASE
            WHEN m.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            WHEN m.white_manifest_number IS NOT NULL AND length(m.white_manifest_number) >= 5 THEN 'dade'::text
            ELSE 'unknown'::text
        END AS jurisdiction,
    -- APPENDED LAST on purpose: CREATE OR REPLACE VIEW can only add columns at the
    -- end. Inserting gdo_id next to gdo_number renames every column after it and
    -- fails with 42P16.
    gd.gdo_id
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     JOIN LATERAL ( SELECT mv.manifest_id,
            GREATEST(m2.updated_at, m2.created_at) AS linked_at
           FROM manifest_visits mv
             JOIN derm_manifests m2 ON m2.id = mv.manifest_id AND m2.deleted_at IS NULL
          WHERE mv.visit_id = v.id
          ORDER BY m2.created_at DESC
         LIMIT 1) mv_link ON true
     JOIN derm_manifests m ON m.id = mv_link.manifest_id
     LEFT JOIN LATERAL ( SELECT cc.email
           FROM client_contacts cc
          WHERE cc.client_id = c.id AND cc.email IS NOT NULL AND cc.email <> ''::text
          ORDER BY cc.id
         LIMIT 1) ce ON true
     LEFT JOIN LATERAL ( SELECT p.address,
            p.city,
            p.zip,
            p.county
           FROM properties p
          WHERE p.client_id = c.id AND p.is_primary
          ORDER BY p.id
         LIMIT 1) pp ON true
     -- CHANGED: every ACTIVE permit, not the first one by id.
     LEFT JOIN LATERAL ( SELECT g.gdo_number, g.id AS gdo_id
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text
         ) gd ON true
     LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
  WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id);

-- ------------------------------------------------- PART 3: the live queue
-- Gates 1 to 3 now key on (manifest, permit). Gate 4, the LEASE, deliberately stays
-- at MANIFEST grain: that is what makes "one permit of a ticket in flight at a time"
-- true, which is what makes the result unambiguous without the bot telling us.
-- DISTINCT ON (manifest_id) then emits the lowest-id unfiled permit for each ticket.
create or replace view public.v_derm_portal_queue as
 SELECT DISTINCT ON (manifest_id) visit_id, visit_date, client_id, client_code,
    client_name, client_email, address, city, zip, county, gdo_number,
    manifest_id, white_manifest_number, dump_ticket_date, disposal_facility,
    derm_address_url, derm_address_extra_urls, derm_manifest_url,
    derm_manifest_extra_urls, updated_at, linked_at, ticket_number, jurisdiction,
    gdo_id
   FROM v_derm_portal_fields f
  WHERE visit_date >= rpa_launch_cutoff()
    -- 1. this PAIR already filed. A null-permit row retires the whole manifest.
    AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run
            AND (s.gdo_id IS NULL OR s.gdo_id IS NOT DISTINCT FROM f.gdo_id)
            AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL)))
    -- 2. 20h attempt cooldown, per pair (null permit = whole manifest)
    AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run
            AND (s.gdo_id IS NULL OR s.gdo_id IS NOT DISTINCT FROM f.gdo_id)
            AND s.created_at > (now() - '20:00:00'::interval)))
    -- 3. held after a non-retryable failure, per pair (null permit = whole manifest)
    AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run
            AND (s.gdo_id IS NULL OR s.gdo_id IS NOT DISTINCT FROM f.gdo_id)
            AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > f.updated_at))
    -- 4. dispense lease. UNCHANGED, and MANIFEST-grained on purpose: this is the
    --    one-in-flight guarantee that lets the endpoint resolve the permit itself.
    AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_leases l
             JOIN manifest_visits lmv ON lmv.visit_id = l.visit_id
          WHERE lmv.manifest_id = f.manifest_id AND l.leased_at > (now() - '20:00:00'::interval)))
  ORDER BY manifest_id, gdo_id, (abs(visit_date - dump_ticket_date)), visit_id;

-- ------------------------------------------------- PART 4: the dry-run queue
-- Same grain so the acceptance cycle exercises the real shape. Pre-cutoff only, so
-- nothing here can ever reach the county.
create or replace view public.v_derm_portal_dryrun as
 SELECT DISTINCT ON (manifest_id) visit_id, visit_date, client_id, client_code,
    client_name, client_email, address, city, zip, county, gdo_number,
    manifest_id, white_manifest_number, dump_ticket_date, disposal_facility,
    derm_address_url, derm_address_extra_urls, derm_manifest_url,
    derm_manifest_extra_urls, updated_at, linked_at, ticket_number, jurisdiction,
    gdo_id
   FROM v_derm_portal_fields f
  WHERE visit_date < rpa_launch_cutoff()
  ORDER BY manifest_id, gdo_id, (abs(visit_date - dump_ticket_date)), visit_id;

-- ------------------------------------------------- PART 5: stop telling the client
-- "reported" when only one of N permits is filed.
-- `reported` was `s.visit_id IS NOT NULL` off a LIMIT 1 lateral, so one filed permit
-- on a three-permit ticket showed the customer a completed report. It is now true only
-- when NO active permit of that client is still outstanding on that manifest.
-- Everything else in the view is unchanged, including which row supplies the
-- confirmation string and the image.
create or replace view customer.gdo_reports as
 SELECT v.id AS visit_id,
    v.client_id,
    v.visit_date,
    (s.visit_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
          FROM gdos g
          JOIN manifest_visits mv ON mv.visit_id = v.id
         WHERE g.client_id = v.client_id AND g.status = 'ACTIVE'::text
           AND g.gdo_number ~ '^GDO-[0-9]+$'::text
           AND NOT EXISTS ( SELECT 1
                 FROM derm_portal_submissions s2
                 JOIN manifest_visits smv2 ON smv2.visit_id = s2.visit_id
                WHERE smv2.manifest_id = mv.manifest_id AND NOT s2.dry_run
                  AND (s2.gdo_id IS NULL OR s2.gdo_id = g.id)
                  AND (s2.status = 'SUCCESS'::text OR s2.portal_confirmation IS NOT NULL)))
    ) AS reported,
    s.created_at AS reported_at,
    s.portal_confirmation AS confirmation,
    COALESCE(s.status = 'SUCCESS'::text AND s.screenshot_path IS NOT NULL, false) AS has_report_image
   FROM visits v
     LEFT JOIN LATERAL ( SELECT s_1.visit_id,
            s_1.created_at,
            s_1.portal_confirmation,
            s_1.status,
            s_1.screenshot_path
           FROM derm_portal_submissions s_1
          WHERE s_1.visit_id = v.id AND NOT s_1.dry_run AND (s_1.status = 'SUCCESS'::text OR s_1.portal_confirmation IS NOT NULL)
          ORDER BY s_1.created_at DESC
         LIMIT 1) s ON true
  WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id);

-- ------------------------------------------------- PART 6: the watchdog
-- Nothing in this system could see a ticket that filed one permit of two. That gap sat
-- for days and surfaced only because Jonathan asked. This is the detector.
-- It must read 1 today (Mila / GDO-11024) and 0 once the rollout has drained.
create or replace view public.v_gdo_permits_short_filed as
 SELECT f.client_code, f.client_id, f.manifest_id, f.ticket_number, f.visit_id,
        f.gdo_id, f.gdo_number, f.visit_date, f.dump_ticket_date
   FROM v_derm_portal_fields f
  WHERE f.gdo_id IS NOT NULL
    -- this permit is NOT filed ...
    AND NOT EXISTS ( SELECT 1
          FROM derm_portal_submissions s
          JOIN manifest_visits smv ON smv.visit_id = s.visit_id
         WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run
           AND (s.gdo_id IS NULL OR s.gdo_id IS NOT DISTINCT FROM f.gdo_id)
           AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL))
    -- ... while a SIBLING permit on the same ticket IS filed
    AND EXISTS ( SELECT 1
          FROM derm_portal_submissions s2
          JOIN manifest_visits smv2 ON smv2.visit_id = s2.visit_id
         WHERE smv2.manifest_id = f.manifest_id AND NOT s2.dry_run
           AND s2.gdo_id IS NOT NULL AND s2.gdo_id IS DISTINCT FROM f.gdo_id
           AND (s2.status = 'SUCCESS'::text OR s2.portal_confirmation IS NOT NULL));

comment on view public.v_gdo_permits_short_filed is
  'Tickets where some of a client''s active GDO permits are filed and others are not. '
  'Reads 1 on 2026-08-11 (043-MIL ticket 832194, GDO-11024 owed). Must read 0 once the '
  'per-permit queue has drained. This is the detector for the failure class that caused '
  'the 2026-08 under-reporting; do not delete it when the count reaches zero.';

grant select on public.v_gdo_permits_short_filed to authenticated, service_role;

-- ------------------------------------------------- PART 7: verification
do $do$
declare
  v_n int; v_txt text; v_before int;
begin
  -- (a) the four live rows carry their permit
  select count(*) into v_n from public.derm_portal_submissions where not dry_run and gdo_id is null;
  if v_n <> 0 then raise exception '% live submissions still have no permit', v_n; end if;
  select count(*) into v_n from public.derm_portal_submissions where not dry_run;
  if v_n <> 4 then raise exception 'expected 4 live submissions, found %', v_n; end if;

  -- (b) fields now emits one row per (visit, active permit).
  -- 56 = 9 Mila visits x 2 permits + 6 Casa Neos x 3 + 20 single-permit visits x 1,
  -- derived independently before this was written rather than read off the new view.
  select count(*) into v_n from public.v_derm_portal_fields;
  if v_n <> 56 then raise exception 'v_derm_portal_fields emits % rows, expected 56', v_n; end if;
  -- and the count only means something if no VISIT was lost or duplicated on the way
  select count(distinct visit_id) into v_n from public.v_derm_portal_fields;
  if v_n <> 35 then raise exception 'field rows now cover % visits, expected 35', v_n; end if;
  select count(*) into v_n from public.v_derm_portal_fields where gdo_id is null;
  if v_n <> 0 then raise exception '% field rows carry no permit', v_n; end if;

  -- (c) THE POINT: the live queue now offers Mila's owed GDO-11024, and nothing else.
  select count(*) into v_n from public.v_derm_portal_queue;
  if v_n <> 1 then raise exception 'live queue returns % rows, expected exactly 1', v_n; end if;
  select gdo_number into v_txt from public.v_derm_portal_queue;
  if v_txt <> 'GDO-11024' then
    raise exception 'live queue offers %, expected GDO-11024 -- the backfill went in backwards', v_txt;
  end if;

  -- (d) ONE IN FLIGHT: no manifest may appear twice in either queue
  select count(*) into v_n from (select manifest_id from public.v_derm_portal_queue group by 1 having count(*)>1) t;
  if v_n <> 0 then raise exception '% manifests appear more than once in the live queue', v_n; end if;
  select count(*) into v_n from (select manifest_id from public.v_derm_portal_dryrun group by 1 having count(*)>1) t;
  if v_n <> 0 then raise exception '% manifests appear more than once in the dryrun queue', v_n; end if;

  -- (e) the five single-permit clients are untouched: still one row per ticket
  select count(*) into v_n from public.v_derm_portal_dryrun
   where client_code in ('041-MB','082-TFC','110-CLA','111-YC','168-AVA');
  if v_n = 0 then raise exception 'single-permit clients vanished from the dryrun queue'; end if;

  -- (f) the watchdog sees the defect it exists for
  select count(*) into v_n from public.v_gdo_permits_short_filed;
  if v_n <> 1 then raise exception 'watchdog reads %, expected exactly 1 (Mila GDO-11024)', v_n; end if;
  select gdo_number into v_txt from public.v_gdo_permits_short_filed;
  if v_txt <> 'GDO-11024' then raise exception 'watchdog names %, expected GDO-11024', v_txt; end if;

  -- (g) the customer no longer sees a part-filed ticket as reported
  select count(*) into v_n from customer.gdo_reports where visit_id = 6617 and reported;
  if v_n <> 0 then
    raise exception 'customer.gdo_reports still reports visit 6617 as fully reported';
  end if;
  -- POSITIVE CONTROL: a fully-filed single-permit ticket must STILL read reported,
  -- otherwise the fix above is just breaking the column for everyone.
  select count(*) into v_n from customer.gdo_reports where visit_id = 6719 and reported;
  if v_n <> 1 then
    raise exception 'visit 6719 (single permit, filed) no longer reads reported -- the guard is too strict';
  end if;

  raise notice 'per-permit queue live: 1 row owed (Mila GDO-11024), watchdog reads 1, 6719 still reported';
end
$do$;
