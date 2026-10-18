# Decided plans: built or not

Fred, 2026-10-17 ("go ahead with all of them"): *decided plans get tracked until they're built, so a decision
like Aug 27's can't quietly sit unbuilt.* The 2026-08-27 multi-GDO stamp plan was agreed, written, never built and
patched by hand for seven weeks. The rule for every session is in the root `CLAUDE.md`, section 7.

**How to use this file**
- When Fred agrees a plan (picks a mockup, answers its questions, says "go ahead"), add a row in the same turn:
  date, his words, the spec, what is to be built.
- When it ships, move it to "Built" with the migration or commit. A spec existing is not "built"; a hand repair of
  one record is not "built".
- Before telling Fred something is done, read the rows for that area.
- Re-audit: one read-only checker per few specs (spec -> live catalog, migrations, changelogs), as on 2026-10-17.

First filled 2026-10-17 from an audit of 35 specs and plans (6 read-only checkers; evidence in each row's spec and
the session scratchpad). Counts and states below are dated observations: re-measure before acting.

## 1. Needs attention now (found by the 2026-10-17 audit, verified)

| what | evidence | who |
|---|---|---|
| **226-JER Jerusalem Pizza is past its permit limit.** GDO-03256 allows 60 days; last service 2026-08-17 (61 days on 10-17); nothing booked, no To Be Scheduled item. Its agreement was closed 2026-10-05 and the call-first reminder that should replace it (spec 2026-08-17) was never built. | visits, gdos, ops.visit_requests | office (Diego) |
| **The GDO bot filed 3 Broward-dump visits with Miami-Dade without their manifest sheet.** `rpa-derm-queue` attaches only `derm_address_url` (+ the receipt); a Broward-dump visit's sheet lives in `derm.manifest_visit_sheets`, so it was never sent. Visits 6218 (Oct 8), 8089 and 6721 (Oct 16), all SUCCESS. | `derm_portal_submissions` 2008, 2015, 2016 | Fred / Jonathan |
| **ticket-836361 has been completed since 2026-10-01 and one client's document was never published.** `derm.v_blackout_completed_unpublished` shows it; nothing reads that view. | the view | Supabase session |
| **3,106 DERM documents are still in public storage, and the number grows** (2026-09-27 plan: only Stage 0 was approved; Stages 1-11 wait on 13 decisions). | storage census by the audit | Fred |

## 2. Agreed, not built (or only partly)

**Stamp Studio / DERM sheets**
- 2026-09-03 page integrity plan: four watchers never built (`PAGE_CARRIES_NO_SCAN` health arm, `v_sheet_page_map_gaps`, the suffix-collision check H3 while `fn_sheet_image_position` still ignores the sheet number, and "is the sheet-number sweep offering anything").
- 2026-09-07 page slots phase 3: guessed (derived) bands are still a fallback; 2 served documents on ticket-831325 rest on them. `v_unclaimed_slots` (63 rows) is read by nothing.
- 2026-09-02 printed-rule phase flip: A (one phase test for app and server) and C (trim short end bars, re-check measured pages) not built.
- Completion-gated publish: one client page per 5-minute tick (a 10-client sheet takes about 50 min); the claim-lock + bigger batch was never built.
- 2026-09-03 sheet-number read: the 10-minute job still calls the reader on every run (only the upload trigger checks first).
- Broward spec (2026-09-07): no county warning on Move/Add visit; `fn_sheet_publishable` has no Broward exit; /upload wording changes; no health count for Broward visits missing their sheet; two docs still describe the County dropdown (DERM Tracker CLAUDE.md rule 8, Stamp 02-architecture.md:52); the GDO bot item above.
- 2026-08-28 in-app detection: ticket-312024 p2 was saved by the machine without the person check the plan asked for.
- Stamp chip clamp (2026-10-17): built in Lovable 6e8ed79d, NOT published (unasked TanStack bump + new sheet tab title; Fred's call).

**Clients / calls / scheduling**
- 2026-08-17 call before scheduling: nothing built (call policy table, "call first" flag, daily job, Slack pointer, outcomes, permit warning). See 226-JER above.
- 2026-05-31 client locations: no tenant name on the DERM Tracker lists, no pick/search by tenant; Wynd 28 tenants Presidente and CU4 have no permit; 148-MOR GDO-11226 has no location.
- 2026-06-25 SA line items: New Visit cannot add fee or custom lines; the two drawer layout mockups were never shown; nobody proved an SA edit reaches the Jobber invoice cleanly.
- 2026-07-29 retry push: the live test (Retry on a likely duplicate, checked in Jobber) was never done.
- 2026-09-01 job status lifecycle: unclear whether "Recurring" on an inactive client hides "reopen the old agreement".
- 2026-08-19 SC job: `jobs-visits-calendar-workflow.md` line 163 still says "0 missing".

**Sign-in / apps**
- 2026-08-26 auth gate: the recovery marker as a shared cookie (a reset link opened in one app can sign you in to the others); live sign-in checks done on DERM Tracker only; the gate rules are not in each app's CLAUDE.md (Stamp's still says the round-trip cut is not shipped).
- HR app (2026-08-31; phase 1 deferred by Fred 2026-09-01): read-only; any signed-in staff member can open it (no admin/office gate); no HR tables, documents bucket, upload link, invites.
- Activity history (2026-06-25): the company-wide "recent activity" page and the redaction ADR were never done.
- 2026-08-21 loading states: `03-brand-and-design-system.md` is still titled "UnclogMe Sales App" while Building Apps rule 1 cites it.

