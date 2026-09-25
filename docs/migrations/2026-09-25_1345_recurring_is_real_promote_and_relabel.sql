-- ============================================================================
-- 2026-09-25_1345 — RECURRING is real: promote 10 serviced clients, relabel 11 stale ones
-- ============================================================================
-- ASK (Fred, 2026-09-25): "330-FSC ... says is Active, but it has a SA Job open, which is
-- contradictory ... we need to fix it, also is this issue happening with other clients?"
-- Asked which rule holds, he chose "RECURRING is real": an open, visit-generating Service
-- Agreement means RECURRING, and RECURRING -> ACTIVE is how staff STOP a schedule. That
-- SUPERSEDES the 2026-09-08 "we dont need recurrent ... set recurrents to active"
-- (migration 2026-09-08_0130, Client App changelog 2026-09-08), which was only half done:
-- the SA generator was widened to ACTIVE, nobody moved the 149 RECURRING clients, and the
-- widening re-created schedules staff had stopped on purpose (029-JOS, 084-ULT, 201-ALA).
--
-- THIS MIGRATION IS DATA ONLY (the generator is NOT changed here; it narrows back to
-- RECURRING in a later migration, AFTER the four stops below are done in the Client App):
--   1. PROMOTE to RECURRING (Fred: "114, 140, 147, 178, 180, 231, 232, 233, 241, 242 are all
--      Recurrents, the 226 is Active"). Each is ACTIVE by the Jobber sync while serviced on a
--      live, visit-generating SA. 226-JER stays ACTIVE (its SA is to be closed by Fred).
--   2. RELABEL to ACTIVE (Fred: "All of them ACTIVE"): RECURRING clients with no open
--      visit-generating SA and no upcoming SA visits: 209-TRUE, 213-TRUE, 030-KGC, 107-PV and
--      the 7 Warranty-only TCE clients (066, 073, 074, 075, 078, 079, 080). 065-TCE already
--      has that shape as ACTIVE.
-- Both write status_source='manual' (Fred decided each row) and one client_status_changes
-- row each, so the change is in the client's status history with its reason.
--
-- 🛑 THE TRIGGER THAT MAKES STEP 2 DANGEROUS: trg_clients_cleanup_sa_visits_on_status
-- soft-deletes every upcoming scheduled SA visit of a client LEAVING RECURRING, and a
-- soft-delete queues a Jobber visitDelete. So step 2 is only a relabel if each client has
-- ZERO such visits. The precondition below uses the trigger's OWN predicate and raises
-- otherwise, and the post-check asserts no visit of these 21 clients was deleted in this
-- transaction. ACTIVE -> RECURRING (step 1) fires no branch of that trigger.
--
-- "Live, visit-generating SA" = public.fn_generate_sa_visits' job predicate: frequency_days
-- > 0, title 'Service Agreement%' not '[OLD]', job not archived/closed/destroyed, and an
-- unbilled line whose catalogue code is a Service Agreement / Service Call service other
-- than 08 (Warranty of Drainage generates no recurring visits).
--
-- Not done here, deliberately (Fred does them in the Client App so they show in the
-- Activity history; the automation was also refused a UI close by the permission system):
-- 029-JOS and 201-ALA -> INACTIVE (Jobber will refuse the archive until their open quotes
-- and past-due invoices are cleared), 084-ULT and 226-JER: close the SA.
--
-- Audit: clients is audited (audit_clients); the ledger rows carry the reason.
-- ROLLBACK (reverses exactly this migration):
--   begin;
--   update public.clients set status = 'ACTIVE'    where id in (359,302,178,374,232,468,472,471,477,233) and status = 'RECURRING';
--   update public.clients set status = 'RECURRING' where id in (454,455,27,77,21,17,286,15,13,16,20) and status = 'ACTIVE';
--     -- (ACTIVE -> RECURRING fires nothing; RECURRING -> ACTIVE here is safe only while
--     --  those 10 have no upcoming SA visits you want to keep: check first)
--   delete from public.client_status_changes where reason like 'Fred 2026-09-25 (RECURRING is real)%';
--   commit;
-- ============================================================================

begin;

create temp table _promote on commit drop as
  select unnest(array[359,302,178,374,232,468,472,471,477,233])::bigint as id;      -- 114-CI 140-TYO 147-OST 178-LG 180-PV 231-CHE 232-AC 233-AH 241-WYN 242-WYN
create temp table _relabel on commit drop as
  select unnest(array[454,455,27,77,21,17,286,15,13,16,20])::bigint as id;          -- 209-TRUE 213-TRUE 030-KGC 107-PV 066/073/074/075/078/079/080-TCE

create temp table _live_sa on commit drop as
  select j.client_id, string_agg('#' || j.job_number, ', ' order by j.job_number) as jobs
    from public.jobs j
   where j.frequency_days > 0
     and j.title ilike 'Service Agreement%'
     and j.title not ilike '%[OLD]%'
     and coalesce(j.job_status, '') not in ('archived', 'closed', 'destroyed')
     and exists (
       select 1 from public.line_items lp
         join public.service_line_items s
           on s.code = lpad(substring(btrim(lp.name) from '^([0-9]+)'), 2, '0')
        where lp.job_id = j.id and lp.invoice_id is null
          and s.reason in ('Service Agreement', 'Service Call') and s.code <> '08')
   group by j.client_id;

-- PRECONDITIONS ---------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(format('%s status=%s live_sa=%s noncust=%s', c.client_code, c.status, l.jobs is not null,
                           public.fn_is_non_customer(c.id)), '; ')
    into v_bad
    from _promote p join public.clients c on c.id = p.id left join _live_sa l on l.client_id = c.id
   where c.status <> 'ACTIVE' or l.jobs is null or public.fn_is_non_customer(c.id);
  if v_bad is not null or (select count(*) from _promote p join public.clients c on c.id = p.id) <> 10 then
    raise exception 'promote precondition failed: %', coalesce(v_bad, 'not 10 rows');
  end if;

  select string_agg(format('%s status=%s live_sa=%s', c.client_code, c.status, l.jobs), '; ')
    into v_bad
    from _relabel r join public.clients c on c.id = r.id left join _live_sa l on l.client_id = c.id
   where c.status <> 'RECURRING' or l.jobs is not null;
  if v_bad is not null or (select count(*) from _relabel r join public.clients c on c.id = r.id) <> 11 then
    raise exception 'relabel precondition failed: %', coalesce(v_bad, 'not 11 rows');
  end if;

  -- the trigger's own predicate: a relabel must remove NOTHING
  select string_agg(format('%s visit %s on %s', c.client_code, v.id, v.visit_date), '; ')
    into v_bad
    from _relabel r join public.clients c on c.id = r.id
    join public.visits v on v.client_id = c.id
   where v.deleted_at is null and v.visit_status = 'scheduled' and v.visit_date >= current_date
     and exists (select 1 from public.jobs j where j.id = v.job_id and j.title ilike 'Service Agreement%');
  if v_bad is not null then
    raise exception 'relabel would remove upcoming SA visits: %', v_bad;
  end if;
end $$;

-- 1. PROMOTE -------------------------------------------------------------------
with upd as (
  update public.clients c
     set status = 'RECURRING', status_source = 'manual'
    from _promote p
   where c.id = p.id and c.status = 'ACTIVE'
  returning c.id
)
insert into public.client_status_changes (client_id, old_status, new_status, reason, changed_by, changed_by_email, visits_removed, changed_at, event)
select u.id, 'ACTIVE', 'RECURRING',
       format('Fred 2026-09-25 (RECURRING is real): serviced on live Service Agreement %s, so RECURRING. It was ACTIVE only because the Jobber sync never derives status from jobs. Set by the Supabase session on Fred''s instruction.', l.jobs),
       null, null, 0, now(), 'status_change'
  from upd u join _live_sa l on l.client_id = u.id;

-- 2. RELABEL -------------------------------------------------------------------
with upd as (
  update public.clients c
     set status = 'ACTIVE', status_source = 'manual'
    from _relabel r
   where c.id = r.id and c.status = 'RECURRING'
  returning c.id
)
insert into public.client_status_changes (client_id, old_status, new_status, reason, changed_by, changed_by_email, visits_removed, changed_at, event)
select u.id, 'RECURRING', 'ACTIVE',
       'Fred 2026-09-25 (RECURRING is real): stale RECURRING label. No open visit-generating Service Agreement and no upcoming SA visits, so ACTIVE. Nothing was removed. Set by the Supabase session on Fred''s instruction.',
       null, null, 0, now(), 'status_change'
  from upd u;

-- VERIFY (inside the transaction; any failure rolls everything back) -----------
do $$
declare n_p int; n_r int; n_led int; n_del int;
begin
  select count(*) into n_p from public.clients c join _promote p on p.id = c.id where c.status = 'RECURRING' and c.status_source = 'manual';
  select count(*) into n_r from public.clients c join _relabel r on r.id = c.id where c.status = 'ACTIVE' and c.status_source = 'manual';
  select count(*) into n_led from public.client_status_changes where changed_at = now() and reason like 'Fred 2026-09-25 (RECURRING is real)%';
  select count(*) into n_del from public.visits v
   where v.deleted_at = now()
     and v.client_id in (select id from _promote union all select id from _relabel);
  if n_p <> 10 or n_r <> 11 or n_led <> 21 or n_del <> 0 then
    raise exception 'verify failed: promoted=% relabelled=% ledger=% visits_deleted=%', n_p, n_r, n_led, n_del;
  end if;
  raise notice 'OK: promoted=% relabelled=% ledger=% visits_deleted=%', n_p, n_r, n_led, n_del;
end $$;

commit;
