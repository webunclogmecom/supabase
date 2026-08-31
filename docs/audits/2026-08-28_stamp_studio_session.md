# Session record, 2026-08-28 (ET): DERM Stamp Studio

*Written because Fred asked for a record of the day's work. Scope note: `Supabase/` and
`Building Apps/` are shared with the parallel session. **Only my commits are listed here.** The
city-email work, the person-colour standard, the Calendar past-due badge, the filter-bar restyle,
the overlapping-visit design and the frequency-change-reason fix landed the same day and are NOT
mine; that session documented them itself.*

The thread began 2026-08-27 ET and ran into 2026-08-28. Git stamps in this repo are **ET + 6h**.

---

## 1. Multi-GDO permit cards

A generated DERM sheet prints **one row per ACTIVE permit**, but `address_row_map` held one card per
client, so a multi-permit client left printed rows **unowned**, which is the shape that leaked across clients
on 2026-08-19.

- `7352127` a served document now covers **all** of a client's own printed rows, not one.
- `216fd58` / `d8e5bbd` `redacted_manifest_docs` keyed `(manifest_id, effective_page)`;
  `work_order.fog_documents` serves one entry per page. `d8e5bbd` fixed a 40-minute regression where
  the array shipped at the wrong path and 022-GRO briefly served nothing.
- `a8c386f` `add_extra_client_card` binds by **`gdo_number`**, matching `pdf_service`'s sort, not by
  `gdos.id` which disagrees for 3 of the 4 multi-permit clients.
- `a2c28f7` re-placed all 10 stamps on sheet 1102 and gave Casa Neos its Bar/Lounge cards.
- `e5bfcd1` **spec**, not built: forward-only, keyed on the FROZEN `rows_printed`.

**Measured, and it changed the design twice.** 77 of 216 sheet-client rows already disagree with
today's permit count and every one is `frozen=1, now=0`, a client with no active permit whom the
generator still prints once. Re-deriving would emit **zero** rows and drop a printed row. And a
generated sheet is **shared**: sheet 1093 carries 8 clients but only 3 have a manifest in
`ticket-833395`, so an unscoped check reported 7 gaps where there is 1.

## 2. The GDO nickname on the chip

`9946b71` first shipped it as an attached badge; Fred: *"it looks like a mini chip"*. `5acac65`
merged it into **one pill** reading `009-CN · Kitchen`.

⚠ **Known, accepted cost, measured.** The pill is centred on the stamp point and grows both ways, and
`overflow-auto` clips left-overflow. On `ticket-832194` p2 (widest pill 184.8px): **100% zoom +10.6px
margin, 0 clipped; 75% −15.2px, 2 of 3; 50% −40.3px, 3 of 3.** The pre-nickname chip was −2.7px at
50%. Fine at the default, degrades zoomed out. Do not "fix" it by re-splitting the badge.

⚠ **419 of 446 labelled chips read `Main`**, and only 7 distinct non-`Main` labels exist. Suppressing it
for single-permit clients is a one-line change if the noise ever bothers you.

## 3. 🛑 The Studio now measures its own printed rules, the day's main piece

Fred, blocked by ten `G9_OFF_RULE` lines: *"I don't want to be needing you to do that, it's supposed
to be something done by the app, what about an office member like diego."*

He was right, and that was the real defect. The guard was correct; **nothing in the product ever
produced the data it demanded.** Every `page_row_rules` row in history came from a developer running
a Playwright script and hand-writing a migration.

- `efd4ebb` **spec**. `c54e303` `derm.record_page_rules` + `fn_validate_page_rules`.
  `b891fb3` / `095ffbb` the in-browser detector and its canonical reference copy. `ffe6626` docs.
- Runs **client-side**: pure canvas pixel arithmetic, no AI call, no server. The app already loads
  the image `crossOrigin="anonymous"` and already uses canvas for the PNG export.
- Automatic on first open; **"Re-measure printed lines"** otherwise.

