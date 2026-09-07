# Geometry-first page slots: draw the lines, then drop clients into them

*Design, 2026-09-07. Nothing in this document is implemented.*

**Fred, 2026-09-07:** *"i need to be able to draw the lines, and that's done by a human so they need
to be approved. Also we shouldn't need to have stamps put first for us to draw the lines, we can just
draw the lines, which they means they can now become the slots of blocks to put the stamps per
client."*

---

## 1. The problem, stated as it actually is

A DERM address sheet is a printed form with a fixed number of rows. That is a fact about the **page**.
This estate stores it as a fact about the **client**.

`derm.address_row_map.band_y0_pct / band_y1_pct` hangs the row geometry off the card, which is the
row that links one client to one sheet. `derm.v_stamp_row_bands` then resolves a band as
`COALESCE(manual, derived)`, where `derived` is a stamp-midpoint heuristic computed with `lag`/`lead`
over the stamps on that page.

Five consequences follow, and four of them have already cost us something:

| # | consequence | evidence |
|---|---|---|
| 1 | A page cannot be measured before its clients are stamped | the shipped Studio bundle says so verbatim: *"No stamps are placed on this page yet. A strip is tied to a client by that client's stamp, so place the stamps first and the strips will fill in."* |
| 2 | A printed slot nobody stamped is DISCARDED | *"The strip from 57.70% to 63.38% has no stamp inside it, so no client claims it and it will not be saved."* Seen on `ticket-833049`, a 6-slot pad carrying 5 clients |
| 3 | An empty printed slot cannot be represented, so an extent derived from bands stops short of it | the `2026-08-03_0046` leak: sheet 1072 page 2 had 5 printed slots and 2 stamped, and a band-derived extent stopped at 41.85% and served everything below |
| 4 | A facility printed on the paper that we hold no card for is invisible, and derived bands stretch across it | the `2026-08-19` leak: `ticket-310590` p2 showed 165-LPB's GDO number and name to 004-BAO, and its street address to 186-PV |
| 5 | The automatic measure path only offers sheets with an UNPLACED card, so a sheet that arrives already stamped is never measured | the recurring `v_blackout_blocked_sheets` backlog, recorded in CLAUDE.md as a known systemic gap |

Fred's instruction inverts the ownership, and the inversion is correct: **the lines are a property of
the page, the slots come from the lines, and a client is assigned to a slot.**

### 1a. What is already true, so it is not re-built

- **Lines are already page-level.** `derm.page_row_rules` is keyed `(dump_folder, effective_page,
  rule_pct, source)` and holds `kind` (`boundary` / `divider`), `run_frac` and `ink_frac`.
- **Human lines are already authoritative.** Since `2026-09-02_0330`, `derm.v_page_printed_rules`
  admits `source ~~ 'human-v1-%'` alongside `runlen-v2-%`, and it takes the NEWEST scan per page. A
  hand-drawn set beats the detector today. Measured: 33 human rules across 5 pages.
- **The Studio can already draw them.** `derm.record_page_rules` accepted `ticket-833049`'s 7 hand
  drawn lines on 2026-09-07 with `grade = OK`.

**So the missing piece is narrow: nothing turns those lines into slots, and nothing can hold a slot
that has no client in it.**

---

## 2. Measured starting state (2026-09-07)

| | |
|---|---|
| cards total / stamped | 747 / 714 |
| cards with a MANUAL band | **694** |
| cards on a DERIVED band | 20 |
| served redacted documents | 677 |
| served documents still resting on a derived band | **9** |
| pages stamped / with rules / with an extent | 181 / 179 / 177 |
| rule provenance | `runlen-v2` 2,378 rules on 177 pages, hand-recorded `claude-*` 198 on 31, `human-v1` 33 on 5 |
| consumers of `derm.v_stamp_row_bands` | 3 views (`v_band_edge_check`, `v_served_blackout_short`, `v_stamp_rows`), 4 functions (`_page_geometry_violations`, `clear_stamp_position`, `fn_blackout_targets`, `set_row_band`) |

**The decisive number is 694 of 714.** Almost every serving row already carries an explicit human or
snapped band. This is not a backfill project. It is about what happens on the NEXT page, and about
being able to represent the parts of a page that no client occupies.

⚠ These are dated observations. Re-measure rather than quoting them.

---

## 3. The model

