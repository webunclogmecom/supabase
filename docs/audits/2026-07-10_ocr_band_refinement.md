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
