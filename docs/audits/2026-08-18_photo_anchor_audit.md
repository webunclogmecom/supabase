# 2026-08-18 · Visit-photo attribution: the completed_at anchor, and a full pipeline audit

*Fred: "yes, do the completed_at anchor and re-run the pass. Do an audit about this, it needs to be
completely perfect, so it means that if you see anything wrong, then you need to check from the start
why is wrong, where that data comes from, why is it wrong, how is it saved in our db, how is shown in
the apps."*

**Status: the anchor is built and dry-run. THE WRITE IS HELD — see §0.** Everything below is measured
read-only against live Prod unless explicitly marked as inference.

---

## 0. 🛑 Read this first: the write is held, and the earlier "settled" claim was already stale

**@Supabase 2 is working on `public.photo_links` at this moment.** Not inferred from a claim file —
read from their transcript and confirmed in `audit.logs`:

| time (ET) | what | who |
|---|---|---|
| 14:22 to 14:25 | **30 INSERTs** into `photo_links` | `sql` |
| 14:25 | **1 hard `DELETE`** (`DELETE FROM photo_links WHERE photo_id=... AND entity_type='visit'`) | `sql` |
| 14:25 | 28 soft-deletes, reason `entity does not exist: visit <id> has no visits row` | `sql` |
| ~14:2x | new BEFORE INSERT trigger **`trg_aa_photo_link_target_exists`** created | `sql` |

Per root `CLAUDE.md` §5.1 that is Fred's to sequence, so **I have not applied anything.**

✅ **Their trigger does NOT block my write path.** It is `BEFORE INSERT` only; my pass only ever
`UPDATE`s `deleted_at` through `public.soft_delete_photo_link`. Verified by reading
`pg_get_triggerdef` and the function body, not by assuming from the name.

### And the numbers moved under me in ~40 minutes

| | my 13:48 run | measured 14:27 |
|---|---|---|
| alive visit links | 7,308 | **7,296** |
| photos holding a visit link | 7,041 | **7,040** |
| classifications | 700 | **708** |
| rows live to clients | 380 | **386** |
| duplicate candidate groups | 80 | **83** |

⇒ **"A re-run is settled, 0 to decide" was true when measured and is not true now.** Classification is
happening live (708 rows, +8), and the candidate set GREW. Any statement of the form "this is now
clean" has a shelf life measured in minutes on this table. That is §5.2b of the root `CLAUDE.md`
happening again, and it is why every number in this document carries the time it was taken.

---

## 1. 🛑 A correction I owe on my own record: every ET timestamp I wrote today was invented

I stamped tonight's claim-file entries "~20:00", "21:30", "22:15", "22:50", "23:00" ET. **The database
says it is 14:30 ET.** I never measured it; I assumed it. The rule I failed to apply is already
written down (`env_shell_tz_america_new_york_returns_utc`: the shell returns UTC even with
`TZ=America/New_York`, so ET must come from the DB).

Measured from `photo_links.deleted_at`, the real times of my own runs today:

| what | claimed | **actual ET** |
|---|---|---|
| visit 7103 unlink (7 links) | "~18:00" | **11:50** |
| August misplaced unlink (16) | "~19:00" | **13:13** |
| cleanup pass, August scope (2) | "~20:30" | **13:42** |
| cleanup pass, fleet-wide (130) | "21:30" | **13:48** |

Nothing operational depended on those stamps, but `WORKING-NOW.md` is the cross-session sequencing
channel, and a session reading "21:30" to decide whether my run preceded theirs would be reasoning off
a number I made up. The wrong stamps were left in place as the record; a correction table sits beside them.

---

## 2. NEW FINDING: 40 live photo links point at soft-deleted visits, and 37 photos are invisible

Not previously known, not in any prior audit, and a different class from the 28 @Supabase 2 fixed
today (theirs were links to visit ids with **no row at all**; these point at rows that exist and are
**soft-deleted**).

| | |
|---|---|
| alive `photo_links` whose visit has `deleted_at IS NOT NULL` | **40** |
| of those, links whose photo has **no other live visit link** | **37** |
| classified (i.e. published to a client) | **0** |
| control: healthy alive links in the same query | 7,256 |

**Where they came from.** All 6 parent visits were **`scheduled`, never `completed`** when deleted:

| visit | client | deleted | by | stranded photos | live completed visits on that job |
|---|---|---|---|---|---|
| 5758 | 180-PV | 2026-06-12 | `sql` | **19** | **0** |
| 7459 | 170-PV | 2026-07-30 | `visit-calendar` (a human) | 8 | 1 |
| 5731 | 276-BRC | 2026-06-09 | `sql` | 7 | 2 |
| 5739 | 168-AVA | 2026-06-23 | `sql` | 3 | 4 |

