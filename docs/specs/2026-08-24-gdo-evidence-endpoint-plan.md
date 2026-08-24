# GDO evidence endpoint: what to build, what the docs need, and what to ask John

*Written 2026-08-24 by @Building Apps, at Fred's request, after reading John's two messages.*
**Status: PROPOSAL. Nothing built.**

> **This supersedes [`2026-08-21-gdo-late-evidence-questions-for-john.md`](2026-08-21-gdo-late-evidence-questions-for-john.md).**
> That draft asked five questions. **John's messages already answer three of them**, and its premise
> was wrong in an important way: it treated John as undecided when he has already shipped HYBRID mode
> and is **blocked on us**. Do not send that draft.

---

## 1. The situation, in his words

> *"we're enabling the inline wait in HYBRID mode: if the 120s window catches the email, the result
> posts the email rendered alone as the evidence image with 'Submitted - DERM email confirmed'; if it
> doesn't, the result posts today's portal screenshot with today's placeholder string, exactly as
> now."*
>
> *"the email-miss branch can never post an empty evidence slot, which was the sequencing risk you
> flagged. The strict behavior (no image + screenshot_missing_reason on a miss) sits behind a separate
> flag we will not touch until you confirm the fill-once deploy."*
>
> *"el bot ya captura el email como evidencia pero está en modo híbrido en espera del endpoint donde
> se publicará la evidencia cuando no se pueda hacer en el mismo flow del run. Cuando crees que ya
> tengamos ese endpoint listo?"*

**He is asking for a delivery date.** He has deliberately parked the strict mode behind a flag so he
cannot create the empty-evidence case before we can absorb it. That is good engineering on his side
and it means **the pressure is entirely on us**.

## 2. What his messages already answer

| old question | answer |
|---|---|
| **Q1** did the county accept the filing when the capture failed? | Effectively yes for the email path: the county's confirmation email **lands the same minute as the submit**, and HYBRID posts that email as the evidence. |
| **Q2** what does the bot do today? | HYBRID. It **never posts an empty evidence slot** today. |
| **Q5** re-POST or a dedicated endpoint? | He wants **an endpoint** ("el endpoint donde se publicará la evidencia"). |

⚠ **Q4 (does the bot re-file a ticket that returns to the queue?) is still unanswered and still
worth asking**, but it is no longer urgent: with HYBRID never posting an empty slot, the 400 does not
fire, so the requeue path is not being exercised by this defect.

## 3. What I measured before proposing anything

**Live traffic is tiny, and that bounds every claim below.** `derm_portal_submissions`, live rows only:

| | |
|---|---|
| rows ever | **11** (7 `SUCCESS`, 4 `ERROR_LOGIN_FAILED`) |
| rows with no image | **0** |
| `portal_confirmation` on all 7 successes | `Submitted — DERM portal confirmed (no tracking number)` |
| last SUCCESS | 2026-08-17 |
| last activity | 2026-08-19, the fourth `ERROR_LOGIN_FAILED` on visit 6617 |

🛑 **THE 400 HAS NEVER LEFT A TRACE, AND STRUCTURALLY CANNOT.** A rejected POST writes no row, so
this table is blind to it by construction. "Zero rows without an image" is **not** evidence the 400
never fired. Same shape as the `audit.logs`-records-successes trap.

**The county issues no tracking number.** That fixed string is the placeholder John refers to, and it
is why `success_requires_portal_confirmation` is satisfied by a constant rather than a real receipt.

🛑 **THE FILL PATH HAS NEVER RUN. WHAT ACTUALLY HAPPENS IS REPLACE.** `audit.logs`, all history:
**0** rows where `screenshot_path` went `NULL -> a path`. But three rows went `.jpg -> .png`:

| when | who | visit |
|---|---|---|
| 2026-08-13 | contact@unclogme.com via DERM Tracker | 7456 |
| **2026-08-24 14:51Z** | **fred@ayache.com** | 6741 |
| **2026-08-24 15:06Z** | **fred@ayache.com** | 6216 |

⚠ **Every replace stranded the superseded object.** All three visits hold **both** files in
`rpa-evidence` (the bucket has no DELETE policy). 3 orphans today, growing one per replace.

