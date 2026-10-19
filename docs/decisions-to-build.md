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
| **226-JER Jerusalem Pizza is past its permit limit.** GDO-03256 allows 60 days; last service 2026-08-17 (61 days on 10-17); nothing booked. ✅ 2026-10-18: the call-first reminder is built and request 81 "Call for approval" is in To Be Scheduled (Call first chip); the 11 AM post names it. **Still needs the call and a booking.** | visits, gdos, ops.visit_requests 81 | office (Diego) |
| **ticket-836361 has been completed since 2026-10-01 and 288-PER's copy was never made.** Cause: page 2 of the paper was never uploaded and the stamp was placed on it anyway. ✅ 2026-10-18 the rule is fixed (`2026-10-18_0230`: no stamp on a page without a scan; the health email names such sheets). **Still needs page 2 uploaded in the DERM Tracker.** | the view, card 3001 | office |
| **3,106 DERM documents are still in public storage, and the number grows** (2026-09-27 plan: only Stage 0 was approved; Stages 1-11 wait on 13 decisions). | storage census by the audit | Fred |

## 2. Agreed, not built (or only partly)

**Stamp Studio / DERM sheets**
- 2026-09-03 page integrity plan: four watchers never built (`PAGE_CARRIES_NO_SCAN` health arm, `v_sheet_page_map_gaps`, the suffix-collision check H3 while `fn_sheet_image_position` still ignores the sheet number, and "is the sheet-number sweep offering anything").
- 2026-09-07 page slots phase 3: guessed (derived) bands are still a fallback; 2 served documents on ticket-831325 rest on them. `v_unclaimed_slots` (63 rows) is read by nothing.
- 2026-09-02 printed-rule phase flip: A (one phase test for app and server) and C (trim short end bars, re-check measured pages) not built.
- Completion-gated publish: one client page per 5-minute tick (a 10-client sheet takes about 50 min); the claim-lock + bigger batch was never built.
- 2026-09-03 sheet-number read: the 10-minute job still calls the reader on every run (only the upload trigger checks first).
- Broward spec (2026-09-07): no county warning on Move/Add visit; `fn_sheet_publishable` has no Broward exit; /upload wording changes; no health count for Broward visits missing their sheet; two docs still describe the County dropdown (DERM Tracker CLAUDE.md rule 8, Stamp 02-architecture.md:52); the GDO bot item is closed (2026-10-18, the county form takes no sheet).
- 2026-08-28 in-app detection: ticket-312024 p2 was saved by the machine without the person check the plan asked for.

**HR App redesign** (plan: Building Apps/HR App/docs/specs/2026-10-19-hr-app-redesign-plan.md; Fred 2026-10-19: "go with the real data, and go as recommended")
- Release 1, the pay and bonus history: 20 per page in a box that scrolls on a laptop; the full white "Open in Admin Review" button on every row; Excel with write-excel-file 4.1.1; office may export (bonus rows only), plus a "By payroll week" sheet; a late take-back stays in the week of the work, with a health email and an "after that week ended" tag; opens on All time and keeps the period from person to person; mockups with real data. History fields migration BUILT (`2026-10-19_0215`, 31a9302). Mockup approved by Fred 2026-10-19 ("go ahead": https://claude.ai/artifact/2EaHeFnE75eQ1DXK7kGs64). Release 1 BUILT and live 2026-10-19 (theme pass + PayHistory + Excel export; Building Apps HR App changelog 2026-10-19 (b)). Open: a real download from the live app and one office user's check.
- Release 2 (after Fred uses release 1): Bonus amounts page, top bar, staff list, person page tabs; pay changes stay in the history table, editing of company amounts moves to the Bonus amounts page, unbuilt parts hidden (Send invite note kept), simple Status/Access chips on the staff list. Fred 2026-10-19: name "Employees"; access levels keep DIFFERENT colours, one set shared by every app (picked from a mockup); radius = the Calendar's 14 / 18 in every app (rollout of Admin Review, Client App, DERM Tracker, Field Portal handed to the Supabase session); the Privileges box turns amber; Shift and Start date columns hidden until filled; pay is hourly only (Edit pay = one hourly amount). Mockups picked 2026-10-19 (https://claude.ai/artifact/2ywYQWBpSCinJYj8XRHHqD): access colours A (Admin violet #6d28d9 on #f5f3ff, Office blue #1d4ed8 on #eff6ff, Field teal #0f766e on #f0fdfa, each with an icon), person page as tabs, Edit details as a centred dialog, bonus history behind an Activity button (Client App style). Access filter chips are the coloured chips alone, no white chip around them. NEW (Fred, same day): bonus amounts are PER PERSON ("Grecia can have a bonus of $15 and $30 ... Michael can have $10 and $20"), replacing the 2026-10-18 company-only rule; answers: someone with no amount of their own earns $0 (no company fallback; the health email names it), and at go-live every active person gets $10 / $25 from Jan 1, 2026 so nothing changes on day one. Office already sees bonuses in the HR App, so Admin Review showing each person's amount to office reviewers is consistent. Mockup v2 (per-person Bonus amounts table) waits on Fred.
- Watched ceiling: server paging (hr.get_pay_history) once one person passes 800 history entries; cleanup migration removing detail and link once no live chunk reads them.

**Clients / calls / scheduling**
- 2026-05-31 client locations: no tenant name on the DERM Tracker lists, no pick/search by tenant; Wynd 28 tenants Presidente and CU4 have no permit; 148-MOR GDO-11226 has no location.
- 2026-06-25 SA line items: New Visit cannot add fee or custom lines; the two drawer layout mockups were never shown; nobody proved an SA edit reaches the Jobber invoice cleanly.
- 2026-07-29 retry push: the live test (Retry on a likely duplicate, checked in Jobber) was never done.
- 2026-09-01 job status lifecycle: unclear whether "Recurring" on an inactive client hides "reopen the old agreement".
- 2026-08-19 SC job: `jobs-visits-calendar-workflow.md` line 163 still says "0 missing".

**Sign-in / apps**
- 2026-08-26 auth gate: the recovery marker as a shared cookie (a reset link opened in one app can sign you in to the others); live sign-in checks done on DERM Tracker only; the gate rules are not in each app's CLAUDE.md (Stamp's still says the round-trip cut is not shipped).
- HR app, still not built: documents bucket and upload link, emergency contact, invites, Add employee, privileges enforcement in other apps; hourly earnings (needs the Jobber time sheet sync).
- Activity history (2026-06-25): the company-wide "recent activity" page and the redaction ADR were never done.
- 2026-08-21 loading states: `03-brand-and-design-system.md` is still titled "UnclogMe Sales App" while Building Apps rule 1 cites it.

