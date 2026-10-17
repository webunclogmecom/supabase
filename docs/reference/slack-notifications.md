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
📋 7 completed DERM pickups since this driver's last dump to report on this load.   <- extras
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
  became #apps-notifications (2026-10-05) several apps and people share one channel. Each post also shows its
  app's name and icon (the bot holds `chat:write.customize` since 2026-10-05), but the header must not rely on it:
  a webhook fallback post shows the bot's own name.
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
10. **No @-mentions in a test post**: it pings real people. [memory feedback_viktor_no_tags_when_testing] The real Stamp Studio and Admin Review posts DO tag Diego and Serena (`<@U0AL9JZ4V7C> <@U0BKM57UPSS>`, Fred, 2026-10-12) on their first body line; the `text` summary line stays tag-free.
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
- **Every scheduled reminder leaves a run record** (since 2026-10-12): one `public.sync_log` row per run, sync_source
  `admin_review_reminder` / `stamp_sheets_reminder` / `time_on_site_reminder` (`<source>_test` for a `[TEST]` run), status `success` (posted, or
  nothing to post) or `error`, with what it listed in `details`. The 11 AM wrappers call the edge function every day
  (`2026-10-12_1310`), so a quiet day and a day the reminder never ran no longer look the same.

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
3b. 🛑 **Read the app's own answer, never rebuild it.** If the message says something an app already decides (a city
   email is done, a sheet is completed, a pickup is reported), the SQL behind it reads that app's canonical view or
   function. It never re-derives the rule. The Admin Review post did, with a narrower "already sent" than the apps, and
   on 2026-10-12 all 5 visits it listed were false (Diego: *"plug in is a unclog ... a la carte, I already sent it o
   october 9"*); on 2026-10-08 the same list made the office re-send two cities' manifests. If no canonical object
   exists, make one first and point the app at it too.
4. **Write a check** that runs the real function against stubs and asserts the message: header first, sections
   rebuild the `text`, limits respected, nothing posted on a dry run. Model:
   `scripts/checks/stamp_sheets_reminder.mjs` (it inlines the real `slack-notify.ts`). Mutation-test it.
   ⚠ A stub check tests the MESSAGE, never the data: it cannot see a query that lists the wrong rows. The daily
   `notification-health` check (`public.log_notification_health`, 9:15 AM ET, `2026-10-12_1400`) compares the Admin
   Review list with the raw send logs and feeds Fred's health email. A new reminder that lists records gets an item
   there too.
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
| DUMP Schedule (`dump-visit-create`) | driver taps GO | `🚛 Dumping` | `🚛 *Dump at <site> (<county>)*: <driver> is dumping` + Time / Truck / Team, called ahead, load lines (below), Route Link | first message; `ts` saved | `[TEST]` from the dump visit's notes |
| DUMP Schedule | driver confirms the load | `📋 Dumping · load reported` | `📋 *Reported on this load (N):*` + list, then `⚠️ *Missing, completed but not added (N):*` + list (or `⚠️ *Missing:* could not be checked.`), then at Homestead `⚠️ *In Broward, file at Pompano (N):*` + list | reply | same |
| DUMP Schedule | driver adds older visits to a dump | `📝 Dumping · added to the manifest` | `📝 *<driver> added N to the manifest*` + list | reply under the chosen dump | same |
| DUMP Schedule | driver removes visits from the manifest, OR presses Undo all on the crib sheet (since 2026-10-07) | `🗑 Dumping · removed from the manifest` | `🗑 *<driver> removed N from the manifest*` + list | reply when it belongs to one dump, else on its own | `[TEST]` from that dump (never from the caller) |
| DERM Stamp Studio (`stamp-sheets-reminder`) | 11 AM ET daily (10 AM until 2026-10-07), only when a sheet is not completed | `📝 Stamp Studio sheets` | `📝 @Diego @Serena *N sheets are not completed*` + one line per sheet, ending since 2026-10-17 with what it waits for in one short sentence (`· page 1: a client on this page is printed on several rows`; from `derm.fn_stamp_sheet_wait_reason`, the Studio's own "Cannot complete yet" answer, first sentence; nothing added when only stamps are missing) (tags since 2026-10-12, never on a test; sheets naming only test or fixture clients are left out since `2026-10-12_1315`); `text` (phone) = `📝 Stamp Studio: N sheets are not completed` | on its own | `{"test": true}` |
| Admin Review (`admin-review-reminder`) | 11 AM ET daily, only when something is waiting | `📸 Photos and city emails` | `🏙 @Diego @Serena *Broward: photos sorted, city email not sent yet (N):*`, one line per visit whose photos are ALL sorted (link to `admin.unclogme.app/review/<visit>` · date · driver), Hallandale Beach and Surfside together under one name; then `🖼 *Photos not sorted: M visits* · K from the last 7 days · oldest <date>` (the tags move to this line when the list is empty), and an `Open Admin Review` link; `text` (phone) = `📸 Admin Review: N visits with photos sorted still need a city email, M visits have photos not sorted` + the full message. Visits with photos not sorted or no photos are not listed (Fred, 2026-10-12: "shorten it"). No tags on a test | on its own | `{"test": true}` |
| Visit Calendar (`time-on-site-reminder`) | 11 AM ET daily, only when yesterday has a client visit with no time on site; since `2026-10-15_2230` it waits (hourly, up to 2 PM ET) while a Samsara feed is not stored up to 10 AM, then posts once (`public.fn_time_on_site_reminder_hold`) | `⏱️ Visits with no time on site` | `⏱️ @Diego *N visits on <day> have no time on site*`, then one line per visit: `• <code> <name linked to its Samsara Place> · <assigned truck linked to its Samsara history, or "no truck assigned">: <reason>` (no map point / <truck> was parked N m from our map point, A to B (M min), when it was marked complete: inside its Samsara place, so our map point is probably off, or outside it too, so both are probably off / <truck> was parked here A to B when it was marked complete, but the time was not saved / either of those ending "the visit is set to <truck>" when another truck was there / no Samsara place / Samsara place X from our address / <truck> was there A to B but it was marked complete C / <truck> only drove past / no truck came within 150 m (closest X)), then `🗂 *K* older visits from the last 30 days still have no time on site.` (left out when 0 or unreadable). Reads `public.fn_time_on_site_gaps` (2026-10-13_0130; since 2026-10-13_1935 each visit carries `stop_at_completion`, the truck stop of 3 min or more within 250 m that holds the completion time, so "only drove past" is said only when there is none; since `time-on-site-reminder` v8 (2026-10-14) the A to B (M min) of that stop is Samsara's own stay, the gap between the truck's two trips that overlaps our stop the most (`/v1/fleet/trips`, so it matches what Samsara shows to the second; our GPS stop is used only when Samsara has no such gap or cannot be read, and the dry run returns it as `gaps[].samsara_stay`); a visit marked `reviewed_blank`, nothing to measure, is left out since 2026-10-13_2320); Place geometry (circle or polygon) from Samsara at run time (a failed read leaves the place reasons out). A dry run also returns `lines` and `gaps`, which `scripts/checks/time_on_site_report.mjs` turns into the Visits Missing Time on Site HTML report, so the report and the post give the same reasons. Tag Diego only (Fred, 2026-10-12), never on a test. Its `text` is the summary line plus every visit as `• visit <number> · <code> <name> · ...` (no links) so Viktor can act on "@Viktor add Moises to <client>" through `viktor-visit-update` (2026-10-13_0300) | on its own | `{"test": true}`; `{"date": "YYYY-MM-DD"}` for a past day |
**Every scheduled reminder posts at 11 AM ET** (Fred, 2026-10-07: "move all notifications to that same time"); the
DUMP messages fire when a driver taps. The Admin Review lists come from `public.fn_admin_review_pending()`. City: the visits whose state is
`needs_city_email` in **`public.v_visit_city_email_state`** (since `2026-10-12_1305`; one row per live visit, the one
answer to "has this visit's city email gone?": a real Admin Review send that carried the manifest, a DERM Tracker "Send
to city" or the automatic sweep all count; not DERM-required, grey water, no inbox, no manifest yet and visits dated
before 2026-09-15 each have their own state), dated 2026-09-15 or later, test clients left out, and the edge function
keeps only those whose photos are all sorted. Photos: the queue's "Photos Not Sorted" (`v_visit_photo_counts`; a photo
saved as `unknown` is not sorted since `2026-10-12_1335`). Fred plans for Viktor to read these posts and act on
them, so keep each line's shape stable. ⚠ Viktor reads only a post's `text`, never its blocks, so the Admin Review
post's `text` is its summary line followed by the WHOLE list (an exception to the one-line `text` rule above; the
phone still shows the first line). Any post Viktor must act on needs the same. (Viktor's own 11:15 reminder to Diego
was retired 2026-10-12: the post tags Diego itself.) Migrations `2026-10-07_1305`, `2026-10-12_1120`, `2026-10-12_1305`,
check `scripts/checks/admin_review_reminder.mjs`.

