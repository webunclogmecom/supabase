# 2026-08-13 — Admin Review: photos showing on the wrong visit. Root cause found, LIVE and ongoing

> 🛑 **SUPERSEDED ON THE ROOT CAUSE, 2026-08-14. READ
> [`2026-08-14_photo_note_linking_audit.md`](2026-08-14_photo_note_linking_audit.md) INSTEAD.**
>
> The numbers here hold. **The mechanism named below is WRONG.** This document blames *inherited
> **Client**Notes*. The real cause is **JOB-level** inheritance: Jobber's `Visit.notes` field is
> documented by Jobber as *"The notes attached to the associated job"*, so every visit of a
> recurring job returns that job's entire note history.
>
> The ClientNote filter I pointed at was added in commit `4d69719` on 2026-07-01 21:47 UTC and it
> **works**. The offending writer's first link landed ten minutes later, so **100% of its output was
> produced with that filter already in place**. Anyone reading only this file would "fix" a filter
> that is already correct and change nothing.
>
> Confirmed live against the Jobber API on 2026-08-14: visits 6826 (2026-06-27) and 7743
> (2026-08-10), two visits of job 1720 six weeks apart, return an **identical** note set, 16 notes
> and 42 attachments, all shared.

Fred: *"I see a lot of them that have pictures from others visits, so we need to do a full audit
about that."*

**He is right, it is worse than it looks, and it is still happening.** The Admin Review app is
innocent: its query is correctly visit-scoped. The **data** is wrong. A scheduled sync attaches one
note's photos to every visit of the client, so a photo taken once reappears on visit after visit.

**Nothing has been changed.** This is the audit only; the fix and the cleanup both need a decision.

---

## The numbers

```
visit-linked photo_links ................ 11,168   across 950 visits
photos linked to MORE THAN ONE visit .... 1,819    across 355 visits
links involved .......................... 5,249
photos spanning DIFFERENT CLIENTS ....... 0        <- the one piece of good news
duplicate links created in the LAST 14 DAYS  925   <- ONGOING, not historical
```

93% of the cross-linked photos land on **sibling visits of the same job**, and **1,743 of them span
different dates** — 916 by more than a month.

## The app is not at fault

Read from the live bundle at `admin.unclogme.app` (`index-BpffYTBm.js`), the visit-detail fetch is:

```js
await supabase.from("photo_links").select("id, role, photo_id, caption")
  .eq("entity_type","visit").eq("entity_id", visitId)
```

Correctly scoped to one visit. My first hypothesis was that the app fetched by **job** (the route is
`/review/:jobId`, and 213 jobs have more than one photo-bearing visit, which would have
cross-contaminated exactly this way). **That hypothesis is refuted by the bundle.**

## 🛑 Root cause: Jobber returns INHERITED client notes as if they were the visit's own

`scripts/sync/sync_jobber_note_photos.js`, run **every 6 hours over a 14-day window** by
`.github/workflows/jobber-note-photo-sync.yml`, iterates completed visits, asks Jobber for that
visit's notes, and links every attachment it finds:

```js
INSERT INTO photo_links (photo_id, entity_type, entity_id, role)
VALUES (photoId, 'visit', t.visit_id, 'other')
ON CONFLICT (photo_id, entity_type, entity_id, role) DO NOTHING
```

**Jobber's `JobNoteUnion` includes inherited ClientNotes.** The sibling script says so in its own
comment: *"Notes can surface twice: via client.notes AND via job.notes (Jobber's JobNoteUnion
includes inherited ClientNotes)."* So "the notes on this visit" silently includes notes belonging to
the client as a whole, and their attachments get stamped onto whichever visit is being processed.

The `ON CONFLICT DO NOTHING` makes each individual link idempotent, which is why this never errored
and never looked broken: each run legitimately adds a *new* (photo, visit) pair.

### The signature that proves it

```
photos on >1 visit ...................... 1,819
  with exactly ONE note anchor .......... 1,775   (97.6%)  <- one note, many visits
  with no note anchor ....................     9
  with more than one note ...............    35
```

One note cannot legitimately belong to nineteen visits.

### Worked example, photo 19984

Taken **2026-06-28**. It has **one** note link (note 3249) and **nineteen** visit links, all on job
1720, added roughly a day after each subsequent visit completed:

```
06-28 10:31 -> visit 6826 (2026-06-27)      07-25 09:04 -> visit 7322 (2026-07-24)
07-01 19:31 -> visit 6828 (2026-06-28)      07-27 05:34 -> visit 7372 (2026-07-26)
07-01 19:33 -> visit 6856 (2026-06-30)      07-28 15:10 -> visit 7412 (2026-07-27)
07-05 09:13 -> visit 7051 (2026-07-04)      07-29 04:24 -> visit 7413 (2026-07-28)
07-05 22:11 -> visit 7015 (2026-07-05)      08-03 10:19 -> visit 7469 (2026-08-02)
07-07 05:27 -> visit 7056 (2026-07-06)      08-04 21:44 -> visit 7682 (2026-08-04)
07-16 03:57 -> visit 7094 (2026-07-15)      08-07 14:43 -> visit 7691 (2026-08-06)
07-16 21:49 -> visit 7106 (2026-07-16)      08-11 02:49 -> visit 7743 (2026-08-10)
07-18 08:53 -> visit 7123 (2026-07-17)      ... and 2 more
```

A June photo is on an August visit. That is precisely what Fred is seeing.

## ⚠ Why the EXIF check is NOT the instrument to fix this with

The obvious test is "photo timestamp far from visit date":

```
same day 1,816 (30%) · 1 day 3,052 (51%) · 2-3d 140 · 4-14d 179 · 15-90d 677 · >90d 102
```

**Do not treat the 1-day bucket as drift.** Overnight commercial routes run ~8 PM into ~6 AM and
`visit_date` is the ET clock date of `start_at`, so a legitimate photo routinely carries the
neighbouring date. And **5,134 of 11,100 visit-linked photos have no EXIF at all**, so an
EXIF-based cleanup would silently skip 46% of the population. The note-anchor signature is the
sound instrument here; EXIF is not.

## What I have NOT done, and the two decisions

**Nothing was changed.** No link deleted, no workflow disabled.

1. **Stop the bleeding.** The sync needs to link an attachment to a visit only when the note is
   genuinely that visit's, not inherited. Options: filter to notes whose Jobber anchor is the visit
   (not the client), or refuse to link a note whose own date is outside the visit's window.
   ⚠ Until then the 6-hourly job keeps adding, currently ~925 links per 14 days.
2. **Clean up the 5,249 existing links.** This is a **DELETE of business data** and needs explicit
   sign-off. The defensible rule is: for each photo with one note anchor and many visit links, keep
   the visit link that matches the note's own date and drop the rest. That is derivable and
   reversible (`photo_links` is small and the photos/storage are untouched), but it is destructive
   and **`public.photo_links` has NO audit trigger** (confirmed: zero triggers on that table), so a
   delete would leave no trail. **Snapshot to a backup table first.**

🛑 **Deleting a `photo_link` also destroys its classification.** `photo_classifications` is keyed on
`photo_link_id`, and the sync's own remove path already does
`DELETE FROM photo_classifications WHERE photo_link_id IN (...)`. So the cleanup discards Yannick's
work on those photos. Count it before deciding.

## Side note that affects the "must classify everything" complaint

The queue counts a photo as classified from **`photo_links.role`** (`before`/`after`/`completion`/
`extra`), while the classifier writes **`photo_classifications.service_phase`**. Two different
sources of truth for "is this classified". Worth confirming which the save-gate reads before
changing that behaviour.
