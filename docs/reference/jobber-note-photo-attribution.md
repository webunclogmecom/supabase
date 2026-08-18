# How a Jobber note photo finds its visit

**Fred, 2026-08-18:** *"jobber notes goes by the job, meaning if you see a note it's linked to
job, so that way i think it could be easier to know to which visit it corresponds to, because
usually when 2 visits for the same clients are close to each other, or like the same date, it
probably goes to different types of jobs, maybe 2 different SA or one of them is a SC visit.
Do a full logic for this and check it on jobber and our db too."*

He is right, it is the backbone of the whole thing, and it had never been written down. This is
the full rule, every number measured rather than reasoned.

## 1. The scoping model (proven on Jobber, not assumed)

Jobber exposes notes at `Visit.notes`, which reads like a per-visit field **and is not one**:

| note type | scope | consequence for us |
|---|---|---|
| **JobNote** | the **JOB**. Every visit of that job returns the whole job's JobNote history. | A driver photo can only ever belong to a visit **of that job**. Cross-job attribution is structurally impossible. |
| **ClientNote** | the **CLIENT**. Repeats on every visit of the client, forever. | Cannot be attributed by date at all. Skipped by the importer, shown read-only in Admin Review. |

**How it was proven.** The hardest available case: client 177-PV, two completed visits on the
**same day** (2026-03-04) on **different jobs** (163, 164).

```
visit A (job 164): 4 JobNotes + 1 ClientNote
visit B (job 163): 0 JobNotes + 1 ClientNote
shared between them: 1 note, and it is the ClientNote.   JobNotes shared: 0
```

Control, same query shape on a **same-job** pair (262-JM, visits 1461/1475, job 73): identical
note sets. So the instrument distinguishes the two cases rather than always reporting agreement.

## 2. What job scoping buys, in numbers

Completed visits, last 180 days, pairs of the same client whose dates fall inside each other's
2-day note window:

```
client pairs inside the window ........ 140
resolved outright by job scoping ......  70   (50%, different jobs, Fred's mechanism)
still ambiguous (same job) ............  70
   of which the visit_date is IDENTICAL 11
```

So half of all collisions never need a tie-break at all. That is why visit 6537 came out right
even though its photos arrived on two separate notes: the client's other visits sit on other jobs.

## 3. The residual, and why the obvious tie-breaks fail

For the 11 same-job same-date pairs:

| candidate signal | measured | verdict |
|---|---|---|
| note author vs visit crew | crews are **identical in 11 of 11** | useless here. Both visits carry the same people. |
| `visit_date` | identical by definition | an exact tie |
| **`completed_at`** | **differs in 11 of 11** (249-LOU 2026-08-14: 18:10 vs 07:07) | the discriminator |

## 4. The rule as implemented (`scripts/sync/sync_jobber_note_photos.js`)

1. Candidates come from `visit(id).notes`, so they are already job-scoped. **JobNotes only.**
2. **Eligibility:** the note's `createdAt` must be within ±2 days of `noon(visit_date)`.
   Unchanged, and deliberately still date-based (Fred's 2026-08-14 ruling on the window).
3. **Tie-break:** among eligible visits of the job, the photo goes to the one whose anchor is
   nearest the note time. Exact ties keep both links.

🛑 **The two anchors are different on purpose.** Distance uses `completed_at`; eligibility stays
on `noon(visit_date)`, computed the way each sibling will compute it on its own pass. If
eligibility were judged on `completed_at` here, a visit could hand a photo to a sibling that
then refuses it, and the photo would land **nowhere**. Losing a photo is worse than dual-linking
one.

🛑 **`completed_at` is trusted only within 24h of the visit date.** It records when someone
*marked* the visit complete, not when the work happened: of 1,072 completed visits in the last
year, **109 sit more than 24h from their own visit_date, 11 beyond a week, worst case 819h (34
days)**. Past the cutoff the anchor falls back to the date. 963 of 1,072 (90%) are inside it,
which also covers the overnight routes.

**Verified with the old body as a control** on visit 1741 (job 497, notes at 17:56 and 21:44,
matching each visit's completion exactly): old rule adds 13 photos, new rule adds 9 and hands 4
to the closer sibling. A matrix that fails nowhere is an untested instrument.

## 5. What is still wrong in the data (measured 2026-08-18, NOT yet repaired)

Photos whose own note timestamp is closer to a sibling visit than to the visit they are linked to:

| class | links | photos | source | note |
|---|---|---|---|---|
| both visits in window, sibling closer by completion time | 78 | 60 | 42 `jobber_migration`, 30 `jobber_note_sync`, 6 `jobber_late_recovery` | the tie class this fix prevents going forward |
| own visit **outside** the 2-day window, sibling inside | 2 | 2 | `jobber_note_sync` | closer by 752h; a real defect, 1 client |

Separately, photos linked to more than one visit:

```
136 photos on multiple visits
  102 span two JOBS   - ALL from jobber_migration (May), 0 since August, 0 cross-client,
                        the two visits are 0-1 days apart. Job scoping says exactly one
                        link in each pair is wrong, and Jobber can arbitrate which.
   34 within one job  - 17 migration, 11 note_sync, 6 late_recovery: the date-tie class.
```

**Nothing above has been repaired.** Existing links were left alone per Fred's 2026-08-14 ruling
("keep the ones inside the 2 day window"), and moving 60+ photos between visits changes what
appears in a customer-facing report, so it is his call, not a cleanup. The repair is
deterministic when he wants it: for each photo, ask Jobber which job holds the attachment, keep
the link on that job's nearest-by-completion visit, soft-delete the other.

## 6. Traps

- **`Visit.notes` is not per-visit.** Reading it as per-visit is how a photo lands on every
  visit of a job.
- **Never widen the importer to ClientNotes.** They repeat on every visit of the client for
  ever; a window rule on note date is a no-op because the albums carry old note dates with
  fresh attachments (21 of 23 unique August images sat outside it).
- **A pinned note is still a JobNote.** `if (n.pinned) continue` silently skipped one driver's
  photo through 13 consecutive sweeps (fixed 2026-08-18; pinned ClientNotes stay excluded).
- **The sync is add-only.** It can put a photo on the right visit but will never take it off the
  wrong one, so a fix-forward change does not heal history.