**Visit duration (time on site)**
- 2026-10-18 one-time fix of the saved 2026 durations (Fred: "run all these Almost certain to help" plus Q2 loads, Q4, Q1 and Q8 of the plan; Q11, reading the photo stamps, after the rest). Spec: the local plan `samsara-checks/duration_fix_plan_2026-10-18/PLAN.md` (names clients, outside the repo). Answers: Q2 re-park = whole visit (reverses the 2026-10-15 "longest single stay"), Q2 loads = sum within one shift, Q5 = split a Samsara stay at the physical move, Q6 = a visit takes a stay only on its own evidence (reverses the 2026-10-14 decision on 8017), Q7 = a parked GPS stop of 3 min or more counts, Q9 = blanks with no Samsara truck stay blank (drive-bys `reviewed_blank`), Q10 = lock the other-day visits, Q4 = pumping goes to the truck whose pump ran (Fred's 10-15 trucks change only on his card), Q1 = split a shared stop only at an independent boundary, Q8 = per-property measuring overrides. **Applied 2026-10-18 for visits dated to 10-07** (`47c7c92`: Stage 0, trucks, times high, times medium, split touch). Q11 photo stamps read 2026-10-18 (77 of 77 hand-read stamps matched; 92.9% of corrected visits have every stamp inside the saved stay, target 97%) and 9 medium-confidence corrections applied (`2026-10-18_1631`). Cards closed 2026-10-19 (`2026-10-18_2023`, Fred: "go ahead"): the photo-settled ones accepted, every other card kept at its saved time and locked. Still open: the 61 catch-up visits dated 10-08 to 10-17 (re-measure from 2026-10-28, then write); 6270 (kept as is, not locked); 9 truck questions on Miami-Dade-filed visits (local list `ledger/truck_questions_derm.md`, Fred decides; a change also changes that LWT row).
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
- Grease trap location: 168-AVA (parking garage basement), 222-SPE (hose inside the garage), 067-TCE ("2 manholes inside the gate"): Inside or Outside?
- Casa Neos manifests not linked to their permit (12 of 12).
- Field Portal: a client code alone opens that client's history (per-location token = reprint about 321 QR signs); the "Pending" wording on the report was replaced by "separate email" with no recorded decision; evidence on the same page as the data.
- Reason photos: move the 13 frequency-change proof images to the new setup?
- Loading states spec: approve the remaining three screens, the delay gate, and the two cheap accessibility fixes?
- Email D5 (separate archive email): after the ~2026-11-18 numbers.
- Visit duration: Q3 (a short errand in the middle of a job: sum the parts or keep) was not chosen on 2026-10-18; those visits keep their value.
- HR pay: per-person bonus amounts? (Admin Review reads the company amounts from HR since 2026-10-18 (b); a per-person amount would show one person's pay to office reviewers there, so still refused.) (Answered 2026-10-18: pay rates admins only; each person on a two-person crew gets the visit bonus; the Oct 5 shift stays $0.)

## 4. Built (recent, with evidence)

| date | plan | evidence |
|---|---|---|
| 2026-10-19 | Corner radius like the Visit Calendar in every app (Fred: "the same across all apps"; Building Apps rule 1f): `--radius` .625rem in Admin Review, Client App, DERM Tracker, Field Portal (the other six already matched) | each app's `docs/08-changelog.md` 2026-10-19; BA c5f4ee0, 4be382f, 63eba22, rule 1f 0229bec; DERM + FP shipped with a vite-tanstack-config bump to 2.26.5, Fred OK |
| 2026-10-17 | Grease trap location on the property (Inside / Outside / Inside and Outside): Client App field, site survey third answer, Planner accept row, Viktor's Jobber-notes list (59 of 82 loaded) | Supabase `2026-10-16_1530`, `_1730`, `_1745`, `_1815`, `2026-10-17_0034`; open: 168-AVA, 222-SPE, 067-TCE wait on Fred (section 3) |
| 2026-10-18 | ticket-838130 redone with one stamp per permit (043-MIL 2, 009-CN 3), completed again | Supabase `2026-10-18_1240`, 17d2b5a |
| 2026-10-18 | Stamp chips stay inside the sheet (view + Export PNG), published with Fred's OK and Lovable's unasked TanStack bump | Stamp Studio changelog 2026-10-18; live `index-QfyMBtNI.js`; guard/flock/module checks PASS |
| 2026-10-18 | Call before scheduling (decided 2026-08-17): policy kept by hand, Call first requests 3 days ahead, Not now, permit warning, 11 AM post | Supabase `2026-10-18_0245`, `call-first-reminder`, c8992f0; Calendar chip + Not now (see Visit Calendar changelog 2026-10-18) |
| 2026-10-18 | No stamp on a page without a scan; completed sheets with an unpublished copy reach the health email | Supabase `2026-10-18_0230`, 95b1516 |
| 2026-10-18 | HR App: editable employee record, pay rates (admins only), pay and bonus history linked to Admin Review approvals; renames safe for the shift inspection form | Supabase `2026-10-18_0320`, `_0400`, fillout-inspection v14, `scripts/checks/hr_app/run.js` (38 checks); HR App live chunk `employees._id-CfBT9n92.js`; Building Apps f19e325 |
| 2026-10-18 | Admin Review reads the bonus amounts from HR; admins change the company amounts in the HR App (from today or later) | Supabase `2026-10-18_1410` (`hr.get_bonus_amounts`, `hr.set_company_bonus`, 7 probes); Admin Review live chunk `App-BPJEw14Q.js`; HR App company bonus edit live; Building Apps eaa9dc1 |
| 2026-10-18 | GDO reports are never held for a sheet (the county form takes none); `documents` sent empty. Reverses `_0220` | Supabase `2026-10-18_2100`, `rpa-derm-queue` v31, fd28840 |
| 2026-10-18 | A Dade pickup dumped in Broward still owes its DERM GDO report (Fred). Already true in the queue; swept: 8 of 9 filed, 8095 waits on its county login | `docs/audits/2026-10-18_gdo_sheet_hold_reversal_and_mixed_route_sweep.md` |
| 2026-10-18 | ~~GDO online reports carry the visit's own sheet; never filed without one~~ (reversed the same day by `_2100`) | Supabase `2026-10-18_0220`, `rpa-derm-queue` v30, 70bafb3 |
| 2026-10-17 | 11 AM Stamp post says why each sheet waits | Supabase `2026-10-17_1330`, `stamp-sheets-reminder` v12, b9acb00 |
| 2026-10-17 | One stamp per GDO permit, automatic (decided 2026-08-27) | Supabase `2026-10-17_0050`, 9a9472e |
| 2026-10-13 | Intake task closes on submit / cancel / expiry | `2026-10-13_1235`, `intake-task-sync` |
| 2026-10-14 | Email Delivered / Opened chips (except the docs and D5 above) | Admin Review + DERM Tracker live |
| 2026-10-15 | Moises water balance | `2026-10-15_1950`, `2026-10-16_1126` |
| 2026-09-14 | Generated sheets measure and complete themselves | `generated-sheet-finisher` |
| 2026-09-16 | Client reason photos | `reason-photos` bucket, Client App 2q |
| earlier | Calendar create visit, who-did-it attribution, frequency proof upload, SC job auto creation, Admin Review scope inclusions, DERM email send gates, Field Portal customer RPCs | see each spec |
