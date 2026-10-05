// slack-notify.ts: the building blocks EVERY app notification uses on the ONE shared Slack bot.
// The rules (header, wording, threading, test marking) are in docs/reference/slack-notifications.md; read it
// before adding a notification.
//
// * slackHeader(text): the header every message starts with, so a reader knows what it is about before reading
//   it (Fred, 2026-10-05: "it needs a header to know it's for dumping", Option A of the mockups: a bold header line).
// * slackSections(text): mrkdwn text as section blocks, split on line breaks under Slack's 3,000-character limit.
// * slackIdentity(token, name, iconKey): the app's own name and icon on the post (Fred, 2026-10-05: one bot for
//   every app notification, each message labelled with its app). Slack applies chat.postMessage's username /
//   icon_url only when the app holds the chat:write.customize scope, and its docs do not say what a post asking
//   for them without it does. So the bot's scopes are read first (auth.test, header x-oauth-scopes, once per
//   worker) and the identity is sent only when that scope is granted; without it a post is exactly what it was.

const ICON_BASE = "https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/favicons";
const CUSTOMIZE = "chat:write.customize";
const HEADER_MAX = 150;    // Slack header block: plain text, 150 characters at most
const SECTION_MAX = 3000;  // Slack section block text: 3,000 characters at most
const scopesByToken = new Map<string, Promise<string[]>>();

/** The header block a notification starts with: one emoji, then what the message is about. */
export function slackHeader(text: string) {
  return { type: "header", text: { type: "plain_text", text: text.slice(0, HEADER_MAX), emoji: true } };
}

/** mrkdwn text as section blocks, split on line breaks so no section passes Slack's limit. */
export function slackSections(text: string) {
  const blocks: unknown[] = [];
  let cur = "";
  for (const line of text.split("\n")) {
    const piece = line.length > SECTION_MAX ? line.slice(0, SECTION_MAX - 1) + "…" : line;
    if (cur && cur.length + 1 + piece.length > SECTION_MAX) { blocks.push({ type: "section", text: { type: "mrkdwn", text: cur } }); cur = ""; }
    cur = cur ? `${cur}\n${piece}` : piece;
  }
  if (cur) blocks.push({ type: "section", text: { type: "mrkdwn", text: cur } });
  return blocks;
}

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
