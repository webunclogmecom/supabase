-- ============================================================================
-- 2026-08-17_1636 — sync.source_field_shadow: remember what we LAST SAW in a
-- source system, per field, so a two-way custom-field sync can adopt ONLY on a
-- real change instead of blind-copying a default.
-- ============================================================================
-- ASK. Yannick, 2026-08-17: custom fields like Client Code and Grease Trap size
-- "should be two-way, if it's us or in jobber that change it the other should
-- adopt". Fred, pinning the safe shape: "only when a change is made we need to
-- adopt." This migration ships the STORAGE for the inbound half. It changes no
-- app, no edge function, no cron, and it does not adopt anything.
--
-- ============================================================================
-- 🛑 READ THIS BEFORE YOU "SIMPLIFY" THIS INTO A STRAIGHT COPY. IT IS MEASURED.
-- ============================================================================
-- Jobber's ALL_PROPERTIES numeric custom field "Grease Trap size"
-- (gid://Jobber/CustomFieldConfigurationNumeric/3061111) has:
--     defaultValue : 0      (Float!, never null)
--     valueNumeric : Float! (materialised on EVERY property, never null)
--     updatedAt    : DOES NOT EXIST on the value
-- So a property nobody has ever touched in Jobber is BYTE-IDENTICAL to one where
-- a human deliberately typed 0. There is no timestamp, no null state, and no
-- "dirty" flag to tell them apart. Confirmed live on a 10-property page: all 10
-- returned a materialised CustomFieldNumeric row, 7 of them reading 0.
--
-- What "just copy Jobber's value in" would have done, measured over the 105
-- linked properties that carry a size:
--     69 properties zeroed          -> 47,732 recorded gallons destroyed
--     10 properties overwritten     -> 9 of them DOWNWARD
--      3 properties actually gained a correct value
--     = 79 of 105 values damaged, SILENTLY.
-- Silently, because public.properties_grease_trap_size_chk permits 0
--     CHECK (grease_trap_size_gallons IS NULL OR (>= 0 AND <= 20000))
-- so nothing raises. There is no error to notice.
--
-- ⇒ THE VALUE ITSELF CARRIES NO INFORMATION ABOUT WHETHER A HUMAN CHOSE IT.
--   Only a comparison against what we saw last time does. That is this table.
--
--     jobber now | last seen | decision
--     0          | 0         | IGNORE    <- the 69. Not an edit. Never adopt.
--     190        | 0         | ADOPT     <- a human just typed it
--     0          | 190       | ADOPT     <- a human just cleared it
--     500        | 500       | IGNORE    <- stale, but not a decision
--     (no row)   | -         | SEED      <- record it, adopt NOTHING
--
-- 🛑 AND DO NOT REPLACE THE SHADOW WITH A TRUTHINESS TEST. `if (value)` and
-- `value ?? fallback` both drop a legitimate 0. The compare must be an identity
-- compare against the stored last-seen value (IS DISTINCT FROM), never a test of
-- whether the value "looks empty". This is the numeric twin of the ?? null bug
-- the property poll already shipped once (CLAUDE.md, "Jobber PROPERTY sync",
-- trap 2: Jobber returns "" not null, and "" is not caught by ?? ).
--
-- 🛑 FIRST RUN MUST SEED SILENTLY. Fred chose this explicitly. With no shadow row
-- yet we RECORD Jobber's current value and change nothing on our side. Adoption
-- begins from the next edit. That is what makes the rollout non-destructive, and
-- it is not optional. The seeding script writes only this table.
--
-- 🛑 CONFLICT = BOTH SIDES MOVED SINCE THE LAST SYNC => RECORD IT AND TOUCH
-- NEITHER. Fred's standing ruling is that the 10 existing disagreements are a
-- human question, not a data question. A conflicting row deliberately does NOT
-- re-baseline, or the conflict would silently resolve itself on the next pass and
-- nobody would ever see it.
--
-- ============================================================================
-- WHY A NEW TABLE AND NOT A COLUMN
-- ============================================================================
-- Rule 1 (source-agnostic schema): a `jobber_grease_trap_size_last_seen` column on
-- public.properties is exactly the source-prefixed column the rule forbids. Here
-- 'jobber' is a VALUE in source_system, never a column name, the same discipline
-- public.entity_source_links already applies one level up at identity.
--
-- Rule 2/3 (3NF): the shadow depends on (entity, source system, source field) and
-- NOT on the property's key alone, so it does not belong on properties. Per column:
--   entity_type/entity_id/source_system/field_key  = the whole key, by definition
--   source_value / our_value / *_at / conflict_*   = facts about THAT sync pair only
-- Nothing here is derivable from a join. It is a record of an observation at a
-- point in time, which is precisely what cannot be recomputed later.
--
-- Not entity_source_links: that answers "which Jobber object is this", one row per
-- identity, shared by 14 entity types and 15k photo rows. It has no unique key to
-- upsert against (no UNIQUE on entity_type/entity_id/source_system).
-- Not raw.jobber_pull_properties: upsertRaw DELETEs then INSERTs every sweep, so it
-- holds "current", never "last seen when we last decided".
--
-- field_key holds the Jobber CUSTOM FIELD CONFIGURATION GID, never the label.
-- There are FOUR numeric grease-trap fields in the account and two of them share
-- the label "GT size"; two more differ only by a capital S. A label binding
-- collides today and breaks the moment anyone renames a field in Jobber.
--   3061111  "Grease Trap size"  ALL_PROPERTIES   <- the only one in scope
--   3061109  "Grease Trap Size"  ALL_JOBS         (archived:true)
--   3070341  "GT size"           ALL_JOBS
--   3070342  "GT size"           ALL_INVOICES
--
-- A SECOND FIELD NEEDS NO MIGRATION. Lock Box/Key would be a new field_key whose
-- values are JSON strings ("A-14") instead of JSON numbers (190). Values are stored
-- as BARE jsonb scalars, not wrapped in a {"numeric": ...} envelope, so one compare
-- serves every type. That is what value-as-jsonb buys, and it is why the
-- decision function below is typeless and compares with IS DISTINCT FROM: it
-- handles 0, "" and null correctly without any per-type special case.
-- ⚠ "CLIENT #" (ALL_PROPERTIES text, gid 3087457) is OUT OF SCOPE. It is populated
-- on 1 of 474 properties, its only value is a list of restaurant names, and it is
-- NOT clients.client_code. Do not wire it.
--
-- ============================================================================
-- RULE 8 — AUDIT DECISION: EXPLICIT OPT-OUT.
-- ============================================================================
-- sync.source_field_shadow gets NO audit.log_change trigger. Reasons, in order:
--   1. It is machine sync state, not human-editable business data. No human ever
--      types into it. ADR 010's opt-in default is for human-editable fields.
--   2. The business column it guards, public.properties.grease_trap_size_gallons,
--      IS audited (trigger audit_properties). Every adoption therefore lands in
--      audit.logs with its old_row, where the forensics actually matter.
--   3. Auditing the shadow as well would double every row for zero forensic gain:
--      the shadow is rewritten on every sweep across ~459 properties per field,
--      which is a high-churn machine write.
--   4. The one thing worth keeping IS kept on the row itself: conflict_at,
--      conflict_count and the two conflict_* value snapshots, plus adopted_at /
--      adopted_from / adopted_to. A conflict is never overwritten by a later pass.
-- The VERIFY block below ASSERTS the opt-out is real rather than assuming it.
-- Reversing this decision needs Fred's sign-off (ADR 010).
--
-- ============================================================================
-- GRANTS. The schema is NOT PostgREST-exposed, and nothing is granted to anon or
-- authenticated. This is deliberate: Supabase's ALTER DEFAULT PRIVILEGES hands new
-- tables in an exposed schema out anon-readable and authenticated-writable BEFORE
-- any GRANT in the migration runs, and a GRANT cannot remove what it did not
-- create. That is exactly how public.job_frequency_changes shipped with
-- authenticated holding TRUNCATE on 2026-08-07 while its own header asserted the
-- opposite. So the VERIFY block reads the ACL back with has_table_privilege AFTER
-- the fact, with service_role as the positive control, instead of trusting the
-- GRANT statements written here.
-- ⚠ A probe over the Management API runs as postgres, which OWNS the table and
-- holds rolbypassrls, so "an insert works" proves nothing about the ACL.
-- has_table_privilege does not depend on who is asking, which is why it is used.
--
-- RULE 5 — IDEMPOTENT. Every statement is CREATE ... IF NOT EXISTS / CREATE OR
-- REPLACE / a guarded DO block. Re-running this file is a no-op. The VERIFY block
-- writes a sentinel probe row (entity_id = -1) and deletes it again, asserting
-- both the upsert idempotency and that it left nothing behind.
--
-- NO FOREIGN KEY on entity_id, by design: entity_type is polymorphic, exactly as
-- in public.entity_source_links, so no single FK target exists.
-- ============================================================================

-- STOP. THIS FILE IS SUPERSEDED IN PART BY 2026-08-18_0120, AND RE-APPLYING IT WOULD
-- REVERT THAT FIX. It CREATE OR REPLACEs sync.fn_record_shadow, so a successful re-run
-- silently restores the body in which an open conflict did NOT freeze the row, and a row
-- explicitly held for a person becomes eligible for a silent overwrite again.
--
-- Until 0120 existed this was prevented only by accident: the VERIFY block at the end
-- asserted the table was empty, which stopped being true once seeding ran, and the abort
-- rolled the replacement back. Relying on an unrelated assertion to protect a later fix is
-- not a guard, it is luck. This is the guard.
--
-- A fresh database (0120 not yet applied) passes straight through, which is what makes
-- this a supersession check rather than a permanent lock.
do $supersede$
begin
  if to_regprocedure('sync.fn_record_shadow(text,bigint,text,text,text,jsonb,jsonb,jsonb)') is not null
     and pg_get_functiondef('sync.fn_record_shadow(text,bigint,text,text,text,jsonb,jsonb,jsonb)'::regprocedure)
         like '%CONFLICT_FROZEN%' then
    raise exception 'refusing to re-apply 2026-08-17_1636: 2026-08-18_0120 is already applied and this file would revert its conflict freeze. Apply 0120 instead, or drop this guard deliberately if you really mean to roll back.';
  end if;
end
$supersede$;

create schema if not exists sync;

comment on schema sync is
  'Machine sync state between our warehouse and external source systems. NOT PostgREST-exposed and NOT granted to anon/authenticated. Holds no business data: everything here is a record of what we observed in a source system and when, so a two-way sync can tell an EDIT from an unchanged default.';

-- ----------------------------------------------------------------------------
-- The store.
-- ----------------------------------------------------------------------------
create table if not exists sync.source_field_shadow (
  entity_type   text        not null,
  entity_id     bigint      not null,
  source_system text        not null,
  field_key     text        not null,

  -- Informational only. NEVER bind on this: four numeric grease-trap fields exist
  -- and two share a label. field_key (the configuration GID) is the binding.
  field_label   text,

  -- What the SOURCE read, the last time we looked. NOT NULL on purpose: JSON null
  -- means "the source has no value for this field", and a MISSING ROW means "we
  -- have never looked". Collapsing those two into a SQL NULL is what would make
  -- the first-run silent seed indistinguishable from a cleared field.
  source_value  jsonb       not null,
  -- What WE held at that same instant. This is the half that makes a both-sides-
  -- changed conflict decidable without archaeology through audit.logs (which
  -- cannot answer it today anyway: handleProperty writes with the plain client, so
  -- its writes land as app_source='sql', indistinguishable from a manual psql edit).
  our_value     jsonb       not null,

  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),

  -- Set when we last ACTED on a change. adopted_from/adopted_to are the values
  -- written, kept so an adoption can be explained and reversed without a log dig.
  adopted_at    timestamptz,
  adopted_from  jsonb,
  adopted_to    jsonb,

  -- Set when BOTH sides moved since the last sync. The row is then frozen: neither
  -- source_value nor our_value is re-baselined, so the conflict stays visible until
  -- a human resolves it (by making the two sides agree, which re-baselines).
  conflict_at           timestamptz,
  conflict_source_value jsonb,
  conflict_our_value    jsonb,
  conflict_count        integer     not null default 0,

  constraint source_field_shadow_pkey
    primary key (entity_type, entity_id, source_system, field_key),

  -- Same vocabulary as public.entity_source_links_entity_type_chk, so the two
  -- tables join on a shared alphabet rather than a parallel one.
  constraint source_field_shadow_entity_type_chk check (entity_type = any (array[
    'client','derm_manifest','employee','inspection','invoice','job','line_item',
    'note','photo','property','quote','vehicle','visit','calendar_day_marker'])),
  constraint source_field_shadow_source_system_chk check (length(btrim(source_system)) > 0),
  constraint source_field_shadow_field_key_chk     check (length(btrim(field_key)) > 0),
  constraint source_field_shadow_conflict_count_chk check (conflict_count >= 0)
);

