-- 2026-08-05_1456 — Dispatch routing (generalized drive time) + company depot + dump-site exposure
--
-- Fred: "go with the marker phase, and the drive-time behavior too."
-- Two product choices he made when asked (both recorded because both are reversible-looking but not):
--   DEPOT   = the Doral Yard address (client 311, property 80). There was NO depot anywhere in Prod:
--             public.vehicles has 14 columns and not one is a location, and no company/settings
--             relation exists at all. This is the first time the DB knows where a day starts.
--   BUDGET  = drive time computes ON DEMAND against its OWN daily cap, NOT the dump app's.
--
-- ⚠ WHY A SECOND CAP AND NOT `public.dump_eta_take_token`: that cap FAILS CLOSED and it is what
-- protects the DRIVER-FACING DUMP Schedule ETA. Dispatch recompute volume is unbounded (a dispatcher
-- dragging visits around), so sharing the bucket would let office work starve a driver standing at a
-- truck. Separate buckets is the whole point; do not "simplify" them back into one.
--
-- ⚠ APP-WRITE / APP-READ SURFACE (root CLAUDE.md §5 rule): the Visit Calendar (Lovable 6533c3ee,
-- calendar.unclogme.app) reads ops.v_depot + ops.v_dump_sites and calls public.dump_site_status as
-- `authenticated`. Do NOT revoke these as "unused" — measured 2026-08-05, the live Calendar carries a
-- real Supabase session (jwt role=authenticated, sub present). There is NO audit trigger on the two
-- new tables (see the audit opt-out below), so audit.logs silence proves nothing about their use.
--
-- 🛑 AUDIT OPT-OUT, DELIBERATE (Supabase CLAUDE.md rule #8 requires an explicit decision):
--   ops.route_leg_cache        — a derived cache of Google Routes answers. No human-editable field,
--                                fully reconstructible by re-calling the API. Opt-out.
--   ops.dispatch_routing_usage — a spend counter. Append/increment only, no business meaning. Opt-out.
-- Neither touches customer.*, billing, DERM compliance, or webhook secrets, so the hard rule does not
-- bite. public.app_config gets ONE row here and is likewise config, not business data.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE DEPOT. Stored as a PROPERTY REFERENCE, not as a loose address string.
-- ─────────────────────────────────────────────────────────────────────────────
-- Deliberate: public.properties already carries address + city + state + zip + latitude + longitude
-- AND is kept geocoded by the weekly backfill. Storing '8455 Northwest 53rd Street' as text would
-- create a second, un-geocoded copy that silently drifts from the row it was typed from. A property
-- id reuses one source of truth and gets coordinates for free.
insert into public.app_config (key, value, updated_at)
values ('depot_property_id', '80', now())
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ops.v_depot — resolves that key to a usable origin. ONE row, or ZERO if the key is absent/bad.
-- Zero rows is a legitimate state and the caller must handle it (see the degradation note on
-- ops.v_dump_sites below): with no depot, Start/End markers keep honoring the literal drop time,
-- which is exactly the behaviour that shipped 2026-07-28.
create or replace view ops.v_depot as
select
  p.id            as property_id,
  c.name          as depot_name,
  p.address,
  p.city,
  p.state,
  p.zip,
  p.latitude,
  p.longitude
from public.app_config cfg
join public.properties p on p.id = (cfg.value)::bigint
join public.clients   c on c.id = p.client_id
where cfg.key = 'depot_property_id'
  and p.latitude is not null
  and p.longitude is not null;

comment on view ops.v_depot is
  'The company depot (where a truck day starts/ends), resolved from public.app_config key '
  '"depot_property_id" to a geocoded public.properties row. Set to Doral Yard (property 80) by '
  'Fred 2026-08-05. Returns ZERO rows if unset or ungeocoded — callers must degrade to the literal '
  'drop time rather than guessing an origin.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. DUMP SITES, from public.properties — so the app does not re-hardcode coordinates.
-- ─────────────────────────────────────────────────────────────────────────────
-- 🛑 THE DESTINATION AMBIGUITY IS ALREADY SETTLED AND MUST NOT BE RE-LITIGATED. There are two models
-- and they are DIFFERENT THINGS, not duplicates to reconcile:
--   public.disposal_facilities  = the DERM COMPLIANCE catalogue (where waste was legally disposed).
--                                 Its "Homestead Dump" row reads 28000 SW 197th Ave, Homestead 33030.
--   the 000-DH / 000-DP client properties = the DRIVER'S NAVIGATION TARGET, and therefore the correct
--                                 routing destination. DH = 8950 SW 232nd St, Cutler Bay 33190.
-- Those two Homestead addresses are ~20 miles apart. Routing to the compliance address would be
-- confidently, invisibly wrong. This view deliberately reads the OPERATIONAL properties, matching the
-- DUMPS constant in supabase/functions/dump-visit-create/index.ts (whose lat/lng were themselves
-- re-synced to these property rows in migration 2026-08-04_1650).
-- ⚠ DP is TWO physical sites 726 m apart on N Powerline Road; 3100 (Oakland Park) is the one we
-- frequent and is the navigation target. Detection accepts either — that is public.dump_investigate's
-- job, not this view's. Do not "fix" this to the other point.
create or replace view ops.v_dump_sites as
select
  d.dump_key,
  d.label,
  d.client_id,
  d.job_id,
  d.property_id,
  p.address,
  p.city,
  p.latitude,
  p.longitude,
  d.county
from (values
  ('DH', 'Homestead', 365::bigint, 1720::bigint,  98::bigint, 'Miami-Dade'),
  ('DP', 'Pompano',    76::bigint, 1662::bigint, 155::bigint, 'Broward')
) as d(dump_key, label, client_id, job_id, property_id, county)
join public.properties p on p.id = d.property_id;

comment on view ops.v_dump_sites is
  'The two real dump sites as ROUTING DESTINATIONS + the ids needed to create a Dump Offload visit '
  'via public.create_dump_visit. Coordinates come from public.properties so there is ONE source. '
  'NOT public.disposal_facilities — that is the DERM compliance catalogue and its Homestead address '
  'is ~20 miles from the site drivers actually use.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. ROUTE LEG CACHE — arbitrary origin -> destination.
-- ─────────────────────────────────────────────────────────────────────────────
-- public.dump_eta_cache CANNOT be reused: it is keyed (dump_key, lat_r, lng_r, traffic_aware), i.e.
-- the destination is an enum of exactly two dumps. It structurally cannot hold a depot->first-job or
-- a job->job leg. Hence a second cache rather than a widened one.
--
-- Both endpoints are rounded to 2dp (~1.1 km cells), matching what dump_eta_cache actually does.
-- (⚠ the comment in dump-visit-create says "3dp (~110m)" while the code calls toFixed(2) — the CODE
-- is what ships. Copying the comment instead of the code would have produced a different cell size
-- and a cache that never hit.)
create table if not exists ops.route_leg_cache (
  origin_lat_r    numeric(6,2) not null,
  origin_lng_r    numeric(6,2) not null,
  dest_lat_r      numeric(6,2) not null,
  dest_lng_r      numeric(6,2) not null,
  traffic_aware   boolean      not null,
  duration_minutes integer     not null check (duration_minutes > 0),
  distance_mi     numeric(6,1),
  computed_at     timestamptz  not null default now(),
  primary key (origin_lat_r, origin_lng_r, dest_lat_r, dest_lng_r, traffic_aware)
);

comment on table ops.route_leg_cache is
  'Cache of Google Routes v2 legs for DISPATCH-side drive time (depot->job, job->job, job->dump). '
  'Endpoints rounded to 2dp (~1.1km) so repeat views of the same route are free. Derived data: safe '
  'to TRUNCATE, it simply re-populates at API cost. Audit-exempt by design.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE SEPARATE SPEND BUDGET.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists ops.dispatch_routing_usage (
  day          date        not null primary key,
  calls        integer     not null default 0,
  last_call_at timestamptz
);