```
  page_row_rules          the lines a person drew or a detector found   (EXISTS)
        |
        v
  page_slots              one row per interval between consecutive      (NEW)
                          boundary lines, INCLUDING unclaimed ones
        |
        v
  address_row_map.slot    a card is ASSIGNED to a slot                  (NEW COLUMN)
        |
        v
  v_stamp_row_bands       band = COALESCE(manual, slot, derived)        (ONE ARM ADDED)
        |
        v
  fn_blackout_targets     unchanged
```

### 3.1 `derm.page_slots` (new)

```
dump_folder      text
effective_page   int
slot_index       int          1..N in printed order, top to bottom
y0_pct           numeric      the boundary above this slot
y1_pct           numeric      the boundary below it
source           text         'human-v1-<date>' or 'runlen-v2-<date>', matching page_row_rules
set_by           text         derm._actor(...)
set_at           timestamptz
PRIMARY KEY (dump_folder, effective_page, slot_index)
```

Plus the page's own boundary, which is what the two Limit bands already are:
the extent stays in `derm.page_block_extents` unchanged, written in the same transaction.

**🛑 Slots are MATERIALISED, not derived on read, and the estate has already paid for the
alternative.** `address_sheet_clients.rows_printed` used to be recounted live from `public.gdos`, so
adding one permit silently re-indexed five already-printed sheets and moved stamps onto other
clients' rows. A served document's geometry must not move because a detector re-ran or a classifier
improved. The stored "what we measured then" is the control.

⚠ This also contains the known classifier limitation rather than inheriting it. The end-bar trim in
`classify.js` strips only LONG bars, so on a page whose outermost rule at each end is SHORT every
label below inverts (`ticket-312024` p1 is that page). Deriving slots live from `kind` would let a
future detector run flip a serving page's slots. Materialising freezes the human decision.

### 3.2 Assignment

`derm.address_row_map` gains `slot_index int NULL`, meaning "this card sits in that printed slot".

Band resolution in `derm.v_stamp_row_bands` becomes:

```
band_y0_pct = COALESCE(manual_y0, slot_y0, derived_y0)
band_y1_pct = COALESCE(manual_y1, slot_y1, derived_y1)
```

**Manual stays on top, and that is the whole migration-safety argument.** All 694 existing manual
bands keep winning, so not one of the 677 served documents changes. 80 of those bands are already
accepted in `derm.band_review` for reasons a slot cannot express, most often the client's own
handwriting overflowing the printed slot. A design that let slots override manual would crop a
client's own row out of their own compliance document.

### 3.3 The write path

One RPC, one transaction, extending the existing `derm.save_page_geometry`:

1. record the lines (`derm.record_page_rules`, unchanged),
2. materialise every interval as a slot, **including intervals no client claims**,
3. for each card assigned to a slot, write its band from that slot,
4. write the extent from the two Limit lines.

Steps 2 and 3 are the change. Today step 2 does not exist and step 3 only happens for cards whose
stamp happens to fall inside a strip.

---

## 4. What this fixes, concretely

| today | after |
|---|---|
| a page with no stamps cannot be measured | measure any page, any time; slots wait for clients |
| the unclaimed 6th slot on `ticket-833049` is thrown away | it is stored, and the extent legitimately covers it |
| a printed-but-unrowed facility is undetectable | a slot with no card is a **row in a table**, so it is a query |
| `fn_sheet_row_ocr_targets` skips pre-stamped sheets, so they are never measured | measuring is independent of placement, so the queue can offer any unmeasured page |
| `auto_place_page` places on a fixed y-ladder | it can place on the slot, which is where the row actually is |

**The third row is the one worth pausing on.** Both confirmed blackout leaks in this estate were an
unowned printed slot: `ticket-310590` p2 (165-LPB printed, no card, derived bands stretched across
it) and the three still-open sightings at `window4-sheet1` p2, `window10-sheet4` p2 and
`window3-sheet5` p2, all recorded in CLAUDE.md as *"still no detector for this"*. Slots turn that
into `SELECT ... FROM page_slots s WHERE NOT EXISTS (a card in s)`. It is the first mechanical
detector for the exact shape that has leaked twice.

---

## 5. Staging

Each phase is independently shippable and phase 1 alone answers Fred's complaint.

### Phase 1: slots exist and can be empty (DB only)
- `derm.page_slots` + `address_row_map.slot_index`
- `save_page_geometry` materialises slots and writes bands from them
- G6 applies only to cards that exist, so a page with zero cards is measurable
- **Acceptance:** `derm.v_stamp_row_bands` output is byte-identical before and after, for all 714
  rows. Asserted in the migration, not claimed in the header.

### Phase 2: the Studio uses slots (app)
- slots render as drop targets; assigning a client writes `slot_index` and places the stamp at the
  slot centre
