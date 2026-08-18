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

✅ **The 48 h settling window shipped 2026-08-17 is NOT affected**: it keys on `completed_at` alone and
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
