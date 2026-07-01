# DERM Address-Sheet → Client-Row Mapping Engine — Design

- **Date:** 2026-07-01
- **Author:** Claude (Supabase 2 session)
- **Status:** Approved design → ready for implementation plan (writing-plans)
- **Owner area:** DERM-side (this session). FP blackout consumer = Building Apps, later.

---

## 1. Problem & goal

Every DERM disposal produces a **FOG eManifest "address sheet"** (Miami-Dade DERM_V4.00 form).
Section B ("Origination of Waste") lists **up to 6 serviced facilities per page**, each with a
handwritten **Facility Name** and **Complete Facility Address**. A single dump ticket (disposal
`white_manifest_number`) can span **several pages** = many facilities on one physical sheet-set,
because the truck combines many stops into one disposal load.

Yannick needs, for the ~113 historic address sheets (since 2026-01-01), **to know which facility row
belongs to which client** — so he can (a) receive an annotated copy of each sheet with the **client
code shown next to each row**, and (b) later drive the **Field Portal "blackout"** that hides other
clients' rows on a shared sheet.

**Goal of this project:** a re-runnable engine that produces a **verified row → client mapping** for
every address sheet, stores it as the source of truth, renders Yannick's annotated copies from it,
and surfaces linkage data-gaps as a bonus. Maximum certainty regardless of handwriting; **flag, never
guess**.

## 2. Why this is tractable (the reframe)