**⇒ This settles a design question I had open.** The earlier spec asked whether staff should be able
to *replace* an image or only *fill* an empty one. The answer from behaviour is that **replace is a
real, deliberate, in-use staff workflow** (Fred used it twice today). So:

> **Staff keep REPLACE. The bot gets FILL-ONCE.** Different actors, different rules. A human
> correcting a bad capture is a deliberate audited act; a machine retrying must never clobber.

⚠ **`rpa-derm-result` does no format sniffing.** It hardcodes the key `<visit>/<run>.jpg` and
`contentType: 'image/jpeg'` (index.ts 243, 249), while its sibling `record-manual-gdo-report` sniffs
properly. **The bot's own uploads are genuinely JPEG today** (verified by reading the stored bytes),
so nothing is mislabelled yet. **But John has just changed the evidence from a portal screenshot to a
rendered email**, which is exactly the kind of artefact that comes out as PNG. If he sends PNG we
will store PNG bytes at a `.jpg` key labelled `image/jpeg`, silently.

## 4. Do the docs need updating? Yes, in four places

| file | state | needed |
|---|---|---|
| [`postman/README.md`](../../postman/README.md) | **the API reference, and accurate on the current contract.** Its 18 error codes match the live source **exactly**, verified code by code. | ADD the evidence endpoint (a new section + its error codes). UPDATE the status header and §8 "Rollout gates", which still read as if nothing has gone live: gates 1 and 2 are passed, 7 real filings exist since 2026-07-24. REVISIT §10 "what we still need from you". DOCUMENT the image-format behaviour, which appears nowhere. |
| [`postman/gdo-reporting-bot.postman_collection.json`](../../postman/gdo-reporting-bot.postman_collection.json) | 8 requests, 3 folders. **The cloud workspace matches it exactly.** | ADD a "4. Evidence (late attach)" folder: attach to a dry-run result, attach when one already exists, attach to an unknown result. Re-export to the repo **and** push to the cloud workspace so they do not drift. |
| [`docs/api/gdo-reporting-api-roadmap.md`](../api/gdo-reporting-api-roadmap.md) | **premise is stale.** It says *"0 submissions yet, rollout imminent"*. **None of its 6 KEEP-NOW items were built** (checked each: `ALREADY_FILED`, `rpa_queue_paused`, `rpa_rollout_allowlist`, `needs_human`, `attempt_count`, `v_rpa_derm_deadletter` all absent). | Mark the premise superseded. Note that item 3 (manual close-out) **was effectively delivered** as `record-manual-gdo-report`, under a different name. Keep the rest as an unbuilt menu. |
| [`docs/integration.md`](../integration.md) | 🛑 **line 311 is WRONG.** It states an event trigger `trg_zz_gdo_reporting_notify` on `manifest_visits` *"pings the bot's `/run`"*. **That trigger does not exist**, and no function in the database references railway, the bot, or `/run` (control: 8 functions do use `net.http_post`, so the sweep was live). | Delete or correct that clause. README §5's *"there is no push from us, you poll"* is the accurate description and should win. |

⚠ **The two docs contradict each other on the single most basic question an integrator asks: does
UnclogMe call me, or do I poll?** README is right; integration.md is wrong. Fix before sending John
anything that references either.

## 5. What I propose to build

### 5a. A dedicated endpoint, `POST /functions/v1/rpa-derm-evidence`

Auth: the same `x-rpa-key`. Body:

```jsonc
{ "visit_id": 6216, "run_id": "5133d0d7-...", "screenshot": "<base64 JPEG or PNG>" }
```

Behaviour, in order:

1. Resolve the submission by `(visit_id, run_id)`. Not found -> **404 `result_not_found_for_visit_run`**.
   Evidence cannot arrive before its result; that ordering keeps the endpoint simple and makes a bot
   bug loud instead of creating a floating orphan.
2. If the stored row already has a `screenshot_path` -> **200 `{attached:false, already_had_evidence:true, screenshot_path}`**.
   Idempotent, deliberately **not** an error, so a retry storm is harmless.
3. Sniff the real bytes (JPEG or PNG, 5 MB cap), upload to `rpa-evidence` at
   `<visit_id>/<run_id>.<real_ext>`, then **one** UPDATE with an explicit two-column set list:

```js
.update({ screenshot_path: path, screenshot_missing_reason: null })
.eq('visit_id', visitId).eq('run_id', runId).eq('dry_run', false)
.is('screenshot_path', null)          // <- the whole safety property
```

`.is('screenshot_path', null)` makes the write **monotonic**: NULL to a path, never a path to a
different path. The bot may retry forever, in any order, and can never overwrite evidence we hold.
Clearing `screenshot_missing_reason` in the same statement stops a row ever showing both an image and
a reason it is missing.

**Why a dedicated endpoint rather than re-POSTing the result** (which was the earlier spec's plan):

- It is what John asked for and what his flag is built around.
- The body is small. He does not have to retain and replay the whole original result hours later, and
  replaying `status` / `portal_confirmation` invites confusion about which values win.
- The responses can be precise: attached, already had one, no such result. A re-POST can only answer
  through `deduped` plus `screenshot_stored`, which is inference rather than an answer.
- `rpa-derm-result` keeps one meaning: "here is what happened."

### 5b. Two small changes to `rpa-derm-result`

- **Sniff the image format** instead of hardcoding `.jpg` / `image/jpeg`, matching what
  `record-manual-gdo-report` already does. Do this **before** John's email-rendered evidence goes
  wide, or we start mislabelling from the first PNG.
- **Stop the 400** when neither a screenshot nor a reason is present: default the reason to
  `EVIDENCE_PENDING` and record the result. ⚠ **This is a safety net, not the blocker.** HYBRID never
  produces that case, and in strict mode John sends an explicit reason, which is already accepted. It
  matters only for a bot bug, and for the window where strict mode is on and something goes wrong.

### 5c. Not in scope, deliberately

Cleaning up the 3 stranded objects, and adding a DELETE path for replaced evidence. Real, small, and
a separate decision because it touches a compliance-evidence bucket.

## 6. The questions for John, revised

Only ask what his messages did not already answer.

1. **Is the rendered email a PNG or a JPEG?** We currently store every bot image as `.jpg` with
   `image/jpeg` regardless of its real bytes. We are fixing that, but knowing which you send lets us
   verify the fix against the real thing rather than a synthetic file.
2. **In strict mode, what exact `screenshot_missing_reason` string will you send?** We want it to read
   well where staff see it, and we would rather agree the vocabulary than parse whatever arrives.
3. **How long after the run might the evidence arrive?** Seconds, minutes, or possibly the next day?
   It decides whether a row can sit evidence-pending across a DERM deadline and whether we need to
   surface a "waiting for evidence" state to staff rather than just storing one.
4. **Do you want to attach evidence to failed runs too, or only to successes?** Cheap to allow, but it
   changes what the endpoint accepts and we would rather decide it once.
5. **Still open from before: when a ticket you already filed comes back on our queue hours later, do
   you re-file or skip?** Less urgent now that HYBRID always posts a result, but it is the one
   question that bears on a duplicate county filing, and we would still like the answer.
6. **Is the bot currently stuck on the portal login?** We see four `ERROR_LOGIN_FAILED` results on
   visit 6617, the most recent on 2026-08-19, and no successful filing since 2026-08-17.

And one thing to tell him rather than ask: **the strict-mode flag stays off until the evidence
endpoint is deployed and he has confirmed a round trip against it.** He has already proposed exactly
that sequencing; confirming it in writing closes it.

## 7. Open for Fred

- **The delivery date.** John asked for one and that is the actual reply he is waiting on. The build
  above is small (one endpoint, two small edits, docs, Postman); the honest constraint is your
  review, not the code.
- **You replaced the bot's evidence on two visits today** (6741 and 6216, `.jpg -> .png`). If that was
  you swapping a portal screenshot for the county email by hand, it is the manual version of what
  HYBRID now automates, and it is worth saying so, because it tells us the email image is the shape
  you actually want as evidence.
- **Staff replace vs bot fill-once**, confirmed above from behaviour rather than assumed. Say if you
  want staff constrained to fill-only as well.
- **The 3 stranded objects**, and whether a replace should delete the superseded file.
