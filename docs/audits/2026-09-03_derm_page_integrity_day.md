# 2026-09-03 — DERM page integrity: one question, seven migrations, two app releases

*Day record for the @Supabase (workspace root) session. Written 23:00 ET.*

⚠ **SCOPE.** This covers ONE thread: the DERM page/stamp-page integrity work that started with Fred
noticing a duplicated page in the Stamp Studio. The same day's Jobber two-way authority audit, the
GraphQL cost regression, the `ci_medium` compute upgrade, the `max_worker_processes` episode, the
Samsara asset check and the past-due panel were the **parallel session's** work and are recorded
separately. Do not read this file as the whole day.

---

## What Fred reported, and what it actually was

> *"page 2 is a dupe of page 1, why? at the DERM App we only have uploaded 2 pages, we need to get
> the source of this and fix it so it never happens again."*

`derm.ticket_page_images('834742')` was returning **three** entries built from **two** uploaded
images. The cause was not the upload and not a person: **`derm.trg_autoplace_generated` executed
`NEW.page := v_img`** — the image POSITION — **without ever setting a matching `image_url`.** A
catalogue sweep showed it was the only object in the database that assigns `NEW.page`, and across the
entire audit history it had written a `page > 1` row exactly **twice**, corrupting the image list
**both times**: `ticket-833049` card 972 (2026-08-17) and `ticket-834742` card 1106 (that morning).
**0 of 2 correct** is the signature of a broken writer, not of unlucky data.

---

## What shipped

### Seven migrations

| migration | what it did |
|---|---|
| `2026-09-03_1500` | Repaired `ticket-834742`: card 1106 `page` 2→1, then `fn_reconcile_stamp_pages` moved 5 ordinals **from the witness**, the 14 `page_row_rules` + 1 `page_rule_scans` rows followed 3→2, and the scan read taken THROUGH the duplicate was deleted |
| `2026-09-03_1510` | Closed **three** source routes (`trg_autoplace_generated`, `add_sheet_client`, `add_extra_client_card`), added `derm.fn_page_image_url`, and installed the deferrable constraint trigger `trg_zz_page_image_injective` |
| `2026-09-03_1600` | **Fixed a regression in my own guard** (see corrections below) |
| `2026-09-03_2030` | Recorded the page identity I read off the paper for `ticket-834742` |
| `2026-09-03_2040` | Repaired the `ticket-833049` two-page transposition, 0 of 10 → 10 of 10 |
| `2026-09-03_2100` | `clear_stamp_position` keeps `stamp_page`; `auto_place_page` rosters on `COALESCE(stamp_page, page)` |
| `2026-09-03_2210` | Rebuilt the sheet-number read as an **event**, not a schedule |

### Two Lovable releases (DERM Stamp Studio, `6e8ed79d-…`)

1. The per-page card list now keys on `(e.stamp_page ?? e.page) === tab`, closing the client/server
   divergence `_2100` opened. Verified in the LIVE bundle: 24 chunks / 939,075 B, new predicate **2**
   occurrences, old raw-`page` filter **0**.
2. The **Draw the bands** dialog caps at `max-h-[80vh]` with only its middle section scrolling and the
   Save/Cancel footer pinned, because it was taller than the viewport and hid the scan being measured.

---

## The part that could only be settled by reading the paper

Both stuck folders were adjudicated by fetching the scans from the bucket and reading them at 8x —
not by any database check, because **every database signal on these folders is circular**
(`stamp_image_url` was backfilled from each stamp's own ordinal, and `fn_blackout_targets`' page
identity check is scoped to `source='claude-vision-v1'`, which is inert on every `derm-link` sheet).

| folder | image | printed | roster matches its stamps |
|---|---|---|---|
| `ticket-834742` | `address_1.jpg` | sheet **1106-1** | 5 of 5, in printed order |
| | `address_2.jpg` | sheet **1108-2** | 5 of 5, in printed order |
| `ticket-833049` | `address_1.jpg` | pad **338** | the group that was at `effective_page` **2** |
| | `address_2.jpg` | pad **387** | the group that was at `effective_page` **1** |

⇒ 834742 was **10 of 10 correct** and the repair is confirmed against the paper.
⇒ 833049 was **0 of 10** — a straight two-page transposition, the same signature as `ticket-833813`
and `ticket-312433` — and is now 10 of 10.

🛑 **Two facts worth carrying.** `ticket-834742` is a **two-sheet job** (1106 and 1108), not a
two-page sheet, so `fn_sheet_image_position(folder, 2)` returning NULL was correct rather than merely
unhelpful. And `ticket-833049`'s two images are **separate handwritten pads**, both 6-slot with the
6th empty, neither carrying a `-N` suffix, so that folder correctly falls through to the identity map.

---

## Corrections I made to my own work during the day

Recorded because the estate's most expensive defects have all been sound measurements wrapped in a
wrong sentence, and three of these were exactly that.