**The DUMP load lines** (`loadLines()`, checked by `scripts/checks/dump_load_lines.mjs`), each left out when its count
could not be read:
- `📋 *N* completed DERM pickups since this driver's last dump to report on this load.` (or `🫙 *No completed DERM
  pickups since this driver's last dump.*`; `🫙 *No Miami-Dade DERM pickups to report on this load.*` when only
  Broward ones exist; `🫙 *No completed DERM pickups to report on this load.*` when there is nothing at all)
- `⚠️ *N* of this driver's pickups is/are in Broward (<codes>): file it/them at Pompano.` (Homestead only: its county
  gate hides them from every count)
- `↪️ *N* of this driver's pickups were already reported elsewhere (<code> (<who>), ...).` (since 2026-10-12,
  v72: a pickup another dump already holds leaves the count above and is named here; the thread repeats it as
  `↪️ *Already reported elsewhere (N):*` after Missing)
- `🗂 *N* other completed DERM pickups are still waiting to be reported (any truck).`

**The counts behind them** come from `public.dump_manifest_handout_list` (the driver's pickups completed after his
last dump that started BEFORE this one, and since `2026-10-12_1330` completed no later than 30 minutes after this
dump began; a [TEST] dump lists, confirms and links only test and fixture clients, a real dump never lists them), and a dump soft-deleted
anywhere releases its marks (`trg_zz_dump_delete_releases_holds`), so its pickups show as Missing again
(`docs/migrations/2026-10-07_1225_dump_load_window_and_deleted_dump_holds.sql`).

