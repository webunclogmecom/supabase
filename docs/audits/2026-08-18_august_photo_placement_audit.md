# 2026-08-18 · August 2026: is every visit photo on the right visit?

*Fred: "for this whole month check all the visits of all the clients we went to this month to make
sure all the photos are correctly placed." Every August 2026 visit, every image link, checked against
the two best available signals. The watermark question was explicitly dropped at his instruction.*

---

## Result

**820 image links across 106 August visits. 745 correct (91%), 41 misplaced (5%), 34 undecidable (4%).**

🛑 **Nothing wrong is visible to any client. Zero of the 41 is classified**, so zero is published to
`customer.wo_photos`. Control: 700 links are classified fleet-wide, so the join can find rows. This is
entirely latent.

| verdict | links | how established |
|---|---|---|
| correct, only one candidate visit on the job | 99 | nothing to misassign between |
| correct, confirmed by **camera EXIF** | **135** | camera timestamp falls in that visit's window |
| correct, confirmed by Jobber note time | 511 | note `createdAt` falls in that visit's window |
| **MISPLACED** | **41** | signal points at a different visit by a clear margin |
| undecidable, left alone | 34 | 22 overlapping windows, 8 within 30 min, 4 no signal at all |

## How it was measured

Two signals, strongest first, both compared against the visit's **[start_at, completed_at] window**:

1. **Camera EXIF `DateTime`** read from the actual image bytes in storage. Independent of Jobber and of
   our own linkage. Scanned all 760 distinct photos, **zero fetch failures**. Coverage: **142 (19%)**
   carry a real camera timestamp, 135 a GPS IFD, and **134 of those are the "Timestamp Camera" app**.
   So EXIF coverage is essentially one app's users.
   ⚠ `photos.exif_taken_at` was NOT used: it is Jobber's upload time, not camera EXIF.
   ⚠ EXIF is local wall clock with no zone. August 2026 is EDT, so local + 4 h = UTC.
2. **Jobber note `createdAt`**, pulled live from the API for all **91 jobs** (282 notes, 1,648
   attachments, zero failures, with a content-type guard and an 8-failure circuit breaker).
   ⚠ Our own `notes.note_date` was NOT used: it is a `now()` ingest fallback on 92.6% of
   `jobber_note_sync` rows.

🛑 **Compared against the WINDOW, never against `visit_date`.** An overnight visit starting 07-13 and
finishing 00:40 on 07-14 legitimately owns a photo stamped 07-14 00:07. Testing against the date would
reassign it and be wrong.

## The 41, and how much to trust each cluster

**⚠ 40 of the 41 rest on note timing; only 1 is EXIF-confirmed.** Note timing matches a visit
completion within 5 minutes about 80% of the time, so treat these as strong leads, not proof.

| client | links | confidence |
|---|---|---|
| **155-PV** Pura Vida Flamingo | 9 | **high.** 7770 (ends 08-17 10:06) and 7802 (ends 08-18 07:01) have clean windows, and the note times land *exactly* on those completions while the links are crossed the other way |
| **000-DH** Homestead Dump | 5 | **high.** Note times land exactly on 7469's and 7682's completions |
| **235-LOU** Skinny Louie WPB | 3 | **high**, and one is the single EXIF-confirmed case |
| **043-MIL** Mila | 24 | 🛑 **LOW. Do not act on these yet.** See below |

### 🛑 Why the Mila cluster is not trustworthy

Visit **7757 has physically impossible timestamps: `start_at` 08-14 19:45, `completed_at` 08-14 15:17.
It completed four and a half hours before it started.** A containment test can never be true for that
visit, so the 12 links that "should be 7757" were decided on nearest-distance only, with no window to
confirm them. The remaining 12 in that cluster point *away* from 7757 and inherit the same doubt,
because its window cannot be used to rule it in or out.

**Mila needs its timestamps fixed before its photos can be adjudicated.**

## 🛑 Spin-off finding: 38 visits fleet-wide have a backwards window

🛑 **SUPERSEDED BY SECTION 14 (same day). These 38 are NOT corrupt and need no upstream fix.** Our copy matches Jobber exactly on all 38; `start_at` is a scheduled slot, not a measured start, so its ordering against `completed_at` was never an invariant. Read section 14 before acting on anything below.

Not part of the photo question, and worth more than it.

