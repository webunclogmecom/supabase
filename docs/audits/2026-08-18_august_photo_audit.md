# 2026-08-18 · August photos vs Jobber: audit, adversarial review, and what shipped

**Fred:** *"do an audit about this month all visits check their pictures in jobber to make sure
it's correct what we have ... once you have a plan made, review that plan again and the data too,
so you are double sure that's the way to go, and do it."* Triggered together with Yannick's URGENT
([Slack](https://unclogme.slack.com/archives/C0BD3VDPB9S/p1787070293163449)) on visit 6537.

Instrument: `scripts/probes/audit_august_photos_vs_jobber.js`, read-only, one Jobber query per job
(144/144 fetched, complete; positive control on 6537's job passed). The plan was then attacked by a
3-lens adversarial review (29 findings) before anything below was executed. **Four of those
findings changed the fixes materially** — they are marked ⚠REVIEW.

## Headline: 139 of 166 August visits match Jobber exactly

The 27 with findings decompose into classes with different owners:

| class | pairs | unique photos | verdict |
|---|---|---|---|
| never-imported, in-window, **JobNote** | 14 | 13 | 11 = same-day sweep latency (imported by the 18:21Z run, verified per-visit); 1 = **pinned-note skip** (fixed tonight); 1 = double-counted by overlapping windows |
| never-imported, in-window, **ClientNote** | 36 | 23 | skipped **BY DESIGN** — decision item for Fred below |
| in-window but linked to a different visit | 27 | — | overlapping ±2d windows of back-to-back visits; 56 ambiguous pairs existed; tie-break shipped tonight |
| our links not on the job's notes | 12 | — | 9 sit on jobs where the probe's attachment page truncated (likely artifacts); 6840's 3 remain the only real suspects — human list |
| "window orphans" | 425 | — | 399 ClientNote (albums); the probe windows only August visits, so this is "unattributed on the job", **not** "lost" |
| same-note late additions | 270 | — | 266 ClientNote (albums, p50 gap 78 days). **JobNote: 4 all August** — Yannick's hypothesized mechanism is essentially extinct since the 08-14 attachment-diff fix |

⚠ The probe over-approximates what the sync can see (it accepts attachment-time OR note-time and
never modelled the pinned skip), so "missing" is an upper bound. 8 jobs had truncated attachment
pages (first:20); their "clean" verdicts are unverified. Both caveats are ⚠REVIEW findings.

## Root causes, each proven not guessed

1. **Sweep latency** (Yannick's 6537, and the whole 08-18 cluster): photos posted between 6h runs
   are invisible up to 6h. His "added later to the same note" hypothesis described a real bug —
   **fixed 2026-08-14** (attachment-level diff); what he saw was the gap between runs.
2. **The pinned-note skip**: `if (n.pinned) continue` sat in the sync since its first commit with
   no written rationale. Visit 6840's driver note ("3 manholes, located at front of the
   restaurant", WITH the photo) was pinned — skipped by **13 consecutive sweeps** while every
   condition for import held. ⚠REVIEW found it by asking why a targeted re-run of the same code
   would help; the audit could not see it because the probe never fetched `pinned`.
3. **The dual-link generator**: two completed visits ≤4 days apart both satisfy the ±2d window, and
   the sync processed visits independently — the 18:21Z sweep attached 3 photos to BOTH 155-PV
   visits **minutes after the review predicted it would**.
4. **28 dangling links, not 14**: alive `photo_links` rows pointing at visits that do not exist —
   1795 (14), 4326 (4), 4717 (10). ⚠REVIEW re-measured what the attribution audit's "all other
   visit links resolve" line asserted; that line was wrong (correction noted there).
5. **NULL property_id**: 99 of 166 August visits (59.6%) — every city email for one rendered
   "Address not on file" in a regulator-facing subject. The NULL factory was
   **`fn_generate_sa_visits`**, whose INSERT omitted `property_id` (677 future rows), not
   `handleVisit` as the draft plan said (⚠REVIEW).

## What shipped tonight (all verified live)

| change | where | verification |
|---|---|---|
| 48h send gate removed (Fred's ruling: photos present + classified ⇒ send now) | `send-visit-photos-email`, `acad0fc` | visit 6995 sent 11h inside the old window |
| Driver notes on the review page | Admin Review (2 builds, published) | /review/6537 renders the driver's lock-box note |
| Pinned **JobNotes** now import (pinned ClientNotes still excluded) | `sync_jobber_note_photos.js` | targeted run imported 6840's photo (+1, now 11 images) |
| Nearest-visit tie-break on ADD (strictly closer sibling wins; exact ties keep dual) | `sync_jobber_note_photos.js` | tonight's 3 fresh duals cleaned: 7770→1 image, 7802 keeps 10 |
| 28 dangling links soft-deleted, then a BEFORE **INSERT** existence guard | `2026-08-18_1450` | 0 dangling remain; dead-visit insert blocked; legitimate insert + soft-delete both proven (guard is INSERT-only ⚠REVIEW — an UPDATE guard would have made the repair itself impossible) |
| Property backfill (1,269 alive visits) + generator carries `property_id` | `2026-08-18_1520` | August: 0 NULL-property visits remain; fleet: 22 honest NULLs (job has no property); the row-corridor guard caught a missing `deleted_at` filter on the first apply |
| Hourly hot-window sweep (`30 * * * *`, `--days=3`) alongside the 6h full sweep | `jobber-note-photo-sync.yml` | ⚠REVIEW: a scheduled run cannot read dispatch inputs, so days branches on `github.event.schedule` — without that the hourly run would silently do the full 14-day sweep 24×/day |
| Audit probe fetches `pinned`, notes truncation, splits by noteType | `audit_august_photos_vs_jobber.js` | v2 run 144/144 |

Worst-case photo invisibility drops from ~6h to ~1h, and the mechanism that made 6537 confusing is
labelled in the app (Reopened + driver notes).

## Decision items for Fred (deliberately NOT implemented)

1. **ClientNote photos — 23 unique images in-window this month.** Drivers/office use client notes
   as albums (399 unattributed on these jobs). The importer skips them by design because client
   notes repeat on every visit of the client. ⚠REVIEW: "import them with the window rule" is a
   NO-OP as stated — ClientNote albums carry years-old note dates with fresh attachments, and the
   sync windows on NOTE date (21 of 23 unique images sit outside it). Honest options:
   (a) keep skipping and tell reviewers client-note photos live in Jobber only;
   (b) window ClientNotes on **attachment** date — a mechanism change (query + rule), photos
       arrive tagged internal/extra;
   (c) show them read-only from Jobber in the app without importing;
   (d) change crew behaviour: photos go on JOB notes.
2. **The skip-table / "photos await manual attach" queue** (P3): keyed on attachment gid with a
   resolution lifecycle and a one-time seed of the historical backlog (⚠REVIEW: as first drafted
   it would have shipped empty of its motivation and fanned out 24×/day). Design settled, not built.
3. **The client-match guard on photo_links** (P4b): `photos` has **no client column**, so the
   "photo's client = visit's client" predicate is undefined as drafted, and RLS binds none of the
   importers (they write as postgres/service_role). Needs either `photos.client_id` (rule 1–3
   review) or a trigger deriving the client via the sibling note link. Architecture call.
4. **"Refresh from Jobber" button** (P2): edge fn firing the existing `workflow_dispatch`; needs
   the GitHub PAT as a function secret, an authenticated-role assertion (verify_jwt is half a
   gate), and run-id polling. UX sugar now that the hourly sweep exists.

## The human list (small, bounded)

- 6840's 3 `extra_not_on_job` links: attachments absent from the job's notes today — Jobber-side
  deletion vs cross-job stapling; re-fetch that note with a full attachment page first.
- The 9 truncated-page "extras" on 6617/7692/7695: probably artifacts; same re-fetch resolves.
- 8 jobs with truncated attachment pages: re-probe to convert "clean (unverified)" to "clean".

Raw reports (client codes inside, so scratchpad-only, not committed): `august_photo_audit{,2}.json`
in the session scratchpad; regenerate any time with the probe.
