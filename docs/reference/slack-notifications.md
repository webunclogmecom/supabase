# Slack notifications: the format, and how to build a new one

Read this before adding or changing any message an app posts to Slack. The bot itself (which Slack app it is, its
token, how it shows each app's name, and how to set it up) is in
[slack-unclogme-apps-bot.md](slack-unclogme-apps-bot.md).

Fred, 2026-10-05:
- *"we need to have a format for the notifications for each notification it sends, like example, the one for the
  Dump Visits, today is a good one, but it needs a header to know it's for dumping"*;
- *"document on how to structure and create this kind of messages then for later on if we need to make more kind of
  notifications for different things"*;
- from three rendered mockups of the real Sep 23 dump, he picked **Option A: a bold header line on every message**.

Every notification in this file is a one-way message from an app (nobody replies to the bot). A bot that reads
messages or answers people (the GDO bot) is its own Slack app and is not covered here.

## 1. The shape of every message

A notification is a Slack `chat.postMessage` with `blocks` (what people see) and `text` (the one-line version
Slack uses for phone notifications, search and the sidebar). Blocks, in this order:

| # | block | required | what goes in it |
|---|---|---|---|
| 1 | **header** | always | One emoji, then what the message is about, in plain words. A follow-up adds ` · ` and its step. Built with `slackHeader(...)`. |
| 2 | context (follow-ups only) | for a thread reply | `↳ Update to *<parent title>* · <who> · <when ET>`: one small line naming the message it follows. |
| 3 | main line (section) | always | The same emoji, the bold subject (linked to the record people act on), a colon, what happened. `[TEST] ` goes here. |
| 4 | details (section) | when there are any | `*Label:* value`, one per line. |
| 5 | extras (section) | when there are any | Optional lines, each starting with its own emoji. |
| 6 | lists (section) | when there are any | `• <client code> <name>` per line. Long lists go through `slackSections(...)`. |
| 7 | links (context) | when there are any | Small labelled links: `🧭 <url|Route Link>`. |

What it looks like (the DUMP "dump created" message; the picture Fred chose is the Option A mockup):

```
🚛 Dumping                                                      <- header (big, bold)
🚛 Dump at Homestead (Miami-Dade): Michael Escobar is dumping   <- main line, title links to Jobber
Time: Wed, Sep 23, 6:34 AM ET                                   <- details
Truck: Moises
Team: Michael Escobar
📋 7 completed DERM pickups to report on this load.             <- extras
🧭 Route Link                                                   <- links (small)
```

and its follow-up, posted as a reply in the thread of that message:

```
📋 Dumping · load reported
↳ Update to Dump at Homestead (Miami-Dade) · Michael Escobar · Wed, Sep 23, 6:34 AM ET
📋 Reported on this load (9):
• 034-LG La Granja Calle 8
• ...
```

### The header

- **Says what the message is about, so it can be read without reading the message.** Since the old #dump-visits
  became #apps-notifications (2026-10-05) several apps and people share one channel, and until the bot holds
  `chat:write.customize` every bot post shows the same name.
- One emoji, then a short subject in sentence case: `🚛 Dumping`, `📝 Stamp Studio sheets`. A follow-up keeps the
  subject and adds its step after ` · `: `📋 Dumping · load reported`.
- The header's emoji is the same as the main line's emoji, so the two read as one message.
- No app name when the post already carries it (the bot shows the app's name once it can, see the bot doc); say what
  the message is ABOUT. Exception: when the subject IS the app's own thing (`Stamp Studio sheets`).
- Plain text only (Slack allows no bold or links in a header), at most 150 characters. `slackHeader` cuts longer
  text.
- No `[TEST]` in the header: the marker stays on the main line, where it has always been.

### The `text` (fallback)

Required on every post. One line, the main line's words without formatting:
`🚛 Dump at Homestead (Miami-Dade): Michael Escobar is dumping`. It is what a phone notification shows, so it must
make sense alone. Carry `[TEST] ` in it too.

## 2. Writing rules

Each of these was set by Fred or learned the hard way; the source is in brackets.

1. **Plain operator language.** No technical words, ids, error codes or raw errors. Keep the trade words people use:
   Jobber, DERM, GDO, manifest, truck names, client codes. Rewording must never make a message disappear.
   [memory feedback_messages_must_be_semantic_and_never_vanish, 2026-09-07]
2. **No em dashes, ever, including in Slack.** Use a colon, `·`, a comma or a new sentence. The DUMP messages had
   six and lost them on 2026-10-05. [memory feedback_no_em_dash]
3. **Times are Eastern** and say so: `Wed, Sep 23, 6:34 AM ET` (`Intl.DateTimeFormat("en-US", { timeZone:
   "America/New_York", weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })` + ` ET`).
   Dates alone: `Sep 23`.
4. **Never leave a field silently missing.** A missing value reads as a broken message; say what is known:
   `*Truck:* not identified`, `*Time:* not recorded`. [DUMP truck rule, 2026-07-27]
5. **Never state what you could not find out.** If a count could not be read, leave its line out; never print 0.
   [DUMP load count, 2026-07-24]
6. **An empty result is said out loud**, not left blank: `🫙 *No completed DERM pickups to report on this load.*`.
   [DUMP, 2026-07-24]
7. **Links**: Slack's form `<url|label>`. The subject links to the record people act on (the dump links to the dump
   client in Jobber, where the office attaches the manifest); a secondary link gets its own labelled line
   (`🧭 Route Link`). Every post sets `unfurl_links: false, unfurl_media: false`, so Slack does not add preview boxes.
   [DUMP, 2026-07-24]
8. **Lists**: `• <client code> <client name>`, one per line, and nothing else on the line unless asked (no address,
   no GDO number in the DUMP lists).
9. **Text that comes from people or records** (names, notes) may contain `&`, `<` or `>`, which Slack treats as
   formatting. In new code, replace them with `&amp;`, `&lt;`, `&gt;` before putting them in a message.
10. **No @-mentions in a test post**: it pings real people. [memory feedback_viktor_no_tags_when_testing]
11. **Emoji**: one per line kind, used consistently (the DUMP set: 🚛 dump, 📋 load, 📝 added, 🗑 removed, ⚠️ missing or
    unconfirmed, 📞 called ahead, 🫙 empty, 🧭 route).

## 3. Threads

- The first message about something (a dump) is posted to the channel. Save its `ts` (the DUMP app stores it as a
  `public.dump_activity` row, `action='slack_parent'`).
- Later messages about the same thing (load reported, added, removed) are **replies in its thread**
  (`thread_ts`), with the `↳ Update to ...` line and never a repeat of the first message's details.
- **No `reply_broadcast`** (the "Also sent to the channel" copy). Fred: *"can we change it so the updates only gets
  send as a thread message and not on the channel also?"* (2026-08-04). A new message may opt in only when asked.
- **Never guess the parent.** If there is no single message it honestly belongs to, post it to the channel on its own
  (the DUMP removal from VIEW ADDRESSES does this).

## 4. Test messages

- A test is marked `[TEST] ` at the start of the main line and of `text`, decided by data the app itself set (the
  DUMP app writes `[TEST]` into the dump visit's notes in its Testing screen; the Stamp reminder takes `{"test": true}`).
  A caller must never be able to mark a real event as a test.
- Use the app's own test path. A test post goes to the real channel, so ask before sending one.

## 5. Sending: rules that keep a message from being lost or doubled

- **A Slack failure never fails what the person was doing.** Wrap the post, log the error, carry on.
- **Only a clear refusal may be retried another way.** If Slack answers `ok:false`, a fallback (the DUMP webhook) may
  try. If the answer cannot be read, or the connection dropped, do NOT retry: Slack may already have posted it, and a
  retry posts it twice.
- **Slack's limits**: a header is plain text up to 150 characters; a section's text up to 3,000 characters; up to 50
  blocks per message. `slackSections` splits text on line breaks to stay under 3,000 (a 41-line Stamp reminder is
  4,872 characters, which Slack refuses in one section).
- The bot posts only in channels it is a member of: `/invite @UnclogMe Apps` (the name after the rename).

## 6. Building a new notification

1. **Decide the event and the channel.** One-way app notifications go to `#apps-notifications` (`C0BJYHQKZM1`)
   unless Fred names another.
2. **Write the message in this file's shape**, with real data, and show Fred a rendered mockup before building
   (his rule for anything visual). The Option A mockups of 2026-10-05 were plain HTML styled like Slack, built on the
   real messages read from the channel.
3. **Code it** in the edge function that sees the event, using the shared helpers in
   `supabase/functions/_shared/slack-notify.ts`:

   ```ts
   import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";

   const token = Deno.env.get("SLACK_BOT_TOKEN");
   if (token) {
     try {
       const as = await slackIdentity(token, "<App name>", "<icon key>");   // e.g. "DUMP Schedule", "dump-schedule"
       const res = await fetch("https://slack.com/api/chat.postMessage", {
         method: "POST",
         headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
         body: JSON.stringify({
           channel: "C0BJYHQKZM1",
           text: `${tag}<one line that makes sense alone>`,                    // tag = "[TEST] " or ""
           blocks: [
             slackHeader("<emoji> <what it is about>"),
             ...slackSections(`<emoji> ${tag}*<subject>*: <what happened>\n*Label:* value`),
           ],
           unfurl_links: false, unfurl_media: false,
           ...as,
         }),
       });
       const j = await res.json().catch(() => null);
       if (!j?.ok) console.error(`slack: ${j?.error ?? "unreadable answer"}`);  // log, never fail the action
     } catch (e) { console.error("slack:", e instanceof Error ? e.message : String(e)); }
   }
   ```

   The icon key is the app's folder under `manifests/_brand/favicons/` (every staff app has one).
4. **Write a check** that runs the real function against stubs and asserts the message: header first, sections
   rebuild the `text`, limits respected, nothing posted on a dry run. Model:
   `scripts/checks/stamp_sheets_reminder.mjs` (it inlines the real `slack-notify.ts`). Mutation-test it.
5. **Have Slack validate the message without posting it.** `chat.scheduleMessage` validates blocks; schedule each
   payload 90 days ahead, delete it at once with `chat.deleteScheduledMessage`, then read
   `chat.scheduledMessages.list` to prove nothing is left. Include a deliberately broken payload as a control (a
   header with `mrkdwn`, a 3,001-character section): Slack must refuse it with `invalid_blocks`, or the check proved
   nothing. On 2026-10-05 this ran from a temporary edge function (it needs `SLACK_BOT_TOKEN`, which only edge
   functions hold) that was deleted afterwards: the four DUMP messages and the Stamp reminder (1 and 45 sheets) were
   accepted, both controls refused, 0 left scheduled.
6. **Deploy**, read the deployed body back (`scripts/probes/edge_deployed_body.js`), and post one `[TEST]` only if
   Fred agrees.
7. **Document**: add the message to the catalogue below and to the app's `docs/08-changelog.md`.

## 7. Catalogue

### On this format

| app (edge function) | when | header | main line | thread | test |
|---|---|---|---|---|---|
| DUMP Schedule (`dump-visit-create`) | driver taps GO | `🚛 Dumping` | `🚛 *Dump at <site> (<county>)*: <driver> is dumping` + Time / Truck / Team, called ahead, load count, Route Link | first message; `ts` saved | `[TEST]` from the dump visit's notes |
| DUMP Schedule | driver confirms the load | `📋 Dumping · load reported` | `📋 *Reported on this load (N):*` + list, then `⚠️ *Missing, scheduled today but not added (N):*` + list | reply | same |
| DUMP Schedule | driver adds older visits to a dump | `📝 Dumping · added to the manifest` | `📝 *<driver> added N to the manifest*` + list | reply under the chosen dump | same |
| DUMP Schedule | driver removes visits from the manifest | `🗑 Dumping · removed from the manifest` | `🗑 *<driver> removed N from the manifest*` + list | reply when it belongs to one dump, else on its own | from the app's test flag |
| DERM Stamp Studio (`stamp-sheets-reminder`) | 10 AM ET daily, only when a sheet is not completed | `📝 Stamp Studio sheets` | `📝 *Stamp Studio: N sheets are not completed*` + one line per sheet | on its own | `{"test": true}` |

The DUMP messages' own rules (truck resolution, called ahead, which visits count, the removal threading rule) are in
`Building Apps/DUMP Schedule/CLAUDE.md`. The Stamp reminder's are in the Supabase `CLAUDE.md` Draw-the-bands section.

### Not on this format yet (a different bot, `Supabase - Notifications`, posting to #viktor-supabase)

Four GitHub Actions jobs in this repo post with their own bot token (GitHub secret `SLACK_BOT_TOKEN`, a different
Slack app): `scripts/alerts/audit_critical_poll.js` (Prod audit alert), `scripts/sync/daily_no_photo_visits_alert.js`
(photo audit), `scripts/sync/weekly_dedup_audit.js`, `scripts/probes/audit_client_code_drift.js`. They are plain text
with no header and some carry em dashes. Moving them to the shared bot and this format is Fred's call (open as of
2026-10-05).