| | |
|---|---|
| completed visits with both timestamps | 1,072 |
| **`completed_at` earlier than `start_at`** | **38** |
| worst case | **-44.74 hours** |
| in August | 2 (one is 7757) |
| windows longer than 24 h | 98 |

Any reasoning that uses a visit window is silently wrong on those 38. That includes this audit, and it
would include any future ownership rule built the same way.

🛑 **CORRECTED 2026-08-18: there IS no settling window any more.** Fred overruled it the same day; 48 h
is the crew posting deadline, not a send delay. Verified on deployed version 12: `SETTLING_HOURS` and the
`not_settled` gate are both gone. The original point still holds in the sense that mattered: nothing in
the send path forms a visit window, so the 38 backwards pairs cannot corrupt it. It keys on
never forms a window, so a backwards pair cannot corrupt it.

## What I would do

1. **Fix nothing yet on Mila.** Correct visit 7757's timestamps first, then re-run.
2. **The other 17 (155-PV, 000-DH, 235-LOU) are actionable**, and safe: unlinking them changes nothing
   a client sees, because none is classified. Doing it now prevents someone classifying them later,
   which is the only way this becomes a disclosure.
3. **Leave the 34 undecidable alone.** A wrong unlink deletes a client's real photo.
4. **Investigate the 38 backwards windows** as a data-integrity item in its own right.
5. ⚠ **19% EXIF coverage is the ceiling on how well this can ever be checked automatically**, and it
   is entirely down to which camera app the crew used. That is the argument for standardising the app,
   in `Building Apps/Admin Review/docs/14-jobber-photos-brainstorm.md`.

## Reproducing this

Scripts, in order, in the session scratchpad: `aug_exif_scan.js` (caches to `aug_exif.json`),
`aug_jobber_notes.js` (needs `JOBBER_TOKEN` in env, caches to `aug_jobber_notes.json`),
`aug_adjudicate.js` (writes `aug_verdict.json`), `aug_harm.js`. Both caches make re-runs cheap.

---

## 11. ACTIONED 2026-08-18: 16 unlinked, and why 7757 was NOT "fixed"

**Fred: "yes unlink the 17, and fix 7757 timestamps".** Both instructions changed on inspection, so
here is exactly what was and was not done.

### 16 of the 17 unlinked

`docs/migrations/2026-08-18_1900_unlink_misplaced_august_photos.sql`. Verified after applying:
16 soft-deleted with reason, **all 16 photos still alive on their correct visits**, 16 audit rows,
0 classified so no client sees any change.

🛑 **Link 42263 was deliberately NOT unlinked.** Photo 22954 (155-PV) has exactly **one** alive visit
link, so unlinking it would **delete a client's photo rather than move it**. Correcting it needs an
INSERT on visit 7802 followed by the unlink, which is a different operation from the one approved.
The migration carries a hard control that aborts if any photo would be left with no alive link, so
this cannot be done by accident later either.

### 🛑 7757 was NOT fixed, because the wrong value is JOBBER'S, not ours

```
OURS     start 2026-08-14 19:45:00 ET   completed 2026-08-14 15:17:48 ET
JOBBER   start 2026-08-14 19:45:00 ET   completed 2026-08-14 15:17:48 ET   end 20:45, duration 60
```

Identical to the second. **Our row is a faithful mirror of a wrong upstream value.**

And it is not a one-off. Checked **all 38** backwards visits against the live Jobber API, every one
with a Jobber link, zero query failures:

| | |
|---|---|
| also backwards in Jobber | **38** |
| sane in Jobber, so our copy drifted | **0** |

⇒ **Zero are our fault.** Writing a corrected value here would (a) invent data that contradicts the
declared source of truth, (b) most likely be reverted by the next poll, which is the documented
`jobs.frequency_days` failure mode, and (c) hide a real upstream problem behind a tidy-looking table.

**The fix belongs in Jobber, done by a person.** The shape of the error suggests either a visit
completed against the wrong occurrence, or a schedule moved after completion: 7757 is scheduled
19:45 to 20:45 yet marked complete at 15:17.

⚠ **Until they are fixed upstream, the Mila cluster cannot be adjudicated**, because 7757's window is
the thing that would rule its 24 links in or out.

✅ Restating, because it is the reassuring half: the **48 h settling window** shipped 2026-08-17 keys
on `completed_at` alone and never forms a window, so none of the 38 can corrupt it.

---

## 12. The cleanup pass, built and run on August (2026-08-18)

