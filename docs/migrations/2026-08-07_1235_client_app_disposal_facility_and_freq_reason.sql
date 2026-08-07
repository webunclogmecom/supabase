-- ============================================================================
-- 2026-08-07_1235: Client App: retire the property disposal-facility field, and
--                   give a job's frequency change a recorded reason
-- ============================================================================
-- Fred, 2026-08-07, two of six items in one batch:
--   1. "remove the 'Default disposal facility' we don't need that"  (Edit property)
--   3. "When changing a Job frequency we also need a reason for it, same as we ask
--       for a reason when changing the client status."
--
-- The other four items in that batch are app-side or edge-function work and are
-- NOT in this file: the New Job fee picker + the Service Call tab, dropping the
-- "Generate visits" button in favour of generating when a start date is first
-- set, GDO drag-and-drop, and the code-27 GDO audit.
--
-- 🛑 SHIP ORDER FOR ITEM 3, AND IT IS THE WHOLE REASON THIS IS SPLIT UP.
-- `docs/09-known-issues.md` 0g: shipping client.update_client_status's required
-- third argument WITHOUT the UI that supplies it broke every status change in the
-- live app for hours. So the requirement goes on LAST:
--     1. this migration (additive: nothing is required of anyone yet)
--     2. save-client-job deploy A, which RECORDS a reason if one arrives, never demands
--     3. Lovable publish, so the dialog starts asking for one
--     4. save-client-job deploy B, where the demand turns on
-- There is no window in which a cached bundle is refused.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): PART 1 changes no table. PART 2 adds a
-- table and OPTS IN. See the block above the CREATE TABLE.
--
-- Rolled-back probes for both parts ran before this was applied; results are in
-- the changelog entry, not restated here.
-- ============================================================================

-- ============================================================================
-- PART 1: client.update_property_operational stops writing
--          public.properties.default_disposal_facility_id
-- ============================================================================
-- Fred: "remove the 'Default disposal facility' we don't need that."
--
-- MEASURED BEFORE TOUCHING IT: 0 of 856 properties carry a value. Nothing is
-- lost, and this is why the column itself is left in place rather than dropped:
-- an empty column is not urgent, and it is still selected by three views
-- (client.properties, ops.properties, customer.clients), so dropping it is its
-- own change with its own view rewrites. Retiring the WRITER is the whole ask.
--
-- ⚠ THE KEY IS STILL ACCEPTED, AND THAT IS DELIBERATE. Removing
-- 'default_disposal_facility_id' from v_allowed would make the RPC raise 22023
-- on EVERY property save from a browser still running the old bundle, because the
-- unsupported-field branch refuses the whole patch, not just the stray key. The
-- key is therefore accepted and ignored until the new bundle is everywhere.
-- Follow-up, not urgent: drop the key from v_allowed, then the column, then the
-- three views' references.
--
-- 🛑 THE BODY BELOW IS THE LIVE pg_get_functiondef OUTPUT WITH EXACTLY TWO EDITS
-- APPLIED MECHANICALLY (an anchor asserted to match once, then replaced). It was
-- not retyped. CLAUDE.md's "COPY THE WHOLE BODY, NEVER RETYPE IT" rule exists
-- because a retype silently deletes whatever you fail to reproduce, and it cost
-- this repo a 3.5-hour outage on 2026-08-06. The diff of the two files was read
-- line by line and shows only: the comment added above the v_allowed entry, and
-- the removal of the default_disposal_facility_id assignment (with its comma).
-- Positive controls asserted in the same script: sample_port_count and
-- access_schedule are still written, so the edit was not greedy.
-- ============================================================================