comment on table sync.source_field_shadow is
  'What we LAST SAW in a source system for one field of one entity, plus what we held at the same instant. Exists because Jobber custom fields carry a defaultValue (0 for numerics) and no updatedAt, so an untouched field is byte-identical to a deliberate zero: adoption must fire on a CHANGE vs this row, never on the value itself. A missing row means we have never looked (=> seed silently, adopt nothing). See docs/migrations/2026-08-17_1636_jobber_custom_field_shadow.sql.';
comment on column sync.source_field_shadow.field_key is
  'Source-side field identity. For Jobber custom fields this is the CustomFieldConfiguration GID (e.g. gid://Jobber/CustomFieldConfigurationNumeric/3061111), NEVER the label: four numeric grease-trap fields exist in the account and two share the label "GT size".';
comment on column sync.source_field_shadow.source_value is
  'Last observed source value, as jsonb. JSON null = the source holds no value. A MISSING ROW = we have never observed it. Those are different states and must stay different.';
comment on column sync.source_field_shadow.our_value is
  'Our value at the instant source_value was observed. Comparing our CURRENT value against this is how "did our side change too" is answered.';
comment on column sync.source_field_shadow.conflict_at is
  'Both sides moved since the last sync. The row is frozen while this is set: nothing is adopted and nothing is re-baselined, so the disagreement stays visible. Fred 2026-08-17: the existing disagreements are a human question, not a data question.';

