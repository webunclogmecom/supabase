# 031-KRU job-split reconciliation (Grease Trap ↔ Lift Station)

**Date:** 2026-06-30 (ET 2026-06-29 at execution) · **Client:** 031-KRU Krudo Fish Market (id 368) · **Author:** Claude (Fred-directed)

## Why
Fred split the bundled Jobber job **#99900557** ("Grease Trap & Lift Station Pumping & Tank Cleaning",
freq 30, line items 02+04) because the Lift Station needs a different cadence. After his Jobber edits the
live state was: **#99900557 → "Lift Station & Tank Cleaning" (item 04, freq 21)**, **#99900971 → "Grease
Trap Pumping…" (item 02, freq 30)**, #99900558 → Aux Cleaning (item 06, freq 21, unchanged). The DB hadn't
caught up — no `JOB_UPDATE` webhook fired for #557 and the jobs poll's `createdAt` cursor never re-pulls an
old job (see `reference_jobs_sync_gaps`). `handleJob`/`reconcile_jobs.js` (daily 09:00 UTC) are the
canonical catch-up and read Jobber-live, so the manual sync below is corrective and durable.

## Decisions (Fred)
- GT freq = 30 (Fred set the Frequency custom field on #99900971).
- Keep the existing ~30-day series as the **GT** series → re-home to #99900971, preserve dates.
- New **Lift Station** series @21 on #99900557, **co-scheduled** with the existing Aux @21 series.
- Today's/imminent Jun30 GT visit (6605, timed) left as-is on the now-LS job #557.

## What changed (Prod `wbasvhvvismukaqdnouk`)
**Step A — job 1304 (#99900557) sync:** `frequency_days 30→21`; title → "Service Agreement - Lift Station &
Tank Cleaning"; dropped the `02` line item (kept `04`). app_source='sql' (jobs/line_items are NOT audited).

**Step B — re-home GT series to job 1722 (#99900971), dates preserved:**
- Inserted Jul30 GT replacement on 1722 first (scope floor) → created in Jobber under #971.
- Soft-deleted 6606 (old Jul30 under #557) → Jobber `visitDelete` succeeded (visit gone). NOTE: the edge fn
  marked it `sync_state='failed'` and skipped the unlink because `visitDelete` returned a userError (likely
  "Visit not found" from a duplicate delivery — `jobber-push-visit/index.ts:216-218` throws on ANY userError).
  Manually unlinked + set confirmed. **Follow-up: make the delete path idempotent.**
- Re-homed 6607–6611 (DB-only, beyond 60d horizon) via `job_id`+`title` together → settled DB-only (promote later).

**Step C — generate LS series on 1304:** `generate_service_agreement_visits.js --client=031-KRU --execute`
inserted 8 LS visits (Jul21, Aug11, Sep1, Sep22, Oct13, Nov3, Nov24, Dec15), service_type GT (code 04 →
service_type NULL → COALESCE default 'GT'), derm_required=true. In-horizon (Jul21/Aug11) pushed to #557.

## Verification
- All touched rows `sync_state='confirmed'`; 0 `failed` for the client.
- Jobber #557 = {Jun30, Jul21, Aug11}; #971 = {Jul30}; in-horizon GT/LS carry GIDs; rest DB-only.
- DERM preserved on both series (codes 02 & 04 both `requires_derm=true`; rederive is monotonic).
- Pre-flight gated on a live read-only Jobber confirm of #557=21/Lift-Station/[04] & #971=30/[02].
- Plan was adversarially reviewed (4-lens workflow, GO_WITH_CHANGES); all required changes applied.

## Open items
- **6605 (Jun30 GT visit)** sits on the LS job #557 (Fred: leave today's). One visit where Grease Trap shows
  under the Lift Station job. Can re-home (delete+recreate, timed 10:15 ET) if desired.
- **Edge-fn delete idempotency** (separate task): `visitDelete` returning a not-found userError marks
  `failed` + skips unlink even though the visit was deleted.
- LS @21 co-schedules with Aux @21 on 8 dates (intended — Fred confirmed). Default trucks differ (LS=1, Aux=2).
- Acceptance: next 09:00 UTC `reconcile_jobs` + 10:00 UTC sa-gen are self-checking (Jobber is authority, already correct → corrective, not reverting).