- the two save buttons collapse into one (see section 7)
- **Acceptance:** a page can be measured, then have clients assigned, in that order.

### Phase 3: retire the heuristic
- once every serving page has slots, drop the `derived` arm from `v_stamp_row_bands`
- a card with no slot and no manual band then gets NO band, which fails the closed-world gate
  **loudly** instead of publishing a guess
- **Acceptance:** the 9 documents currently resting on derived bands are re-measured first. Phase 3
  does not start until that number is 0.

---

## 6. What must not break

- **The 677 served documents.** Guarded by manual-wins plus the byte-identical assertion.
- **`derm.band_review` is keyed on band VALUES**, so any band that does change correctly re-enters
  the review worklist. That is the intended behaviour and must not be worked around.
- **Every guard in `derm._page_geometry_violations` stays.** Slots change where a band comes from,
  never whether it is checked. G13 (own stamp in own band) in particular becomes nearly automatic
  but must still run, because it is the only thing tying a band to the client who owns it.
- **`page_block_extents` keeps its audit trigger**, and `page_slots` opts IN under rule 8: it is
  human-edited and it feeds a regulator-facing redaction.

---

## 7. Two defects found while specifying this, both real, neither fixed

1. **The Studio has two save buttons and one of them silently submits a partial page.** Read off the
   live bundle: the lines path sends `p_bands: $.bands` (every claimed strip, correct), while the
   older drag editor sends `p_bands: P.map(e => Ht[e.id] ?? tn(e)).filter(Boolean)` where `Ht` is
   drag state and `tn` reads `client_row_top_pct`. Both are null for an unedited card, so the row is
   **dropped from the payload**. The server correctly refuses with `G6_MISSING_ROW`, which is what
   Fred saw three times. The server is fine; the button should not be able to submit a partial page.
2. **9 served documents still rest on derived bands.** Pre-existing, not introduced here, and it is
   the population phase 3 depends on.

---

## 8. Open questions for Fred

1. ~~What does "approved" mean operationally?~~ **SETTLED by Fred, 2026-09-07:** *"no separate
   approve step, human lines are authoritative."* See section 8a.
2. **Should an unclaimed slot raise a flag?** It is safe either way (the extent blacks it), but a
   slot with no card is exactly the shape that leaked twice. Recommend: a detector view, empty is
   healthy, not a hard refusal.
3. **Order of work.** Phase 1 is a contained DB change. Phase 2 touches the Stamp Studio Lovable
   project. Do you want them shipped together, or phase 1 first so the DB can be proven before the
   UI moves?

---

## 8a. SETTLED: human lines are authoritative, with no approve step

**Fred, 2026-09-07:** *"no separate approve step, human lines are authoritative."*

So a person drawing lines on the scan IS the approval. There is no second signature, no pending
state, and no queue. What that buys, and what it obliges:

- **A saved human line set takes effect immediately.** `derm.v_page_printed_rules` already behaves
  this way (newest scan per page, `human-v1-%` admitted alongside `runlen-v2-%`), so no change is
  needed to make it true.
- **🛑 The obligation this creates: a later detector run MUST NOT silently displace a human line
  set.** `v_page_printed_rules` picks the newest scan by `scanned_at`, so today a `runlen-v2-` run
  landing after a `human-v1-` set would quietly win and move a serving page's geometry. With no
  approve step there is no human in the loop to notice. **Precedence must become explicit: human
  outranks detector regardless of recency.** This is now a REQUIREMENT of phase 1, not a nicety.
  Measured today: 5 pages carry human lines, so the exposure is small and the fix is cheap now.
- **Slots inherit the provenance.** `page_slots.source` carries the `human-v1-` stamp, and
  `set_by` / `set_at` record who and when, which is the durable form of the approval.
- **Authoritative does not mean unchecked.** Every guard in `derm._page_geometry_violations` still
  runs on a human save. Fred's own `ticket-833049` lines pass all of them cleanly, which is the
  point: the guards are not there to second-guess the person, they are there to catch a payload
  that does not describe the page.
- **`derm.band_review` stays.** It is keyed on band VALUES, so a human-drawn band that later moves
  re-enters the worklist. That is a record of what was accepted, not an approval gate, and it does
  not block anything.

⚠ **The one thing to watch.** Removing the approve step removes the only place a second person would
have seen the geometry before it reached a regulator-facing document. The compensating control is
`derm.v_band_edges_off_rule` plus `v_blackout_blocked_sheets`, both of which are "empty is healthy"
worklists. Those become more load-bearing under this decision, not less.