-- Conflicts are the thing a human is asked to look at, and they are rare, so a
-- partial index keeps that report cheap without paying on the hot upsert path.
create index if not exists source_field_shadow_conflict_idx
  on sync.source_field_shadow (source_system, field_key, conflict_at desc)
  where conflict_at is not null;

-- Sweeps are per (source_system, field_key) across every entity.
create index if not exists source_field_shadow_field_idx
  on sync.source_field_shadow (source_system, field_key);

-- ----------------------------------------------------------------------------
-- THE DECISION. One place, typeless, testable.
--
-- It lives in SQL rather than only in the Node scripts so that the truth table can
-- be asserted here, in the migration, against the real implementation. A sweep or
-- a script that returns "nothing to do" with no positive control is an untested
-- instrument; the VERIFY block below exercises every branch and asserts that more
-- than one distinct decision comes back.
--
-- p_shadow_exists is a separate argument and NOT inferred from a NULL value,
-- because "the source holds null" and "we have never looked" are different states
-- and only the second one may seed.
-- ----------------------------------------------------------------------------
create or replace function sync.fn_shadow_decision(
  p_shadow_exists boolean,
  p_source_now    jsonb,   -- what the source reads right now
  p_source_seen   jsonb,   -- source_value on the shadow row
  p_our_now       jsonb,   -- what we hold right now
  p_our_seen      jsonb    -- our_value on the shadow row
) returns text
language sql
immutable
set search_path = ''
as $fn$
  select case
    -- Never looked before. Record and adopt NOTHING. Fred's explicit choice.
    when not coalesce(p_shadow_exists, false)              then 'SEED'
    -- Already agree. Nothing to adopt either way; safe to re-baseline, and this is
    -- also how a recorded conflict gets released once a human makes the two match.
    when p_source_now is not distinct from p_our_now       then 'IN_SYNC'
    -- The source did not move. Whatever its value is, it is not an edit. THIS is
    -- the branch that protects the 69 never-touched zeros.
    when p_source_now is not distinct from p_source_seen   then 'IGNORE'
    -- The source moved and so did we, since the last time we looked. Do not guess.
    when p_our_now    is distinct from p_our_seen          then 'CONFLICT'
    -- The source moved, we did not. A human edited it over there.
    else 'ADOPT'
  end
