# Handoff — FP "blackout": re-expose the raw DERM address sheet per-client, using Stamp Studio's captured regions

**From:** Supabase 2 (DERM Stamp Studio) · **To:** Supabase 1 (FP + backend + pdf-service)
**Date:** 2026-07-06 · **Status:** ready to pick up (data fills in as Yannick stamps)
**Related:** [ADR 017](../decisions/017-derm-address-sheet-privacy.md) (FP address-sheet privacy),
[ADR 019](../decisions/019-derm-storage-private-signed-urls.md) (private buckets + `get-derm-doc`),
Stamp Studio [architecture](../../../Building%20Apps/DERM%20Stamp%20Studio/docs/02-architecture.md).

---

## TL;DR

Today FP **hides the raw DERM address sheet entirely** (ADR 017 Option 1: `customer.work_orders.derm_manifest_url = NULL`) because that scanned page rosters **every** client on the dump run — showing it would leak other customers' names/addresses. ADR 017's better "Path B" (show the sheet with other clients **blacked out**) was **rejected** for one reason: *we had no way to know where each client's row sits on the scanned image.*

**Stamp Studio now captures exactly that** — as a byproduct of Yannick stamping, every facility row gets `matched_client_id` + a **y-band** (`band_y0_pct`/`band_y1_pct`) on the page image, human-**verified**. So the redaction rectangles are now known data. This makes Path B feasible **and** leak-proof — and it's the same shape as the per-client redaction the **pdf-service already ships** for the generated FOG eManifest (black bars over co-clients, commits `6110e51`/`8466973`). This handoff is: extend that proven server-side redaction to the **raw scanned address sheet**, using Stamp Studio's bands as the coordinates.

---

## What Stamp Studio provides (the inputs — all in schema `derm`)

Per facility row on a scanned sheet (`derm.address_row_map`, anon-readable via `derm.v_stamp_rows`):

| Field | Meaning for blackout |
|---|---|
| `matched_client_id` | **whose** row this is — keep the viewing customer's, redact all others |
| `band_y0_pct`, `band_y1_pct` | the row's **vertical extent** on the page image (0–100%) = the black-bar rectangle. Manual (`set_row_band`) or auto-derived. |
| `derm.v_stamp_row_bands` | **auto-derived** bands (midpoints between placed stamps) — bands exist for any page with placed stamps, even without manual band-setting. `COALESCE(manual, derived)`. |
| `stamp_x_pct`, `stamp_y_pct`, `page`, `image_url` | which page image + where the stamp sits (bands span the row) |
| `reviewed_at` / `reviewed_by` | **human verify gate** — only redact from verified rows (a wrong region = a leak) |
| `derm.v_sheet_client_count` (`white_manifest_number`, `client_count`) | **single vs multi-client** per sheet — single → safe to show whole; multi → must redact |

**Real state today (2026-07-06):** 90 sheets — **77 multi-client, 13 single-client** · 496 facility rows, 482 matched · bands auto-derive from stamps (`v_stamp_row_bands` = 72 rows so far) · **verified rows = 1** · **sheets fully captured (all rows placed + verified) = 0.** So the *mechanism* is live; the *data* fills in one sheet at a time as Yannick stamps + verifies. **Blackout goes live sheet-by-sheet, not all at once.**

---

## What Supabase 1 builds (the consumption)

1. **Server-side redacted-image generator** — reuse the pdf-service redaction pattern already proven for `fog_manifest_url`. Input: the raw page image + the list of redact-bands (all rows on that page where `matched_client_id ≠ viewer`). Output: a JPEG with black rectangles **burned in** across each redact-band's full width at `[band_y0_pct, band_y1_pct]`. Store per-client (e.g. `derm/<id>/address-<client_id>-p<page>.jpg`) or generate on demand + cache.
   - ⚠️ **MUST be server-side.** A client-side overlay (black `<div>`s over an `<img>`) is **not** a redaction — the raw image is still in the DOM/network/devtools and every other client's PII is one right-click away. This is a compliance feature; the pixels other clients occupy must never leave the server.
2. **Consumption view/RPC** — for `(client_id, manifest_id or visit_id)`, resolve the page image(s) + the redact-bands (others') gated on the **safety condition** below. Suggest `derm.v_fp_blackout_sheet` or an RPC returning `{page, image_url, redact_bands[]}`.
3. **Safety gate (hard requirement)** — only ever serve a redacted sheet when **every** facility row on that page is `matched_client_id IS NOT NULL` **and** `reviewed_at IS NOT NULL` (fully captured + human-verified). If any row is unmatched or unverified, **fall back to hiding** (current ADR 017 behavior) — never risk serving a page with an un-redacted unknown region. (Single-client sheets per `v_sheet_client_count.client_count = 1` may be shown whole without redaction, still gated on being verified.)
4. **Re-expose in FP** — replace ADR 017's hardcoded `NULL AS derm_manifest_url` in `customer.work_orders` with the redacted raw-sheet URL **when the safety gate passes**, else keep `NULL`. Serve via `get-derm-doc` signed URLs (ADR 019) so the redacted image is private-bucket + short-lived. This finally supersedes ADR 017 Option 1 → Path B.

---

## Suggested flow

```
FP customer opens their visit
  -> customer.work_orders resolves the visit's manifest + white_manifest_number + the customer's client_id
  -> IF sheet single-client (v_sheet_client_count=1) AND fully verified -> serve whole sheet (signed URL)
     ELIF sheet multi-client AND fully verified -> serve per-client REDACTED sheet
        (edge fn burns black bars over every band where matched_client_id != this customer)
     ELSE -> NULL (keep hidden; sheet not yet captured/verified)
```

## Why it's safe now (vs. the 2026-05-27 rejection)

- The leak that broke the old row-shape gate (visit 5079: co-clients on one `derm_manifests` row) is handled because redaction is **per-band by client**, not per-row-count inference.
- The redaction is **leak-proof by construction** (server-burned pixels), like the FOG eManifest one already shipped.
- The verify gate means a human confirmed each region before it's trusted — no auto-redaction of an OCR guess.

## Open questions for Fred / Supabase 1

- Generate redacted images **eagerly** (on sheet-complete in Stamp Studio, via a trigger/edge call) or **lazily** (on first FP request, cached)? Lazy is simpler; eager is faster for the customer.
- Band width: redact the **full page width** at the band's y-range (simplest, safe) vs. only the roster columns. Full-width recommended (a facility name/address can span).
- Do we also want an ops-only "show full sheet" path preserved? (Yes — ops keep `public.derm_manifests.derm_address_url`; only the FP/customer path is redacted.)

## References

- [ADR 017](../decisions/017-derm-address-sheet-privacy.md) — current hide-everything gate + the rejected Path B this completes.
- pdf-service per-client FOG redaction (the proven pattern to extend): ADR 017 §2026-07-01 update, pdf-service `6110e51`/`8466973`.
- Stamp Studio objects: `derm.address_row_map` (bands/verify/match), `derm.v_stamp_row_bands`, `derm.v_sheet_client_count`, `derm.v_stamp_rows` — migrations `2026-07-04_derm_stamp_studio_v2_backbone.sql`, `2026-07-04_derm_stamp_derived_bands.sql`.
- [ADR 019](../decisions/019-derm-storage-private-signed-urls.md) + `get-derm-doc` — private delivery of the redacted image.
