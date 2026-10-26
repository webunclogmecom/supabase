# Supabase Auth settings: changes on record

Prod `wbasvhvvismukaqdnouk`, Management API `GET/PATCH /v1/projects/{ref}/config/auth` (the PAT). One row per deliberate change,
newest first. The Auth settings are not in any migration and have no audit trail of their own, so this file is the record.

**How a change is made (the Send invite plan, phase 4, is the template):**
1. Read every setting and save the copy to the workspace `backups/` folder (never committed: two secrets come back as
   look-alike digests, so the copy is never sent back whole).
2. Write the undo body: only the keys you change, with their old values.
3. PATCH only those keys. Then read every setting again and compare: only the named keys may differ.
4. Check Auth health (`/v1/projects/{ref}/health?services=auth`), and whatever the change touches.

## 2026-10-26 · Self sign-up off, D16 (Send invite phase 7)

Fred: "Now, this afternoon" (the phase 7 test). Applied 14:21 ET, one key.

| key | before | after |
|---|---|---|
| `disable_signup` | `false` | `true` |

- Effect: nobody can create a sign-in on their own any more, by email form or by a first Google sign-in. A sign-in is
  created only by an HR App invite (or the admin API). Existing sign-ins, Google included, are unaffected.
- 🛑 **Never undo it while `app_config.hr_invites_on` is `true`** (plan D16). The before-user-created hook
  (`public.fn_restrict_signup_domains`) stays as the second lock.
- Checked: control sign-up with a `probe-...@example.com` address before the change answered the hook's 403; after it,
  422 `signup_disabled` (about 30 s after the PATCH, while Auth restarted); 8 sign-ins before and after; 243 settings
  compared, only `disable_signup` differs, the 42 secret-like keys identical; Auth health 200 v2.197.0; one reset email to
  fred@ayache.com arrived 6 s after sending. Measured the same afternoon: a first Google sign-in as the (not yet invited)
  test mailbox was refused with `422: Signups not allowed for this instance` and created no user.
- Undo (one key): `backups/2026-10-26_auth_d16_UNDO_body.json`; copies `backups/2026-10-26_auth_config_{before,after}_d16.json`.

## 2026-10-26 · ⚠ Measured: a custom template can silently fall back to Supabase's default

The phase 7 invite (14:42 ET) went out with Supabase's built-in email ("You've been invited", "Accept invitation"), not
the template below. Auth log: `templatemailer: template type "invite": http: GET
https://api.supabase.com/platform/auth/<ref>/templates/invite: status code 502` (event
`templatemailer_template_body_http_error`). Auth fetches each custom template from the Supabase platform at send time and,
when that fetch fails, sends its default instead, with no error to the caller (the invite answered 200 and the link was
right). The same address served the template correctly right after (30 of 30 fetches 200), and both reset emails that day
rendered fine, so it was a passing platform failure, not the template. **A settings read-back cannot catch this; only
the Auth log or the received email can.**

## 2026-10-26 · The invite email (Send invite phase 4)

Fred: "Go ahead with phase 4" (plan `Building Apps/HR App/docs/specs/2026-10-26-send-invite-implementation-plan.md`, decision 3:
subject "Set Up Your UnclogMe Account", the drafted text, 1 hour as today). Applied about 13:18 ET.

| key | before | after |
|---|---|---|
| `mailer_subjects_invite` | `You have been invited` | `Set Up Your UnclogMe Account` |
| `mailer_templates_invite_content` | Supabase's default (197 characters, "You have been invited to create a user on {{ .SiteURL }}") | [`auth-email-templates/invite.html`](auth-email-templates/invite.html) |

- The new template is the branded reset email ([`auth-email-templates/recovery.html`](auth-email-templates/recovery.html), unchanged)
  with six lines swapped: title, preview text, heading "Welcome to UnclogMe", body naming hub.unclogme.app, button "Choose your
  password", expiry line ("If it has expired, ask an admin to send a new invite."). The link variable `{{ .ConfirmationURL }}` is
  used three times; `{{ .SiteURL }}` is not used (the Site URL is the Calendar). No dashes.
- 🛑 **Not changed: the link lifetime, `mailer_otp_exp` = 3600 (1 hour).** It is one setting shared by invite and reset links,
  and both emails say "1 hour". Change it and both texts become false.
- Who sends an invite: only the edge function `hr-sign-in` (`inviteUserByEmail`, return page
  `https://hub.unclogme.app/reset-password/invite`), and only while `public.app_config` `hr_invites_on` is `true` (missing today).
- Checked: 243 settings before and after, only these two differ (SMTP and Google secret digests identical); Auth health 200,
  GoTrue v2.197.0; a fake invite link with `redirect_to` the invite page answers 303 to exactly
  `hub.unclogme.app/reset-password/invite#error=...otp_expired`, and a host not on the allow-list falls back to the Calendar
  (control); one password-reset email to fred@ayache.com from the Hub arrived 8 s later, unchanged. Draft rendered at 600 and
  375 px before the change.
- Undo (two keys): `backups/2026-10-26_auth_invite_template_UNDO_body.json`; before and after copies:
  `backups/2026-10-26_auth_config_{before,after}_invite_template.json`.

## 2026-10-19 · Emails per hour 2 to 30 (record added 2026-10-26)

`rate_limit_email_sent` 2 to 30 (Fred, 2026-10-19), so that the HR App's "Send password reset" (and now Send invite) does not run
out after two emails an hour. Read back 2026-10-26: 30. The before copy of that change was not kept.
