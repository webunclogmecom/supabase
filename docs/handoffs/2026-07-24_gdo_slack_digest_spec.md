# GDO daily digest — Slack format spec (for the bot)

*A ready-to-implement spec for John's GDO Online Reporting bot. It defines the daily Slack digest format (the color-bar version tested in #tests) and includes a drop-in Python builder so the bot can produce it directly. No secrets: the webhook is read from an env var.*

---

## 1. What it is + where it posts

Once per run (or once a day), the bot POSTs a summary of what it did to a Slack channel via an **Incoming Webhook**. Read the webhook URL from an env var, never hard-code it:

```python
import os, requests
requests.post(os.environ["SLACK_WEBHOOK_URL"], json=payload, timeout=10)
# a 200 with body "ok" means delivered
```

## 2. The look

A message made of a small header section plus up to four **color-bar groups** (Slack attachments), one per status. Color comes from the attachment's left bar; everything else is emoji + `code` + bold text.

- **Header:** `🗓️  Daily digest · <date>` (no "GDO" in it — the bot is already named "GDO Report Bot", so a GDO header would just repeat the name).
- **Phase badge:** `🟢  *Live filing*` on a real run, `🧪  *Dry run · nothing filed*` on a dry run.
- **Summary line:** `✅ N filed · ⚠️ N needs review · ❌ N failed · ⏳ N in queue`.
- **Freshness:** a small context line `🕔  Last run <time> ET`.
- Then the color-bar groups, in this order: **filed → needs review → failed → in queue.**

## 3. Which bucket each result goes in

Classify from the fields the bot already sends to `rpa-derm-result`:

| Bucket | Bar color | Emoji | Condition (from the result) | Row shows |
|---|---|---|---|---|
| **Filed** | green `#2eb67d` | ✅ | `status == "SUCCESS"` | the `portal_confirmation` (as `code`) |
| **Needs review** | amber `#ecb22e` | ⚠️ | an error with `retryable == false` (data problem: email mismatch, missing field, expired permit…) | a short, human reason + the fix |
| **Failed** | red `#e01e5a` | ❌ | an error with `retryable == true` (transient: portal timeout, portal down, unhandled) | the failure + "will retry" |
| **In queue** | blue `#36c5f0` | ⏳ | still-unfiled dumps the bot has **not attempted this cycle** (from the queue `count`, not from results) | why it is waiting |

Notes:
- On a **dry run** (`dry_run == true`), everything that would be "Filed" is shown as `previewed, not filed` instead of a confirmation, and the phase badge is `🧪 Dry run`.
- **Empty buckets simply do not appear** — a clean day with 3 filed and nothing else is just one green bar (that is the "quiet day" behavior, no special-casing needed).
- **Queue length:** on a busy day the queue list can get long. Default is to list it; if it grows past ~5, collapse it to a single count line instead (a one-line variant is in the Python below). Filed / review / failed are always listed in full because they are actionable or notable.

## 4. Drop-in Python builder

```python
GREEN, AMBER, RED, BLUE = "#2eb67d", "#ecb22e", "#e01e5a", "#36c5f0"

def _section(text):
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}

def build_digest(date_label, phase, filed, review, failed, queue, last_run, collapse_queue=False):
    """
    date_label : "Wed, Jul 23"
    phase      : "live" or "dry"
    filed      : [{"code","name","confirmation"}]
    review     : [{"code","name","reason"}]   # reason includes the fix, e.g. "email mismatch, fix in Jobber"
    failed     : [{"code","name","reason"}]    # e.g. "portal timeout, will retry"
    queue      : [{"code","name","reason"}]    # e.g. "waiting on the dump ticket"
    last_run   : "5:06 PM ET"
    """
    live = phase == "live"
    badge = "🟢  *Live filing*" if live else "🧪  *Dry run · nothing filed*"
    counts = (f"✅  *{len(filed)}* filed   ·   ⚠️  *{len(review)}* needs review   ·   "
              f"❌  *{len(failed)}* failed   ·   ⏳  *{len(queue)}* in queue")

    blocks = [
        {"type": "header", "text": {"type": "plain_text", "text": f"🗓️  Daily digest · {date_label}", "emoji": True}},
        _section(badge),
        _section(counts),
        {"type": "context", "elements": [{"type": "mrkdwn", "text": f"🕔  Last run {last_run}"}]},
    ]

    attachments = []
    if filed:
        rows = [f"✅  *{f['code']}*  {f['name']}   ·   `{f['confirmation']}`" if live
                else f"✅  *{f['code']}*  {f['name']}   ·   previewed, not filed" for f in filed]
        attachments.append({"color": GREEN, "blocks": [_section(r) for r in rows]})
    if review:
        rows = [f"⚠️  *{r['code']}*  {r['name']}   ·   {r['reason']}" for r in review]
        attachments.append({"color": AMBER, "blocks": [_section(r) for r in rows]})
    if failed:
        rows = [f"❌  *{r['code']}*  {r['name']}   ·   {r['reason']}" for r in failed]
        attachments.append({"color": RED, "blocks": [_section(r) for r in rows]})
    if queue:
        if collapse_queue:
            attachments.append({"color": BLUE, "blocks": [_section(f"⏳  *{len(queue)}* in queue for the next run")]})
        else:
            rows = [f"⏳  *{q['code']}*  {q['name']}   ·   {q['reason']}" for q in queue]
            attachments.append({"color": BLUE, "blocks": [_section(r) for r in rows]})

    fallback = (f"Daily digest · {date_label}: {len(filed)} filed, {len(review)} needs review, "
                f"{len(failed)} failed, {len(queue)} in queue")
    return {"text": fallback, "blocks": blocks, "attachments": attachments}
```