$fn$;

comment on function sync.fn_shadow_decision(boolean, jsonb, jsonb, jsonb, jsonb) is
  'Two-way field sync decision: SEED / IN_SYNC / IGNORE / CONFLICT / ADOPT. Branch order is load-bearing. IN_SYNC precedes IGNORE so a resolved conflict re-baselines. IGNORE precedes CONFLICT so "the source did not move" wins over "we moved": our own edit with the source unchanged is not a conflict, it just re-baselines our_value, and the NEXT source-side edit then adopts over it (last edit wins, which is what two-way was asked for). Compares with IS DISTINCT FROM, never truthiness: 0 and "" are real values.';

-- ----------------------------------------------------------------------------
-- The writer. One statement, idempotent on the PK (rule 5), with the freeze-on-
-- conflict and the never-re-baseline-a-conflict behaviour built in so no caller
-- can forget it. Returns the decision it acted on.
--
-- p_adopted_to is what the CALLER actually wrote on our side (or NULL if it wrote
-- nothing). This function does NOT touch public.properties: the adoption write is
-- the caller's, so that the field-specific column, CHECK range and clearing guard
-- stay in the field-specific layer.
-- ----------------------------------------------------------------------------
create or replace function sync.fn_record_shadow(
  p_entity_type   text,
  p_entity_id     bigint,
  p_source_system text,
  p_field_key     text,
  p_field_label   text,
  p_source_now    jsonb,
  p_our_now       jsonb,
  p_adopted_to    jsonb default null   -- non-null only when the caller adopted
) returns text
language plpgsql
set search_path = ''
as $fn$
declare
  v_exists      boolean;
  v_source_seen jsonb;
  v_our_seen    jsonb;
  v_decision    text;
begin
  select true, s.source_value, s.our_value
    into v_exists, v_source_seen, v_our_seen
    from sync.source_field_shadow s
   where s.entity_type   = p_entity_type
     and s.entity_id     = p_entity_id
     and s.source_system = p_source_system
     and s.field_key     = p_field_key;

  v_decision := sync.fn_shadow_decision(
    coalesce(v_exists, false), p_source_now, v_source_seen, p_our_now, v_our_seen);

  if v_decision = 'CONFLICT' then
    -- FREEZE. Record the disagreement, re-baseline NOTHING. If this re-baselined,
    -- the conflict would resolve itself on the next pass and no human would ever
    -- be asked about it, which is the failure this whole table exists to avoid.
    update sync.source_field_shadow s
       set conflict_at           = now(),
           conflict_source_value = p_source_now,
           conflict_our_value    = p_our_now,
           conflict_count        = s.conflict_count + 1,
           last_seen_at          = now()
     where s.entity_type   = p_entity_type
       and s.entity_id     = p_entity_id
       and s.source_system = p_source_system
       and s.field_key     = p_field_key;
    return v_decision;
  end if;

  insert into sync.source_field_shadow as s (
    entity_type, entity_id, source_system, field_key, field_label,
    source_value, our_value, first_seen_at, last_seen_at,
    adopted_at, adopted_from, adopted_to)
  values (
    p_entity_type, p_entity_id, p_source_system, p_field_key, p_field_label,
    p_source_now, p_our_now, now(), now(),
    case when p_adopted_to is not null then now() end,
    case when p_adopted_to is not null then p_our_now end,
    p_adopted_to)
  on conflict (entity_type, entity_id, source_system, field_key) do update
     set field_label  = coalesce(excluded.field_label, s.field_label),
         source_value = excluded.source_value,
         -- After an adopt, OUR value is now the adopted one, not what we held a
         -- moment ago. Recording our pre-adopt value here would make the very next
         -- pass see "we changed" and report a phantom conflict.
         our_value    = coalesce(p_adopted_to, excluded.our_value),
         last_seen_at = now(),
         adopted_at   = case when p_adopted_to is not null then now()        else s.adopted_at   end,
         adopted_from = case when p_adopted_to is not null then p_our_now    else s.adopted_from end,
         adopted_to   = case when p_adopted_to is not null then p_adopted_to else s.adopted_to   end,
         -- Sides agree again => release a recorded conflict. conflict_count is kept
         -- as history; only the open flag clears.
         conflict_at  = case when v_decision = 'IN_SYNC' then null else s.conflict_at end;

  return v_decision;
