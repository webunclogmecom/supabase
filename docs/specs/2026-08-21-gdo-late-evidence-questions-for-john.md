# Draft message to John: GDO Report Bot, data first and evidence image later

**Status: DRAFT, NOT SENT.** Written 2026-08-24 by @Building Apps at Fred's request. Nothing has been
sent to John through any channel. Fred picks the channel and sends it.

**Why it exists:** [`2026-08-21-gdo-late-evidence-design.md`](2026-08-21-gdo-late-evidence-design.md)
is PROPOSED and unbuilt, and it is blocked on exactly these five answers. Question 4 is the urgent one:
it decides whether a duplicate Miami-Dade filing has already happened, which is the spec's number one
ranked risk and is live today.

**Facts in the message, verified against the live source** (`supabase/functions/rpa-derm-result/index.ts`):
the 400 is `screenshot_or_screenshot_missing_reason_required` at line 129, and the dedupe branch
returns `{recorded:true, deduped:true}` at lines 205 to 209, before the upload block is reached.

---

## The message

Hi John,

Fred mentioned the bot has hit the case where it has the report data but not the evidence image, and
that you would like to send the data first and the image afterwards. We want to support that, and we
have a design ready to go, but there are five things only you can answer before we change anything on
our side.

First, some context on what our endpoint does today, so the questions make sense.

`rpa-derm-result` rejects a POST with **HTTP 400 `screenshot_or_screenshot_missing_reason_required`**
when it carries neither a screenshot nor a `screenshot_missing_reason`. Separately, a repeat POST on
the same `(visit_id, run_id)` returns `{recorded: true, deduped: true}` **before** it looks at any
attached image, so a retry that carries the image is currently a silent no-op: we return 200 and store
nothing. Both of those are things we intend to change, and both are the reason for the questions.

**1. When you have the report data but no image, did the county actually accept the filing and only
the screen capture failed? Or are you unsure whether the filing went through?**

This one decides the whole design. If the filing definitely went through, we can record the row as a
success with the evidence pending. If you are unsure, then recording it as a success would be us
asserting something neither of us knows, and we need a different approach.

**2. What does the bot do today in that situation:** withhold the POST entirely, send a
`screenshot_missing_reason`, or send neither and take the 400?

**3. Is anything sitting unacknowledged in your retry queue right now?** If so, what HTTP status and
body did we return for it? We would like to reconcile it rather than let it age out.

**4. When a ticket you have already filed with Miami-Dade comes back to you on our queue some hours
later, does the bot re-file it, or does it recognise it and skip?**

This is the one we would most like answered. Our 400 rejects your result, which means the ticket can
remain on our queue and be handed back to you. If the bot re-files on a second sighting, then a
duplicate filing with the county may already have happened. We would rather find that out and check
than assume it has not.

**5. For attaching the image later, is re-POSTing the identical body with the image attached workable
for you, or would you prefer a separate evidence-only endpoint?**

Re-POST is our preference, because it needs no new endpoint and no change to your success path, but it
is your retry logic, so it is your call.

---

Assuming your answer to question 1 is that the filing did go through, here is what we would change on
our side, so you can object before we build it:

- **Stop returning the 400.** If a POST carries neither a screenshot nor a reason, we record the row
  with a reason of `EVIDENCE_PENDING` and accept it, rather than rejecting the whole result.
- **Make a retry that carries the image actually attach it.** Today the dedupe check returns before
  the upload runs. We would let it fall through and fill in the image, but only when the stored row
  does not already have one.
- **That fill is guarded so it can only move from "no image" to "an image", never from one image to a
  different one.** So you can retry as often as you like, in any order, and you can never overwrite
  evidence we already hold. Nothing you send twice can do damage.

Nothing changes for the case that already works today: a result that arrives complete, with its
screenshot, behaves exactly as it does now.

Thanks,
Fred

---

## Notes for Fred, not part of the message

- **Channel is your call.** Per the standing rule I have not sent this anywhere, and I will not send a
  real message without an in-the-moment OK from you.
- **Question 4 is worth asking even if the rest waits.** It is diagnostic about something that may
  have already happened, and it does not depend on any of the design decisions.
- **Question 1 can invalidate the design.** If John answers "unsure whether the filing went through",
  then `status='SUCCESS'` is wrong for these rows and section 3 of the spec needs reworking before
  anything is built. Do not let the build start on an assumed answer to it.
- **Three questions for you are still open too** (section 7 of the spec), the user-visible one being
  what the client should see during the image gap. Measured from the live Field Portal bundle: the
  Online Report card is gated on `reported`, not on `has_report_image`, so a data-first row would show
  a card with a PENDING chip reading "On file, not available for online viewing".
- **Before answering anything about how or when the bot RUNS**, read
  [`docs/reference/gdo-rpa-bot-triggers.md`](../reference/gdo-rpa-bot-triggers.md), which is John's own
  document. It has three triggers rather than one, and `SHADOW_MODE=true` forces every run to dry-run
  regardless of the URL.
