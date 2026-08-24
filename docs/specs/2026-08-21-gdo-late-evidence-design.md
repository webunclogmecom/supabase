# Design spec: file the GDO report data first, attach the evidence image later

**Status: SUPERSEDED 2026-08-24. The capability shipped, but NOT by this design.**
Read [`2026-08-24-gdo-evidence-endpoint-plan.md`](2026-08-24-gdo-evidence-endpoint-plan.md) instead.

🛑 **The approach changed, so do not build from section 3 of this file.** It proposed filling the gap
through the **dedupe branch of `rpa-derm-result`** (re-POST the identical body with the image). What
actually shipped is a **dedicated endpoint, `rpa-derm-evidence`**, because John asked for one and
because a small body he does not have to reconstruct hours later is a better contract. The fill-once
guarantee (`.is('screenshot_path', null)`) carried over unchanged and is the one idea from here that
survived intact.
⚠ Section 3(a) "stop the 400" is **still unbuilt**. Section 3(c), the staff-path fix, was **not needed**
in the end: staff REPLACE evidence deliberately and that path stays as it is.
⚠ Its section 7 questions are **obsolete**: John's own Slack messages answered three of the five before
anything was built.
Author: @Building Apps session, 2026-08-21. Awaiting Fred, and blocked on five questions for John.
**Update 2026-08-21: defect D1 in section 6 is RESOLVED and its original diagnosis was refuted. The
late-evidence design itself is still PROPOSED and unbuilt.**

**Ask, verbatim (Fred, 2026-08-21):** the GDO Report Bot has hit the case where it *"has the report
data but not the evidence image"*, and John wants *"to be able to put the data first, and the evidence
image later."*

---

## 1. The measurement that matters, and why an earlier one was wrong

An earlier check reported **zero** live submissions with a missing image and was read as "this has
never happened". **That instrument was structurally blind and the reading was wrong.**

`supabase/functions/rpa-derm-result/index.ts` returns **HTTP 400
`screenshot_or_screenshot_missing_reason_required`** when a POST carries neither a screenshot nor a
reason string, and it does so *before* the Supabase client is constructed. **No row is written.** So
the event leaves nothing in `public.derm_portal_submissions` for any query to count. An absent row is
not an absent event.

### What is measured

| | value | how |
|---|---|---|
| live rows (`dry_run IS NOT TRUE`) | **11**, over 7 visits, 2026-07-24 to 2026-08-19 | `count(*)` |
| of those, real county filings | **7** SUCCESS | the other 4 are `ERROR_LOGIN_FAILED` on visit 6617 |
| live rows with `screenshot_path IS NULL` | **0** | positive controls fired: the predicate alone matches 49 rows, `dry_run IS NOT TRUE` alone matches 11 |
| live rows carrying `screenshot_missing_reason` | **0** | the 49 that carry one are all dry runs, all labelled `DRY_RUN_EVIDENCE_PURGED 2026-07-24`, which is our own cleanup label and not anything the bot sent |
| times the bot has exercised the reason branch | **6**, end to end, `app_source='gdo-report-bot'` | all `dry_run=true`, all since hard-deleted |
| evidence referential integrity | clean both directions | 0 paths point at a missing object (486 matched), 1 object of 37 is an orphan, and that one is the known residue of the staff jpg-to-png replacement feature |
| `run_id` reuse | **none ever** | 535 rows, 535 distinct run_ids |

### What is unknown, and will stay unknown

Whether `rpa-derm-result` has ever returned a 400 for this case. `function_edge_logs` retention is
roughly 24 hours; the first live filing was 2026-07-24. **Only John's deployment holds that answer.**

### The unresolved contradiction

Fred reports the bot POSTs with a missing reason. If it does that on a live visit, a row lands, and
**zero live rows carry one**. Two readings, and only John can settle it:

1. **His image-less cases were all dry-run.** `rpa-derm-result` derives `dry_run` from the visit date
   against `rpa_launch_cutoff()` and **deliberately ignores the flag the bot sends**; John's own
   `SHADOW_MODE=true` forces every run to dry-run regardless of URL. A real image-less filing on his
   side can therefore land in our data as a dry run and be invisible to any live-row query.
2. **The live ones sent neither field and took a 400.** Leaves no trace we can still read.

**This spec is written to be correct under both readings.** Reading 2 is the one with a live hazard,
so the design closes it either way.

---

## 2. The hazard that makes this urgent

A 400 means no row. All three "already reported" `NOT EXISTS` gates in `public.v_derm_portal_queue`
therefore pass. The only thing then holding the ticket is a **20-hour lease**, and
`rpa-derm-queue/index.ts` treats that lease write as **best-effort and non-blocking**.