**Fred: "build the cleanup pass" then "run it with --since=2026-08-01 first".**

`scripts/sync/cleanup_duplicate_visit_photo_links.js`. Dry run by default; writes only with `--apply`.

### August run

| | |
|---|---|
| candidate groups | 32 (90 links) |
| decided | **2** |
| declined | 30 (26 unusable window, 4 stamp inside two windows) |
| **applied** | **2 links soft-deleted** |
| photos orphaned | **0** (both still alive on their correct visit) |
| classified links touched | **0** |
| re-run afterwards | **0 to remove**, candidate set 32 -> 30. Idempotent. |

**Both were `.mov` files.** ⚠ Worth noting: section 1 of this audit filtered `content_type like
'image/%'`, so **videos were never in it**. These two are the video counterparts of the same clusters
corrected by hand that morning (155-PV -> 7770, 235-LOU -> 7735), same visits, same direction. The
manual pass caught the images; the script caught the videos. **Any future photo audit should decide
explicitly whether it covers video, and say so.**

### 🛑 The bug the dry run caught, which is the real lesson

G3 was first written as "skip the candidate with the unusable window, choose among the rest". On job
1544 that produced a **confident wrong answer**: visit 6955's window is **-12.2 h** (one of the 38
backwards), so it was excluded, and the note timed **7 seconds before 6955's completion** was then
assigned to 6835 instead.

**Excluding a candidate made the remaining choice look MORE certain while removing the visit that
probably owned the photo.** A safety guard manufacturing a wrong answer.

⇒ **A guard that narrows the field must widen the doubt, not shrink it.** It now declines the whole
group whenever any candidate's window is unusable, which is why 26 of the 30 August declines are that
reason, and why job 1544 correctly yields nothing.

### A second silent failure, same run

The first version asked Jobber for `notes(100) x fileAttachments(100)` = 10,000 nodes, over their
query-cost ceiling. Jobber returned an error, the script correctly declined on it, and **every group
declined with "jobber did not answer"** - a total no-op that reads as "nothing to fix". Now 50/50,
with the reason recorded in the file so nobody raises it back.

### Fleet-wide, not yet run

197 groups, 117 decided, 80 declined, **132 surplus links**, 0 orphan-blocked. Awaiting Fred.

---

## 13. Fleet-wide cleanup applied (2026-08-18)

**Fred: "run it on the rest".**

| | before | after |
|---|---|---|
| alive visit photo links | 7,438 | **7,308** (-130, exactly the planned count) |
| `photo_classifications` | 700 | **700** |
| rows live to clients (`wo_photos` JOIN `work_orders`) | 380 | **380** |
| **distinct photos holding a visit link** | **7,041** | **7,041** |
| photos orphaned | | **0** |
| audit rows | | **132** (130 + the 2 from the August run) |

🛑 **The load-bearing line is the fourth.** 7,041 photos held a visit link before and 7,041 hold one
after. **Not one photo lost its place**; only duplicate links went. That, plus `live_to_clients`
unchanged at 380, is what makes this a de-duplication rather than a deletion.

**Settled state:** a re-run now examines **80 groups and decides 0**. Every remaining candidate is
declined for a stated reason:

| reason | groups |
|---|---|
| a candidate visit's window is unusable | **71** |
| the note stamp falls inside more than one window | 7 |
| no note timestamp for that attachment | 2 |

⇒ ⚠ **THE NEXT PARAGRAPH IS WITHDRAWN — see section 14.** The 71 are blocked by an adjudication rule anchored on the wrong column, NOT by upstream data awaiting a human. Original text kept as the record:

⇒ **71 of the 80 remaining are blocked by the 38 backwards visit windows**, which are wrong in Jobber
and not ours. **Fixing those upstream is what unblocks the rest of this cleanup**, including the Mila
cluster. That is now the single highest-value manual action in this area.

Nothing further can be done here automatically without either those upstream corrections or a
different class of evidence.

---

## 14. 🛑 CORRECTION 2026-08-18: the 38 "backwards" visits are NOT corrupt, and there is NOTHING to backfill

**Fred: "jobber should have the correct data, so if we need to do a backfill it should be to our db.
But first show me the list of why you think they're wrong in jobber."** Asked for the list, I
re-measured, and **the list refutes the claim it was meant to support.** Sections 11 and 13 above say
all 38 are "wrong in Jobber" and that a person correcting them upstream is the highest-value action
in this area. **That recommendation is withdrawn. Do not act on it.**