end
$fn$;

comment on function sync.fn_record_shadow(text, bigint, text, text, text, jsonb, jsonb, jsonb) is
  'Idempotent upsert of one shadow row. Returns the decision from sync.fn_shadow_decision. On CONFLICT it FREEZES the row (records the disagreement, re-baselines nothing) so the conflict stays visible for a human. Never writes to the business table: the adoption write belongs to the caller, which owns the column, its CHECK range and the clearing guard.';

-- ----------------------------------------------------------------------------
-- Grants. Nothing to anon or authenticated, on the schema or the objects.
-- ----------------------------------------------------------------------------
revoke all on schema sync from public;
revoke all on all tables    in schema sync from anon, authenticated;
revoke all on all functions in schema sync from anon, authenticated, public;

grant usage on schema sync to service_role;
grant select, insert, update, delete on sync.source_field_shadow to service_role;
grant execute on function sync.fn_shadow_decision(boolean, jsonb, jsonb, jsonb, jsonb) to service_role;
grant execute on function sync.fn_record_shadow(text, bigint, text, text, text, jsonb, jsonb, jsonb) to service_role;

-- ============================================================================
-- VERIFY. Assert the end state; a check that cannot fail proves nothing, so every
-- block below carries a control that MUST come back the other way.
-- ============================================================================
do $do$
declare
  v_pk           text;
  v_audit_trigs  int;
  v_relacl       text;
  v_anon_sel     boolean; v_anon_ins  boolean;
  v_authn_sel    boolean; v_authn_ins boolean; v_authn_trunc boolean;
  v_svc_sel      boolean;
  v_ctl_sel      boolean;
  v_rows         int;
  v_anon_exec    boolean; v_authn_exec boolean; v_svc_exec boolean;
  v_distinct     int;
  v_d            text;
  v_naive        int;