**The port was validated against the developer pipeline.** `ticket-832194` p1 already carried 11
rules from the 2026-08-21 fleet run; re-measured through the shipped app it reproduced
**11 of 11 identically, including every run value**.

### The database validates rather than re-implements

I **deviated from my own spec** and said so in the migration header. The spec put classify.js's ~200
lines into PL/pgSQL; reading that file changed my mind. The app classifies (JS to JS) and the DB
validates and fails closed, because the dangerous error is independently detectable: a **phase flip**
passes an alternation check, since both phases alternate, but cannot survive a split of the run
values.

### Two defects testing caught

1. **Writing rules only on grade `OK` would have helped nothing.** All four blocked pages grade
   SPARSE, and 12 of the 168 already-working pages are non-OK and carry rules. SPARSE means a
   boundary is *missing*, not that a detected line is fake. Rules now write on any grade except
   FAILED.
2. **The first end-to-end run FAILED.** The detector assumes a roster of 18..72 with no extent while
   the classifier trimmed to ±1e9. That is harmless for the 166 pages that have an extent, fatal for the
   ones that do not: footer bars stayed in the chain and the server correctly refused a phase flip.
   Fixed to 16.0..74.0.

⚠ Also found: **`v_page_printed_rules` takes the newest scan and joins rules on that scan's own
source without filtering on grade**, so a new scan carrying no rules would silently strip a working
page. Guarded before writing a line of the RPC.

**Result:** `ticket-312433` p1 and p2 both measured **OK, 14 rules each**; blocked pages 6 → 4; fleet
168 → 170. Fred's original submitted bands re-check **CLEAN**.

## 4. G8: name the client, stop blocking on sub-pixel noise

`3bd625d`. The message read `extent 25.401..62.634 does not contain the bands 25.399..62.634`,
naming no edge, no client, no action. It now emits **one row per offending client**:

> The TOP page boundary (25.945) sits below **091-SB - Main**, whose row starts at 24.945. Move the
> top boundary up by at least 1.000pp…

And the comparison was exact, so it fired on **0.002pp = 0.04 of a pixel**. The redactor rounds to
integer pixels, so the tolerance is now 0.05pp. VERIFY keeps the control: 1.0pp still blocks.

## 5. Layout: the save bar and the banner

`57a0b22`. The bar already had `sticky bottom-0` and **could never engage**: the scroller's
hardcoded `calc(100vh - 140px)` under-reserved by 74px, the shell overflowed the viewport by 98px,
and `main` never actually scrolled so there was nothing to stick inside. Replaced the magic number
with a real flex column (`h-screen` / `flex-1 min-h-0` / `shrink-0`). The amber banner was
`absolute top-0` and covered **32px of the sheet**; now in normal flow.

Shell is now exactly the viewport, the document does not scroll, the bar is fully visible, and the
image still reaches its bottom edge. The page boundary is now **blue**, distinct from the client-row
rectangles (`736e34d`).

## 6. `ticket-833813` and the OCR sweep that skipped it

`ba9195a`. `fn_sheet_number_ocr_targets` excluded **fully-placed** folders, reasoning that a placed
sheet can never be auto-placed again. True for placement, false for verification, which is why a
whole-page transposition survived there. Arm B now offers multi-image `ticket-*` folders that have
never been scanned.

🛑 **THE REASON THIS IS A PREDICATE FIX AND NOT A SECOND ONE-OFF: IT HAD ALREADY RECURRED.**
`ticket-833813` was corrected by hand on 2026-08-27 and the fleet was swept the same day, which
produced the sentence *"833813 was the only transposition."* The next morning Fred opened
`ticket-312433`: *"was showing as completed by AI but ALL the stamps were incorrect."* Same defect,
same mechanism, all 8 stamps on the opposite scan, and the folder had auto-completed itself.

The sweep could not have caught it. It enumerated folders that were fully placed **and never
scanned at that instant**, and on a generated sheet `trg_ab_autoplace_generated` places every card
at INSERT, so a folder is *born* in exactly that state and a new one can appear at any time.
**Fixing the instance twice without fixing the predicate is why it recurred**, which is the whole
argument for Arm B.

