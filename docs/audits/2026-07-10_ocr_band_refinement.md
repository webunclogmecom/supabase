# OCR block-perimeter refinement — 2026-07-10 (Fred-approved)

**What:** replaced all 511 stamp-midpoint-derived Stamp bands with the ACTUAL printed section-B block
boundaries, vision-measured per page. Data-only change to `derm.address_row_map.band_*` (manual bands,
`band_source='ocr-v1'`) — `v_stamp_row_bands` prefers manual, so the FP Blackout redaction now cuts on
the form's real cell lines instead of midpoint approximations.

**How:** 16-agent vision fleet (wf_98e2b9e6) measured all **127 stamped pages** (covering all 511
placed cards): per page, the y-range of EVERY section-B client block (including empty slots), agents
self-calibrated against the known stamp positions (a stamp outside a measured block forced re-measure).
Result: 116 scanned 6-slot V4 forms + 11 generated 5-slot sheets; 89 high / 38 medium confidence;
0 failures.

**Guarded apply** (`apply_bands.js`, dry-run then --execute): per page — blocks ordered, non-overlapping,
height 2–18%; every card's stamp inside EXACTLY one block; every new band intersects the card's previous
derived band. **511/511 cards passed, 0 pages skipped.** Backup of prior bands:
`backups/2026-07-10_bands_before_ocr.json` (restore = UPDATE band_* back + regen). Fingerprint change
auto-queued 372 derivative regenerations (the redaction sweep + batch driver drain it).

**Generated-sheet finding:** the pdf-service sheets (#1000+, 5 slots) do NOT have fixed pixel geometry
in practice — they reach the DB as CamScanner photos of PRINTOUTS (blocks ≈ y 24–66%, ±1.5% variance
across the 11 pages). Per-page vision measurement therefore stays the pipeline for BOTH kinds; no
template constants hard-coded.

**Ongoing:** new stamped pages get midpoint-derived bands until the next measurement pass — the
redaction gates (fully-banded sheet, order-consistency, page-identity) keep those safe in the interim.
Re-run pattern: export stamped pages → `ocr-band-measure` workflow → `apply_bands.js --execute`.

## Addendum — line-snap pass (ocr-v2) + Fred's review round (2026-07-10)

The fleet estimates carried a systematic ~1.4% bias (proven via pixel diagnostics). A deterministic
line detector (row-darkness profile, jpeg-js) now snaps every band edge to the DETECTED printed line,
grid-fitted with stamp-containment phase disambiguation and conservative tilt handling: **465/511
cards snapped (`ocr-v2-snap`), 12 pages auto-flagged.** Fred reviewed the flagged gallery: 11 OK as-is
(fleet bands kept), 1 repaired manually:

**window11-sheet9 (ticket 815375, sheet 237):** stored 90-deg rotated with EXIF orientation 8 (Studio +
browsers displayed it upright; raw pixels sideways -> line detection impossible, edge-fn EXIF guard +
fully-banded gate correctly blocked ALL generation). Fix: rotated the shared image physically upright
(EXIF-free) at derm/43/address.jpg (+ copies; originals in backups/2026-07-10_w11s9_*); deleted OCR
ghost row 467 ("Pizza-Vola" = misread duplicate of Pummarola/132-PUM; backup json in backups/);
snapped the 4 real bands (band_set_by='fred-review'). All 4 derivatives now generate correctly
(visually verified 061-TCE: upright, own block only, header+cert+disposal intact).

Final state: 377 derivatives, regen queue 0, 1 transient retry (cron-managed). Precision ladder now:
printed-line snap (465) > fleet vision (46 on flagged-OK pages) > stamp-midpoint (new pages until the
next measurement pass). Rerun pattern unchanged (export -> measure -> snap_bands.js).

## Addendum 2 — v2.1 extent geometry (the leak Fred caught) — FINAL STATE

Fred spotted co-clients (Fresko, JZ Steak House) visible below Davinci's row on m1309: v2 computed the
blackout span from BANDED CARDS' min/max, but `ticket-*` folders only card LINKED clients (no full OCR
roster) and same-page cards can carry misaligned `stamp_page` — physical rows below the last banded
card escaped the span. **Audit: 238/377 derivatives under-covered → ALL pulled within minutes** (ledger
+ files deleted; FP fell back to "Coming soon"). Fix (`2026-07-10_fp_blackout_v2_1_extents.sql`):
`derm.page_block_extents` persists the vision fleet's FULL-ROSTER extent per page (all 6/5 slots incl.
empty); the span is now `[LEAST(extent, bands) .. GREATEST(extent, bands)]` minus the own band, and
pages WITHOUT a measured extent emit NO target (hard gate — new pages generate only after a measurement
pass). Regenerated fleet-wide: **377 derivatives, 0 queue, 0 errors, 389 FP work orders serving**;
m1309 visually re-verified (Fresko/JZ black). Lesson recorded: the v2 "blacklist" geometry change
shipped without a fresh adversarial pass — the extent gate restores the default-deny property the
original whitelist had.