This is **not** open-ended handwriting OCR. From the DERM-app linkage we already know, per sheet, the
**candidate set of clients** (with each client's name + DB address). So matching each row is a
**constrained assignment**: place a known small candidate set onto the sheet's rows. That unlocks
three handwriting-proof levers:

1. **Digit anchor** — the **street number + zip** are the most legible-resistant tokens (handwritten
   digits survive messy/soft writing far better than cursive names), and we know each client's exact
   street number + zip.
2. **Elimination** — one-to-one assignment: confidently placing the legible rows *forces* the
   illegible ones by process of elimination.
3. **Name fallback** — when a sheet address differs from the DB address (it happens — see POC sheet B,
   "The Moore"), a clear **name** match still resolves the row.

## 3. POC result (2026-07-01) — validated

Ran **blind vision agents** (3 independent passes per sheet, agents never shown the answers) on 3
real sheets, self-scored against hand-established ground truth:

| Sheet | Rows | Result | Inter-agent agreement |
|---|---|---|---|
| A `828601` (1 pg, 4 clients) | 4 | **4/4 correct** | 3/3 on every row |
| B `828625` (1 pg, 4 clients) | 4 | **4/4 correct** | 3/3 on every row |
| C `827989` (3 pg, 14 linked) | 14 | **9/9 matched · 5/5 junk rows flagged UNMATCHED · 5/5 missing clients flagged** | 3/3 on every decision |

**17/17 placeable assignments correct, every decision unanimous across 3 blind agents.** ~9 agents,
~43 s, negligible cost. Model = **Claude vision only — no paid external model required.**

**Critical finding (sheet C):** for multi-page *combined-load* tickets, the **DB-linked client set ≠
the physical sheet contents**. On C, 9 of 14 linked clients appeared; 5 linked clients (047-PAM,
061-TCE, 077-TCE, 155-PV, 231-CHE) did **not**; and the sheet listed ~5 facilities not in the linked
set (Bagel Boss, a Hallandale Carrot Express, One Oak Walk, Wine & Cheese, Cafe Club — several in
**Broward**, i.e. not even Miami-Dade DERM). The engine must therefore treat the linked set as a
*prior*, not gospel, and **audit** the gaps.

## 4. Approach

- **Constrained match** per sheet: candidate set (code + name + DB address) + the image page(s).
- **Vision model = Claude** (session model), N independent **blind** passes per sheet.
- **Digit anchor first**, name to confirm/break ties.
- **Certainty = inter-agent agreement** (+ street#/zip consistency): unanimous → auto-accept; split →
  **flag** for human confirmation. Ensemble with a second vendor model (GPT-4o / Gemini) stays
  available as a tiebreaker but the POC produced zero disagreements, so it is **not** in v1.
- **Flag, never guess:** `UNMATCHED` rows and unplaced candidates are surfaced, not forced.

## 5. Architecture (components, each independently testable)

1. **Data layer** (`fetch sheets`) — enumerate every address sheet (dump folder) with images since a
   cutoff; per sheet pull candidate clients (`code`, `name`, primary `properties` address) + the
   deduped image page URLs. Reads images **server-side via the `service_role` key** (reads private
   buckets directly) — so it is **independent of Supabase's DERM-storage-privacy flip** and their
   `get-derm-doc` edge fn (that fn is only for the anon frontends). Confirmed with the other session.
2. **Matching engine** (`match sheet`) — N blind vision agents → for each filled row: `page`,
   `row_index`, `facility_name_read`, `address_read`, `assigned_code | UNMATCHED`, `confidence`,
   `evidence`; plus `unplaced_candidates`.
3. **Reconciliation** (`reconcile`) — combine the N passes: per row, majority vote; compute agreement
   (e.g. `3/3`) and street#/zip consistency → final `confidence` + `flags`. Deterministic, no model.
4. **Mapping store** — new table `derm.address_row_map` at **physical-row grain** (see §7). Idempotent
   upsert on the natural key. This is the **source of truth** the renderer + (later) the FP blackout
   read.
5. **Linkage audit** (`audit`) — from the mapping: (a) `UNMATCHED` rows = facility on the sheet with
   no linked client → optionally address-lookup against **all** clients/properties to *propose* a
   link; (b) linked clients with no matched row → possible mis-link. Emits a report; does **not**
   auto-mutate `derm_manifests`/`manifest_visits` (Fred reviews proposed fixes).
6. **Renderer for Yannick** — from the mapping:
   - **v1 (ship first): legend beside the image.** Each sheet = the original image + a numbered table
     (`Row 1 → 092-TCE` · transcribed address · confidence/flag). 100% reliable, no pixel-geometry
     risk. Delivered as the same style of bundle PDF Yannick already receives.
   - **v2 (fast-follow): stamped in the GDO# cell.** De-skew each scan to the fixed FOG template and
     print each code inside its row's GDO# box (`?` for flagged), matching Fred's red-pen look. Gated
     on validating template registration on a sample.

## 6. Data flow

```
derm_manifests + clients + properties ──▶ [Data layer] ──▶ per-sheet {candidates, image pages}
                                                              │
                                             (service_role reads, survives private-flip)
                                                              ▼
                                   [Matching engine: N blind Claude-vision passes]
                                                              ▼
                                   [Reconcile: agreement + digit consistency → confidence/flags]
                                                              ▼
                                   derm.address_row_map  (idempotent upsert, audited)
                                        │                         │
                                        ▼                         ▼
                             [Renderer v1 legend PDF]      [Linkage audit report]
                             (Yannick's annotated copies)  (gaps + proposed links → Fred)
                                        │
                                        ▼ (later, Building Apps)
                                   Field Portal blackout
```

## 7. Mapping store — proposed DDL (subject to schema review)

Grain = one physical facility row on a sheet. Natural key = the storage folder (stable per sheet) +
page + row. References client by **FK only** (no denormalized code/name — Rule 2/3). Raw transcription
(`facility_name_read`, `address_read`) is observed data, not derivable, so it belongs here.

```sql
CREATE TABLE derm.address_row_map (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dump_folder        text NOT NULL,            -- e.g. 'derm/1218' (from the image URL path) = the physical sheet-set
  white_manifest_number text,                  -- disposal ticket # (attribute; may be null on legacy)
  page               int  NOT NULL,            -- page within the sheet-set (1..n)
  row_index          int  NOT NULL,            -- physical top-to-bottom row within the page (1..6)
  image_url          text NOT NULL,            -- the specific page image
  facility_name_read text,                     -- raw transcription
  address_read       text,                     -- raw transcription
  matched_client_id  uuid REFERENCES public.clients(id),  -- NULL when UNMATCHED
  assignment_status  text NOT NULL CHECK (assignment_status IN ('matched','unmatched','low_confidence','proposed')),
  confidence         text CHECK (confidence IN ('high','medium','low')),
  agent_agreement    text,                     -- e.g. '3/3'
  flags              jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {unlinked_facility|proposed_client_id|missing_link|...}
  source             text NOT NULL DEFAULT 'claude-vision-v1',
  reviewed_by        text,                     -- Yannick/Fred confirmation
  reviewed_at        timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (dump_folder, page, row_index)        -- idempotent upsert key (Rule 5)
);
-- Rule 8 (DERM compliance → audit opt-IN):
CREATE TRIGGER audit_address_row_map AFTER INSERT OR UPDATE OR DELETE
  ON derm.address_row_map FOR EACH ROW EXECUTE FUNCTION audit.log_change();
-- updated_at trigger-managed (Rule 7) — reuse the standard trigger.
```

Idempotency: re-running the engine upserts on `(dump_folder, page, row_index)` — re-runnable with no
corruption. Human confirmations (`reviewed_*`) are preserved on re-run (engine only overwrites the
machine columns, never a human's `reviewed_*`).

## 8. Verification / human-in-loop

- **Auto-accept** rows that are unanimous across passes AND street#/zip-consistent (the POC's every
  row). These render with the code, no `?`.
- **Flag** low-agreement / low-confidence / `UNMATCHED` rows → rendered with `?` and listed for
  Yannick to confirm; his confirmation writes `reviewed_by/at` and becomes ground truth.
- The flagged set is expected to be small (POC: zero), concentrated on messy multi-page combined-load
  tickets.

## 9. Scope & phasing

- **This session builds:** data layer, matching engine, reconciliation, `derm.address_row_map`,
  linkage audit, and the **v1 legend renderer** (Yannick's deliverable). Then **v2 stamped renderer**
  as a fast-follow.
- **Deferred (Building Apps, later):** the Field Portal blackout that consumes the mapping. Explicitly
  after this engine ships (Fred, 2026-07-01).
- **Not in v1:** second-vendor ensemble model (kept as a tiebreaker option only).

## 10. Coordination / collision (parallel-session protocol)

- Claimed in `WORKING-NOW.md` (Supabase 2). Overlaps Supabase's **DERM-storage-privacy** work only at
  image *access* — resolved: this pipeline reads images **server-side via `service_role`**, so the
  private-bucket flip and `get-derm-doc` are irrelevant to it (confirmed on the board).
- Writes only a **new** table `derm.address_row_map` — **not** `derm_manifests` schema, storage
  policies, edge fns, or any shared view. New spec file = no git-file conflict.
- Linkage-audit **proposals** are reported to Fred; no auto-mutation of `derm_manifests` /
  `manifest_visits` (avoids racing DERM writes).

## 11. Cost, risks, open questions

- **Cost:** Claude-vision only; ~113 sheets × 3 passes ≈ a few hundred short agent runs. Negligible.
- **Risk — combined-load linkage gaps:** handled by design (audit + flag). The engine improves the
  data rather than trusting it.
- **Risk — v2 stamping geometry** on skewed CamScanner scans: de-risked by shipping v1 legend first
  and validating registration on a sample before v2.
- **Open Q1:** cutoff — all sheets since 2026-01-01 (the current bundle horizon), or all-time? Assume
  2026-01-01 for v1.
- **Open Q2:** `derm` schema table vs `public` — assume `derm.*` (DERM-domain). Confirm at schema
  review.
- **Open Q3:** should the audit auto-*propose* links by address-searching all clients in v1, or just
  flag `UNMATCHED`? Assume **flag in v1, propose in v2**.

## 12. Success criteria

1. Every address sheet since the cutoff has rows in `derm.address_row_map`.
2. On a re-labeled validation set (starting with the POC's A/B/C + a Yannick-annotated sample),
   auto-accepted rows are **≥ 99% correct**; the rest are flagged, not wrong.
3. Yannick receives v1 legend PDFs covering all sheets, most-recent-first, bundled as today.
4. A linkage-audit report lists every `UNMATCHED` row and every linked-but-absent client for Fred.
5. Re-running the engine is idempotent and preserves human confirmations.