comment on table ops.dispatch_routing_usage is
  'Daily Google Routes call counter for DISPATCH routing only. Deliberately separate from '
  'public.dump_eta_usage so office recompute volume cannot exhaust the driver-facing dump ETA budget, '
  'which fails closed.';

-- Mirrors public.dump_eta_take_token: counts ATTEMPTS (not successes), resets on the ET day boundary,
-- and returns NULL once the cap is reached so the caller can refuse to spend. Counting attempts is the
-- correct direction for a spend guard — a failed call still costs a quota unit upstream.
create or replace function ops.dispatch_routing_take_token(p_cap integer)
returns integer
language plpgsql
security definer
set search_path = ops, public, pg_temp
as $$
declare
  v_day date := (now() at time zone 'America/New_York')::date;
  v_n   integer;
begin
  insert into ops.dispatch_routing_usage (day, calls, last_call_at)
  values (v_day, 1, now())
  on conflict (day) do update
    set calls        = ops.dispatch_routing_usage.calls + 1,
        last_call_at = now()
  returning calls into v_n;

  if v_n > p_cap then
    return null;   -- over budget: caller must NOT route
  end if;
  return v_n;
end;
$$;

comment on function ops.dispatch_routing_take_token(integer) is
  'Take one token from today''s dispatch routing budget (ET day). Returns the running count, or NULL '
  'when the cap is exceeded. Caller MUST treat NULL — and any error — as "do not route".';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. GRANTS.