**Why it happens, end to end.** A scheduled visit has no photos of its own; it acquired them from the
job-scoped note fan-out (Jobber scopes notes to the JOB, so a note's photos land on *every* visit of
that job, future ones included). The visit was then cancelled upstream and soft-deleted here. **Nothing
cascades.** Enumerated all 13 triggers on `public.visits`: not one touches `photo_links`, and
`photo_links.entity_id` is polymorphic with no foreign key. So the link stays alive, pointing at a
row every app filters out.

**How it shows in the apps: it does not.** Every consumer filters `visits.deleted_at IS NULL`, so
those 37 photos render nowhere — not in the Field Portal, not in Admin Review's classifier queue.
They are not *wrong* on screen; they are absent. Only 8 of the 37 are also reachable via a `note` link.

⚠ **These are NOT safe to "clean up" by deleting the links.** For 18 of them the job still has a live
completed visit that plausibly owns the photo, so the correct repair is to re-point, not to remove.
For 180-PV's 19 the job has **no live completed visit at all**, so there is no candidate owner and the
question is upstream. **Recorded, deliberately not actioned** — it is a different operation from the
one Fred approved, and it needs its own evidence pass.

---

## 3. The change: the anchor is `completed_at`, and the rule was CALIBRATED, not guessed

### What the ground truth says

Two independent ground-truth sets were built and measured against the live Jobber API:

| set | how the true visit is known | n |
|---|---|---|
| **GT-A** | photo has exactly 1 alive link AND its job has exactly 1 alive visit, so there is nothing to misassign | **900** links / 136 jobs |
| **GT-B** | true visit fixed by **camera EXIF** read from the JPEG APP1 bytes, on jobs with MULTIPLE completed visits | **262** links / 57 jobs / 54 clients |

**The finding that decides everything: a note is created AT THE MOMENT OF THE COMPLETION TAP.**

| | GT-A (n=900) |
|---|---|
| median `completed_at − note.createdAt` | **2.2 seconds** |
| within 60 seconds | **84.2%** |
| within ±30 min | 96.8% |
| within [−2h, +6h] | 99.29% |

GT-B agrees independently (median 4.0s). And of 488 GT-A photos with readable camera EXIF, **zero
were captured after completion** — the physical order is: photo taken (median 19 min before), then
the completion tap, then the note within seconds.

⇒ The old rule asked "is the note inside `[start_at, completed_at]`?" The right question is
**"how far is this note from each candidate's completion tap?"**

### The thresholds, and why each stops where it does

| parameter | value | why this number |
|---|---|---|
| `lookback_hours` | **6** | covers 99.29% of GT-A and 100% of GT-B. Widening to 48h adds 0.55pp of coverage and roughly TRIPLES the adversarial wrong rate (0.25% → 1.09%), because a wide band lets the rule act when the nearest candidate is hours away — precisely the weak-evidence case. |
| `grace_after_hours` | **2** | **set by a hard empirical edge, not by rounding.** Of 143 correct links whose note followed completion, **141 are within 60 minutes**, and the 1–2h, 2–4h, 4–6h and 6–12h bins are **completely EMPTY**; support does not resume until 12–24h (2 links). Extending to 14h to catch those 2 would admit six hours of empty space in which only wrong answers can live. |
| `ambiguity_minutes` | **90** | a correct note sits within 30 min of its own completion 96.8% of the time, so a rival within 90 min cannot be ruled out by this signal. Lowest adversarial wrong rate in the sweep (0.247% vs 0.371% at 60 and 0.838% at 30). |

### 🛑 Two STRUCTURAL choices that matter more than the numbers

**1. Rank ALL candidates first, THEN gate the winner on the band.** Never filter candidates to the
band and choose among the survivors. That is the job-1544 failure in a new costume: excluding a
candidate makes the remaining choice look *more* certain while removing the visit that may own the
photo. Ranking first turns "the true owner is nowhere near this note" into a **decline**;
pre-filtering turns it into a confident **wrong removal**.

**2. NEW GUARD G5 — decline `ClientNote` attachments.** ClientNotes are **client**-scoped, not
job-scoped, so their `createdAt` carries no visit information at all:

| attachment kind | median distance from completion | this rule's wrong-removal rate |
|---|---|---|
| **JobNote** | **2.2 seconds** | **0.05%** |
| **ClientNote** | **13.73 hours** (IQR 7.57–23.73h) | **8.45%** |

