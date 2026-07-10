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
