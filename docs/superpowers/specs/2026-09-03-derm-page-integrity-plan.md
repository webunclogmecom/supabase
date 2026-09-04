# DERM page integrity: what is broken, what we fixed today, and the plan

*Written 2026-09-03 evening ET, after Fred's "document this, and design a plan after careful audit of
what we have and what you found."*

---

## 1. The problem, in plain terms

A DERM ticket has one or more scanned sheets. Every client on a sheet gets a redacted copy where only
their own row is visible. **Which scan a client's copy is cut from is decided by a number on their
card, and that number has three different ways of being wrong.** Today we found and fixed the first,
and measured the other two.

1. **`page` got the image position written into it without the matching image.** A trigger did this.
   It turned a two-image ticket into a three-page one, which is what Fred saw as *"page 2 is a dupe
   of page 1."* **Fixed and guarded today.**
2. **`stamp_page` — the number that actually decides the client's document — has no guard at all**,
   and the one button that writes it in bulk reads the wrong column. **Not fixed. This is the live
   foot-gun.**
3. **The only independent evidence of which scan is which is the printed sheet number, and the sweep
   that reads it has been dead.** So nothing can catch 1 or 2 on its own. **Not fixed.**

Two folders are stuck behind this with real clients waiting: **`ticket-834742` (5 clients)** and
**`ticket-833049` (10 clients, since 2026-08-17)**.

---

## 2. Confidence tiers — read this before using any number below

This document mixes three grades of evidence. They are marked throughout.

| tier | meaning |
|---|---|
| **[EYE]** | I read the actual scanned paper. Strongest evidence available in this system. |
| **[MEAS]** | I measured it myself against live Prod, with a positive control. |
| **[1-SRC]** | One audit agent measured it. **The adversarial refutation panel never ran** — the workflow hit the session limit with 84 of 88 agents dead. My script counts "fewer than 2 refutations" as surviving, so with zero votes **everything passed vacuously**. Treat as a good lead, not a verified fact. |

Two of the six planned audit lenses (`folder-834742-path`, `forward-risk`) and the synthesis agent
never ran at all. Where that leaves a gap, it says so.

---

## 3. What we already shipped today

| migration | what |
|---|---|
| `2026-09-03_1500` | Repaired `ticket-834742`. Card 1106 `page` 2 -> 1; `fn_reconcile_stamp_pages` moved 5 ordinals from the witness; 14 `page_row_rules` + 1 `page_rule_scans` followed; the scan read taken through the duplicate was deleted. |
| `2026-09-03_1510` | Removed `NEW.page := v_img` from `derm.trg_autoplace_generated`; fixed `add_sheet_client` and `add_extra_client_card` to resolve through the new `derm.fn_page_image_url` and refuse rather than borrow; added the constraint trigger `trg_zz_page_image_injective`. |
| `2026-09-03_1600` | Narrowed that guard after an audit found it refused legitimate INSERTs into an already-violating folder. |

**[EYE] The 834742 repair is confirmed correct against the paper.** I fetched both scans and read them
at 8x:

| image | printed sheet | printed roster, in order | cards with that `stamp_page`, by `stamp_y_pct` |
|---|---|---|---|
| 1 `address_1.jpg` | **1106-1** | 308-LOU, 247-LOU, 243-FE, 178-LG, 045-NU | 29.800 → 60.040, same five, same order |
| 2 `address_2.jpg` | **1108-2** | 186-PV, 092-TCE, 177-PV, 241-WYN, 089-COW | 29.800 → 60.040, same five, same order |

**10 of 10.** The open question `2026-09-03_1500`'s header raised is answered.

**[EYE] New fact: those are two DIFFERENT sheets** (1106 and 1108), not two pages of one. So
`fn_sheet_image_position('ticket-834742', 2) = NULL` is correct rather than merely unhelpful.

---

## 4. What is still broken

### H1. `stamp_page` is unguarded, and the recovery action mis-files a client

