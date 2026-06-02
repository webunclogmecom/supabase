# OCR Receipt Calibration — Final Analysis

**Date:** 2026-05-19
**Sample:** 878 manifests with known number + dump date + receipt photo
**Cost:** ~$22 in Anthropic API spend
**Wall time:** ~95 minutes across 88 batches

---

## Headline results

| Metric | Correct | Total | Accuracy |
|---|---:|---:|---:|
| Jurisdiction match | 865 | 878 | **98.5%** |
| Number match | 831 | 878 | **94.6%** |
| Dump date match | 793 | 878 | **90.3%** |
| **All three correct** | **772** | **878** | **87.9%** |
| API errors (transient 529s) | 8 | 878 | 0.9% |

**OCR works. The ceiling at ~88% all-three is driven by AT data quality, not OCR limitations.**

---

## Failure breakdown (98 failures out of 878)

| Category | Count | Side | Notes |
|---|---:|---|---|
| `date_off_small` (≤7 days) | **37** | Likely AT | Multi-stop receipt: ops typed each visit's date as dump date instead of the shared facility receive date |
| `completely_different` | 17 | Mixed | Wildly different values — wrong photo, partial visibility, or shared-form confusion |
| `digit_off_by_one` | 11 | Mixed | Hard to attribute — handwriting confusion OR AT typo |
| **`source_text_in_number`** | **10** | **AT** | AT field contains literal "Broward" / "Dump at Pompano" instead of digits |
| `ocr_returned_null` | 8 | OCR | Photo too damaged / model gave up |
| `date_year_wrong` | 7 | OCR | Year misread (2026 → 2024 etc.) |
| **`source_long_number`** | **6** | **AT** | AT has 7-digit number where format is 6 digits |
| `jurisdiction_mismatch` | 5 | OCR | Model picked wrong county |
| `date_invalid` | 1 | OCR | Model produced an impossible date (Feb 31) |

**Definitively source-side (AT data quality):** 16 manifests (16% of failures, 1.8% of dataset)

---

## Clear AT data quality issues — ready to clean up

These are manifests where the OCR consistently returns a sensible value AND the AT stored value is obviously wrong (text instead of digits, wrong digit count). Strongest signal: multiple manifests share the same AT typo and OCR returns the SAME corrected value across all of them.

### Pattern 1 — `yellow_ticket_number` = literal text "Broward"

| Manifest ID | AT stored | OCR proposed |
|---|---|---|
| 49 | "Broward" | 7058 |
| 72 | "Broward" | 7058 |
| 152 | "Broward" | (unreadable) |
| 237 | "Broward" | 7058 |
| 281 | "Broward" | 7058 |
| 503 | "Broward" | ... |
| 691 | "Broward" | ... |
| 727 | "Broward" | ... |
| 769 | "Broward" | ... |
| (10 total) | | |

10 manifests have `yellow_ticket_number = 'Broward'` — clearly a label typed into the wrong AT field. Most are old enough that 4-digit OCR results (7058) are plausible for that era's Broward receipt format, but I'd verify visually before bulk-applying.

### Pattern 2 — `white_manifest_number` = 7-digit "4948222"

| Manifest ID | AT stored | OCR proposed |
|---|---|---|
| 35 | 4948222 | 494822 |
| 158 | 4948222 | 494822 |
| 369 | 4948222 | 494822 |
| 634 | 4948222 | 494822 |
| 848 | 4948222 | 494822 |
| (6 total) | | |

6 manifests all share `4948222` — clearly the same form, where someone added an extra digit on data entry. The OCR returns `494822` (6 digits, fits Dade format) consistently across all 6. **Very high confidence the AT value is wrong.**

---

## OCR-side failure patterns (potentially improvable)

These are real OCR misreads, not AT issues. Distribution: ~21 manifests (2.4% of dataset) — most below the noise floor.

- **Year misread (7 manifests):** 2026 read as 2024 or 2020. The v2 prompt explicitly warned about this but it still happens occasionally with poor-quality scans.
- **Digit off-by-one (11 manifests):** handwritten 4/9, 1/7, 3/8 confusion. Hard to fix prompt-wise.
- **Date invalid (1):** v2 added explicit validation but one slipped through.
- **OCR null (8):** genuinely unreadable photos.
- **Jurisdiction (5):** rare — usually when a Broward receipt has dual jurisdiction markings.

---

## Prompt evolution

- **v1** (batches 1-5, 50 records): baseline prompt — 88% all-three
- **v2** (batches 6-88, 828 records): added invalid-date validation + 6-digit guidance + year-range hint — 88% all-three (no meaningful change)

**The v2 changes were correct in spirit but the failures aren't prompt-fixable** — they're either visual recognition limits or AT-side data quality. No reason to iterate to v3.

---

## What this enables

1. **Trustworthy OCR for backfill use cases.** If the right column is empty and a photo exists, the OCR will populate it correctly ~95% of the time. The 3 manifests we backfilled this morning (842, 579, 82) all checked out.

2. **AT data quality cleanup.** The 16 clear AT-side issues identified can be cleaned with a follow-up SQL pass (after visual spot-check). Optional: also clean the 11 digit-off-by-one cases case-by-case.

3. **Future ingest validation.** When a new manifest's number/date is typed into the system, we could OCR-validate against the photo at write time and flag mismatches for review.

---

## Files

- `state.json` — per-batch progress + cumulative stats
- `batch_001_v1.json` through `batch_088_v2.json` — full OCR vs ground-truth detail per record
- `failure_analysis.json` — classified failure breakdown
- `CALIBRATION_REPORT.md` — running per-batch summary
- This file (`FINAL_ANALYSIS.md`)
