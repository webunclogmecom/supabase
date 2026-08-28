# Session record, 2026-08-28 (ET) — DERM Stamp Studio

*Written because Fred asked for a record of the day's work. Scope note: `Supabase/` and
`Building Apps/` are shared with the parallel session. **Only my commits are listed here.** The
city-email work, the person-colour standard, the Calendar past-due badge and the filter-bar restyle
landed the same day and are NOT mine.*

The thread began 2026-08-27 ET and ran into 2026-08-28. Git stamps in this repo are **ET + 6h**.

---

## 1. Multi-GDO permit cards

A generated DERM sheet prints **one row per ACTIVE permit**, but `address_row_map` held one card per
client, so a multi-permit client left printed rows **unowned** — the shape that leaked across clients
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
today's permit count and every one is `frozen=1, now=0` — a client with no active permit whom the
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

⚠ **419 of 446 labelled chips read `Main`** — only 7 distinct non-`Main` labels exist. Suppressing it
for single-permit clients is a one-line change if the noise ever bothers you.

## 3. 🛑 The Studio now measures its own printed rules — the day's main piece

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
   the classifier trimmed to ±1e9 — harmless for the 166 pages that have an extent, fatal for the
   ones that do not: footer bars stayed in the chain and the server correctly refused a phase flip.
   Fixed to 16.0..74.0.

⚠ Also found: **`v_page_printed_rules` takes the newest scan and joins rules on that scan's own
source without filtering on grade**, so a new scan carrying no rules would silently strip a working
page. Guarded before writing a line of the RPC.

**Result:** `ticket-312433` p1 and p2 both measured **OK, 14 rules each**; blocked pages 6 → 4; fleet
168 → 170. Fred's original submitted bands re-check **CLEAN**.

## 4. G8: name the client, stop blocking on sub-pixel noise

`3bd625d`. The message read `extent 25.401..62.634 does not contain the bands 25.399..62.634` —
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
sheet can never be auto-placed again. True for placement, false for verification — which is why a
whole-page transposition survived there. Arm B now offers multi-image `ticket-*` folders that have
never been scanned.

## 7. The page tab counter

`31d22f0`. The app carried two notions of page: chips render by `stamp_page`, the export filters by
`stamp_page`, but the tab counter bucketed by **`page`**, the OCR page, which is uniformly 1.
**21 of 133 folders** have that shape, so every tab after the first read `0/0` while still drawing
its chips. Now `row.stamp_page ?? row.page`.

⚠ `ticket-829216`'s `Page 1 — 0/0` is **correct** and must not be "fixed": that folder genuinely has
no cards on its first image.

---

## 🛑 8. A finding I reported and then retracted

`82d78cc` / `2a0c19b`. I told Fred that **55 pages leave a strip of a neighbour's row visible**, 19
of them by 10px or more, worst 43.4px, all serving. **It was wrong. The real number is zero.**

`fn_blackout_targets` clamps before the redactor sees the extent. Across all **654** served
documents, `header_y` equals `min(band_y0_pct)` on every page where the stored extent is tighter
than the bands. Proven by outcome: the 44 pages with an identifiable victim document had their
supposedly-exposed strip measured on the served JPEG in a canvas — **blackFrac 1.000 on all 44**.

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

## Open, not done

| item | state |
|---|---|
| **30 orphaned redacted JPEGs**, publicly fetchable with no ledger row | backed up to `backups/2026-08-27_orphaned_redacted_docs/`, **awaiting Fred's approval to delete** |
| `ticket-312024` p1 | refuses measurement: a full-width bar in a divider slot. **Not forced through**; needs a person to look at the scan |
| `ticket-833049` p1/p2 | frozen by a CHECK constraint, out of scope |
| `ticket-312433` | measured, but still needs bands snapped + page boundary set before its 8 clients get documents |
| multi-GDO permit cards | spec'd (`e5bfcd1`), **not built** |
| `ticket-830714` | frozen and serving; needs stamps placed by a person |

⚠ A Lovable **"Upgrade"** button appeared mid-session; the account may be near a plan limit.
