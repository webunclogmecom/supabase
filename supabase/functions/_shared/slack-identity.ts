// slack-identity.ts: each app's Slack posts show the APP's own name and icon on the ONE shared notification bot.
//
// Fred, 2026-10-05: one bot for every app notification (the former "Dump Visits" Slack app, renamed "UnclogMe Apps"),
// each message labelled with the app that sent it. Slack applies chat.postMessage's username / icon_url only when
// the app holds the chat:write.customize scope, and its docs do not say what a post asking for them without it does.
// So the bot's scopes are read first (auth.test, header x-oauth-scopes, once per worker) and the identity is sent only
// when that scope is granted; without it a post is exactly what it was before. Setup:
// docs/reference/slack-unclogme-apps-bot.md.

const ICON_BASE = "https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/favicons";
const CUSTOMIZE = "chat:write.customize";
const scopesByToken = new Map<string, Promise<string[]>>();

/** The bot's granted scopes, read from auth.test. A failed read counts as no scopes (posts stay plain). */
export function slackScopes(token: string): Promise<string[]> {
  let p = scopesByToken.get(token);
  if (!p) {
    p = fetch("https://slack.com/api/auth.test", { method: "POST", headers: { Authorization: `Bearer ${token}` } })
      .then((r) => (r.headers.get("x-oauth-scopes") ?? "").split(",").map((s) => s.trim()).filter(Boolean))
      .catch(() => []);
    scopesByToken.set(token, p);
  }
  return p;
}

/** chat.postMessage fields that make the post appear as `name` with the app's icon (icon key = the app's
 *  folder under _brand/favicons, e.g. "stamp-studio"), or {} when the bot may not set them. */
export async function slackIdentity(token: string, name: string, iconKey: string): Promise<Record<string, string>> {
  return (await slackScopes(token)).includes(CUSTOMIZE)
    ? { username: name, icon_url: `${ICON_BASE}/${iconKey}/icon-512.png` }
    : {};
}