begin
  ---------------------------------------------------------------------------
  -- 1. shape
  ---------------------------------------------------------------------------
  select string_agg(a.attname, ',' order by k.ord)
    into v_pk
    from pg_constraint c
    join lateral unnest(c.conkey) with ordinality as k(att, ord) on true
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.att
   where c.conrelid = 'sync.source_field_shadow'::regclass and c.contype = 'p';
  if v_pk is distinct from 'entity_type,entity_id,source_system,field_key' then
    raise exception 'PK is "%", expected entity_type,entity_id,source_system,field_key', v_pk;
  end if;

  ---------------------------------------------------------------------------
  -- 2. rule 8: the audit OPT-OUT is real, not merely claimed in the header.
  --    Control: public.properties, the table this one guards, MUST come back 1.
  ---------------------------------------------------------------------------
  select count(*) into v_audit_trigs
    from pg_trigger t join pg_proc p on p.oid = t.tgfoid
    join pg_namespace pn on pn.oid = p.pronamespace
   where t.tgrelid = 'sync.source_field_shadow'::regclass
     and pn.nspname = 'audit' and p.proname = 'log_change' and not t.tgisinternal;
  if v_audit_trigs <> 0 then
    raise exception 'rule 8: shadow table opted OUT of audit but carries % audit trigger(s)', v_audit_trigs;
  end if;
  select count(*) into v_rows
    from pg_trigger t join pg_proc p on p.oid = t.tgfoid
    join pg_namespace pn on pn.oid = p.pronamespace
   where t.tgrelid = 'public.properties'::regclass
     and pn.nspname = 'audit' and p.proname = 'log_change' and not t.tgisinternal;
  if v_rows < 1 then
    raise exception 'CONTROL FAILED: public.properties has no audit trigger, so the opt-out reasoning (adoptions are captured there) is false and the check above is untested';
  end if;

  ---------------------------------------------------------------------------
  -- 3. ACL read back AFTER the fact, not inferred from the GRANTs written above.
  --    This is the job_frequency_changes lesson: CREATE TABLE can hand out
  --    privileges before any GRANT runs, and a GRANT cannot remove them.
  --    Control: service_role MUST be true, or has_table_privilege is just
  --    returning false for everything and the anon/authenticated checks are noise.
  ---------------------------------------------------------------------------
  v_anon_sel    := has_table_privilege('anon',          'sync.source_field_shadow', 'SELECT');
  v_anon_ins    := has_table_privilege('anon',          'sync.source_field_shadow', 'INSERT');
  v_authn_sel   := has_table_privilege('authenticated', 'sync.source_field_shadow', 'SELECT');
  v_authn_ins   := has_table_privilege('authenticated', 'sync.source_field_shadow', 'INSERT');
  v_authn_trunc := has_table_privilege('authenticated', 'sync.source_field_shadow', 'TRUNCATE');
  v_svc_sel     := has_table_privilege('service_role',  'sync.source_field_shadow', 'SELECT');
  v_ctl_sel     := has_table_privilege('authenticated', 'public.properties',        'SELECT');

  if not v_svc_sel then
    raise exception 'service_role cannot read the shadow table; the seeding/adoption scripts would 42501';
  end if;
  if not v_ctl_sel then
    raise exception 'CONTROL FAILED: has_table_privilege says authenticated cannot SELECT public.properties, which is false. The instrument is broken; conclude nothing from the anon checks';
  end if;
  if v_anon_sel or v_anon_ins then
    raise exception 'anon holds privileges on the shadow table (select=%, insert=%)', v_anon_sel, v_anon_ins;
  end if;
  if v_authn_sel or v_authn_ins or v_authn_trunc then
    raise exception 'authenticated holds privileges on the shadow table (select=%, insert=%, truncate=%)',
      v_authn_sel, v_authn_ins, v_authn_trunc;
  end if;
  select coalesce(c.relacl::text, '(null = owner only)') into v_relacl
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'sync' and c.relname = 'source_field_shadow';

  -- 3b. EXECUTE is a SEPARATE privilege system. REVOKE ... ON ALL TABLES does
  --     nothing to it, and Supabase's default privileges hand new functions out
  --     to authenticated. Check it explicitly, same control shape.
  v_anon_exec  := has_function_privilege('anon',
    'sync.fn_record_shadow(text, bigint, text, text, text, jsonb, jsonb, jsonb)', 'EXECUTE');
  v_authn_exec := has_function_privilege('authenticated',
    'sync.fn_record_shadow(text, bigint, text, text, text, jsonb, jsonb, jsonb)', 'EXECUTE');
  v_svc_exec   := has_function_privilege('service_role',
    'sync.fn_record_shadow(text, bigint, text, text, text, jsonb, jsonb, jsonb)', 'EXECUTE');
  if not v_svc_exec then
    raise exception 'service_role cannot EXECUTE fn_record_shadow; the scripts would 42501';
  end if;
  if v_anon_exec or v_authn_exec then
    raise exception 'fn_record_shadow is EXECUTEable by anon=% authenticated=%; a shadow write from a browser would let anyone forge a baseline and trigger a bogus adopt',
      v_anon_exec, v_authn_exec;
  end if;

  ---------------------------------------------------------------------------
  -- 4. THE TRUTH TABLE. Every branch, against the real function.
  --    Written as (shadow_exists, source_now, source_seen, our_now, our_seen)
  --    => expected decision. The 0-vs-0 row is the 69 properties.
  ---------------------------------------------------------------------------
  -- assert row by row so the failure message names the case that broke
  for v_d in
    select t.label || ': got ' || t.got || ', want ' || t.want from (values
      -- never looked: seed, whatever the values are
      ('never looked, jobber 0',
        sync.fn_shadow_decision(false, '0'::jsonb,   null,        '190'::jsonb,  null),       'SEED'),
      ('never looked, both empty',
        sync.fn_shadow_decision(false, 'null'::jsonb,null,        'null'::jsonb, null),       'SEED'),
      -- 🛑 THE 69: jobber reads 0 because it always has. NOT an edit. Never adopt.
      ('the 69: jobber 0 unchanged, we hold 190',
        sync.fn_shadow_decision(true,  '0'::jsonb,   '0'::jsonb,  '190'::jsonb, '190'::jsonb),'IGNORE'),
      -- stale but unchanged on both sides
      ('stale 500 vs our 750, neither moved',
        sync.fn_shadow_decision(true,  '500'::jsonb, '500'::jsonb,'750'::jsonb, '750'::jsonb),'IGNORE'),
      -- a human typed a value in Jobber
      ('a human typed 190 in jobber',
        sync.fn_shadow_decision(true,  '190'::jsonb, '0'::jsonb,  '0'::jsonb,   '0'::jsonb),  'ADOPT'),
      -- a human CLEARED it in Jobber (0 is a real decision here)
      ('a human cleared 190 to 0 in jobber',
        sync.fn_shadow_decision(true,  '0'::jsonb,   '190'::jsonb,'190'::jsonb, '190'::jsonb),'ADOPT'),
      -- both sides moved since the last sync
      ('both sides moved',
        sync.fn_shadow_decision(true,  '300'::jsonb, '0'::jsonb,  '250'::jsonb, '190'::jsonb),'CONFLICT'),
      -- we moved, jobber did not: NOT a conflict, just re-baseline
      ('we moved, jobber did not',
        sync.fn_shadow_decision(true,  '0'::jsonb,   '0'::jsonb,  '250'::jsonb, '190'::jsonb),'IGNORE'),
      -- sides already agree (also the release path for a recorded conflict)
      ('sides already agree',
        sync.fn_shadow_decision(true,  '190'::jsonb, '0'::jsonb,  '190'::jsonb, '0'::jsonb),  'IN_SYNC'),
      -- typeless: identical logic on a TEXT field, no migration needed to add one
      ('text field, jobber filled a blank',
        sync.fn_shadow_decision(true,  '"A-14"'::jsonb, '""'::jsonb, '""'::jsonb, '""'::jsonb), 'ADOPT'),
      ('text field, jobber blank unchanged, we hold a value',
        sync.fn_shadow_decision(true,  '""'::jsonb,  '""'::jsonb, '"A-14"'::jsonb,'"A-14"'::jsonb),'IGNORE')
    ) t(label, got, want) where t.got is distinct from t.want
  loop
    raise exception 'truth table FAILED: %', v_d;
  end loop;

  -- The truth table is only meaningful if the function is not answering with a
  -- constant. Assert every expected outcome actually appeared.
  select count(distinct d) into v_distinct from (values
      (sync.fn_shadow_decision(false, '0'::jsonb,   null,        '190'::jsonb,  null)),
      (sync.fn_shadow_decision(true,  '0'::jsonb,   '0'::jsonb,  '190'::jsonb, '190'::jsonb)),
      (sync.fn_shadow_decision(true,  '190'::jsonb, '0'::jsonb,  '0'::jsonb,   '0'::jsonb)),
      (sync.fn_shadow_decision(true,  '300'::jsonb, '0'::jsonb,  '250'::jsonb, '190'::jsonb)),
      (sync.fn_shadow_decision(true,  '190'::jsonb, '0'::jsonb,  '190'::jsonb, '0'::jsonb))
  ) t(d);
  if v_distinct <> 5 then
    raise exception 'CONTROL FAILED: only % distinct decisions across 5 designed-different cases; the function may be answering with a constant', v_distinct;
  end if;

  -- NEGATIVE CONTROL: what the naive "copy if it differs from ours" rule would do
  -- to the 69. It must say ADOPT, or this whole table is solving a problem that
  -- does not exist and the header is wrong.
  select count(*) into v_naive from (values
      ('0'::jsonb, '190'::jsonb)   -- jobber 0 (untouched), we hold 190
  ) t(src, ours) where t.src is distinct from t.ours;
  if v_naive <> 1 then
    raise exception 'CONTROL FAILED: the naive value-compare did not flag the 0-vs-190 case, so the "69 would be zeroed" premise is untested here';
  end if;

  ---------------------------------------------------------------------------
  -- 5. RULE 5: the writer is idempotent. Sentinel entity_id = -1 cannot collide
  --    with a real property id. Cleaned up before this block ends.
  ---------------------------------------------------------------------------
  delete from sync.source_field_shadow where entity_id = -1;

  v_d := sync.fn_record_shadow('property', -1, 'jobber',
           'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size',
           '0'::jsonb, '190'::jsonb);
  if v_d <> 'SEED' then raise exception 'first write should SEED, got %', v_d; end if;

  -- second identical pass: jobber unchanged => IGNORE, and still exactly one row
  v_d := sync.fn_record_shadow('property', -1, 'jobber',
           'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size',
           '0'::jsonb, '190'::jsonb);
  if v_d <> 'IGNORE' then raise exception 'second identical write should IGNORE, got %', v_d; end if;

  select count(*) into v_rows from sync.source_field_shadow where entity_id = -1;
  if v_rows <> 1 then raise exception 'upsert is not idempotent: % rows for the sentinel', v_rows; end if;

  -- our side did NOT move: assert the seed wrote nothing to properties-shaped state
  select count(*) into v_rows from sync.source_field_shadow
   where entity_id = -1 and adopted_at is null and source_value = '0'::jsonb and our_value = '190'::jsonb;
  if v_rows <> 1 then raise exception 'seed did not record (source 0 / ours 190) with adopted_at NULL'; end if;

  -- a genuine jobber edit, adopted by the caller
  v_d := sync.fn_record_shadow('property', -1, 'jobber',
           'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size',
           '300'::jsonb, '190'::jsonb, '300'::jsonb);
  if v_d <> 'ADOPT' then raise exception 'a changed jobber value should ADOPT, got %', v_d; end if;
  select count(*) into v_rows from sync.source_field_shadow
   where entity_id = -1 and adopted_to = '300'::jsonb and adopted_from = '190'::jsonb
     and our_value = '300'::jsonb and adopted_at is not null;
  if v_rows <> 1 then raise exception 'adopt did not re-baseline our_value to the adopted value'; end if;

  -- and the pass right after an adopt must be quiet, not a phantom conflict
  v_d := sync.fn_record_shadow('property', -1, 'jobber',
           'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size',
           '300'::jsonb, '300'::jsonb);
  if v_d <> 'IN_SYNC' then raise exception 'the pass after an adopt should be IN_SYNC, got %', v_d; end if;

  -- both sides move => CONFLICT, and the row FREEZES (source_value must NOT advance)
  v_d := sync.fn_record_shadow('property', -1, 'jobber',
           'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size',
           '450'::jsonb, '275'::jsonb);
  if v_d <> 'CONFLICT' then raise exception 'both sides moved should CONFLICT, got %', v_d; end if;
  select count(*) into v_rows from sync.source_field_shadow
   where entity_id = -1 and conflict_at is not null and conflict_count = 1
     and source_value = '300'::jsonb and our_value = '300'::jsonb;
  if v_rows <> 1 then
    raise exception 'CONFLICT did not freeze the row: source_value/our_value were re-baselined, so the conflict would vanish on the next pass';
  end if;

  -- repeated conflict counts, still frozen
  v_d := sync.fn_record_shadow('property', -1, 'jobber',
           'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size',
           '450'::jsonb, '275'::jsonb);
  select count(*) into v_rows from sync.source_field_shadow where entity_id = -1 and conflict_count = 2;
  if v_rows <> 1 then raise exception 'conflict_count did not advance on a repeat'; end if;

  -- a human resolves it by making the sides agree => IN_SYNC releases the flag
  v_d := sync.fn_record_shadow('property', -1, 'jobber',
           'gid://Jobber/CustomFieldConfigurationNumeric/3061111', 'Grease Trap size',
           '450'::jsonb, '450'::jsonb);
  if v_d <> 'IN_SYNC' then raise exception 'agreeing sides should be IN_SYNC, got %', v_d; end if;
  select count(*) into v_rows from sync.source_field_shadow
   where entity_id = -1 and conflict_at is null and conflict_count = 2;
  if v_rows <> 1 then raise exception 'IN_SYNC did not release the conflict flag (or lost the count history)'; end if;

  delete from sync.source_field_shadow where entity_id = -1;
  select count(*) into v_rows from sync.source_field_shadow where entity_id = -1;
  if v_rows <> 0 then raise exception 'sentinel probe rows left behind'; end if;

  ---------------------------------------------------------------------------
  -- 6. the migration itself adopted nothing and seeded nothing.
  --
  -- SCOPED TO ROWS THIS RUN COULD HAVE CREATED. It used to count the WHOLE table,
  -- which was true only for as long as the table shipped empty. Once seed_jobber_custom_
  -- field_shadow.js ran for real (458 rows, 2026-08-17), re-applying this file raised here
  -- and rolled back its own CREATE OR REPLACE of fn_shadow_decision and fn_record_shadow --
  -- so the file broke the rule-5 idempotency its own header claims, and broke it in the
  -- direction of reverting later fixes. An assertion about what THIS migration did must not
  -- be written as an assertion about the state of the world.
  ---------------------------------------------------------------------------
  select count(*) into v_rows from sync.source_field_shadow where first_seen_at >= now();
  if v_rows <> 0 then
    raise exception 'the migration left % shadow rows; it must ship EMPTY (seeding is a separate, dry-runnable script)', v_rows;
  end if;

  raise notice 'OK  pk=%  audit_triggers=%  relacl=%', v_pk, v_audit_trigs, v_relacl;
  raise notice 'OK  anon: select=% insert=% | authenticated: select=% insert=% truncate=% | service_role select=% (control: authenticated on public.properties=%)',
    v_anon_sel, v_anon_ins, v_authn_sel, v_authn_ins, v_authn_trunc, v_svc_sel, v_ctl_sel;
  raise notice 'OK  EXECUTE fn_record_shadow: anon=% authenticated=% service_role=%',
    v_anon_exec, v_authn_exec, v_svc_exec;
  raise notice 'OK  truth table: 11 cases, % distinct decisions across the 5 designed-different ones', v_distinct;
  raise notice 'OK  writer: SEED -> IGNORE -> ADOPT -> IN_SYNC -> CONFLICT(frozen, count 2) -> IN_SYNC(released); sentinel cleaned up';
  raise notice 'OK  table ships EMPTY: % rows. Seeding is scripts/sync/seed_jobber_custom_field_shadow.js (dry-run by default).', v_rows;