-- ─────────────────────────────────────────────────────────────────────────────
-- ⚠ Supabase's ALTER DEFAULT PRIVILEGES auto-grants on newly CREATEd objects in exposed schemas, so
-- everything below is explicit in BOTH directions: revoke what should not be reachable, and grant the
-- WRITER by name. Revoking from PUBLIC alone leaves the explicit anon grant in place, and forgetting
-- the service_role grant is what made the sheet-number OCR function fail 42501 on its first real
-- insert (2026-08-05). Both traps are avoided here on purpose.

-- The two new tables are written ONLY by the edge function (service_role). The app never touches them.
revoke all on ops.route_leg_cache        from public, anon, authenticated;
revoke all on ops.dispatch_routing_usage from public, anon, authenticated;
grant select, insert, update on ops.route_leg_cache        to service_role;
grant select, insert, update on ops.dispatch_routing_usage to service_role;

revoke all on function ops.dispatch_routing_take_token(integer) from public, anon, authenticated;
grant execute on function ops.dispatch_routing_take_token(integer) to service_role;

-- The two views ARE app-facing (read-only) and the Calendar reads them as `authenticated`.
grant select on ops.v_depot      to authenticated, service_role;
grant select on ops.v_dump_sites to authenticated, service_role;
revoke all on ops.v_depot      from anon;
revoke all on ops.v_dump_sites from anon;

-- The dump-site-hours advisory. This is the ONE pre-existing object this migration re-grants:
-- public.dump_site_status was service_role-only, so the Calendar (authenticated) could not call it
-- and the "you are scheduling a dump when Pompano is shut" warning was impossible to build.
-- It is a pure read over public.dump_site_hours (14 rows of opening times) and leaks nothing.
grant execute on function public.dump_site_status(text, timestamptz) to authenticated;

commit;

-- Applied to Prod wbasvhvvismukaqdnouk 2026-08-05 via Management API.
-- Verified AS THE REAL ROLE (`set local role authenticated`), not as owner — see
-- reference_test_as_the_role_not_the_owner: owner-rights testing hides exactly the 42501 this
-- migration's grants exist to prevent.