⚠ **Arm B is self-draining, so state its limit rather than reading it as coverage.** It stops
offering a folder the moment any scan read exists, so it does not cover a folder scanned once and
read wrong. For that, the handler's EXPLICIT mode is still the only route.

✅ Measured 2026-08-29: **19 multi-page `ticket-*` folders, all 19 fully read**, 0 partly read,
0 unread, number-OCR queue empty. `a2c28f7` re-placed sheet 1102 on the corrected mapping
(printed page 1 to image 2, page 2 to image 1) and took the folder from 8 cards to 10.

## 7. The page tab counter

`31d22f0`. The app carried two notions of page: chips render by `stamp_page`, the export filters by
`stamp_page`, but the tab counter bucketed by **`page`**, the OCR page, which is uniformly 1.
**21 of 133 folders** have that shape, so every tab after the first read `0/0` while still drawing
its chips. Now `row.stamp_page ?? row.page`.

⚠ `ticket-829216`'s `Page 1 - 0/0` is **correct** and must not be "fixed": that folder genuinely has
no cards on its first image.

---

## 🛑 8. A finding I reported and then retracted

`82d78cc` / `2a0c19b`. I told Fred that **55 pages leave a strip of a neighbour's row visible**, 19
of them by 10px or more, worst 43.4px, all serving. **It was wrong. The real number is zero.**

`fn_blackout_targets` clamps before the redactor sees the extent. Across all **654** served
documents, `header_y` equals `min(band_y0_pct)` on every page where the stored extent is tighter
than the bands. Proven by outcome: the 44 pages with an identifiable victim document had their
supposedly-exposed strip measured on the served JPEG in a canvas: **blackFrac 1.000 on all 44**.

The one residual, `derm/1246` p1 at 0.074pp, is **half a pixel** on a 724px document and at 6x is the
printed rule itself.

**Every number I measured was correct; the sentence I wrapped around them was not.** I measured
STORED state and asserted something about RENDERED output without checking the transform between
them. This repo already had the rule written down: *instrument the inference*.

✅ `derm.v_served_blackout_short` now measures the **published document**. Empty means healthy and it
is empty. Tolerance is **one pixel derived per page** from `image_h` (scan heights run 485–2492px, so
any constant is wrong at one end). Its VERIFY carries both controls: the stored discrepancy must
still be present, and at zero tolerance the query must still return rows.

🛑 **Never compare `page_block_extents` against `v_stamp_row_bands` and call the result a leak.**

---

## 9. `ticket-312024` measured and published, and the etag defect that inflated the worklist

Fred measured p2, then p1, through the Studio's own re-measure button after
`2026-08-28_2010` recorded the labels the classifier could not derive. The folder left
`derm.v_blackout_blocked_sheets` and the sweep drained it: **all 9 card-pages are now served**
and the fleet-wide blackout queue is empty.

🛑 **A defect I shipped the same afternoon, worth keeping because it failed in the direction
that looks like a finding.** `derm.record_page_rules` did not write `source_etag`, and
`edge_verdict` tests `source_etag IS DISTINCT FROM derm._img_etag(...)` **before** it looks at
any edge gap. NULL is DISTINCT FROM everything, so every page measured through the app graded
`STALE` and the worklist went **2 to 15**. Thirteen of those were not geometry at all.
Fixed by defaulting the etag inside the RPC (`2026-08-28_2110`), with a backfill.

⚠ **A new detector that writes its own provenance must write ALL of it.** The etag is not
metadata about the scan, it is an operand in the grade.

## 10. `expected_slots` counted slots per CLIENT, so every multi-permit card failed

The last three rows on the worklist were Casa Neos on `ticket-312433`, graded `ODD_SLOT`, and
all three bands were correct: `ON_RULE` at both edges, gaps of 0.102 to 0.228pp against a
0.35pp tolerance, tiling 33.104 to 40.108 to 47.251 to 54.778 with no gap and no overlap.

