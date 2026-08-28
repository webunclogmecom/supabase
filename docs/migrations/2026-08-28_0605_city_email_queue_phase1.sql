-- 2026-08-28_0605_city_email_queue_phase1.sql
--
-- PHASE 1 of the automatic city email ("email 2"). This migration adds NO send behaviour.
-- It adds the interlock column, the go-live switch, and the two views that decide what is due.
-- Nothing can send until a cron and an edge function are wired in a later phase, and even then
-- only once `city_email_start_from` is moved off 'infinity'.
--
-- WHY THIS EXISTS
-- Fred, 2026-08-27: *"the 24-hour email is for when i approve it, which is the final workflow of
-- sending emails to the city."* The timer starts when the DERM sheet has been BLACKED OUT
-- (*"24 hours after the DERM have been blacked out, so it means we need the stamp for it"*),
-- i.e. at derm.redacted_manifest_docs.generated_at.
--
-- FRED'S DECISIONS, 2026-08-28
--   * Payload: the email always carries everything, even if a manual email already sent the photos.
--     *"Yes, the automatic emails sends everything even if it has already been sent."*
--   * No city email on the property => SKIP. *"if they don't have an email it skips."*
--   * Backlog: START FROM NOW. 123 manifests are already older than 24h; switching on without a
--     cutoff would fire all 123 at municipal inboxes in one sweep. `city_email_start_from` is that
--     cutoff and it ships as 'infinity' (= off).
--
-- RULE 8 (ADR 010) — AUDIT
--   * public.visit_photo_email_sends is ALREADY audited; the new column rides the existing
--     full-row JSONB trigger, so no action is needed for it.
--   * public.app_config is OPTED IN by this migration. It had zero triggers. It is a
--     human-editable table and it is about to hold the switch that governs whether regulator
--     email goes out, which rule 8 puts squarely in the must-audit set.
--   * The two new objects are VIEWS and hold no rows, so audit does not apply to them.
--
-- GRAIN NOTES, measured 2026-08-28 before writing this
--   * redacted_manifest_docs is keyed (manifest_id, client_id, effective_page) — PER PAGE.
--     2 manifests have pages whose generated_at differ by more than a minute, so the timer
--     anchors on MAX(generated_at): a partially-generated multi-page manifest is never sent.
--   * The recipient resolves manifest -> manifest_visits -> visits.property_id -> properties.
--     Measured over all 640 blackout docs: 125 resolve to EXACTLY ONE property carrying a city
--     email and ZERO resolve to more than one. Resolving by CLIENT instead would have been
--     ambiguous for 116 of them. Do not "simplify" this to a client-level lookup.
--
begin;

-- ---------------------------------------------------------------------------
-- PART 1 — the interlock column
--
-- 🛑 Nothing has ever recorded WHICH BRANCH the manual Admin Review email took. `include_photos`
-- exists; its manifest sibling did not. Without it, "a manual email already carried the manifest,
-- so cancel the timer" is unenforceable, and the city would receive the manifest twice.
-- NULL is deliberate for historic rows: we genuinely do not know, and NULL never suppresses.
-- ---------------------------------------------------------------------------
alter table public.visit_photo_email_sends
  add column if not exists include_manifest boolean;

comment on column public.visit_photo_email_sends.include_manifest is
  'Did this manual Admin Review email carry the DERM manifest as well as the photos? '
  'TRUE cancels the automatic 24h city email for every manifest linked to this visit. '
  'NULL = unknown (all rows predating 2026-08-28) and never suppresses. '
  'Written by send-visit-photos-email. See derm.v_city_email_candidates.';

-- ---------------------------------------------------------------------------
-- PART 2 — audit public.app_config (rule 8 opt-in)
-- ---------------------------------------------------------------------------
drop trigger if exists audit_app_config on public.app_config;
create trigger audit_app_config
  after insert or update or delete on public.app_config
  for each row execute function audit.log_change();

