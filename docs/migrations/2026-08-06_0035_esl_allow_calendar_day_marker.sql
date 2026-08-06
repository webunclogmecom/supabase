-- 2026-08-06_0035 — allow 'calendar_day_marker' in entity_source_links.entity_type
--
-- Caught by a live round-trip, not by reading code. `jobber-push-task` created a real Jobber Task,
-- returned ok:true, and the link row was NEVER written — because `entity_source_links` is NOT the
-- free-form polymorphic bridge it is usually described as. It carries a CHECK WHITELIST:
--
--   CHECK (entity_type = ANY (ARRAY['client','derm_manifest','employee','inspection','invoice',
--          'job','line_item','note','photo','property','quote','vehicle','visit']))
--
-- so the insert was rejected 23514 and the edge function swallowed the error.
--
-- 🛑 TWO LESSONS, and the second is the dangerous one:
-- 1. "Polymorphic bridge table" does NOT mean "accepts any entity_type". Read the constraint before
--    adding a new kind of link. (Same shape as the dump_site CHECK that bit the marker insert on
--    2026-08-05: a new value meeting an old constraint.)
-- 2. **A push that creates the remote object but fails to record the link is WORSE than a failed
--    push**, because the next upsert sees no link and creates a SECOND Jobber Task. The verify-then-
--    commit guard covered the Jobber call and not the local write. The function is fixed in the same
--    cycle to fail loudly on the link write; this migration removes the reason it was failing.
--
-- 'calendar_day_marker' is `ops.calendar_day_markers.id` -> a Jobber Task GID. Additive only; no
-- existing row can violate the widened list. Audit: entity_source_links is a sync-linkage table and
-- is not audited (unchanged by this migration).

begin;

alter table public.entity_source_links
  drop constraint if exists entity_source_links_entity_type_chk;

alter table public.entity_source_links
  add constraint entity_source_links_entity_type_chk
  check (entity_type = any (array[
    'client','derm_manifest','employee','inspection','invoice','job','line_item','note','photo',
    'property','quote','vehicle','visit',
    'calendar_day_marker'   -- 2026-08-06: Calendar Day Start/End/Dump markers -> Jobber Tasks
  ]));

commit;

-- Verified: the 13 pre-existing values all still pass (constraint added without NOT VALID, so
-- Postgres validated every existing row at ALTER time — a violation would have aborted this).
-- Then re-run the jobber-push-task round-trip and confirm the link row IS recorded, which is the
-- assertion that failed before this migration.
