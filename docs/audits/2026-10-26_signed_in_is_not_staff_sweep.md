# Signed in is not staff: sweep of the edge functions (2026-10-26)

Send invite, phase 1 (Trello HhuFXLlt, plan `Building Apps/HR App/docs/specs/2026-10-26-send-invite-implementation-plan.md`).
Until Send invite, every sign-in was staff: sign-up is limited to unclogme.com and ayache.com
(`public.fn_restrict_signup_domains`) and all 8 accounts were admin or office. An invited driver gets a real
`@unclogme.com` sign-in and may have View in no app. **A domain check alone is therefore not an access check any more.**

Question asked of every function in `supabase/functions/*/index.ts` that reads a bearer token (`auth.getUser(`, a
`bearerRole()` decode, `isSecretKeyCaller`) or has no caller check at all: what does it give a plain signed-in caller
with no access? Read from the code and `supabase/config.toml` on 2026-10-26 (working tree = deployed for the files
named here, not re-read from the live bodies).

## Result

| Class | Functions | What a no-access signed-in caller gets |
|---|---|---|
| **Needed an access check, fixed now** | `get-derm-doc` (kinds `address`, `fog`) | Before: signed URLs for raw DERM Address sheets (every co-client on a dump ticket) and per-client FOG PDFs, for any manifest whose client code it knows. Now: `checkAppAction(token, 'view_derm_doc')` (DERM Tracker View) after `getUser`; service key still by exact match. Migration `2026-10-26_1030` adds the action. |
| Calls `checkAppAction` (the database decides, as the caller) | adopt-visit-from-jobber, archive-client, calculate-driving-time, create-client, derm-visit-report, generate-derm-address-pdf, generate-derm-address-preview, parse-gdo-permit, push-visit-to-jobber, record-manual-gdo-report, rotate-photo, save-calendar-task, save-calendar-visit, save-client-contact, save-client-fields, save-client-job, save-client-property, save-day-marker, send-derm-email, send-visit-photos-email, unarchive-client, visit-client-note-photos | 403. `hr.check_app_action` now refuses a caller with View/Edit in no app in every mode (before: an app in `watch` or `off` let them through). The call goes through PostgREST, so the read gate refuses them first anyway. |
| Service key only (`bearerRole() === 'service_role'` behind `verify_jwt = true`, or `isSecretKeyCaller`) | admin-review-reminder, call-first-reminder, gdo-permit-label, generate-fog-manifest, heal-day-starts, health-escalate, intake-size-lookup, intake-task-sync, jobber-push-custom-field, jobber-push-task, jobber-push-visit, measure-generated-page, measure-page-reference, ocr-address-sheet-number, ocr-address-sheet-rows, plan-drive-fill, poll-calendar-tasks, redact-manifest-sheet, stamp-sheets-reminder, sync-jobber-billing-observe, sync-jobber-client-state-sweep, sync-jobber-invoice-drift, sync-jobber-job-drift, sync-jobber-poll, sync-jobber-timesheets, sync-jobber-upcoming-visits, sync-jobber-visit-drift, time-on-site-reminder, time-on-site-samsara-recheck, unopened-email-reminder | 403. A user token carries `role: authenticated`. Safe only because the gateway verifies the signature (`verify_jwt = true`, checked in config.toml for each). |
| Signed or keyed, not a user path | webhook-jobber, webhook-samsara (HMAC), webhook-resend (Svix), rpa-derm-queue, rpa-derm-result, rpa-derm-evidence, rpa-derm-monthly, rpa-derm-monthly-filed (`x-rpa-key`), fillout-inspection (`x-fillout-key`), viktor-visit-update (`x-viktor-key`), webhook-airtable (retired) | 401. A sign-in is worth nothing there. |
| Database decides as the caller (no `checkAppAction`, same effect) | hr-sign-in | `hr.request_sign_in_action` as the caller: admin only. 403 with the database's sentence. |
| Public by design (capability in the link, no sign-in involved) | driver-page, intake-submit, dump-visit-create, get-permit-doc, `get-derm-doc` kinds `manifest` / `gdo_report` | The same as anyone without a sign-in: what the link or client code already opens (the Field Portal model). Unchanged; an invite adds nothing here. |

## Follow-ups (not changed now)

1. **`inbound-file-drain`** has `verify_jwt = true` and no caller check in the code, so any valid JWT (the publishable
   key included, not only a sign-in) can trigger a drain run. It returns counts only and the drain is lease-safe, so an
   invite changes nothing about it. Worth a service-key-only check of its own (pg_cron is its only intended caller).
2. **Database helpers behind the read gate.** `hr.fn_check_app`, `hr.fn_require_app`, `hr.fn_app_open` and
   `hr.fn_check_any_app` (used by `client.cancel_intake`) still let any caller through while their app is not `on`.
   They are reached only through PostgREST, where `public.fn_request_gate` now refuses a no-access caller whatever the
   modes, so they are closed while the gate is on. Turning the gate off (G3) reopens them: the undo sheet
   (`docs/runbooks/access-undo.md`) now says to ban the no-access sign-ins first.
3. The functions that call `checkAppAction` also have branches for the service key (cron and sweeps). Those were not
   re-read here; they do not involve a user token.

## Rule for a new function

A new edge function that accepts a user token must call `checkAppAction(token, '<action>')` (add the action to
`hr.check_app_action`'s map in a migration) before it returns data or writes, or be service-key-only. "The token is a
real user" and "the email is @unclogme.com" are not access checks.
