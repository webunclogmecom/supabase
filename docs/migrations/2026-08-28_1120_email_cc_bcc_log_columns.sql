-- 2026-08-28_1120_email_cc_bcc_log_columns.sql
--
-- STEP 1 of the Gmail-style Cc/Bcc work: the AUDIT TRAIL, shipped before the behaviour.
--
-- Fred, 2026-08-28: he wants a Gmail-style "Cc Bcc" control on the send dialogs in Admin Review
-- and the DERM Tracker, with chip-style multi-address entry.
--
-- 🛑 THE COLUMNS GO FIRST, ON PURPOSE. Cc and Bcc are caller-supplied RECIPIENTS on a
-- regulator- and client-facing email. If the functions learned to send them before the log could
-- record them, every copy sent in that window would be unattributable - and a BCC is by definition
-- invisible to everyone else on the thread, so the send log is the ONLY place it can ever be seen.
-- Shipping the behaviour first would create exactly the silent-recipient problem this feature is
-- most likely to be blamed for later.
--
-- RULE 8 (ADR 010): both tables are ALREADY audited, and adding a column to an audited table is
-- captured automatically by the full-row JSONB trigger. No trigger work needed, and that is the
-- documented behaviour rather than an assumption.
--
-- NULL vs '{}' : NULL means "this send predates the feature, we do not know". An empty array means
-- "we asked and there were none". Do not backfill NULL to '{}' - that would assert knowledge about
-- 60+ historical sends nobody has.
--
begin;

alter table public.visit_photo_email_sends
  add column if not exists cc_emails  text[],
  add column if not exists bcc_emails text[];

alter table public.derm_email_sends
  add column if not exists cc_emails  text[],
  add column if not exists bcc_emails text[];

comment on column public.visit_photo_email_sends.cc_emails is
  'Cc addresses on this send, as supplied by the sender and validated server-side. '
  'NULL = predates the feature (unknown); {} = none were given.';
comment on column public.visit_photo_email_sends.bcc_emails is
  'Bcc addresses on this send. The send log is the ONLY record of a Bcc, because a blind copy is '
  'invisible to every other recipient. NULL = predates the feature; {} = none were given.';
comment on column public.derm_email_sends.cc_emails is
  'Cc addresses on this send, validated server-side. NULL = predates the feature; {} = none given.';
comment on column public.derm_email_sends.bcc_emails is
  'Bcc addresses on this send, including the standing compliance copy. The send log is the ONLY '
  'record of a Bcc. NULL = predates the feature; {} = none given.';

commit;