**Visit duration (time on site)**
- 2026-10-18 one-time fix of the saved 2026 durations (Fred: "run all these Almost certain to help" plus Q2 loads, Q4, Q1 and Q8 of the plan; Q11, reading the photo stamps, after the rest). Spec: the local plan `samsara-checks/duration_fix_plan_2026-10-18/PLAN.md` (names clients, outside the repo). Answers: Q2 re-park = whole visit (reverses the 2026-10-15 "longest single stay"), Q2 loads = sum within one shift, Q5 = split a Samsara stay at the physical move, Q6 = a visit takes a stay only on its own evidence (reverses the 2026-10-14 decision on 8017), Q7 = a parked GPS stop of 3 min or more counts, Q9 = blanks with no Samsara truck stay blank (drive-bys `reviewed_blank`), Q10 = lock the other-day visits, Q4 = pumping goes to the truck whose pump ran (Fred's 10-15 trucks change only on his card), Q1 = split a shared stop only at an independent boundary, Q8 = per-property measuring overrides. Building now.
- The same answers for visits dated from 2026-10-18 (the capture plan, not designed yet): until then the 03:50 Samsara recheck still keeps the longest part of a re-parked visit and gives a shared stop whole to each visit.

**Email / tank sensors**
- 2026-10-14 email delivery: Admin Review `11-city-email.md:90` and DERM Tracker `06-features-and-routes.md` not updated; `derm_email_smoke.js` has no bcc option; nothing reminds anyone to read the city-open numbers around 2026-11-18 (gate for D5).
- 2026-10-12 tank sensors: docs (no ADR, schema.md, the plan header still says "Nothing applied"); app views beyond the Calendar tiles (M9).
- 2026-09-18 LWT Broward: properties 651, 978, 1084 still have no trap size, so their Broward tickets cannot be filed.

## 3. Waiting on Fred

- DERM storage private: decisions 2-14 before Stage 1 (scope, archive, receipts, soak lengths ...). FDEP sheets: keep public or move.
- LWT Broward (2026-09-18): which month a Broward ticket belongs to; tell Yan the gallons are trap capacity; ticket 310590 / Cloggy decal; FDEP sheet size fallback; confirm Jonathan's generator change (0 Broward tickets ever filed).
- Broward spec: 6 Broward manifests with no visit; Boca Raton printed as Broward (15 properties); FDEP form questions (contact name, mark styles, hauler date); the dead "Generate address sheet" button.
- Tank sensors: Miami-Dade tip point 0.6-0.9 km off (D3a); truck capacity in two places (M10); flag digest (M11); filing snapshot (M12); refill location and shift form (D12); other D's run on defaults.
- Older window folders: read their page numbers (17 folders, 157 served documents)?
- 2026-09-02 phase flip: "A + B now, C later?" never answered.
- Audit history is deleted after 24 months; DERM may need 3 years.
- Casa Neos manifests not linked to their permit (12 of 12).
- Field Portal: a client code alone opens that client's history (per-location token = reprint about 321 QR signs); the "Pending" wording on the report was replaced by "separate email" with no recorded decision; evidence on the same page as the data.
- Reason photos: move the 13 frequency-change proof images to the new setup?
- Loading states spec: approve the remaining three screens, the delay gate, and the two cheap accessibility fixes?
- Email D5 (separate archive email): after the ~2026-11-18 numbers.
- Visit duration: Q3 (a short errand in the middle of a job: sum the parts or keep) was not chosen on 2026-10-18; those visits keep their value.
- Stamp: publish the chip clamp; redo ticket-838130 (043-MIL 2 rows, 009-CN 3 rows on one card each; reopens a completed sheet).

## 4. Built (recent, with evidence)

| date | plan | evidence |
|---|---|---|
| 2026-10-17 | 11 AM Stamp post says why each sheet waits | Supabase `2026-10-17_1330`, `stamp-sheets-reminder` v12, b9acb00 |
| 2026-10-17 | One stamp per GDO permit, automatic (decided 2026-08-27) | Supabase `2026-10-17_0050`, 9a9472e |
| 2026-10-13 | Intake task closes on submit / cancel / expiry | `2026-10-13_1235`, `intake-task-sync` |
| 2026-10-14 | Email Delivered / Opened chips (except the docs and D5 above) | Admin Review + DERM Tracker live |
| 2026-10-15 | Moises water balance | `2026-10-15_1950`, `2026-10-16_1126` |
| 2026-09-14 | Generated sheets measure and complete themselves | `generated-sheet-finisher` |
| 2026-09-16 | Client reason photos | `reason-photos` bucket, Client App 2q |
| earlier | Calendar create visit, who-did-it attribution, frequency proof upload, SC job auto creation, Admin Review scope inclusions, DERM email send gates, Field Portal customer RPCs | see each spec |