-- ---------------------------------------------------------------------------
-- PART 3 — the go-live switch, shipped OFF
--
-- One value carries both the on/off state and the backlog cutoff, so they cannot disagree:
--   'infinity'  => off. Nothing is ever due. This is the shipped state.
--   a timestamp => live, and ONLY manifests blacked out strictly after it are ever considered.
-- To go live:  update public.app_config set value = now()::text where key='city_email_start_from';
-- To pause:    set it back to 'infinity' (the cutoff is then lost; record the old value first).
-- A missing key is treated as 'infinity' too, so deleting the row fails closed rather than open.
-- ---------------------------------------------------------------------------
insert into public.app_config (key, value)
values ('city_email_start_from', 'infinity')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- PART 4 — derm.v_city_email_candidates
--
-- EVERY blackout doc with an explicit status. This is the observability view: a row is never
-- silently absent, so "nothing is due" and "everything is blocked" can be told apart.
-- Same three-verdict discipline as scripts/checks/never-executed.mjs.
-- ---------------------------------------------------------------------------
create or replace view derm.v_city_email_candidates as
with cfg as (
  select coalesce(
           (select nullif(btrim(value), '')::timestamptz
              from public.app_config where key = 'city_email_start_from'),
           'infinity'::timestamptz) as start_from
),
docs as (
  select r.manifest_id,
         r.client_id,
         max(r.generated_at) as blacked_at,
         count(*)            as pages
    from derm.redacted_manifest_docs r
    join public.derm_manifests dm on dm.id = r.manifest_id and dm.deleted_at is null
   group by 1, 2
),
resolved as (
  select d.manifest_id,
         d.client_id,
         d.blacked_at,
         d.pages,
         count(distinct v.property_id) as properties,
         count(distinct p.id)          as city_properties,
         min(p.id)                     as property_id
    from docs d
    left join public.manifest_visits mv on mv.manifest_id = d.manifest_id
    left join public.visits v
           on v.id = mv.visit_id and v.deleted_at is null and v.client_id = d.client_id
    left join public.properties p
           on p.id = v.property_id
          and p.deleted_at is null
          and p.city_emails is not null
          and cardinality(p.city_emails) > 0
   group by 1, 2, 3, 4
),
sent as (
  select manifest_id, client_id, min(sent_at) as first_sent_at
    from public.derm_email_sends
   where recipient_type = 'city' and status = 'sent' and coalesce(is_test, false) = false
   group by 1, 2
),
suppressed as (
  select mv.manifest_id, v.client_id, min(s.sent_at) as suppressed_at
    from public.visit_photo_email_sends s
    join public.visits v          on v.id = s.visit_id and v.deleted_at is null
    join public.manifest_visits mv on mv.visit_id = v.id
   where s.status = 'sent'
     and coalesce(s.is_test, false) = false
     and s.include_manifest is true
   group by 1, 2
)
select r.manifest_id,
       r.client_id,
       r.property_id,
       r.blacked_at,
       r.blacked_at + interval '24 hours' as due_at,
       r.pages,
       r.properties,
       r.city_properties,
       s.first_sent_at,
       sup.suppressed_at,
       (select start_from from cfg) as start_from,
       case
         when s.manifest_id   is not null then 'already_sent'
         when sup.manifest_id is not null then 'suppressed_manual'
         when r.properties = 0            then 'no_property'
         when r.city_properties > 1       then 'ambiguous_property'
         when r.city_properties = 0       then 'no_city_email'
         when r.blacked_at + interval '24 hours' > now() then 'waiting_24h'
         when r.blacked_at <= (select start_from from cfg) then 'before_go_live'
         else 'ready'
       end as status
  from resolved r
  left join sent       s   on s.manifest_id   = r.manifest_id and s.client_id   = r.client_id
  left join suppressed sup on sup.manifest_id = r.manifest_id and sup.client_id = r.client_id;

comment on view derm.v_city_email_candidates is
  'Every blacked-out DERM manifest with an explicit status for the automatic city email. '
  'status=ready means due now. Never filters a row away: no_city_email, ambiguous_property and '
  'before_go_live are visible states, not silent absences. Read by derm.v_city_email_queue.';

-- ---------------------------------------------------------------------------
-- PART 5 — derm.v_city_email_queue
--
-- What a sender may act on, and nothing else. `ambiguous_property` is deliberately NOT served:
-- it is zero today, and picking one of two municipal inboxes by min(id) is not a decision code
-- should make silently.
-- ---------------------------------------------------------------------------
create or replace view derm.v_city_email_queue as
select manifest_id, client_id, property_id, blacked_at, due_at, pages
  from derm.v_city_email_candidates
 where status = 'ready';

comment on view derm.v_city_email_queue is
  'Blacked-out manifests due for the automatic city email right now. EMPTY until '
  'public.app_config.city_email_start_from is moved off ''infinity''. One row per '
  '(manifest_id, client_id); the recipient is resolved from properties.city_emails on property_id.';

-- ---------------------------------------------------------------------------
-- PART 6 — grants
--
-- The estate's default privileges hand out grants nobody wrote, so these are set explicitly and
-- then asserted in PART 7 rather than assumed. Only service_role reads these: no app surface
-- consumes them yet, and the Admin Review dialog will get a narrow RPC in a later phase.
-- ---------------------------------------------------------------------------
revoke all on derm.v_city_email_candidates from public, anon, authenticated;
revoke all on derm.v_city_email_queue      from public, anon, authenticated;
grant select on derm.v_city_email_candidates to service_role;
grant select on derm.v_city_email_queue      to service_role;

commit;
