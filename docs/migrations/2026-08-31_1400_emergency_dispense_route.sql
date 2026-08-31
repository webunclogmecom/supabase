-- 2026-08-31_1400_emergency_dispense_route.sql
--
-- Adds `dispense_route` to the emergency issuance ledger.
--
-- WHY. Fred, 2026-08-31: "no auth it enters at once on the app, and everyone is the same user
-- Default". That turned the edge function from passphrase-only into origin-gated-with-optional-
-- passphrase, so there are now TWO ways a credential leaves the door. When this window is reviewed
-- afterwards, "the app asked on page load" and "a human typed the passphrase" are different events
-- and the ledger has to tell them apart. The first draft overloaded `refusal_reason` to carry it,
-- which would have put the string 'via_origin' in a column named for refusals on rows whose
-- outcome is 'granted' - a field that lies about its own meaning is how the NEXT reader gets it
-- wrong, and this table exists precisely to be read by someone who was not here.
--
-- RULE 8 (ADR 010): the table already opted IN and carries audit_emergency_session_grants.
-- Adding a column to an already-audited table is captured automatically (full-row JSONB), so no
-- trigger work is needed here.
--
-- ⚠ NULLABLE ON PURPOSE. The two rows written before this column existed genuinely do not know
-- their route, and inventing a default would manufacture evidence. NULL means "not recorded",
-- which is the truth.
--
begin;

alter table public.emergency_session_grants
  add column if not exists dispense_route text
    check (dispense_route in ('via_origin','via_passphrase'));

comment on column public.emergency_session_grants.dispense_route is
  'How the credential was released: via_origin = the app asked on load with an allowed Origin '
  '(no human typed anything); via_passphrase = someone supplied EMERGENCY_PASSPHRASE. NULL on the '
  'two probe rows written before 2026-08-31 14:00 ET, which predate the column. '
  'NOTE: Origin is browser-set and trivially spoofed outside a browser, so this records WHICH PATH '
  'was taken, not that the caller was genuine. It is provenance, not proof.';

commit;
