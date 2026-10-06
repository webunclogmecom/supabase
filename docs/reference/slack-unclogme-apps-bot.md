# The shared Slack notification bot ("UnclogMe Apps", formerly the "Dump Notification" app)

The FORMAT of every message (the header, the shape, the writing rules) and how to build a new notification:
[slack-notifications.md](slack-notifications.md). This file is about the bot.

Fred, 2026-10-05: *"we might need another bot, because you're using the dump visit bot"*, then, on the choice
between one bot and one per app: one bot for every app notification, each message labelled with its app, and
*"let's remake the Dump Notification Bot then that we have"*. So there is ONE Slack app for one-way app
notifications: the existing Slack app "Dump Notification" (`A0BK2UBD1ML`, bot user "Dump Visits",
`U0BJYLYS011`), renamed "UnclogMe Apps". Each app's posts show the APP's own name
and icon. A bot that does more than post (reads messages, answers people, has buttons or slash commands) stays its
own Slack app: the GDO bot (`Slack/GDO Bot`) is one.

## What uses it

| app | edge function | channel | shown as | icon key |
|---|---|---|---|---|
| DUMP Schedule | `dump-visit-create` | `C0BJYHQKZM1` (secret `SLACK_DUMP_CHANNEL_ID`) | DUMP Schedule | `dump-schedule` |
| DERM Stamp Studio | `stamp-sheets-reminder` | `C0BJYHQKZM1` | Stamp Studio | `stamp-studio` |

Both post to the SAME private channel: `C0BJYHQKZM1` was #dump-visits and is now #apps-notifications (all 17
stored DUMP thread parents in `dump_activity` carry that id, measured 2026-10-05). The app name on each post is
what tells the two apart.

Token: Supabase secret `SLACK_BOT_TOKEN`. Scopes since 2026-10-05 22:00 ET: `chat:write`, `chat:write.customize`,
`incoming-webhook` (the webhook is `SLACK_DUMP_WEBHOOK_URL`, the DUMP alerts' fallback when Slack refuses a
chat.postMessage; a webhook cannot thread and ignores the custom name). `auth.test` (and so `check_bot`) still
reports the bot user's handle as `dump_visits`: the display name and default username changed, the user id did not.

## How a post gets its app's name and icon

`supabase/functions/_shared/slack-notify.ts`: `slackIdentity(token, "<App name>", "<icon key>")` returns
`{username, icon_url}` to spread into the chat.postMessage body, or `{}`. Slack applies those two fields only when
the app holds `chat:write.customize`, and its docs do not say what a post asking for them without it does, so the
helper reads the bot's scopes first (`auth.test`, response header `x-oauth-scopes`, once per worker) and sends the
identity only when that scope is granted. Without it, a post is exactly what it was before. The icons are the app
icons already published at `.../storage/v1/object/public/manifests/_brand/favicons/<icon key>/icon-512.png`.

Check, posts nothing:

```bash
curl -s -X POST -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "Content-Type: application/json" -d '{"check_bot":true}' https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/stamp-sheets-reminder
```

It answers `{ok, bot, team, scopes, posts_as_app}`. `posts_as_app: true` means every app's posts now carry their
own name. Test: `node scripts/checks/stamp_sheets_reminder.mjs` (runs the real helper; swapping the scope gate for
`true` fails it).

## Remaking the "Dump Notification" app (a person does this in Slack: it changes an installed app)

✅ **DONE 2026-10-05, about 22:00 ET** (Fred: "go ahead with all"), in Fred's signed-in Chrome, steps 1 to 6 below:
app name `UnclogMe Apps`, short description, background `#f14714`, the UnclogMe mark as the icon; bot display name
`UnclogMe Apps`, default username `unclogme_apps`; scope `chat:write.customize` added; reinstalled with
#apps-notifications as the webhook channel. **The bot token did not change** (a SHA-256 fingerprint of the token was
taken before and after the reinstall and matched), so `SLACK_BOT_TOKEN` needed no update. `check_bot` afterwards:
`scopes: incoming-webhook, chat:write, chat:write.customize`, `posts_as_app: true`. Step 7 could not run: every
sheet was completed, so the reminder's test mode posts nothing; the first real DUMP or Stamp post is the visual proof.
⚠ Two traps met on the way: typing into the **Background color** box opens a picker that froze the tab for every
tool (set the value with form input, never by clicking the box), and the browser **autofilled an email into the
Default username box** of the App Home dialog: read the field before saving.

1. https://api.slack.com/apps, open **Dump Notification**.
2. **Basic Information**, **Display Information**: App name `UnclogMe Apps`, Short description
   `Notifications from the UnclogMe staff apps`, Background color `#f14714`, App icon: upload
   https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/favicons/apps-hub/icon-512.png
   (the UnclogMe mark). **Save Changes**.
3. **App Home**, **Your App's Presence in Slack**, **Edit**: Display Name `UnclogMe Apps`, Default username
   `unclogme_apps`. Save.
4. **OAuth & Permissions**, **Scopes**, **Bot Token Scopes**, **Add an OAuth Scope**: `chat:write.customize`.
5. Slack then shows a banner asking to reinstall: **Reinstall to Workspace**, **Allow**. Because the app has an
   incoming webhook, Slack may ask for a channel: pick **#apps-notifications** (the existing webhook keeps
   working).
6. Run the check above. Expect `posts_as_app: true`. If it says `invalid_auth` or `token_revoked`, the reinstall
   issued a new token: copy **Bot User OAuth Token** (OAuth & Permissions) into the Supabase secret
   `SLACK_BOT_TOKEN` (dashboard, Edge Functions, Secrets). No redeploy is needed.
7. A `{"test":true}` post of the reminder shows as "Stamp Studio"; the next DUMP alert shows as "DUMP Schedule".

## Adding a new app's notifications

Use `SLACK_BOT_TOKEN`, `chat.postMessage`, and spread `await slackIdentity(token, "<App name>", "<icon key>")` into
the body. Invite the bot to the channel (`/invite @UnclogMe Apps`). Do not create a new Slack app for a one-way
notification.