end
$do$;

-- The Management API does not return RAISE NOTICE, so the same facts are emitted
-- as a result set. Pure SELECT, safe to re-run.
select 'sync.source_field_shadow'                                                as object,
       (select count(*) from sync.source_field_shadow)                           as rows_shipped,
       (select count(*) from pg_trigger t join pg_proc p on p.oid = t.tgfoid
          join pg_namespace pn on pn.oid = p.pronamespace
         where t.tgrelid = 'sync.source_field_shadow'::regclass
           and pn.nspname = 'audit' and p.proname = 'log_change'
           and not t.tgisinternal)                                               as audit_triggers_optout,
       (select count(*) from pg_trigger t join pg_proc p on p.oid = t.tgfoid
          join pg_namespace pn on pn.oid = p.pronamespace
         where t.tgrelid = 'public.properties'::regclass
           and pn.nspname = 'audit' and p.proname = 'log_change'
           and not t.tgisinternal)                                               as control_properties_audited,
       coalesce((select c.relacl::text from pg_class c
                   join pg_namespace n on n.oid = c.relnamespace
                  where n.nspname='sync' and c.relname='source_field_shadow'),
                '(owner only)')                                                  as relacl,
       has_table_privilege('anon','sync.source_field_shadow','SELECT')            as anon_select,
       has_table_privilege('authenticated','sync.source_field_shadow','SELECT')   as authenticated_select,
       has_table_privilege('authenticated','sync.source_field_shadow','TRUNCATE') as authenticated_truncate,
       has_table_privilege('service_role','sync.source_field_shadow','SELECT')    as service_role_select,
       has_table_privilege('authenticated','public.properties','SELECT')          as control_instrument_works,
       sync.fn_shadow_decision(true,'0'::jsonb,'0'::jsonb,'190'::jsonb,'190'::jsonb)   as the_69_case,
       sync.fn_shadow_decision(true,'190'::jsonb,'0'::jsonb,'0'::jsonb,'0'::jsonb)     as human_typed_case,
       sync.fn_shadow_decision(true,'300'::jsonb,'0'::jsonb,'250'::jsonb,'190'::jsonb) as both_moved_case,
       sync.fn_shadow_decision(false,'0'::jsonb,null,'190'::jsonb,null)                as first_run_case;