A **160x** difference, and the guard is free: the base64 GID decodes to `gid://Jobber/<Kind>/<id>`,
so the kind is readable with no API call. This was not previously known and no earlier pass had it.

### Backtest

| set | correct | **WRONG** | declined |
|---|---|---|---|
| GT-A strict (n=900) | 89.44% | **0.083%** | 10.47% |
| GT-A all (n=1,819) | 90.00% | **0.050%** | 9.95% |
| GT-B EXIF (n=262) | 90.65% | **0.000%** (0 wrong in 5,240 trials) | 9.35% |

⚠ **An honesty point that must not be lost:** on *today's* live data, any band from 2h/1h to 48h/14h
produces **identical** decisions. The tight band buys nothing now; it buys failure behaviour later.
Adopt it for that reason, not because it changes the current outcome.

### Verified on the exact case that broke the old rule

Job 1544, one job, four notes, and the new rule points three different ways — all correct:

| note (UTC) | 6835 completed 09:38:45 | 6955 completed 16:33:09 | winner |
|---|---|---|---|
| 09:36:44 | **2 min** | 6.94h | **6835** |
| 10:24:25 | 46 min | 6.15h | **6835** |
| **16:33:02** | 6.9h | **7 SECONDS** | **6955** |
| 07-02 17:04:57 | −31h | −24h | **6989** (removed from both) |

The third row is the one the old rule got wrong: 6955's `[start_at, completed_at]` is −12.2h
(backwards), so the old G3 excluded it and handed its photos to 6835. **The new rule keeps them on
6955**, and it does so without ever consulting `start_at`.

### Live result of the dry run

| | old rule | **new rule** |
|---|---|---|
| candidate groups | 83 | 83 |
| **decided** | ~0 | **many** |
| **surplus links removable** | 0 | **96** |
| blocked by never-orphan (G1) | — | **0** |
| declines: surplus link is classified (G2) | — | 23 |
| declines: two candidates within 90 min (G4) | — | 9 |
| declines: no note timestamp | — | 2 |

**The Mila / 7757 cluster is now adjudicable**, exactly as predicted — its photos split cleanly
between 7696 and 7757 on note time, with no reference to 7757's broken slot.

---

## 4. 🛑 THE BLEEDING IS NOT STOPPED. This is the most important finding in the document.

**A cleanup that runs while a writer keeps producing duplicates is a treadmill, and that is exactly
what is happening.** Measured, with two independent instruments agreeing:

```
17:42–17:48 UTC   cleanup pass soft-deletes 132 links          (me)
18:22–18:23 UTC   the 18:00 UTC cron INSERTS links 42330/42332/42334/42336
                  photos 22954, 22955, 22974 — all from ONE Jobber note —
                  now hold ALIVE links to BOTH visit 7770 (08-17) and 7802 (08-18)
18:30:08 UTC      a second manual pass removes three of them again
```

**34 minutes.** That is the half-life of "this table is clean."

### Why the ingest still produces them

`scripts/sync/sync_jobber_note_photos.js` (every 6h) asks Jobber `visit(id){ notes }`, which Jobber
documents as *the notes attached to the associated **JOB***. Every visit of a recurring job therefore
returns the same note history. The only defence is a **±2-day window** between `note.createdAt` and
`visit_date`, added 2026-08-14.

**That window cannot separate two visits of the same job one day apart.** For the note above:
distance to visit 7802 = **59 minutes**, to visit 7770 = **23 hours**. Both ≤ 2 days, so both got a link.

**Exposure:** of 381 completed visits in the last 60 days, **48 (12.6%) have a same-job sibling within
2 calendar days.** Of 253 alive surplus links, **30 were created AFTER** the window shipped.

⇒ **The window is a coarse filter; `completed_at` proximity is a sharp one.** The rule this audit
calibrated would resolve that exact case in the ingest (59 min vs 23 h is not close). Whether to move
it there is **Fred's call** — the header of the cleanup script records a deliberate earlier decision
to over-link and adjudicate later, and that decision was taken against a *different, weaker* proposal
(one that guesses a single visit and can leave a photo with no link at all). **I have not changed the
ingest.**

⚠ **Whatever is decided, the cleanup must be SCHEDULED, not run by hand**, and its look-back must be
at least as wide as the sync's (`--days=14` on the cron, default 45).

## 5. A second live writer nobody documented as live

`scripts/migrate/jobber_notes_photos.js` lives in `scripts/migrate/`, calls itself a one-time
pre-sunset migration, and **runs every day at 12:12 UTC** via `.github/workflows/daily-notes-photos-sync.yml`.
Last write: **2026-08-18 13:16 UTC — today.** 5,090 rows.