**[MEAS]** `effective_page = COALESCE(stamp_page, page)` is what `fn_blackout_targets` indexes
`imgs[effective_page]` with. It decides the client's document. Nothing guards it.

**[MEAS]** `derm.auto_place_page(folder, page)` rosters on **raw `page`**
(`WHERE g.dump_folder = ... AND g.page = p_page AND NOT g.placed`) and writes `stamp_page = p_page`.

**[MEAS]** 106 cards across 24 folders have `page <> stamp_page`, and it is exactly **one shape**:
`page = 1`, `stamp_page ∈ {2,3,4}`.

**[MEAS] The estate splits three ways**, and this is the key to the whole problem:

| class | folders | cards | `page` means |
|---|---|---|---|
| A: ≤1 image | 97 | 343 | unambiguous |
| B: OCR-split, >1 distinct `page` | 18 | 190 | meaningful |
| **C: >1 image but ONE `page` value** | **23** | **193** | **nothing at all** |

`derm._materialize_card` inserts `page = 1` unconditionally, so on a class-C folder `page` is a
constant, not a locator. `ticket-834742` is class C.

**[MEAS] In the live Studio bundle** (walked to closure, 7 chunks / 998,950 bytes; both positive
controls present), the same logic in both chunks:

```js
se = l.filter(e => e.page === d)                    // CARD LIST for the tab      -> raw `page`
ce = l.filter(e => e.placed && e.stamp_page === d)  // STAMPS drawn on the scan   -> stamp_page
le = se.filter(e => !e.placed)                      // AUTO-PLACE QUEUE, from se
```

**[MEAS] Confirmed live, signed in on `stamp.unclogme.app/834742`:** tab 2's *PLACED* list correctly
shows all five clients (it keys on `stamp_page`); what is empty on tab 2 is the *unplaced queue* (it
keys on `page`). So the harm needs a clear first, and then it is one click: **clear a page-2 card and
it appears in tab 1's queue, where "Auto-place page 1" files it against `address_1.jpg`.**

> ⚠ **This corrects what I first told Fred.** I said tab 2's card list was empty. It is not.

**[1-SRC] and my own [MEAS] confirm: the obvious fix does not work.** Changing `auto_place_page`'s
roster to `COALESCE(stamp_page, page)` is a **no-op** — 0 of 23 unplaced cards differ under the two
predicates (control: 23 unplaced cards exist) — **and it would not have prevented the harm**, because
`derm.clear_stamp_position` sets `stamp_page = NULL` (verified in the live body, along with the whole
band block). After a clear, `COALESCE(stamp_page, page)` collapses to `page`, which is the field
carrying no information. **The information is destroyed by the clear, not lost by the predicate.**

### H2. The sheet-number OCR sweep is a structural no-op

**[MEAS]** `derm.fn_sheet_number_ocr_targets()` returns **0 rows estate-wide**. Positive control:
`fn_sheet_number_ocr_targets_for(ARRAY['834742'])` returns 1 row, so the machinery works and the zero
is structural. Arm A needs an unplaced card: 0 across every `ticket-%`. Arm B is self-draining and all
20 multi-image ticket folders already have a read. Cron 24 (`sheet-number-ocr-sweep`, `2-59/10`,
ACTIVE) has therefore been doing nothing.

This matters because the printed sheet number is the **only** independent evidence of which scan is
which, and a reversed pair is what put every stamp on the wrong scan on `ticket-833813` and
`ticket-312433`.

### H3. The page map is keyed on the suffix only

**[MEAS]** `derm.fn_sheet_image_position` matches `split_part(sheet_no_read, '-', 2)::int` and never
compares the sheet number, taking `order by sr.page limit 1`. One live instance, found with controls
(17 folders have suffixed reads; 29 (folder, suffix) groups; exactly 1 ambiguous): **`derm/1194`**
holds `1003-1`, `1003-2`, `1004-1`, so suffix `1` sits at positions 1 and 3.