CREATE OR REPLACE FUNCTION client.update_property_operational(p_property_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_allowed text[] := array[
    'zone_id','county','access_hours_start','access_hours_end','access_days',
    'access_notes','notes','grease_trap_manhole_count','sample_port_count',
    -- RETIRED 2026-08-07 (Fred: "remove the Default disposal facility, we don't need that").
    -- Deliberately STILL ACCEPTED so a cached bundle that keeps sending the key is not
    -- refused mid-save; it is simply no longer WRITTEN (see the UPDATE list below).
    -- Measured before removing it: 0 of 856 properties ever carried a value.
    'default_disposal_facility_id',
    'access_schedule'  -- NEW 2026-07-30_2103: per-day windows
  ];
  -- The ONLY vocabulary public.properties.access_days uses (verified: 201 rows,
  -- 0 non-conforming). Long names are accepted as ALIASES and normalised down,
  -- so a stale client cannot introduce a second vocabulary.
  v_days     text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  v_bad      text[];
  v_row      public.properties;
  v_in       text[];
  v_norm     text[];
  v_d        text;
  v_sched    jsonb;
  v_k        text;
  v_open     text;
  v_close    text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if lower(coalesce(auth.jwt() ->> 'email','')) not like '%@ayache.com'
     and lower(coalesce(auth.jwt() ->> 'email','')) not like '%@unclogme.com' then
    raise exception 'not a staff account' using errcode = '42501';
  end if;
  if p_property_id is null then
    raise exception 'p_property_id is required' using errcode = '22023';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception 'p_patch must be a non-empty JSON object' using errcode = '22023';
  end if;

  select array_agg(k) into v_bad
  from jsonb_object_keys(p_patch) k
  where k <> all (v_allowed);
  if v_bad is not null then
    raise exception 'unsupported field(s) for properties: %. Wave 1 allows only %. Address fields are Jobber-owned and geofence/lat/long are Samsara-owned; both would be reverted by the inbound sync.',
      v_bad, v_allowed using errcode = '22023';
  end if;

  if p_patch ? 'grease_trap_manhole_count'
     and nullif(p_patch->>'grease_trap_manhole_count','') is null then
    raise exception 'grease_trap_manhole_count cannot be null' using errcode = '22023';
  end if;

  -- ⚠ BUG 1 FIX. Type check first, then VALUE check. The old version stopped at
  -- the type check, which is how ["Monday","Tuesday"] was accepted.
  if p_patch ? 'access_days' then
    if jsonb_typeof(p_patch->'access_days') not in ('array','null') then
      raise exception 'access_days must be a JSON array of day codes (got %)',
        jsonb_typeof(p_patch->'access_days') using errcode = '22023';
    end if;
    if jsonb_typeof(p_patch->'access_days') = 'array' then
      select array_agg(x) into v_in from jsonb_array_elements_text(p_patch->'access_days') x;
      v_norm := array[]::text[];
      foreach v_d in array coalesce(v_in, array[]::text[]) loop
        -- ⚠ A JSON null becomes SQL NULL here, and `NULL <> all(v_days)` evaluates
        -- to NULL rather than true, so the check below would NOT fire and the NULL
        -- would land in the text[]. Caught by the fix's own test run. Reject first.
        if v_d is null then
          raise exception 'access_days cannot contain a null entry' using errcode = '22023';
        end if;
        v_d := lower(btrim(v_d));
        -- accept the long form as an alias, store the canonical short code
        v_d := case v_d
                 when 'monday' then 'mon' when 'tuesday'   then 'tue'
                 when 'wednesday' then 'wed' when 'thursday' then 'thu'
                 when 'friday' then 'fri' when 'saturday'  then 'sat'
                 when 'sunday' then 'sun' else v_d end;
        if v_d <> all (v_days) then
          raise exception 'access_days: % is not a valid day. Use %', v_d, v_days
            using errcode = '22023';
        end if;
        if v_d <> all (v_norm) then v_norm := v_norm || v_d; end if;  -- de-dup
      end loop;
    end if;
  end if;


  -- NEW: access_schedule validation. Object; keys in mon..sun; values
  -- {open:"HH:MM", close:"HH:MM"} 24h. Overnight open>close is legal (into the
  -- next morning), exactly like the legacy single window.
  if p_patch ? 'access_schedule' then
    if jsonb_typeof(p_patch->'access_schedule') = 'null' then
      v_sched := null;
    elsif jsonb_typeof(p_patch->'access_schedule') <> 'object' then
      raise exception 'access_schedule must be an object keyed by day (mon..sun)'
        using errcode = '22023';
    else
      v_sched := p_patch->'access_schedule';
      for v_k in select jsonb_object_keys(v_sched) loop
        if v_k <> all (v_days) then
          raise exception 'access_schedule: % is not a valid day key. Use %', v_k, v_days
            using errcode = '22023';
        end if;
        v_open  := v_sched->v_k->>'open';
        v_close := v_sched->v_k->>'close';
        if v_open is null or v_close is null
           or v_open  !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
           or v_close !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
          raise exception 'access_schedule.%: open/close must be 24h "HH:MM" strings', v_k
            using errcode = '22023';
        end if;
      end loop;
    end if;
  end if;

  update public.properties p set
    zone_id = case when p_patch ? 'zone_id'
                   then nullif(p_patch->>'zone_id','')::bigint else p.zone_id end,
    county = case when p_patch ? 'county'
                  then nullif(nullif(btrim(p_patch->>'county'),''), 'None')
                  else p.county end,
    access_hours_start = case
        -- NEW: a written schedule derives the legacy start as the MODAL open
        -- (Field Portal + ops keep reading the legacy pair as the typical window)
        when p_patch ? 'access_schedule' and v_sched is not null then
          (select v_sched->d->>'open' from jsonb_object_keys(v_sched) d
            group by v_sched->d->>'open' order by count(*) desc, 1 limit 1)
        when p_patch ? 'access_schedule' then null
        when p_patch ? 'access_hours_start' then nullif(p_patch->>'access_hours_start','')
        else p.access_hours_start end,
    access_hours_end = case
        when p_patch ? 'access_schedule' and v_sched is not null then
          (select v_sched->d->>'close' from jsonb_object_keys(v_sched) d
            group by v_sched->d->>'close' order by count(*) desc, 1 limit 1)
        when p_patch ? 'access_schedule' then null
        when p_patch ? 'access_hours_end' then nullif(p_patch->>'access_hours_end','')
        else p.access_hours_end end,
    -- normalised, de-duplicated, validated. An empty array still stores NULL
    -- (0 of 817 rows use '{}'), which is the documented app contract.
    access_days = case when p_patch ? 'access_days'
                       then nullif(v_norm, array[]::text[])
                       else p.access_days end,
    access_schedule = case when p_patch ? 'access_schedule' then v_sched
                           else p.access_schedule end,
    access_notes = case when p_patch ? 'access_notes'
                        then nullif(p_patch->>'access_notes','') else p.access_notes end,
    notes = case when p_patch ? 'notes'
                 then nullif(p_patch->>'notes','') else p.notes end,
    grease_trap_manhole_count = case when p_patch ? 'grease_trap_manhole_count'
                                     then (p_patch->>'grease_trap_manhole_count')::integer
                                     else p.grease_trap_manhole_count end,
    sample_port_count = case when p_patch ? 'sample_port_count'
                             then nullif(p_patch->>'sample_port_count','')::integer
                             else p.sample_port_count end
  where p.id = p_property_id
  returning p.* into v_row;

  if not found then
    raise exception 'property % not found', p_property_id using errcode = 'P0002';
  end if;
  return to_jsonb(v_row);
end;
$function$
;

-- ============================================================================
-- PART 2: public.job_frequency_changes: a job's cadence change needs a REASON
-- ============================================================================
-- Fred, 2026-08-07: "When changing a Job frequency we also need a reason for it,
-- same as we ask for a reason when changing the client status."
--
-- Modelled on public.client_status_changes deliberately, down to the column names
-- and the grant set, so the two read the same way in a query.
--
-- ⚠ WHY THIS IS NOT REDUNDANT WITH audit.logs. public.jobs IS audited (verified
-- 2026-08-07 against pg_trigger), so the frequency VALUE change is already
-- captured as a full-row JSONB before/after. What audit.logs structurally cannot
-- hold is the REASON, a free-text sentence a human typed at the moment of the
-- change. That is the whole point of the ask, and it is the same reason
-- client_status_changes exists alongside the audited public.clients.
--
-- 🛑 WHAT THIS TABLE DOES **NOT** RECORD, AND THE HONEST NAME FOR IT.
-- It records frequency changes made THROUGH THE CLIENT APP, not every frequency
-- change. Cadence is JOBBER-MASTERED (it lives in a Jobber "Frequency" custom
-- field; a DB-only write is reverted within the hour, see
-- memory reference_frequency_days_is_jobber_mastered). public.jobs.frequency_days
-- is therefore also written by webhook-jobber, sync-jobber-poll and
-- sync-jobber-job-drift whenever someone edits the job in Jobber's own UI. Those
-- writes arrive with no reason and MUST NOT be blocked.
-- ⇒ The requirement is enforced at the save-client-job boundary ONLY. Do not add
--   a trigger on public.jobs demanding a reason: it would break all three sync
--   writers, and the sync would then be blamed for a rule we imposed. A gap in
--   this table means "changed outside our app", never "changed without a reason".
--
-- AUDIT-TRAIL STANDING CHECK (CLAUDE.md rule 8): OPT-IN. The trigger is added
-- below, matching audit_client_status_changes on the sibling table. Volume is
-- negligible (one row per deliberate cadence change) and the table is
-- append-only, so the audit rows are a tamper record rather than noise.
-- ============================================================================

create table if not exists public.job_frequency_changes (
  id                 bigint generated by default as identity primary key,
  job_id             bigint      not null references public.jobs(id),
  client_id          bigint      not null references public.clients(id),
  old_frequency_days integer,
  new_frequency_days integer     not null,
  reason             text        not null,
  changed_by         uuid,
  changed_by_email   text,
  changed_at         timestamptz not null default now(),
  -- A blank reason is the same as no reason. NOT NULL alone accepts '' and ' '.
  constraint job_frequency_changes_reason_not_blank check (btrim(reason) <> ''),
  -- Same 1..365 window save-client-job enforces, asserted here too so a script
  -- cannot record a cadence the app would have refused.
  constraint job_frequency_changes_new_freq_range check (new_frequency_days between 1 and 365),
  -- Recording a "change" that changed nothing would make the table lie about how
  -- often cadence moves. The edge function only inserts on a real change; this is
  -- the backstop for anything else that writes here later.
  constraint job_frequency_changes_actually_changed
    check (old_frequency_days is distinct from new_frequency_days)
);

comment on table public.job_frequency_changes is
  'Why a Service Agreement''s cadence changed, captured at the moment of the change by save-client-job. Sibling of public.client_status_changes. Records app-driven changes ONLY. Cadence is Jobber-mastered, so a Jobber-side edit legitimately leaves no row here.';

create index if not exists job_frequency_changes_job_idx
  on public.job_frequency_changes (job_id, changed_at desc);
create index if not exists job_frequency_changes_client_idx
  on public.job_frequency_changes (client_id, changed_at desc);

-- Grants: EXACT parity with public.client_status_changes (measured 2026-08-07).
-- Note what is absent on purpose: `authenticated` holds nothing. The browser
-- never reads or writes this table directly; save-client-job writes it as
-- service_role. A history UI, if one is ever wanted, goes through a view or RPC.
grant select, insert, update, delete, truncate, references, trigger
  on public.job_frequency_changes to service_role;
grant select on public.job_frequency_changes to yannick_readonly;

-- RLS: DISABLED, matching client_status_changes (relrowsecurity = false there).
-- Nothing but service_role and a read-only reporting role can reach the table at
-- all, so a policy would have no role to constrain.

drop trigger if exists audit_job_frequency_changes on public.job_frequency_changes;
create trigger audit_job_frequency_changes
  after insert or update or delete on public.job_frequency_changes
  for each row execute function audit.log_change();
