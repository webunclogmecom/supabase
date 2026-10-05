# The "UnclogMe Apps" Slack bot (app notifications)

Fred, 2026-10-05, after the first Stamp Studio reminder: *"we might need another bot, because you're using the dump
visit bot"*. Until then the daily reminder posted with the DUMP alerts' token (`SLACK_BOT_TOKEN`, Slack user
`dump_visits`), so it appeared as "Dump Visits" in #apps-notifications.

## How the reminder picks its bot

Edge fn `stamp-sheets-reminder` (v3) uses the FIRST of these secrets that is set:

| secret | bot |
|---|---|
| `APPS_SLACK_BOT_TOKEN` | the app notifications bot made with the manifest below |
| `SLACK_BOT_TOKEN` | the shared "Dump Visits" bot (DUMP alerts, `dump-visit-create`) |

Every reply names the secret it used (`bot_secret`). `{"check_bot": true}` asks Slack who the bot is
(`auth.test`) and posts nothing:

```bash
curl -s -X POST -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H "Content-Type: application/json" -d '{"check_bot":true}' https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/stamp-sheets-reminder
```

`dump-visit-create` keeps `SLACK_BOT_TOKEN`; nothing about the DUMP alerts changes.

## Creating the bot (a person does this: it installs an app and handles a token)

1. https://api.slack.com/apps : **Create New App**, **From a manifest**, pick the Unclogme workspace, paste the JSON
   below, **Create**.
2. **Install to Workspace**, then **Allow**.
3. **OAuth & Permissions**: copy the **Bot User OAuth Token** (starts `xoxb-`).
4. Supabase dashboard, project `wbasvhvvismukaqdnouk`, **Edge Functions**, **Secrets**: add
   `APPS_SLACK_BOT_TOKEN` with that token. No redeploy is needed: the next run reads it.
5. In #apps-notifications: `/invite @UnclogMe Apps` (the bot has only `chat:write`, so it must be a member).
6. Optional, for the icon: **Basic Information**, **App icon**, upload
   https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/favicons/apps-hub/icon-512.png
   (the orange UnclogMe mark, 512 px).
7. Check: run the `check_bot` call above (expect `"bot_secret":"APPS_SLACK_BOT_TOKEN"`), then a `{"test":true}` post.

```json
{
  "display_information": {
    "name": "UnclogMe Apps",
    "description": "Notifications from the UnclogMe staff apps",
    "background_color": "#f14714"
  },
  "features": {
    "bot_user": { "display_name": "UnclogMe Apps", "always_online": false }
  },
  "oauth_config": {
    "scopes": { "bot": ["chat:write"] }
  },
  "settings": {
    "org_deploy_enabled": false,
    "socket_mode_enabled": false,
    "token_rotation_enabled": false
  }
}
```

Only `chat:write`: the bot posts and does nothing else. Any later app notification for #apps-notifications should use
`APPS_SLACK_BOT_TOKEN` the same way.