`derm.v_band_edge_check.expected_slots` counted every printed row a **client** owns on a page
and applied that total to **each** of its cards. Right when a client held one card; wrong since
the multi-GDO split gave a client one card per permit, each covering a single printed row.

**This is the third thing the split has quietly invalidated**, after the card ordering in
`add_extra_client_card` and the per-page keying of served documents. Anything still assuming
one card per client is a candidate for the same review, and that is the reusable part.

The fix divides by the cards the client holds on that page, and it is right in both directions:
3 rows / 3 cards = 1 for Casa Neos, and **3 rows / 1 card = 3 for 242-WYN on `ticket-833395`**,
which is still un-split and whose band really must span all three of its printed rows.

⚠ **VERIFY 2 is the assertion that matters, not VERIFY 1.** A divisor that flattened a genuinely
multi-row band to 1 would satisfy the Casa Neos check just as well and be wrong, so the control
pins 242-WYN at 3. VERIFY 5 covers the other direction: a band dragged 1.5pp off its rule must
still reach the worklist, or every clean row above it means nothing.

`2026-08-28_2150`. Body spliced out of `pg_get_viewdef` by script against a single asserted
anchor, so nothing else in the view moved.

**Worklist 6 to 4, and no survivor is an exposure:**

| folder | why |
|---|---|
| `ticket-830714` p1, 009-CN and 034-LG | pre-existing. Frozen on the closed-world gate, bands still derived, needs a person to place the missing stamps. Better geometry cannot clear it. |
| `ticket-312024` p1, 067-TCE and 215-G7 | **false positives, and symmetric**, which is the tell. Both bands are right. The newest scan of that page is missing the roster's FIRST boundary at 24.420 and its LAST at 62.564, so the top client's top edge and the bottom client's bottom edge fall back to the nearest surviving divider (28.608, 58.505) and read 4.296 and 4.059pp. That is the `classify.js` end-trim limitation from section 3: the trim strips only LONG bars, and here the outermost rule at EACH end is short, so the chain loses a real boundary at both ends. 067-TCE's top sits 0.108pp above the true boundary (outward, into the header region); 215-G7's bottom sits exactly on 62.564. Neither reaches another client. |

⚠ So the end-trim limitation is no longer only a blocker for measuring a page. Now that
`ticket-312024` is serving, it also **manufactures worklist rows on correct bands**, one at each
end of the roster. Changing the trim still has to be validated against all 168 already-measured
pages, so it is still its own piece of work, but it now has a second cost.

## 11. The operating manual was carrying three claims this work made false

`Supabase/CLAUDE.md` is the file every session reads first, so drift there is not a tidiness
problem: a reader acting on any of these would have done the wrong thing. Corrected in place in
`60a1ced`, with the old wording quoted in each case rather than deleted, because the trail is the
point.

| the manual said | why it was false |
|---|---|
| *"a multi-permit client gets one stamp ... the data model cannot express it today"* | `derm.address_row_map.gdo_id` expresses it. **449 of 709 cards carry a permit**, and 4 folder-client pairs hold more than one card. |
| *"833813 WAS THE ONLY TRANSPOSITION"* | `ticket-312433` was a second one the next morning, and the sweep behind that sentence was structurally incapable of finding it. |
| the `expected_slots` rule, stated per CLIENT | it is per CARD since `2026-08-28_2150`. The manual's own 242-WYN example is what makes the division right rather than a carve-out, so it is kept and pointed at. |

Two more places said something was impossible that is now routine: **"THE DOCUMENTED RERUN PATH DOES
NOT EXIST"** (the Studio now measures its own printed rules) and **"Always populate it"** about
`source_etag` (`record_page_rules` now computes it). Both were left standing with the correction
appended, because the reasoning under them is still the reason the thing matters.

⚠ **Every number in that update was re-measured against live Prod on 2026-08-29**, not copied out
of the migration headers that introduced it. The headers were right; a manual is read months later
and a stale count there reads as current.