1. **The guard I shipped at 20:06 was not "no-worse", despite the header saying so.** The skip was
   gated on `IF TG_OP = 'UPDATE'`, so it never applied to an INSERT, and the predicate asked *"is this
   manifest violating?"* instead of *"did this row put its page there?"*. Any insert into an
   already-violating folder was refused, including a correct one — and because the trigger is
   DEFERRED, the `23514` lands at COMMIT, **outside `derm._materialize_card`'s
   `EXCEPTION WHEN unique_violation` handler**, aborting the whole filing. It broke the estate's own
   documented recovery action on the one folder the guard existed to leave workable. Found by a
   163-agent adversarial audit of my own migrations (52 findings, 48 refuted, **4 survived**). Fixed
   in `_1600`.
   **Why the VERIFY missed it:** its four live controls were a clean INSERT on a clean folder, a bad
   INSERT on a clean folder, a no-op UPDATE on the violator and a bad UPDATE on the violator. The
   defect lived in the one cell nobody wrote: **a legitimate INSERT into the violating folder.**
   Enumerate the COMBINATIONS, not one cell per variable.

2. **My first reproduction of that finding returned a confident ACCEPTED and briefly "refuted" it.**
   A DEFERRED constraint trigger does not fire inside a transaction that rolls back unless you
   `SET CONSTRAINTS ALL IMMEDIATE` first. Without it the probe measures nothing.

3. **The one-line fix I proposed for the `auto_place_page` hazard was a no-op.** Changing only the
   roster to `COALESCE(stamp_page, page)` differs on **0 of 23** unplaced cards, because
   `clear_stamp_position` nulls `stamp_page` first. **The locator is destroyed by the CLEAR, not lost
   by the predicate.** Both halves had to ship together.

4. **I told Fred the cron-24 fix would be "unobservable". True for `ticket-%`, false estate-wide.**
   In-scope: 0 unread. Estate-wide: 35 unread across 17 `window*` folders.

5. **I described the Studio symptom imprecisely.** Tab 2's *PLACED* list was correctly populated (it
   keys on `stamp_page`); what was empty was the *unplaced queue* (which keys on `page`). The harm
   therefore needed a clear first — and then it was one click.

---

## Verified final state, 23:00 ET

| check | value |
|---|---|
| injectivity violators estate-wide | **0** (was 2 manifests / 18 rows) |
| `ticket-834742` documents | **10 of 10** |
| documents served overall | 677 |
| `derm.v_blackout_blocked_sheets` | 833049 (frozen, 10 clients) · window4-sheet1 (2) · window5-sheet3 (1) |
| `derm.v_stamp_placement_health` | 1 row, the pre-existing `ticket-310607` |
| `derm.v_sheet_number_ocr_backlog` | in-scope **0**, out-of-scope **35** |
| `derm.v_cards_awaiting_page_map` | **0** |

**Documents opened and read by eye, one facility each:** 186-PV (page 2, first printed row, top
edge), 243-FE (page 1, middle row, both edges), 045-NU (page 1, last row, bottom edge). Three
distinct edge cases; the remaining seven share their geometry.

⚠ **`ticket-834742`'s page-2 geometry was measured by Fred in the Studio at 20:27 ET**, in parallel
with this session, not by a migration. My `_2030` had asserted `needs_snap_then_extent` seconds
earlier, so the sequence is consistent — but it is a live instance of §5.2b: **re-read before
concluding.**

---

## Still open, and whose

| item | owner | note |
|---|---|---|
| `ticket-833049`'s **10 undelivered documents** (since 2026-08-17) | **Fred** | The repair is done and verified against the paper. What remains is dropping the CHECK, measuring the two pads in the Studio, and re-completing. The pads are handwritten 6-slot forms, so the detector often fails and a person has to drag. |
| Widening the sheet-number OCR scope to the 17 `window*` folders | **Fred** | They serve **157 client documents** and their page mapping has never been machine-checked. Cost: 35 vision calls on pads whose reads may be garbage. Widening is one line; the backlog view is scope-free so the gap stays countable. |
| `window4-sheet1` (`cards_withheld`), `window5-sheet3` (`no_stamp_timestamp`) | Yannick | Need a stamp re-placed, not a measurement. |

🛑 **Deliberately NOT built: unattended re-placement.** Auto-placement is the mechanism that put every
stamp on the wrong scan on `ticket-833813`, `ticket-312433` and `ticket-833049`. A second unattended
placement path firing on freshly-changed page maps is how that class returns. The detector
`derm.v_cards_awaiting_page_map` ships instead; empty is healthy, and it is empty.

---

## Where the detail lives

- Plan and the corrected 833049 diagnosis:
  `docs/superpowers/specs/2026-09-03-derm-page-integrity-plan.md`
- Event-driven sheet-number read, with the measured scope table and test plan:
  `docs/superpowers/specs/2026-09-03-sheet-number-read-on-upload-design.md`
- Rules, traps and corrections: `Supabase/CLAUDE.md`, the `address_row_map.page` and FP-blackout
  sections
- App-facing behaviour and the outstanding items: `Building Apps/DERM Stamp Studio/docs/08-changelog.md`
- Each migration header is the authoritative "why" for its own change.
- Pre-repair backups (gitignored): `backups/2026-09-03_ticket-834742_pre_repair.json`,
  `backups/2026-09-03_ticket-833049_pre_repair.json`
