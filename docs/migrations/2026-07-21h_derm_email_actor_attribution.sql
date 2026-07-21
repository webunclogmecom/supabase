-- ============================================================================
-- 2026-07-21h — Activity-trail attribution for DERM emails (who hit "Send")
-- ============================================================================
-- WHY (Fred 2026-07-21, after the "who sent the Hallandale city emails?" ask):
-- the DERM Tracker's DIRECT writes are ALREADY fully attributed — every
-- derm-tracker audit.logs row carries the user (jwt_claims.email + sub;
-- verified 71/71 over 7 days). The ONE hole is the `send-derm-email` edge
-- function: it runs as service_role, so its derm_email_sends rows recorded
-- role='service_role' with no user (the 6 city sends on 2026-07-21 were
-- un-attributable to a person). This closes that hole by recording WHO
-- triggered each send.
--
-- HOW: the DERM Tracker forwards the signed-in user's JWT on
-- functions.invoke (same session that makes its authenticated table writes).
-- The edge fn now decodes that JWT (read-only; the app is auth-gated) and
-- writes the actor onto the send-log row. These columns are auto-captured by
-- the existing audit trigger on derm_email_sends too.
--
-- 3NF NOTE: sent_by_email is a POINT-IN-TIME snapshot of the actor at send
-- time (intentional denormalization per ADR 004, the standard exception for
-- audit/activity records — the email is the human-readable "who", captured as
-- it was then, not a live FK to auth.users). sent_by_user_id is the stable
-- auth uid. AUDIT: derm_email_sends is already audit-opted-in (2026-06-04);
-- adding columns is auto-captured, no trigger change.
--
-- SCOPE: this is the email path only. Frontend "who did it" display is a
-- deferred TODO (spawned as a task). The rest of the DERM app activity trail
-- already lives in audit.logs (get_record_history / app_source + jwt_claims).
-- ============================================================================

ALTER TABLE public.derm_email_sends
  ADD COLUMN IF NOT EXISTS sent_by_email   text,
  ADD COLUMN IF NOT EXISTS sent_by_user_id text;

COMMENT ON COLUMN public.derm_email_sends.sent_by_email IS
  'Point-in-time email of the signed-in user who triggered the send (from the app-forwarded JWT; null for anon/service callers).';
COMMENT ON COLUMN public.derm_email_sends.sent_by_user_id IS
  'auth.users id (JWT sub) of the user who triggered the send; null when the caller was anon/service_role.';

-- ============================================================================
-- VERIFICATION + STATE (2026-07-21)
-- ============================================================================
-- - Columns live: derm_email_sends.sent_by_email (text, null), sent_by_user_id
--   (text, null). Confirmed via information_schema.
-- - send-derm-email redeployed: decodes the caller's Authorization JWT
--   (verify_jwt=true on this fn, so the gateway VERIFIES the token first, then
--   passes it through) and records email/sub for role='authenticated'; null
--   for anon/service. The decode is fully try/catch-guarded and the columns
--   are nullable, so the change cannot break a send (worst case = null actor,
--   same as before).
-- - CONFIRMING TEST: the next real "Send DERM to city/clients" from the DERM
--   Tracker will populate sent_by_email with the acting account (today that is
--   the shared contact@unclogme.com login). Could not simulate a live user
--   token here (the app uses the new-style signing keys + a real session), so
--   this is confirmed on the next genuine app send rather than a synthetic one.
-- - The rest of the DERM app activity trail already lives in audit.logs
--   (derm-tracker rows carry jwt_claims.email + sub; 71/71 over 7 days).
-- - Frontend "who did it" view = deferred TODO (spawned task 2026-07-21).
-- - Open follow-up: staff share the contact@unclogme.com login, so per-person
--   attribution needs individual @unclogme.com accounts (Fred's call).