**Reviewed 2026-10-07** (Fred: "Is it good now? ... correct Headline ... body/format"): a 20-agent review found every
header right and the DUMP numbers wrong on real nights (Oct 5: two unreported pickups hidden from Missing because
their dump had been deleted; Oct 3: a Broward pickup made the post say "No completed DERM pickups"; Jul 31: a dump
scheduled ahead emptied the load). Fixed the same day (`dump-visit-create` v71, `stamp-sheets-reminder` v6), then
one `[TEST]` of every message was posted to #apps-notifications with Fred's OK and read back (dump 8750, 112-YA
visits 7822 / 7027, cleaned up). ⚠ The Slack connector's channel reader can label a post with ANOTHER app's name
(it showed the Stamp reminder as "DUMP Schedule"): check names and icons in Slack itself, not through it.

The DUMP messages' own rules (truck resolution, called ahead, which visits count, the removal threading rule) are in
`Building Apps/DUMP Schedule/CLAUDE.md`. The Stamp reminder's are in the Supabase `CLAUDE.md` Draw-the-bands section.

### Not on this format yet (a different bot, `Supabase - Notifications`, posting to #viktor-supabase)

Two GitHub Actions jobs in this repo post with their own bot token (GitHub secret `SLACK_BOT_TOKEN`, a different
Slack app): `scripts/alerts/audit_critical_poll.js` (Prod audit alert) and
`scripts/sync/weekly_dedup_audit.js`. (`daily_no_photo_visits_alert.js` and `audit_client_code_drift.js` were retired 2026-10-07 (timed-jobs move step 0).) They are plain text
with no header and some carry em dashes. **They stay on their own bot** (Fred, 2026-10-06: "do not move the audit
jobs to the shared bot"). The weekly duplicate check was tidied the same day (only addresses not reported the
week before, inactive clients skipped, client codes and names, escaped text, no em dash): see the header of
`scripts/sync/weekly_dedup_audit.js`.