⚠ The parallel session pushed two commits touching the same file while I was editing it. Their 85
lines are intact and my commit removed exactly the 5 anchor lines it was meant to replace, verified
with `git diff 6b0005f HEAD -- CLAUDE.md`.

## Open, not done

| item | state |
|---|---|
| **30 orphaned redacted JPEGs**, publicly fetchable with no ledger row | backed up to `backups/2026-08-27_orphaned_redacted_docs/`, **awaiting Fred's approval to delete** |
| `ticket-312024` | **CLOSED.** Fred measured both pages through the Studio; the folder left `v_blackout_blocked_sheets` and all 9 card-pages are served. Two residual worklist rows (p1 067-TCE and 215-G7) are symmetric false positives from the end-trim limitation below, not an exposure |
| `ticket-833049` p1/p2 | frozen by a CHECK constraint, out of scope |
| `ticket-312433` | **CLOSED.** All 8 card-pages published, both page boundaries set |
| `classify.js` end-trim | strips only LONG bars, so a page whose outermost rule at each end is SHORT keeps its header or footer bar in the roster chain and every label below inverts. It now costs twice: it blocks measurement, and on a serving folder it manufactures a worklist row on a correct band. Fixing it means changing the trim and re-validating all 168 measured pages |
| multi-GDO permit cards | spec'd (`e5bfcd1`), **not built** |
| `ticket-830714` | **that line was stale, corrected 2026-08-31.** The stamps WERE placed (2026-08-27 20:56), so it is no longer frozen on the closed-world gate; its blocker is now `needs_snap_then_extent`. It serves 3 documents built from DERIVED bands with **0 extents**, so it cannot regenerate and improving its geometry changes nothing about what those 3 clients see until a measurement pass runs |
| `ticket-312500` | **new since 2026-08-29**, same state as 830714: 2 cards stamped, bands derived, 0 extents, **0 documents**, so its 2 clients see no FOG sheet. Blocked 2 days |
| 🛑 830714's two flags: that line said "look like FALSE POSITIVES" and it was HALF WRONG, corrected 2026-08-31 | It was right for **009-CN** (owns three printed rows, band spanning them is correct, `expected_slots` reads 1 on the N=1 fallback) and **wrong for 034-LG**, whose derived band starts 2.371pp above the true slot-4 boundary and contains Casa Neos Lounge's address line. **The wrong half is the half that leaks.** I had reasoned from the row OCR, which says who owns which row and cannot say where an edge falls between them; opening the served images and cropping the strip is what settled it. Reviewed in full and recorded `repair_needed` in `derm.band_review` (`2026-08-31_1045`) |
| ✅ what 830714's 3 clients SEE is clean | all three served documents opened: each shows only its own rows, empty slot 6 blacked for everyone. Nothing withdrawn. The leak above is **latent**, blocked by the folder having no extent |
| ✅ `G14_SPANS_EXTRA_SLOTS` **RESOLVED without relaxing it** | Casa Neos was given its three permit cards (`2026-08-31_1130`), so every band spans exactly one slot and `check_page_geometry` returns clean. **G14 only bites an UNDER-CARDED client**; the refusal was pointing at the real defect, not at itself. The latent 034-LG leak went with it (band 41.762 to 44.133) |
| ✅ 830714 complete, blocker now `needs_extent` | 5 cards, all placed and banded on canonical boundaries, fleet band worklist 4 to 2. **Nothing published**: the page boundary is deliberately unset and is Fred's to set in the Studio |
| ⚠ `ticket-833395` will refuse the same way | 242-WYN, 3 active permits, 1 unbound card. `add_extra_client_card` refuses while any of the client's cards has a NULL `gdo_id`. **Harder than 830714**: it holds an extent and serves 3 documents, so splitting it changes what a client sees |
| ⚠ `ticket-820714` is a TYPO folder, not retired | no manifest carries white number `820714`; the paper is `830714`. Its verified layout was ported across and it is now inert. Retiring it is a delete and awaits Fred |

⚠ A Lovable **"Upgrade"** button appeared mid-session; the account may be near a plan limit.