### What is actually true

| check | result |
|---|---|
| all 38 pulled live from Jobber | 38 / 38, **zero query failures** |
| our `start_at` + `completed_at` vs Jobber's, to the second | **identical on 38 of 38** |
| drifted from Jobber | **0** |
| still backwards in Jobber | 38 |

⇒ **Our copy is already a faithful mirror. A backfill from Jobber would write the same bytes back.**
There is no discrepancy to close, in either direction.

### 🛑 THE REAL ERROR WAS MINE: `[start_at, completed_at]` IS NOT A WORK WINDOW

Measured across **all 1,072** completed visits, so the 38 cannot bias it:

| | seconds `= :00` | on a quarter hour |
|---|---|---|
| `start_at` | **1,072 / 1,072** | 1,070 / 1,072 |
| `completed_at` | **17 / 1,072** | 73 / 1,072 |

`start_at` is a **scheduled slot**, machine-tidy, and `endAt - startAt == duration` on 38 of 38.
`completed_at` is a **measured tap**, ragged to the second. **They are not two ends of one
measurement**, so their ordering was never an invariant and "backwards" is not a defect class.

**A visit completed before its scheduled slot opened is an ordinary thing**: the crew went early, or
the slot was dragged later afterwards. Confirmed in `audit.logs` — the slot moved *after* completion:

```
7757  08-14 14:30  app_source=jobber                            08-13 15:30 -> 08-14 17:45  (scheduled)
7757  08-14 17:17  app_source=jobber-daily-completion-reconcile 08-14 17:45 -> 08-14 19:45  (already COMPLETED 15:17)
6592  07-01 07:39  app_source=sql                               06-30 04:15 -> 07-01 04:15  (already completed)
6592  07-02 07:09  app_source=sql                               07-01 04:15 -> 07-02 04:15  (already completed)
```

`scripts/sync/cron_jobber_reconcile_completion.js` reads `visit(id:){ startAt endAt completedAt }`
and writes `start_at = jbVisit.startAt`. **It is a pure mirror**, which is why drift is zero: the
value moved in Jobber and we copied it.

### Severity, so nobody treats 38 as 38 problems

| gap | visits |
|---|---|
| under 1 hour | **9** |
| 1 to 6 hours | 20 |
| 6 to 24 hours | 6 |
| over 24 hours | **3** (6592 -44.7h, 5160 -43.4h, 5837 -26.0h) |
| flagged `allDay` in Jobber | 3 |

29 distinct clients, Jan to Aug. **Only the top 3 are odd enough to be worth a human glance**, and
even those are most likely a completed visit whose schedule was rolled forward afterwards.

### Does Jobber hold a better start time? No.

`Visit.timeSheetEntries` exists and carries `startAt` / `endAt` / `finalDuration` — real work times.
**The 38 have zero entries.**
⚠ **My first control was confounded and I nearly shipped it as a finding.** Sampling the 25 *most
recent* completed visits gave 11/25 with entries, which looks like a stark contrast — but timesheet
use is recent and the 38 span January onward. **Date-matched** (one normal completed visit nearest
in time to each of the 38): **2 / 38 vs 0 / 38.** No real difference. Nobody used the timer in that
era, so there is no actual-start value to import.

### What this means for the cleanup pass

`cleanup_duplicate_visit_photo_links.js` declines **71 of its 80 remaining groups** on G3 ("a
candidate visit has an unusable window"). **G3's behaviour is still correct** — declining is right —
but its stated reason was wrong, and so was the conclusion drawn from it. **The 71 are not blocked
by bad upstream data waiting on a human. They are blocked by an adjudication rule anchored on the
wrong column.**

⇒ The improvement is to anchor on **`completed_at` alone**, which is the measured signal, instead of
containment in `[start_at, completed_at]`. **Not built** — recorded here rather than shipped,
because it changes what the pass would remove and that is Fred's call.

### The lesson, which is the one this workspace keeps relearning

Every number in sections 11 and 13 was **right**. "38 backwards", "38 also backwards in Jobber",
"0 drifted" — all still reproduce today. **The sentence wrapped around them was wrong**: I read a
structural property (`completed_at < start_at`) as a defect without ever asking what the two columns
*are*. Same shape as `customer.work_orders`' DERM filter, and the same fix would have worked —
**one question about intent, before the recommendation.**