## Addendum 3 — full-fleet certification campaign + camera-geotag class + FP smoke test (2026-07-10, FINAL)

A per-derivative adversarial vision certification of the whole fleet (each redacted sheet READ at full
resolution, FAIL if ANY co-client identity OR any camera/GPS overlay text is legible) surfaced one new
leak class the geometry gates could not catch: **camera geotag overlays burned into the SOURCE sheet
photo** — a driver's phone stamped location/timestamp text (e.g. "200 NW 36th St, Miami", "Homestead FL
33032 · 7/4/26 9:48 PM", "Estados Unidos") into the image margins/corners BEFORE upload, so it sits
outside the roster region the blackout spans and rides straight through. Fix = black the overlay at the
**source** image (`patch_source.js`, full-strip box, EXIF-safe, original backed up to workspace
`backups/`) then regenerate. **Gotcha:** a sheet photo can exist as several per-manifest copies
(`derm/<id>/address*.jpg` + `manifests/derm/<id>/address_N.JPG`); patching one and regenerating still
serves an unpatched sibling — you must patch EVERY copy and force a fresh CDN re-pull (delete the
ledger row + redacted file so the sweep refetches). Patched sources this round: `derm/661`,
`derm/261` (a 2nd copy of window7-sheet1), `manifests/derm/1276/address_1.JPG` + `address_2.JPG`.
Final certification of the last geotag batch: **10/10 PASS** (pixel-verified black + vision-verified).
⚠ STANDING RISK: re-uploading/re-scanning any patched source drops the geotag patch → re-patch + regen.

**Final fleet reconciliation (509 carded manifests, exact):**
- **356 serving** — all certified clean, 0 regen queue, 0 errors.
- **21 hard-gated** = the 3 contaminated tickets **824026 / 827989-p4 / 829322** (wrong sheet photo
  attached, contaminated from ticket 827989). They were part of the earlier "377"; certification
  correctly pulled them (377 − 21 = 356). Generate nothing / cannot leak. **Yannick: re-upload the
  correct sheet photos** → a measurement pass then releases them. Their *clean* sibling pages on the
  same tickets still serve (page-level gating is surgical — verified 007-CC on 827989).