**After 20 hours the manifest returns to the queue and the bot files with Miami-Dade a second time.**

Whether this has fired is unknown to us. It is the reason to act now rather than after John replies.

---

## 3. Design

**Row first with `status='SUCCESS'`, image attached later under the SAME `run_id`.**

### The row shape needs no schema change

Verified live:

```
derm_portal_submissions_evidence
  CHECK (screenshot_path IS NOT NULL OR screenshot_missing_reason IS NOT NULL)
```

A data-first row is **already a legal state**:

| column | value | why this and not something else |
|---|---|---|
| `status` | `'SUCCESS'` | `customer.gdo_reports.has_report_image` and `get-derm-doc` both hard-filter `status='SUCCESS'`. Any other value makes the image unreachable **forever, silently**. |
| `portal_confirmation` | the county confirmation | `CHECK derm_portal_submissions_success_confirmed` requires it, and it is what holds the visit out of queue gate 1. |
| `screenshot_path` | `NULL` | the point of the feature |
| `screenshot_missing_reason` | `'EVIDENCE_PENDING'` | satisfies the OR above. No new column, no new constraint. |

### Three changes, all to objects that already exist

**(a) Stop the 400.** In `rpa-derm-result`, when neither a screenshot nor a reason is present, default
the reason to `'EVIDENCE_PENDING'` and continue instead of rejecting. Everything downstream already
handles a null path. This single change closes the hazard in section 2.

**(b) Make the dedupe branch fill the gap.** Today a repeated POST on the same `(visit_id, run_id)`
returns `{recorded:true, deduped:true}` *before* reaching the upload block, so a retry carrying the
image is a silent 200 no-op. Change it so that when the stored row has `screenshot_path IS NULL` and
the POST carries decodable bytes, it falls through to the upload and then performs **one UPDATE with
an explicit two-column set list**:

```js
.update({ screenshot_path: derivedPath, screenshot_missing_reason: null })
.eq('visit_id', visitId).eq('run_id', runId)
.eq('dry_run', false)
.is('screenshot_path', null)     // attach-once: makes the retry idempotent forever
```

The `.is('screenshot_path', null)` predicate is the whole safety property. It makes the write
monotonic (NULL to a path, never a path to a different path), so the bot may retry indefinitely and
can never overwrite evidence on an already-complete row.

**(c) Fix the staff path to match.** `public.fn_set_gdo_evidence_ext` has exactly one
`SET screenshot_path = ...` and does not clear the reason. Without that, a staff attach leaves a row
showing both an image and a "missing" reason, and `derm.visit_gdo_report` exposes both columns to the
DERM Tracker. See also defect D2 in section 6, which lives in the same function.

### What must remain impossible

`v_derm_portal_queue` reads exactly six columns: `dry_run`, `gdo_id`, `status`,
`portal_confirmation`, `created_at`, `retryable`. **The attach write must touch none of them.**

- No new status value. `SUCCESS` end to end.
- No DELETE-and-reinsert. That drops the excluding row and resets `created_at`.
- No attach path that accepts a new `run_id`. That inserts a second row instead of completing the first.
- No generic row-update verb on the table (section 4).
- No widening of `get-derm-doc`'s `status='SUCCESS'` filter. That filter is a security control: a
  dry-run image is the full county Preview form and can carry another facility's details.

**Why this is safe against re-filing by construction, not by care:** the definitions of
`v_derm_portal_queue` and `v_derm_portal_fields` contain neither `screenshot_path` nor
`screenshot_missing_reason` (verified with two positive controls on the same bytes: matching
`portal_confirmation` returns TRUE and matching `status` returns TRUE, so the check can see). A write
confined to those two columns cannot change queue membership under any value.

---

## 4. Rejected alternatives

**A REST PUT or PATCH on `derm_portal_submissions`.** Rejected, but the first reasoning offered for
this was the weaker half and is corrected here. "Only `service_role` holds a grant" is true
(`has_table_privilege('authenticated', ..., 'SELECT')` is false, RLS enabled, zero policies) but it
describes today rather than defending anything, since a PATCH would need a new grant regardless.

The real reason is the **verb**:

- Queue gate 1 is `status='SUCCESS' OR portal_confirmation IS NOT NULL`. A single PATCH can move
  status off SUCCESS **and** null the confirmation in one statement, and
  `CHECK derm_portal_submissions_success_confirmed` **only fires while status stays `SUCCESS`**. It
  does not catch that combination.
