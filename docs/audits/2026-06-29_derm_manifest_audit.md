# DERM Manifest Data Audit + Fixes (2026-06-29)

Triggered by Fred spotting manifest **#827172** showing a wrong number (827989) + a missing DERM Address image.
Scope: all 445 active `public.derm_manifests`; full OCR of all 382 distinct receipt photos.

## How the data is structured (for reference)
- One truck dump = one **manifest/receipt** (Miami-Dade "South District WWTP" red `NO.` form, or Broward "Septage Receiving Receipt").
- A Miami-Dade dump's clients are itemized on a **FOG Single-Load eManifest** ("DERM Address" page) — **max 6 grease interceptors per page** ("Attach Additional Sheets if more than 6"). So **n_clients ≤ 6 × (number of address pages)** is a hard rule for Miami-Dade.
- Each serviced client gets its own `derm_manifests` row, all sharing the manifest number + photos; rows link to visits via `manifest_visits`.

## What was wrong + fixed
### A. Number typos (stored ≠ printed) — OCR-verified, corrected
| Stored | Correct | Type | Rows |
|---|---|---|---|
| 815374 | **815375** | off-by-one (own photo) | 3 |
| 813340 | **814340** | digit typo (own photo) | 2 |
| 306858 | **306859** | off-by-one (Broward) | 14 |
| 826114 | **826477** | wrong number, reused photo | 8 renumbered + 1 dup retired |
| 827172 | **827989** | wrong number, reused photo | (see C — this caused the over-merge) |

### B. Broward ticket numbers were never captured — backfilled
**65 rows** across 7 Broward tickets (294999, 296524, 298064, 300373, 302279, 303478, 305031) had a **blank** number; the receipts clearly print one. OCR-read and backfilled.

