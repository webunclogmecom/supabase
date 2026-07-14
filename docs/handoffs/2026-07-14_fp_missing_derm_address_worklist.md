# FP "missing DERM address" — full scan + stamp worklist (2026-07-14)

**Yan flagged:** the Field Portal does not show the DERM FOG address for 009-CN's 5/12 visit
(ticket 824273) — the "DERM FOG eManifest" card shows the "On file — not available for online viewing"
placeholder instead of the redacted address sheet. He asked which other visits have the same problem.

## Scan result — 32 visits missing the DERM address, 5 missing the WWTP receipt

Of 509 FP work-orders that have a DERM ticket, **32 show the FOG placeholder instead of the redacted
address**. Root cause is NOT random: the per-client redaction (blackout) is only generated once EVERY
row on a sheet is stamped (a safety gate — an unstamped row could otherwise leak). So one unstamped
row freezes the WHOLE sheet. All 32 come from just **6 blocked sheets + 2 quarantined manifests**:

| Sheet | # visits blocked | The UNSTAMPED row(s) that block it (must be resolved in Stamp Studio) |
|---|---|---|
| **824949** | 14 | "The Circuit" 6301 NE 4 Ave (unmatched — new client?) · 214-MYK "MYRA Brickell" (matched, not stamped) |
| **825450** | 7 | one faint pencil row "(illegible)" ~33142 (real client — needs a human read) |
| **822919** | 4 | 009-CN "Casa Neos-B2T" 40 SW N River (matched, not stamped) — *plus 204-JCC quarantined, below* |
| **819788** | 3 | 117-BH, 214-MYK, 035-LG — all matched, just **not stamped yet** (recent 07-10 sheet) |
| **814105** | 2 | top row = 033-LG La Granja Allapattah, 3333 NW 17th Ave (OCR misread it "Unclogme LLC"; fields transposed) |
| **824273** | 1 (009-CN) | MYLA (Lincoln Rd, unmatched) · "Casa Neos Lounge" ×2 (009-CN sub-units) — **Yan's case** |

**+ 2 quarantined (data issues, not just unstamped):**
- **827989 / 007-CC** — wrong-client band (the sheet row shows 052-PV, not 007-CC). Needs a human fix.
- **822919 / 204-JCC** (2 visit dates) — its redaction leaked 114-CI's margin address; pulled + quarantined pending the 822919 re-generation (blocked by 009-CN above).

## To fix (Stamp Studio — Yannick)
Stamp / resolve the blocking rows above. **The moment a sheet's last unstamped row is stamped, all of
its blocked visits' DERM addresses appear in the FP automatically** (the */5 blackout cron regenerates).
A few need a decision, not just a stamp:
- **New clients not in our DB:** "The Circuit" (6301 NE 4 Ave), "MYLA" (Lincoln Rd) — create + match, or confirm they belong.
- **The illegible 825450 row** — needs a human who knows the route to read the pencil.
- **009-CN Casa Neos** appears as multiple sub-units (main / Kitchen / Lounge / Bar) across 824273 + 822919 — decide how to stamp (one client, per-interceptor lines).
- **827989/007-CC + 204-JCC** — data fixes, not stamps.

## 5 visits missing the WWTP receipt (separate)
035-LG, 117-BH, 214-MYK all on **819788** (07-10); 065-TCE **822415** (04-20); 117-BH **821038** (03-25).
These are the raw disposal receipt not yet vision-classified safe (`derm.receipt_doc_class` gate) or
not uploaded — surfaces once classified. (819788 is a fresh sheet; its receipts likely just pending.)