Classifying the run's results into those four lists (adapt field names to the bot's data):

```python
def classify(results, queue_items):
    filed, review, failed = [], [], []
    for r in results:
        row = {"code": r["client_code"], "name": r["client_name"]}
        if r["status"] == "SUCCESS":
            filed.append({**row, "confirmation": r.get("portal_confirmation", "confirmed")})
        elif r.get("retryable"):
            failed.append({**row, "reason": humanize(r) + ", will retry"})
        else:
            review.append({**row, "reason": humanize(r)})   # data problem, needs a human
    queue = [{"code": q["client_code"], "name": q["client_name"], "reason": "queued for the next run"} for q in queue_items]
    return filed, review, failed, queue
```

Then: `payload = build_digest("Wed, Jul 23", "live", *classify(results, queue), last_run="5:06 PM ET")` and POST it.

## 5. Raw Block Kit shape (for reference)

A trimmed example of what `build_digest` produces (2 filed + 1 review):

```json
{
  "text": "Daily digest · Wed, Jul 23: 2 filed, 1 needs review, 0 failed, 0 in queue",
  "blocks": [
    { "type": "header", "text": { "type": "plain_text", "text": "🗓️  Daily digest · Wed, Jul 23", "emoji": true } },
    { "type": "section", "text": { "type": "mrkdwn", "text": "🟢  *Live filing*" } },
    { "type": "section", "text": { "type": "mrkdwn", "text": "✅  *2* filed   ·   ⚠️  *1* needs review   ·   ❌  *0* failed   ·   ⏳  *0* in queue" } },
    { "type": "context", "elements": [ { "type": "mrkdwn", "text": "🕔  Last run 5:06 PM ET" } ] }
  ],
  "attachments": [
    { "color": "#2eb67d", "blocks": [
      { "type": "section", "text": { "type": "mrkdwn", "text": "✅  *041-MB*  Ocean Drive Kitchen   ·   `DERM-2026-0723-4471`" } },
      { "type": "section", "text": { "type": "mrkdwn", "text": "✅  *111-YC*  Yard Cafe   ·   `DERM-2026-0723-4472`" } }
    ]},
    { "color": "#ecb22e", "blocks": [
      { "type": "section", "text": { "type": "mrkdwn", "text": "⚠️  *082-TFC*  The Fresh Company   ·   email mismatch, fix in Jobber" } }
    ]}
  ]
}
```

## 6. Rules / gotchas

- **Timestamps in ET.** The bot's clock may be UTC; convert to `America/New_York` for the displayed times (e.g. `5:06 PM ET`).
- **No em dashes.** Use `·`, commas, or colons as separators (house style).
- **Don't wrap emails in backticks.** Slack auto-links them into `mailto:` even inside code, which looks broken. Leave emails plain (they become normal clickable links).
- **Attachments are Slack's only color mechanism.** Slack stamps a small "Added by <app>" under each attachment; that is expected and unavoidable with color bars. (If that repetition is ever unwanted, the alternative is pure blocks with emoji-only color and no bars.)
- **Block limits:** max 50 blocks per attachment, plenty for any real day. If a single bucket could ever exceed that, cap the list and add a "and N more" line.
- **The message is a compact daily rollup, not the system of record.** Detail lives in the DERM tool; the digest is for a glance.