### C. CORRECTION of an over-merge I introduced
Renumbering a **reused-photo** batch (a 2nd batch of clients that got another manifest's photo) to match that photo **merged clients onto a dump they weren't on**. 827989 jumped 14 → 18. The 827989 eManifest lists **14** (3 pages). The 4 extras (067-TCE, 103-BWC, 090-OAK, 007-CC) were soft-deleted + their visits unlinked (true manifest unknown → office re-capture). **827989 back to 14.**

## The pattern (capacity audit) — and why it MOSTLY MISFIRED

### Reconciliation pass run + verified 2026-06-29 → NO further deletions
I ran a 14-agent OCR reconciliation over all 73 multi-client manifests, then **verified its output against the actual page images myself**. The automated pass flagged 29 "imposters" across 7 manifests. **Reading the real sheets, every imposter I checked is actually printed on a legitimate attached eManifest sheet of its own manifest.** The automated flags are **false positives** and were NOT applied.

**Root cause of the false positives (two compounding flaws):**
1. **One representative page per manifest fed to each agent.** The reconciliation input carried `addr1` (+ a couple of `extras`) but the DB stores a *distinct address image per client row* for many manifests. So an agent saw 1 of N sheets and called everyone on the other sheet(s) an "imposter."
2. **The "≤6 per page" capacity heuristic assumed one shared page per dump.** In reality a dump legitimately spans multiple ≤6-client sheets ("Attach Additional Sheets if more than 6"), and the app also stores a *copy of the sheet under each client's folder* (byte-identical images, different storage paths). So `n_clients > 6` is NOT an over-merge signal by itself.

**Verified by reading the actual sheets (`scratchpad/p_*.jpg`, `q_*.jpg`):**
- **306859** — sheet 1003-2 lists RAB/CS/ALC/KRU/MP; sheet **1004-1 (ticket 306859) lists the 5 "imposters"** WYN/JER/LG/STM/PAL. They belong.
- **826477** — sheet 357 (ticket 826477) lists TU/DKC/PV/BGT/PV-Wyn; sheet **355 lists the 5 "imposters"** LTG/PV/JZ/FRK/Krudo. They belong (sheet 355's disposal ticket may read 826114 — an attribution split, NOT a coverage gap; see below).
- **300373** — sheet **257 (ticket 300373) lists all 6 "imposters"** HUM/ALC/PC/TCE/GRO/DAV; the other sheet lists G7×2/OAK/BWC/TCE-central/PV-PP. Both legit.
- By the same mechanism, **298064 / 813222 / 823174** flags are under-read false positives.

**Net real over-merge across all 73 = essentially just 827989** (the reused-photo batch), already corrected 18 → 14 (Fred's stated target). **No deletions performed in this pass.**

### Residual real issues (small, for the office — not auto-fixable from images)
- **827989** — ~~14 clients all point to a single stored sheet; additional sheets never uploaded~~ **SUPERSEDED 2026-07-03 (see below) / CORRECTED 2026-07-03 (DB re-verification):** the ticket has THREE address sheets in storage (derm/1218/address_1-3.JPG), all uploaded with the original Jun-23 filing and shared across all 14 rows — this audit saw only the primary because it predated the 2026-07-01 extras-pooling view fix. Links re-verified 1:1 client-matched. Remaining office check: confirm the 3 sheets between them list all 14 facilities.
- **826477 / 306859 number attribution** — my earlier renumbers (826114→826477, 306858→306859) may have merged two adjacent dump tickets under one number. Both numbers are valid DERM; this is a number-accuracy nuance, not lost coverage. Flagged, not thrash-reverted.
- **1 empty record** (id 512, client 287, 1/26) — no image, no number; office to attach or remove.

**Lesson for any future reconciliation:** feed the agent EVERY distinct address image for a manifest (dedupe by image bytes, not by URL), and treat "linked-but-not-on-the-one-page-I-saw" as *inconclusive*, never as "imposter."

## Is it permanent? — NO. These were ONE-TIME data corrections.
Root cause is **manual entry in the DERM Tracker app**, with no validation:
mis-typed red-stamp digits, the same photo re-used for a second batch (→ over-merge), Broward numbers never captured, and no client-count-vs-page-capacity check. **New entries can still produce all of these.**

### Permanent fix — DERM Tracker app guards ✅ SHIPPED + PUBLISHED 2026-06-29
Lovable project `bd120ad4-0103-4780-9534-22a237f86bca` (derm.unclogme.app). Implemented + published 4 deterministic guards that fire on **every** real create/attach path — the Bulk Upload "File" button, "Attach Manifests" (routes to `/upload`), and the Edit Manifest "Save". ("Generate Manifest" only renders a blank eManifest PDF for hand-filling — it writes no row, so it's correctly excluded.)
1. **Sheet capacity** — soft, overridable warning when a manifest's facility count exceeds 6 × (distinct DERM Address sheets attached). NOT a hard block — legit dumps span multiple ≤6 sheets (this audit proved it).
2. **Duplicate number** — soft warning if `white_manifest_number` already exists on another (non-deleted) manifest. Catches typo-collisions + accidental reuse.
3. **Require a number** — hard block on empty manifest number (the ~65 blank-Broward class).
4. **Reused-photo** — intra-session reuse warning + DB-level byte-hash check vs images on a *different* manifest number; soft, overridable. Directly targets the over-merge that produced 827989=18.

**Dropped from the original plan:** in-app OCR-assist (auto-prefill the number from the photo). Reason: this audit watched capable vision models misread these faint CamScanner manifests badly — an auto-prefill would inject *wrong* numbers. Deterministic guards only.

**Not yet verified:** a real happy-path upload (couldn't test from here without writing a junk compliance row into Prod). The office's next manifest entry is the live test; one-click revert available in Lovable if any guard misbehaves.

<details><summary>Original paste-ready prompt (superseded by the shipped version above)</summary>
```
In the DERM Tracker manifest-entry flow, add these validations to stop bad data at the source:
1. CAPACITY: a Miami-Dade FOG eManifest page holds at most 6 clients ("Attach Additional Sheets if more than 6"). When more than 6 clients are added to one manifest, require an additional DERM Address page; block saving if clients > 6 × (number of address pages). Show the count "X / Y capacity".
2. DUPLICATE NUMBER: when the user types/saves a manifest (white_manifest_number), check public.derm_manifests for an existing ACTIVE row with the same number. If found, warn "Manifest 8XXXXX already exists (date, N clients) — is this the same dump or a typo?" before saving. This catches both digit typos that collide and accidental photo/number reuse.
3. BROWARD NUMBER REQUIRED: when the dump is a Broward "Septage Receiving Receipt", make the Ticket Number a required field (it has been left blank ~65 times). 
4. PHOTO REUSE GUARD: if the uploaded manifest photo is byte-identical (or same storage object) to one already attached to a DIFFERENT manifest number, warn before saving — this is the reused-photo error that merged clients onto the wrong dump.
5. (Nice-to-have) OCR-ASSIST: OCR the red "NO." (Miami-Dade) or "Ticket Number" (Broward) off the uploaded photo and pre-fill the number field; if the typed number differs from the OCR'd one, flag it for the user to confirm. This catches off-by-one entry slips.
Do not change anything else in the flow.
```
</details>

All DB changes above are reversible + audited (`derm_manifests` carries audit triggers).


## SUPERSEDED (2026-07-03): the 827989 "over-merge correction" itself was WRONG — reversed with evidence
Fred located the ticket's missing 4th page (typed sheet #1006-1, "Page 2 of 4", signed + ticket-stamped,
never uploaded to storage). The ticket has FOUR address pages listing NINETEEN facilities: the 14 on the
stored pages (#323/#322/#1006-2) PLUS 231-CHE, 061-TCE, 155-PV, 047-PAM, 077-TCE on the found page. The
four rows this audit soft-deleted (067-TCE, 103-BWC, 090-OAK, 007-CC) are on stored sheet #322 —
address-verified — so the "over-merge" deletion removed legitimate rows. Corrections executed 2026-07-03:
4 rows restored + relinked, 087-BB given its own row (visit moved off the cross-client 055-PV attachment),
end state 19 rows / 19 links / 0 cross-client. Root cause of the whole episode: the never-uploaded signed
page + no sheet/page tracking (derm_address_no was 0/455 — the preview workflow never stamps). New
detection surface: `ops.v_derm_ticket_doc_gaps` (migration 2026-07-03k). Backup:
`backups/2026-07-03_827989_link_corrections_backup.json`.
