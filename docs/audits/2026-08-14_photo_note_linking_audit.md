# 2026-08-14 — how Jobber notes become visit photos, audited across all three writers

Fred: *"We need to do an audit about the logic of how us read the notes in the jobs on jobber to get
the images and cross-reference them to the visits, because i say in the Admin review app a visit with
images from the visits of the whole month, which i thought the images were linked by a couple of days
not the whole month."*

**Fred is right about the rule and right about what he saw. Both are true, because the "couple of
days" rule and the writer producing the month are different pieces of code.**

Supersedes the root cause in [`2026-08-13_admin_review_photo_visit_mislinking.md`](2026-08-13_admin_review_photo_visit_mislinking.md).
**Nothing has been changed.** Read-only audit.

---

## 🛑 The mechanism: Jobber's `Visit.notes` is JOB-scoped, not visit-scoped

Jobber's own schema describes the field verbatim as **"The notes attached to the associated job"**,
typed `JobNoteUnionConnection` (captured in `docs/audits/2026-06-03/112ya_jobber_probe_v2.json`).

**Confirmed live against the API on 2026-08-14**, two visits of job 1720 six weeks apart:

```
visit 6826  (2026-06-27)   notes=16   attachments=42
visit 7743  (2026-08-10)   notes=16   attachments=42
notes on BOTH visits ........ 16 of 16
attachments on BOTH visits .. 42 of 42
```

Identical. So asking Jobber "what notes are on this visit?" returns the **whole job's** note history,
and for a recurring Service Agreement that is every visit, forever.

⚠ **This corrects the 2026-08-13 audit**, which blamed inherited **Client**Notes. The ClientNote
filter (commit `4d69719`, 2026-07-01 21:47 UTC) works and is irrelevant: the offending writer's first
link landed ten minutes later, so **100% of its output was produced with that filter in place**.

---

## The three writers

| script | matching rule | window | status | blame |
|---|---|---|---|---|
| `scripts/sync/sync_jobber_note_photos.js` | none: staples every JobNote attachment onto whichever visit the loop is on (`:158`, `:200`) | **NONE** | **LIVE**, every 6h | **PRIMARY** |
| `scripts/migrate/jobber_notes_photos.js` | note's `createdAt` → nearest visit within ±2 days (`:313-329`) | **±2 days, honoured** | LIVE, daily 12:12 UTC | **exonerated** |
| `scripts/migrate/recover_visit_note_photos_window2d.js` | same shape as the sync, but does compare note date to visit | ±2d, **bypassable** | DORMANT, manual | historical, 855 links on one afternoon |

### Why the live sync has no window, in the strongest sense

It is not that someone forgot a date check. Its GraphQL selection (`:133-136`) **never requests
`createdAt`** on the note or the attachment, so no date ever reaches the script. Both sibling scripts
do request it. The entire matching rule is one line:

```js
// :158  — "it is a JobNote" and "this visit doesn't have it yet". That is all.
const toAdd = [...curAtt.keys()].filter(g => curAtt.get(g).noteType === 'JobNote' && !ourByGid.has(g));
// :200
INSERT INTO photo_links (photo_id,entity_type,entity_id,role) VALUES (${photoId},'visit',${t.visit_id},'other')
```

`t.visit_id` is the loop variable. `ON CONFLICT DO NOTHING` makes each insert idempotent, which is
exactly why this never errored: every run legitimately adds a genuinely **new** (photo, visit) pair.

🛑 **`--days=14` is NOT a window.** It selects which visits to refresh (`:111`). It limits work per
run; it limits nothing about which photos land. Because it slides forward every 6 hours, the same
unchanged job note is re-offered to each newly completed sibling visit. **The effective reach is the
life of the job, not 14 days.**

### 🛑 The metric that looks exonerating and is not

`link.created_at − visit.visit_date` for this writer is **tight**: p50 = 1 day, 79% within 0-2 days.
That is **scheduler latency, not a window**. The job links a visit within hours of it completing, so
the link is always ~1 day after the *visit*. The *photo* can be a month old. The metric holds the
visit fixed and never asks how far the photo is from it. Do not quote it as evidence of a window.

---

## The evidence, with controls

**Exhaustive job-sibling coverage.** Of the 690 multi-visit photos stamped `jobber_note_sync`,
**690 (100.0%)** are linked to *every* completed sibling visit of their job between their first and
last linked date. Zero gaps.
*Control, same query:* `jobber_migration` 475/739 exhaustive (64%), `jobber_late_recovery` 140/235
(60%). The query detects gaps where they exist, so 100% is a real signature.

**It is job-level, not client-level.** For `jobber_note_sync`, photos spanning more than one job:
**0 of 690**. Cross-client: **0**.
*Control:* the same query returns **130** cross-job photos for `jobber_migration`.

**April and June are the natural control.** The daily migration ran alone through both months and
produced **zero** duplicate links. The entire problem starts **2026-07-01**, when the 6-hourly sync
went live.

```
2026-04    0 surplus links      2026-07   1,775 surplus
2026-05  855 surplus (one-off)  2026-08     825 surplus (14 days in)
2026-06    0 surplus
```