- Column-level grants could restrict *which* columns, but cannot express *"only when
  `screenshot_path IS NULL`"*. Attach-once is not expressible as a grant.

**A new interim status such as `FILED_PENDING_EVIDENCE`.** Rejected, and it is the most dangerous
option considered. It kills the client-visible image permanently in two independent places that both
fail silently, and it moves the queue exclusion off the CHECK-protected `status='SUCCESS'` branch onto
the unprotected `portal_confirmation IS NOT NULL` branch, where `fn_correct_gdo_report` (EXECUTE to
`authenticated`) can null it. Keeping `status='SUCCESS'` is the single reason the design is shaped
this way.

**A separate `rpa-derm-evidence` edge function.** Workable and marginally cleaner as a contract, but
it is a second endpoint, a second key check, and a second thing for John to build. The dedupe
fall-through reuses the retry loop his bot already has. **Keep as the fallback** if John says
re-POSTing the full body is awkward on his side (question 5 for John).

**A new SECURITY DEFINER RPC for the bot's attach.** Adds no security over the explicit-column UPDATE,
since the edge function already holds `service_role`. Worth it only to state the two-column
restriction in the database rather than in TypeScript. Optional, not recommended for the first cut.

**Do nothing, and tell John to always send `screenshot_missing_reason`.** This is what the contract
already says and it would work. Rejected as insufficient: it leaves the 400 as a live second-filing
path for any bot bug or older build, and it gives us no way to ever obtain the image.

---

## 5. Ordered actions

| # | What | Who | Verification | Reversible |
|---|---|---|---|---|
| 1 | Ask John the five questions in section 7. **Do not build the bot half until answered.** | Us to John | His answer in writing | n/a |
| 2 | Ask Fred the three questions in section 7. | Us to Fred | Answers | n/a |
| 3 | Fix `fn_set_gdo_evidence_ext`: clear the reason, and add the storage-object existence check (defect D2). One migration. | Us | Call against a dry-run row and confirm it raises; call against a live row with a real object and confirm both columns move; confirm the two prior real calls still resolve | **Yes**, CREATE OR REPLACE back |
| 4 | Re-key `fn_correct_gdo_report` to `(visit_id, run_id)` and guard against nulling a confirmation on a non-SUCCESS row (defect D3). | Us | Call with visit 6617 and each run_id, confirm each targets its own row; confirm the SUCCESS row still rejects an emptied confirmation with 23514 | **Yes**, but it is a signature change: ship with its Tracker caller in the same cycle |
| 5 | ~~Prove `record-manual-gdo-report` works end to end (defect D1).~~ **DONE 2026-08-21** (`e30f28f`): it was broken for every visit, one line, now fixed and proven through the app. | Us | Submitted for real on visits 7276 and 7270, verified row + storage object + signed URL, then removed both and confirmed the live-row count back at its baseline of 11 | done |
| 6 | Change `rpa-derm-result` to default `EVIDENCE_PENDING` instead of 400. Deploy. | Us | POST a **dry-run** body with neither field: expect a row with `screenshot_path IS NULL` and the reason set. Confirm the previously-400ing shape now succeeds | **Yes**, redeploy prior version |
| 7 | Change the dedupe branch to fall through to upload plus the two-column UPDATE. Deploy. | Us | On the row from #6, re-POST with an image: confirm the path is set and the reason cleared. Re-POST a **third** time with a *different* image and confirm the path does not change. Confirm `audit.logs.changed_keys` is exactly `['screenshot_path','screenshot_missing_reason']` | **Yes** |
| 8 | Widen `v_rpa_derm_health` with an `evidence_pending_over_24h` counter. | Us | Insert a dry-run fixture with an old `created_at`, confirm it counts, delete it | **Yes** |
| 9 | John updates the bot: POST on capture failure, re-POST the identical `(visit_id, run_id)` when the image arrives. | John | One run against a dry-run visit, checked from our side | Yes |
| 10 | Document in `Building Apps/DERM Tracker/docs/08-changelog.md` and its `CLAUDE.md`: the new row shape, `EVIDENCE_PENDING`, attach-once, and that status must stay SUCCESS. Migration headers for #3, #4, #8. | Us | The doc names the exact columns and the traps | Yes |
| 11 | Verify no re-queue **correctly**. | Us | Gates 2 and 4 are both 20-hour windows, so a same-hour check is a guaranteed false all-clear. Either wait 20+ hours, or evaluate gates 1 and 3 directly on that manifest with the windows removed, read-only | n/a |

