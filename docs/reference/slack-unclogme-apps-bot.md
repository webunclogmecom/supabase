# The shared Slack notification bot ("UnclogMe Apps", formerly "Dump Visits")

Fred, 2026-10-05: *"we might need another bot, because you're using the dump visit bot"*, then, on the choice
between one bot and one per app: one bot for every app notification, each message labelled with its app, and
*"let's remake the Dump Notification Bot then that we have"*. So there is ONE Slack app for one-way app
notifications: the existing "Dump Visits" app, renamed "UnclogMe Apps". Each app's posts show the APP's own name
and icon. A bot that does more than post (reads messages, answers people, has buttons or slash commands) stays its
own Slack app: the GDO bot (`Slack/GDO Bot`) is one.

## What uses it

| app | edge function | channel | shown as | icon key |
|---|---|---|---|---|
| DUMP Schedule | `dump-visit-create` | #dump-visits (private, secret `SLACK_DUMP_CHANNEL_ID`) | DUMP Schedule | `dump-schedule` |
| DERM Stamp Studio | `stamp-sheets-reminder` | #apps-notifications (`C0BJYHQKZM1`) | Stamp Studio | `stamp-studio` |

Token: Supabase secret `SLACK_BOT_TOKEN` (Slack bot user `dump_visits` until the app is renamed). Scopes measured
2026-10-05: `chat:write`, `incoming-webhook` (the webhook is `SLACK_DUMP_WEBHOOK_URL`, the DUMP alerts' fallback
when Slack refuses a chat.postMessage; a webhook cannot thread and ignores the custom name).

## How a post gets its app's name and icon

`supabase/functions/_shared/slack-identity.ts`: `slackIdentity(token, "<App name>", "<icon key>")` returns
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

## Remaking the "Dump Visits" app (a person does this in Slack: it changes an installed app)

1. https://api.slack.com/apps, open **Dump Visits**.
2. **Basic Information**, **Display Information**: App name `UnclogMe Apps`, Short description
   `Notifications from the UnclogMe staff apps`, Background color `#f14714`, App icon: upload
   https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/favicons/apps-hub/icon-512.png
   (the UnclogMe mark). **Save Changes**.
3. **App Home**, **Your App's Presence in Slack**, **Edit**: Display Name `UnclogMe Apps`, Default username
   `unclogme_apps`. Save.
4. **OAuth & Permissions**, **Scopes**, **Bot Token Scopes**, **Add an OAuth Scope**: `chat:write.customize`.
5. Slack then shows a banner asking to reinstall: **Reinstall to Workspace**, **Allow**. Because the app has an
   incoming webhook, Slack may ask for a channel: pick **#dump-visits** (the existing webhook keeps working).
6. Run the check above. Expect `posts_as_app: true`. If it says `invalid_auth` or `token_revoked`, the reinstall
   issued a new token: copy **Bot User OAuth Token** (OAuth & Permissions) into the Supabase secret
   `SLACK_BOT_TOKEN` (dashboard, Edge Functions, Secrets). No redeploy is needed.
7. A `{"test":true}` post of the reminder shows as "Stamp Studio"; the next DUMP alert shows as "DUMP Schedule".

## Adding a new app's notifications

Use `SLACK_BOT_TOKEN`, `chat.postMessage`, and spread `await slackIdentity(token, "<App name>", "<icon key>")` into
the body. Invite the bot to the channel (`/invite @UnclogMe Apps`). Do not create a new Slack app for a one-way
notification.