Its visit picker (`classifyNote`, line 326) is **CLIENT-scoped, not job-scoped**:
`WHERE client_id = <client> AND visit_date BETWEEN date-2 AND date+2 ORDER BY ABS(...) LIMIT 1`.
Nothing restricts the candidate to the job the note came from, so for a multi-property client it can
attach a note's photos to a **different job's** visit. It writes exactly one link, so it cannot fan
out — **it mis-places silently, leaving no duplicate anywhere to reveal it.** That is the worse shape.

## 6. What a wrong link can actually do to a client

| question | measured answer |
|---|---|
| Rows a client can reach today | **386** (63 work orders, 48 clients) |
| Photos on 2+ visits | **182** (432 links) |
| Photos a client sees twice today | **0** — the sibling links are unclassified |
| **Unclassified links on gate-passing work orders** | **4,881** |
| If someone bulk-classified that backlog | work orders with photos **63 → 582**, clients **48 → 165**, and **35 photos would appear on two different dated work orders** |

**Classification is the publish switch** (`customer.wo_photos` INNER JOINs `photo_classifications`),
and publishing is a single INSERT that any signed-in staff account can make. So the damage is latent,
not absent, and it is one bulk action away.

### Three things worth raising on their own merits

1. **Nothing in the chain constrains client identity.** `customer.wo_photos` joins
   `photo_links → photos → photo_classifications → visits` and emits `work_order_id`, with no
   `client_id` anywhere; `customer.get_work_order` matches on work-order id alone. The only INSERT
   guard checks that the visit **exists**, never whose it is. **0 cross-client links exist today** —
   this is an empirical zero, not a structural one.
2. **A published photo URL is a permanent unauthenticated bearer token.** The `GT - Visits Images`
   bucket is `public = true`. A HEAD with no Authorization, no apikey and no cookie returned **HTTP
   200, image/jpeg, 623,694 bytes**; negative controls (bogus uuid, nonexistent bucket) both returned
   400, so that 200 is the object. **Unlinking in the DB does not revoke it** — remediating a
   mis-publish needs the storage object moved or deleted, not the link fixed.
3. **`authenticated` holds SELECT, INSERT, UPDATE, DELETE *and TRUNCATE* on all three photo tables**
   (`has_table_privilege`), with RLS enabled but `relforcerowsecurity = false` and a
   `FOR ALL USING true WITH CHECK true` policy on `photo_classifications`. Contrast `public.visits`,
   where `authenticated` holds SELECT only. TRUNCATE is not subject to RLS at all. This is the same
   shape as the `public.job_frequency_changes` defect already recorded in `Supabase/CLAUDE.md`.

## 7. Repo hygiene that makes the code lie about production

- `scripts/sync/sync_jobber_note_photos.js` has **uncommitted working-tree edits**. GitHub Actions
  checks out the committed tree, so **the deployed behaviour is not what the file on disk says**, and
  the regression the edit fixes (visit 6840 / 031-KRU losing a pinned JobNote photo) is still live.
- `docs/migrations/2026-08-18_1450_photo_links_dangling_repair_and_guard.sql` is **applied to Prod but
  untracked in git**. Its guard trigger is running right now.
- The sync's REMOVE arm is a **hard `DELETE`** that cascades away `photo_classifications` — human
  before/after markings — bypassing the soft-delete model adopted 2026-08-14. It has never fired
  (`removed: 0` on every run), so this is latent, but if it ever fires it destroys the publish switch
  with no soft-delete trail.

## 8. What I recommend, in order

1. **Sequence the collision, then apply the 96.** Verified: 0 orphan-blocked, 23 classified links
   correctly refused, G1/G2 unchanged.
2. **Schedule the cleanup** with a look-back ≥ the sync's, or it is a treadmill by construction.
3. **Decide the ingest question** (§4). The calibrated rule would fix the consecutive-day case at
   source. This is a decision, not a fix I should make unilaterally.
4. **Land the uncommitted sync edit and the untracked migration** so the repo describes production.
5. Separately, on their own merits and not as part of this change: the client-identity gap, the public
   bucket, and `authenticated`'s TRUNCATE grant.
6. **Do not "clean up" the 37 stranded photos** (§2) — 18 have a plausible owner and need re-pointing,
   19 have none.

---

*Method: six parallel read-only investigations plus direct measurement, every claim carrying its
control. Ground truth from 900 known-correct links and an independent 262-link EXIF set. Nothing in
this document was written from inference where a measurement was available, and where I inferred, it
says so.*