**The single irreversible hazard on this list is a test POST against a LIVE visit** at steps 6, 7
or 9. For those three, use a visit whose `visit_date < rpa_launch_cutoff()`, which forces
`dry_run=true` server-side in `rpa-derm-result`, derived from the visit and not trusted from the caller.

🛑 **THAT PROTECTION DOES NOT EXIST ON THE MANUAL PATH, AND ASSUMING IT DOES IS THE TRAP.**
`fn_record_manual_gdo_report` writes **`dry_run = false` hardcoded**. There is no dry-run mode, so a
"test on a pre-cutoff visit" still commits a **live** `SUCCESS` row. Pre-cutoff only buys you that
`suppresses_bot` is false, i.e. the bot was never going to file that visit anyway.
⇒ To test it safely, pick a visit where **`fn_visit_is_gdo_reporting` is false**. That is the filter
on `customer.gdo_reports`, so such a visit can never reach a client's Field Portal whatever you write.
Then delete the row and the object afterwards. Both test visits used on 2026-08-21 (7276, 7270) were
chosen on exactly that basis and measured at 0 client-visible rows throughout.
⚠ And the object must be removed through the **Storage API**: `storage.protect_delete()` refuses a
direct `DELETE` on `storage.objects` and aborts the whole transaction.

---

## 6. Three defects found during this audit, independent of this feature

These are **not** caused by the proposed design and do not depend on it. They are recorded here
because the audit found them and they are live now.

**D1. `record-manual-gdo-report` was broken for every visit. RESOLVED 2026-08-21, and the
hypothesis first recorded here was WRONG.** This entry originally said the cause "points at the token
the DERM Tracker sends" because the logs showed 4 gateway 401s. **Tested end to end through the app as
a signed-in user and that is refuted:** `verify_jwt` accepted the token and the function ran. Those
401s were not the app.

The real cause was one line. The eligibility read called
`.from('visit_gdo_manual_eligibility')` on a service client built with **no `db.schema` option**, so
it resolved against `public` while the view lives in **`derm`**. PostgREST errored, the guard returned
its own 500 (*"Could not check whether this stops the bot, so nothing was recorded."*), and **the
feature failed for every visit**. That is why 535 submissions carried 0 manual rows and 0 filers.

Fixed with a per-query `.schema('derm')` (`e30f28f`). Pinning the whole client would break the other
two calls, `.from('visits')` and `.rpc('fn_record_manual_gdo_report')`, which are both `public`.

A **composition defect**: the client and the view name were each correct in isolation and nothing had
ever run the composed statement. The UI was verified with real clicks but never submitted, so the
write path was never exercised. That gap is the author's error.

Proven on visit 7276 (`137-BB`, `gdo_reporting = false`, so no client could see it): 500 before, 200
after, row `1921` with `status SUCCESS`, `is_manual true`, `filed_by_email fred@ayache.com`, the
evidence object stored at the derived path and signed back at 200. Repeated cleanly on 7270. Both
test rows and objects removed; live-row count back to its baseline of 11; backup at
`backups/2026-08-21_manual_gdo_e2e_test_rows.json`; the two DELETEs are in `audit.logs`.

**D1b. ~~The modal does not close on success.~~ WITHDRAWN 2026-08-21: THERE IS NO BUG. This entry
was an artifact of my own automation and it is left here, corrected, because the retraction is the
lesson.**

The automated tab reports `document.visibilityState === "hidden"`, and **CSS animations do not
advance in a backgrounded tab**. Radix keeps a dialog mounted until its exit animation completes, so
the element stays in the DOM, fully visible, with `body { pointer-events: none }`, forever. Measured
on the live page: `data-state="closed"` (React HAD closed it) while the `exit` animation sat at
`playState: "running", currentTime: 0` on a 0.2s animation.

**The control that settled it:** pressing **Cancel**, which submits nothing and runs no success
handler, produces the **identical** symptom. So the success path was never implicated.

⚠ **Cost of getting this wrong:** two Lovable build-and-publish cycles were spent "fixing" it. Those
changes are benign (an explicit form reset on success, plus a redundant `setTimeout(() => onOpenChange(false), 0)`),
but the redundant timeout is cruft born of a phantom defect and should be removed the next time that
file is touched.

⚠ This is `Building Apps/CLAUDE.md` **rule 20**, which was already written down and which I did not
reach for. **Before reporting any UI state as broken under automation, check `document.visibilityState`
first.** If it is `hidden`, anything animated or transitioned is not evidence of anything.