- **130 awaiting a banding pass** across 21 distinct sheets (14 of the 21 need just ONE more row
  banded) — held by the fully-banded-sheet gate (default-deny; by design per CLAUDE.md "new stamped
  pages generate nothing until measured"). Not a regression — never in the serving set.
- **2 no-live-visit-link** (041-MB m913, 242-WYN m1205) — no `manifest_visits` row, so no customer
  work order exists to attach a blackout to anyway. Nothing to fix.

**FP visual smoke test (Fred's request — 10 SA clients × 3 orders in the live Field Portal, Chrome):**
all 30 orders passed the DB join/staleness check (every served derivative's manifest belongs to the
signed-in client, FP serves the current ledger URL, none deleted). 10/10 clients visually confirmed in
the app showing ONLY their own roster row + form header/certification/disposal footer, everything else
black — including the hard cases: **815064** (025-GRO, the sole sanctioned legacy cross-client ticket),
**827989** (007-CC, clean page of the ex-contaminated ticket), and the co-loaded yellow-only sheet
**308684** where 019-G7 and 020-G7 each see only their own entity. **FOG eManifest "Preview" already
opens an in-page zoom modal identical to the WWTP receipt** (close X + secondary "Open in new tab"
button) — the earlier "opens a new tab" behavior is gone; no change needed.

## Addendum 4 — the geotag source-patch OVER-BLACKED the printed sheet number (Fred caught it) — CORRECTED

The Addendum-3 "fix = black the geotag at the source" was **wrong on 829201** and Fred caught it: on that
sheet the camera geotag sits in the **same top-right corner as the DERM form's pre-printed sheet number**
(`1009-1` / `1009-2`), so the full-strip source patch (`x 50-100%, y 0-12%`) blacked the number too —
staff opening the raw sheet in the DERM app saw a black box where the page number should be. Root lesson:
**never source-patch a region that can overlap legitimate printed form content, and camera geotags are
NOT client-roster PII** — the blackout's real privacy boundary is Section B (the co-client roster), which
the derivative already hides; a phone's GPS stamp of the driver's photo location is not roster data.

**Verification the geotags are non-PII:** `Homestead FL 33032` → 0 clients in ZIP 33032 (it's the
disposal-facility / Black Point area); `200 NW 36th St, Miami` ≠ La Granja's `2885 NW 36th St` (the only
"36th" client) → neither geotag is any client's address.

**Fix applied:** restored `manifests/derm/1276/address_1.JPG` + `address_2.JPG` to the pristine pre-patch
originals (backups `2026-07-10_bf829201_p*_pre_geotag.jpg`), deleted the ledger rows + redacted files for
mids 1276–1285, regenerated all 10 from clean source. Verified: number region luma 0→166/187 (visible);
**live-verified in FP** (168-AVA order, 829201) — the modal now shows `1009-1` top-right with only
168-AVA's own row visible and the four co-clients still fully blacked. **Exhaustive re-check:** scanned
the top-right number region of ALL 92 distinct source sheets → **0 have a blacked number region**, so
829201 was the only one affected.

**Still open — geotag customer-visibility policy (Fred's call):** 829201 now shows its (non-PII) geotag
in the customer header because it couldn't be separated from the number. `window7-sheet1` (`GT - Visits
Images/derm/661/address.jpg`, mids 261/511/578/661) still carries a LEFT-edge geotag patch — its number
(`072`, top-right) is unaffected, so it was NOT part of this defect, but its "200 NW 36th St" geotag stays
hidden. Policy is currently inconsistent (829201 shows the geotag, window7-sheet1 hides it). To make it
uniform: either restore window7-sheet1 too (show non-PII geotags everywhere — the simplest correct state,
since sources should stay pristine and only the roster is hidden), OR add a derivative-level geotag box
that hides geotags from customers while never touching the number. Awaiting Fred's preference.

**Also corrected (Fred, from the DERM app):** the 3 tickets **824026 / 827989-p4 / 829322** are NOT
wrong-photo "contaminated" as Addendum 3 stated — the raw photos are CORRECT in the DERM app. They are
simply **page_unmeasured**: no `page_block_extents` row yet, so the FP customer blackout can't generate
(FP shows "Coming soon"). Fix is a **measurement pass** (export pages → `ocr-band-measure` → `apply_bands`),
NOT a photo re-upload. Supersedes the Addendum-3 "Yannick re-upload photos" note.

## Addendum 5 — geotag policy resolved + a NEW "why no blackout" class (phantom OCR row) + a band-precision LEAK

**Geotag policy (Fred decided): show non-PII geotags everywhere.** window7-sheet1 restored to pristine
(`GT - Visits Images/derm/661/address.jpg` AND its copy `derm/261/address.jpg` — both needed identical
bytes or the page-identity etag gate fails; `ticket_page_images` resolves to the `derm/261` copy).
Regenerated mids 261/511/578/661; verified only-own-row + number `072` + the "200 NW 36th St" geotag
now visible. All source sheets are now pristine; the blackout hides ONLY the Section-B roster.

**Taxonomy — a blackout can fail to appear in the FP for FOUR distinct reasons** (each needs a different
fix; do NOT assume "re-stamp"):
1. **Unmeasured page** — no `page_block_extents` row (the 3 tickets). Fix: vision measurement pass.
2. **Phantom / duplicate OCR row** — the OCR mis-matched a client onto a sheet they were never serviced
   on; that row has no manifest, so it can't be stamped, and its missing band trips the fully-banded gate
   forever. Fix: DELETE the phantom row (established ghost-row pattern). **825560 (sheet #352, `derm/1158`)
   was this:** OCR added a 6th row matched to `213-TRUE` (True Barista GT), but 213-TRUE's only manifest is
   on ticket **824533** (correctly stamped there, `window4-sheet2`), NOT 825560. The 5 real clients were
   all stamped. Deleted the phantom (id 113, backup `2026-07-10_derm1158_phantom_row113_213TRUE.json`) →
   fully-banded → generated 5 → **certified 5/5, 0 leaks** → **live-verified in FP** (087-BB Bagel Boss
   shows only its own row, #352 visible, 4 co-clients black). ⚠ Watch for the `212-TRUE` vs `213-TRUE`
   labeling on that slot (handwriting reads "GT"=213, manifest says 212 — same operator, low impact).
3. **Genuinely unstamped real row** — Yannick needs to stamp it in Studio (the classic "awaiting banding").
4. **Imprecise (grid/midpoint) bands** — generates but LEAKS: the black band boundary drifts off the
   printed row line and exposes a sliver of the *adjacent* co-client. **This bit the 3 tickets:** after
   measuring their extents and generating 21, the adversarial certification caught **5 co-client leaks**
   (m970, m1220, m1223, m1221, m1330 — each exposing the neighbor's name/GDO#/address). Their bands are
   grid-derived, never line-snapped. **All 21 pulled + hard-gated** (extents removed) → FP back to
   "Coming soon", no live leak. They need an `ocr-v2-snap` band pass before regenerating + re-certifying.
   ⚠ **PROCESS LESSON:** pulling the ledger row alone does NOT stop regeneration — the sweep re-derives it
   from the still-present extent+bands. To quarantine, remove the `page_block_extents` row too (or the
   bands). Confirmed: after removing the 4 extents, `fn_blackout_targets()` = 0 fleet-wide.

**Why 825560 was safe but the 3 tickets leaked:** 825560's 5 bands were already `ocr-v2-snap` (line-snapped
during the earlier pass); the 3 tickets' pages were never in that pass. **Standing rule reaffirmed: a page
must have line-snapped bands (not grid/midpoint) before its blackout may serve — the certification is the
gate that catches the difference.**