**The accidental experiment that settles it.** Commit `88cfef9` switched the recovery script from
`client.notes` to `visit.notes` **mid-run** on 2026-05-01. The 294 links made *before* the switch
have **zero** fan-out; the 988 made *after* produced **140** fanned photos. **The endpoint everyone
assumed was safe is the one that broke.**

**Scale today:** 3,455 surplus links on 1,794 photos. Median multi-visit photo spans **32 days**, max
161, one photo on 19 visits. 66 visits show a photo set spanning over 30 days.
*Control:* 795 of 941 photo-carrying visits span exactly 0 days, so most visits are still correct.
**Still bleeding at roughly 60 links a day**; newest created 2026-08-14 12:47 UTC.

Fred's screen, most likely: **visit 6503** (214-MYK, 2026-08-13) shows 27 photos spanning 49 days,
only 2 within 2 days of the visit. **Visit 6502** (same client, 2026-08-07) shows the *same 27-photo
reel* — the duplication visible on one screen.

---

## 🛑 A separate landmine found in the same file

`scripts/sync/sync_jobber_note_photos.js:210`

```sql
DELETE FROM photo_links WHERE photo_id = ${r.photo_id}   -- no entity_type, no entity_id
```

One visit deciding a photo is removable would delete that photo's link on **every other visit** plus
its note anchor, and `:209` does the same to all its classifications. It has **never fired** (0
removals across 151 logged runs; control in the same row: 4,089 adds) but only because the trigger
condition is currently unreachable, **not** because any guard prevents it. Scope both statements to
the visit being processed. This is worth fixing regardless of everything else.

---

## Recommended order, and what needs sign-off

1. **Stop the bleeding.** Comment out the `schedule:` cron in
   `.github/workflows/jobber-note-photo-sync.yml`, keep `workflow_dispatch`. Reversible, touches no
   data, and the daily migration keeps importing photos.
2. **Enable a window.** Add `createdAt` to both note fragments in the query at `:133-136` and store
   it, replacing `note_date = now()` at `:183`. **Today the script destroys the only date signal on
   the 2,434 photos it created**, so "add a ±2 day window" is not implementable until this lands.
3. **Then the window itself**, gating `:158` on note date vs visit date, matching what
   `jobber_notes_photos.js` already does.
4. **Scope the DELETE** at `:209-210`, independently of all of the above.

### 🛑 Deleting the 3,455 surplus links needs Fred's explicit sign-off, and is worse than it looks

- `photo_classifications_photo_link_id_fkey` is **ON DELETE CASCADE**. Deleting a link silently
  destroys the classification with no second statement: **140 classifications**, 86 photos losing
  every classification, including **72 deliberate "internal, do not show the customer" markings**.
- `customer.wo_photos` INNER JOINs classifications, so **68 of the 399 photos the Field Portal serves
  disappear** and **3 client work orders go to zero**.
- In Admin Review, 205 visits lose photos and 44 completed visits go to an empty gallery.
- **Not cleanly reversible.** `photo_links` has no audit trigger, and its `id` is
  `GENERATED ALWAYS AS IDENTITY`, so a restore needs `OVERRIDING SYSTEM VALUE` or it mints new ids,
  orphaning every restored classification and changing the customer-facing id
  (`customer.wo_photos.id` is derived from `pl.id`).
- **Order matters, and it is a decision:** 757 of the deletions are on visits inside the sync's own
  14-day window. If the sync is still scheduled they **return within 6 hours as new link ids with no
  classification**, while the classifications stay permanently dead. For that slice, cleaning before
  fixing the writer is strictly worse than doing nothing.
- ⚠ A cleanup must run as `service_role`/`postgres`. `authenticated` holds the DELETE **grant** on
  `photo_links` but has **no DELETE policy**, so a cleanup run as `authenticated` deletes nothing and
  reports success.

**The business question underneath it:** is "one photo on several visits" ever legitimate? In the
current data it never is (0 photos link both a visit and a manifest, 0 both a visit and an
inspection; control: 4,057 link both a visit and a note). But that is a measurement, not intent, and
the standing rule is to ask rather than deduce what something is FOR.

## Still unresolved

- **Link authorship is inferred, not recorded.** `photo_links` has no source/author column.
  `photos.source` labels who created the **photo**, not each **link**, and the sync reuses existing
  photo rows (`:189`). The fingerprints used each carry a passing control, but any per-writer count
  built on `photos.source` alone mis-attributes recent activity.
- **126 surplus links (111 July, 15 August) do NOT land on the photo's home job** (same client,
  different job). Job inheritance does not explain those.
- **158 surplus links sit within 2 days of their visit and may not be wrong at all.** Two visits of
  one job days apart could legitimately share a photo set. "Nearest wins" would pick one at random.
- **All damage figures are floors.** 5,134 of 11,100 visit-linked photos have no `exif_taken_at`, and
  **0%** of the 2,434 photos the live sync created have one.
- **`notes.visit_id` is also mis-attributed** for all 287 notes the sync created (`:183` records
  whichever visit it iterated first). Deleting photo_links does not fix that.
- Whether the audit trigger on `photo_classifications` fires on a CASCADE delete was not probed. One
  rolled-back transaction settles it, and it decides whether a bad cleanup is reversible.