**D1c. A visit outside `derm.visits` renders "Loading..." forever. FIXED 2026-08-21.** Visit 7280 is
one of **34** completed visits excluded from that view. 🛑 **NOT because `derm_required = false`,
which this entry first claimed and which is WRONG** (386 not-required visits are in the view): the
predicate excludes the two DUMP-SITE clients `000-DH` and `000-DP`. The view is correct and must not
be widened. Worth knowing when picking a test target:
`derm.visit_gdo_manual_eligibility` covers **1,089** completed visits while the app renders **1,057**,
so eligibility can report `can_record_manual = true` for a visit the app cannot show at all.

**D2. `fn_set_gdo_evidence_ext` is a live hole.** EXECUTE is held by `authenticated`, and the body
**never references `storage.objects`** (verified). Any signed-in staff user can repoint a live
report's evidence at a path that does not exist, which blanks the client's evidence card. Its sibling
`fn_record_manual_gdo_report` received exactly this check on 2026-08-19; this one did not.

**D3. `fn_correct_gdo_report` edits the wrong row.** It targets `ORDER BY attempted_at DESC LIMIT 1`
over live rows. On visit 6617 that is row **593** (`ERROR_LOGIN_FAILED`, 2026-08-19), not row **572**
(`SUCCESS`, 2026-08-07), so a staff member correcting the real filing edits the failed attempt.
`fn_set_gdo_evidence_ext` already keys correctly on `(visit_id, run_id)`; this one does not.

---

## 7. Open questions, to be answered before building

### For John

1. When you have the report data but no image, did the county **accept the filing** and only the
   capture fail, or are you **unsure whether the filing went through**? If it is the second,
   `status='SUCCESS'` is a lie and this design is wrong.
2. What does the bot do today in that case: withhold the POST, send `screenshot_missing_reason`, or
   send neither and take a 400?
3. Is any result sitting unacknowledged in your retry queue right now, and what HTTP status and body
   did we return for it?
4. When a ticket you already filed comes back on the queue 20 hours later, do you re-file with
   Miami-Dade or recognise it and skip? **This decides whether a double filing has already happened.**
5. Is re-POSTing the identical body with the image attached workable, or would you prefer a separate
   evidence-only endpoint?

### For Fred

6. **During the image gap, what should the client see?** Measured from the live Field Portal bundle:
   the Online Report card is gated on `reported`, **not** on `has_report_image`, so a data-first row
   renders a visible card with a PENDING chip and "On file, not available for online viewing",
   subtitled with the filing date. Acceptable, or hide the card until the image lands?
7. Should staff be able to **replace** an existing image, or only **fill** an empty one? Attach-once
   is safer and idempotent; replace lets a bad capture be corrected. Note the existing staff replace
   flow strands the old object forever, since the bucket has no DELETE policy.
8. Is `fn_correct_gdo_report`'s EXECUTE grant to `authenticated` deliberate, or is it the same
   `ALTER DEFAULT PRIVILEGES` leak that was closed on its sibling on 2026-08-19?

---

## 8. Risks, ranked

1. **CRITICAL, live today, unquantified: the 400 causes a second Miami-Dade filing.** Section 2.
   Closed by action 6. Only John can say whether it has fired.
2. **CRITICAL if an interim status is introduced: `fn_correct_gdo_report` can re-open the queue.** A
   non-SUCCESS row's exclusion rests entirely on the `portal_confirmation IS NOT NULL` branch, which
   no CHECK guards. Measured today: **0** live non-SUCCESS rows carry a confirmation, so there is no
   current exposure. This is a risk the rejected design would *create*. Mitigation: keep
   `status='SUCCESS'`.
3. **HIGH: a row that never receives its image, silently.** Nothing counts it today
   (`store_failed_total` matches the literal `'STORE_FAILED'` only), the visit is permanently out of
   the queue, and the client sees a permanent PENDING chip. Action 8.
4. **MEDIUM: the emailed Field Portal report freezes the gap.** The print route builds its exhibit
   list from `reported && has_report_image`, so a PDF rendered during the gap permanently omits the
   DERM exhibit, and that PDF is what the client keeps. If client email sending is enabled, sequence
   it after this ships.
5. **MEDIUM: D2 above**, independent of this feature.
6. **LOW: a late attach with the wrong extension.** Live evidence is always uploaded as
   `<visit>/<run_id>.jpg` with `contentType: 'image/jpeg'`. A PNG attach must carry both the path and
   the mime.
7. **LOW: orphaned objects.** Attach-then-replace strands objects in a bucket with no DELETE policy.
   One orphan exists today. Attach-once avoids adding a second source.

**There is no re-filing risk in the attach write itself.** Neither queue view references either
evidence column, verified with positive controls.