**Latent, not live harm** — that folder is a legitimate three-page folder, fully placed, correct
geometry, 13 documents served. But a new card there would consult an ambiguous map.

---

## 5. The two stuck folders

### `ticket-834742` — 5 clients, and it is ready to go

**[EYE]** Page identity settled (section 3). **[MEAS]** blocker is `needs_snap_then_extent`; the five
page-2 cards carry DERIVED bands and there is no page-2 extent; 14 detected printed rules sit at
`effective_page = 2` waiting.

**[1-SRC]** With the extent added, `fn_blackout_targets` emits **10 targets correctly split** — five
on `address_1` at page 1, five on `address_2` at page 2, each with its own band. *(This was measured
by the earlier audit's completeness critic, not re-verified by me.)*

### `ticket-833049` — 10 clients, 17 days, and the recorded diagnosis was wrong

**[EYE] I read both scans. It is a straight two-page transposition.**

| image | printed sheet | printed roster, in order | currently at |
|---|---|---|---|
| `address_1.jpg` | 338 | 179-CIG Española Cigars · 83-SHUL The Shul · The Carrot Express Coral Gables · 029-JOS Josh's Deli · 082 The Fresh Carrot of Surfside | **effective_page 2** |
| `address_2.jpg` | 387 | Ceviche Inka · AVA · Yaya · La Spaziotto · MYK Brickell | **effective_page 1** |

Both are **6-slot** handwritten pads with the 6th slot empty ("Attach Additional Sheets if more than 6
Grease Interceptors"), confirming the recorded six-slot note. Each group's stamps run 29.800 → 60.040
in exact printed order.

**0 of 10 correct today; 10 of 10 after a swap.** That is the same signature that settled
`ticket-833813` and `ticket-312433`.

> 🛑 **This contradicts `Supabase/CLAUDE.md`, which says card 972 (page=2) "is in fact the only one
> that agrees with the paper."** Card 972 is 029-JOS at effective_page 2, which resolves to
> `imgs[2] = address_1` — and 029-JOS **is** printed on `address_1`. So that sentence is accidentally
> true of that one card and false as a description of the folder: the *whole* eff-page-2 group is
> correct and the *whole* eff-page-1 group is wrong. The "one-line fix doubles the exposure" warning
> is still right, and for a better reason than the one recorded: normalising `page` without also
> swapping `stamp_page` would move the correct group onto the wrong scan too.

**[EYE]** Also: sheets **338 and 387 are two separate pads**, not pages of one sheet, and neither
carries a `-N` suffix — so `fn_sheet_image_position` correctly falls through to identity here.

---

## 6. The plan

Ordered by dependency and client impact. **Nothing below is shipped.**

### Step 1 — Record the page identity I read, for both folders *(repair, I can do it)*

Write the sheet-number reads and the printed row order into `derm.address_sheet_scan_reads` /
`derm.address_sheet_row_reads` with `source`/`model` marked as a human read, the way
`2026-08-28_2010` recorded hand-verified geometry.

- **Why first:** every other step is downstream of knowing which scan is which, and right now that
  knowledge exists only in this document.
- **Blast radius:** `[MEAS]` 834742 — one new read at image position 2 makes
  `fn_sheet_image_position('ticket-834742', 2)` go NULL → 2. **[1-SRC]** claims no other function's
  answer changes; **I have not verified that myself and it must be verified before applying.**
- **Verify:** must-accept — the 834742 page-1 answer stays 1. Must-not-change — no card, band, extent
  or document moves. Re-run `derm.v_stamp_placement_health` and `v_blackout_blocked_sheets`.
- **Risk:** the map is closed-world, so a wrong entry places stamps on the wrong scan. Mitigated by
  the evidence being read off the paper rather than inferred.

### Step 2 — `ticket-833049`: de-duplicate, then swap *(repair, but see the gate)*

`[1-SRC]` P1: `UPDATE ... SET page = 1 WHERE id = 972` — image list 3 → 2, the estate's only
injectivity violation clears, the Studio stops rendering a phantom third page.
Then `[1-SRC]` P3: `stamp_page = 3 - stamp_page`, re-pointing the witness **from the row OCR**, never
from the new ordinal.

- **Why this order:** the swap is only meaningful once the list is `[address_1, address_2]`.
- **Blast radius:** `[1-SRC]` 1 row then 10 rows, 1 folder, **0 documents** (the CHECK constraint
  keeps it publishing nothing throughout).
- **Gate:** the CHECK `page_block_extents_no_ticket_833049` **stays on** for both steps. Nothing
  reaches a client.
- **Verify:** must-accept — the guard permits both writes (`[1-SRC]` measured; a `stamp_page`-only
  write is skipped by the no-worse clause). Must-hold — after the swap, every card's `stamp_image_url`
  matches the scan its client is printed on, cross-checked against the row OCR from step 1.

### Step 3 — H1, the real fix, as ONE migration *(repair; needs a decision on scope)*

Neither half works alone. **[MEAS]/[1-SRC]:**

1. `derm.clear_stamp_position` stops nulling `stamp_page`. It keeps clearing `stamp_x_pct`,
   `stamp_y_pct`, `stamp_placed_at`, `stamp_placed_by` and the band block. It stops destroying which
   image the operator had chosen.
2. `derm.auto_place_page` rosters on `COALESCE(g.stamp_page, g.page)` in **both** the skipped-count
   SELECT and the UPDATE.
3. The client-side predicate ships in the same cycle, or the two silently diverge.

- **Blast radius:** `[MEAS]` **0 cards change today.** It changes what happens on the *next* clear.
- **Verify:** the must-accept case is the one that matters — clear a page-2 card on 834742 in a
  rolled-back probe and assert it comes back on **tab 2**, not tab 1. That is the exact scenario that
  produced 10 → 8 targets.
- **Risk:** leaving `stamp_page` set on an unplaced card is a new state. `[1-SRC]` says it is already
  reachable; **that needs verifying against `fn_blackout_targets`' closed-world gate before shipping**,
  because a card with a `stamp_page` and no `stamp_placed_at` is exactly the shape that freezes a
  folder.

### Step 4 — `ticket-834742` to green: snap the bands, then add the extent, in one migration *(repair)*

In that order. An extent does not redact anything; it opens the gate onto whatever bands exist, and
adding one over derived bands is what leaked on 2026-08-19. Then a person re-completes in the Studio.

- **Blast radius:** 5 clients get their first document.
- **Verify:** every band edge must **equal** a detected `rule_pct`; `v_band_edge_check` grades all
  five `ON_RULE`/`ONE_CLIENT`; then **open each served document by eye** and confirm one facility per
  document. That last check is not optional — it is the estate's standing rule and it is how the six
  documents on 2026-09-02 were cleared.

### Step 5 — H2, un-drain the sheet-number sweep *(repair; small, and better than it looked)*

`[1-SRC]` Arm B drains per PAGE rather than per FOLDER. **This corrects my earlier warning to Fred
that it would change what gets OCR'd across 20 folders:** measured by rolled-back probe, the first run
offers **exactly 1 pair** (ticket-834742 page 2 — which step 1 supersedes), steady state 0, because 19
of the 20 folders are already page-complete.

- **Open question the audit flagged and I have not resolved:** the row-OCR sweep uses an attempt
  ledger so an unreadable page does not burn a vision call every ten minutes for ever. The number
  sweep has none. `[1-SRC]` says the live error population is 0, so the ledger is not urgent — but it
  is the difference between a fix and a retry loop, and it should ship with or before this.

### Step 6 — `ticket-833049` to green *(NEEDS FRED)*

Measure both pads' printed geometry, snap the bands, then drop the CHECK, add the extents, re-complete
and open a served document per page.

**This is the only step that serves regulator-facing documents to 10 clients from a folder that was
deliberately frozen after a real leak. It should not happen on my initiative at the end of a long
session, on a proposal whose refutation panel never ran.**

---

## 7. Deliberately not doing

| rejected | why |
|---|---|
| `COALESCE` roster change **on its own** | `[MEAS]` no-op today, and does not prevent the harm — `clear_stamp_position` nulls `stamp_page` first. Only meaningful bundled with step 3.1. |
| A `stamp_page` guard keyed on the witness (candidates b and c) | `[1-SRC]` The witness is derived from `imgs[stamp_page]` by `trg_ac_stamp_witness`, so any such check is circular; 643 of 703 witnesses are the 2026-08-24 backfill value; and `ticket-833049` **satisfies** the witness rule while being provably corrupt — which my `[EYE]` reading independently confirms. |
| A sheet-number plausibility guard (reject 3-digit reads) | `[1-SRC]` 38 of 75 numbered reads are bare 3-digit and are genuine handwritten pad numbers, running in orderly per-folder sequences. Confirmed `[EYE]`: 833049's own pads are **338** and **387**. It would refuse real data. |
| De-duplicating `ticket_page_images` | Measured destructive in the earlier audit: re-points 5 stamps on 833049 and pushes 5 out of range on 834742. |
| Changing `fn_blackout_targets`' OCR-agreement gate | `[1-SRC]` says it is vacuous on 72 of 179 live groups and worst exactly where the risk is. Real, but a refusal there means a client loses a document — needs its own measured refusal set. **Not in this plan.** |

---

## 8. Open decisions for Fred

1. **`ticket-833049` — do we serve the 10 clients?** I have read the paper and the transposition is
   unambiguous. My recommendation: yes, via steps 2 → 6, with every served document opened by eye
   before we call it done. It has been 17 days.
2. **Step 3 scope: do we change `clear_stamp_position`'s semantics?** Recommendation: yes. It is the
   only change that puts information back where the roster can read it, and it alters 0 rows today.
3. **Priority order.** Recommendation: 1 → 2 → 4 → 3 → 5 → 6, i.e. unblock the two folders' clients
   first and harden second, because H1 needs a *clear* to bite and nobody has to clear anything while
   we work.

---

## 9. Detectors that should exist afterwards

| detector | healthy = |
|---|---|
| `[1-SRC]` a `PAGE_CARRIES_NO_SCAN` arm on `v_stamp_placement_health` for class C | would surface 23 folders / 193 cards currently invisible. ⚠ It makes that view non-empty as a matter of course, so anything treating "empty = all clear" must change in the same cycle. |
| `[1-SRC]` `derm.v_sheet_page_map_gaps` — pages with no scan read, map holes, live identity fallback | measured output today: 7 unread pages, 6 map holes across 5 folders. Zero writes, zero vision calls. **Highest-value item in the audit.** |
| A suffix-collision detector for `fn_sheet_image_position` | `[MEAS]` today: exactly 1 (`derm/1194`). Empty = healthy. |
| An "is cron 24 actually offering anything" check | `[MEAS]` It has been returning 0 estate-wide and nothing noticed. A sweep whose target list is empty for weeks should say so. |

---

## 10. What this plan does not cover

- Two of six audit lenses never ran: **`folder-834742-path`** (the exact ordered path to green,
  including whether `save_page_geometry` will accept a snap onto the moved rules) and
  **`forward-risk`** (what happens on the next generated multi-page filing, and which other folders
  are one step from the same trap). The synthesis agent also died. **Re-run after 1:50am Paris.**
- No proposal in section 6 has been adversarially refuted. Everything marked `[1-SRC]` should get its
  refutation pass before it ships, especially step 3's new "unplaced card with a `stamp_page`" state.
- The Lovable project is not checked out locally, so the client-side half of step 3 has been read from
  the live bundle but not written.
