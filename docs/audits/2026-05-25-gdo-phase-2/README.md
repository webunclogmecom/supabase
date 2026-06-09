# GDO Phase 2 — Backfill max_frequency_days + location disambiguation

## Status as of 2026-05-25

### What's done
- **Phase 1**: `gdos.max_frequency_days INT` column added (`2026-05-25i`)
- **Phase 1 hardening (REVERTED)**: `2026-05-25j` attempted UNIQUE per active property + Casa Neos dedupe. Both wrong per Fred's corrected domain rule. Reverted by `2026-05-25k`.
- **Phase 2a sample (10 GDOs)**: 60% confident / 40% mismatched. Surfaced renewal-staleness bug (40 rows) + 4 client↔GDO misassignments + missing-from-DB Sarpino's. See `02-phase-2a-sample-results.md`.
- **Phase 2a applies (`2026-05-25l`)**: Shipped 2026-05-25 PM with Viktor approval. 47 audit rows. 6 confident UPDATEs, 4 demotes, 40 stale-expiration fixes.
- **Phase 2b bot batch (50 GDOs via Python module)**: 23 CONFIRMED_MATCH, 14 WRONG_CLIENT, 4 DIFFERENT_TENANT, 7 WRONG_GDO_NUMBER, 2 AMBIGUOUS. Critical learning: bot's `facility_name` is misleading (grabs another tenant's name); reliable signal is `issued_to` (e.g. "NB2J INVESTMENTS, LLC DBA FRESKO"). Re-keyed classifier on `issued_to` + `name_match`.
- **Phase 2b applies (`2026-05-25m`)**: Shipped 2026-05-25 PM with Viktor approval (+ 1 hand-edit for conflict avoidance). 49 audit rows. 24 CONFIRMED_MATCH UPDATEs (incl. Rustico reclassified from AMBIGUOUS per Viktor), 18 demotes (14 WRONG_CLIENT + 4 DIFFERENT_TENANT), 5 in-place WRONG_GDO_NUMBER re-links, 2 conflict-demotes (Kosh + Nu Real Coral Gables — bot's recommended GDO already linked to a duplicate client row). 1 deferred (194-PV Pura Vida 41 — needs ops verification). **Incidentally resolved typo pair `GDO-11433`** (id=7 Pura Vida Bakery renamed to correct `GDO-14681`).
- **Phase 2c bot batch (50 GDOs)**: 27 CONFIRMED_MATCH, 13 WRONG_CLIENT, 5 DIFFERENT_TENANT, 5 WRONG_GDO_NUMBER. **Critical learning #2:** bot's `name_match` flag can return false positives (e.g. "Talmudic University" -> "IHOP") *and* false negatives (e.g. "Grove Kosher LLC (Harding Ave)" vs "GROVE KOSHER LLC" classified as not-matched because of the parens). Added a name-similarity sanity check (difflib SequenceMatcher + word overlap) to the analyzer to surface borderline cases for human review.
- **Phase 2c applies (`2026-05-25n`)**: Shipped 2026-05-25 PM under Viktor's standing-rule auto-apply. 40 audit rows. **41 rows auto-applied** (27 CONFIRMED + 9 clean WRONG_CLIENT + 5 clean DIFFERENT_TENANT). **9 deferred to Viktor** (5 WRONG_GDO_NUMBER + 4 WRONG_CLIENT with high name similarity — Fialkoff's, carrot Sunset Harbor, Pura Vida Bay Harbor, Grove Kosher).
- **Phase 2c deferrals (`2026-05-25o`)**: Shipped 2026-05-25 PM with Viktor's per-case approval. 9 audit rows. **2 in-place `gdo_number` UPDATEs** (Pummarola typo `GDO-000951 → GDO-00951`, Talmudic Univ → Talmudic College `GDO-13076 → GDO-00313`). **3 DEMOTEs** (Pura Vida Brickell 701 = 3rd duplicate-client; Roast + Street Bar = bot false-positives caught by difflib check). **4 reclassified CONFIRMED_MATCH UPDATEs** (Fialkoff's, carrot Sunset Harbor, Pura Vida Bay Harbor, Grove Kosher).
- **Phase 2d bot batch (36 GDOs — full remaining pool)**: Excluded 10 rows already finalized in 25o. Analyzed 26 net-new: 12 CONFIRMED_MATCH, 9 WRONG_CLIENT, 3 DIFFERENT_TENANT, 1 WRONG_GDO_NUMBER, 1 WRONG_CLIENT name variation.
- **Phase 2d applies (`2026-05-25p`)**: 24 audit rows — 12 CONFIRMED + 9 WRONG_CLIENT + 3 DIFFERENT_TENANT auto-applied per Viktor's standing rule.
- **Phase 2d deferrals (`2026-05-25q`)**: 2 audit rows. Ironside Cafe → in-place gdo_number rename (`GDO-10248 → GDO-10249`, issued_to PIZZA AT IRONSIDE matches). Cine Citta Cafe → reclassified to CONFIRMED_MATCH (issued_to CINE CITTA LLC matches; bot.name_match=false was a false negative due to "Franck Taieb" suffix in client name).
- **Post-hoc triple-check PDF verification (25r)**: Fred questioned whether Phase 2's rapid bulk runs had been triple-checked (PDF + bot + Viktor). Honest answer: only the 3 Casa Neos rows had all three. For the 8 in-place `gdo_number` renames (the highest-risk operations across 25m/25o/25q), ran a post-hoc PDF audit (`probes/16_verify_renames_pdfs.py`): downloaded each new permit's PDF from the DERM portal and verified the actual permittee. **8 of 8 verified** ✓ — 7 via pypdf text extraction, 1 (The Moore) via direct PDF read (scanned image). PDF for The Moore additionally revealed cleaning-frequency = 60 days, which the bot's parser had missed on 2 prior lookups → shipped as `25r`.
- **FINAL STATE**: **82 ACTIVE / 53 INACTIVE / 135 total**. **81 of 82 ACTIVE rows have `max_frequency_days`** (**98.8% coverage** — only Pura Vida 41 remains, ops-deferred). **82 of 82 ACTIVE rows have current 2026-12-31 expiration** ✓. **2 remaining typo'd duplicate `gdo_number` pairs** (GDO-05180 — one ACTIVE one INACTIVE; GDO-08912 — both ACTIVE).
- **Total audit rows generated this session**: ~172 across 7 migrations (25l/m/n/o/p/q/r), all `app_source='sql'`.

### Open work for ops (surfaced from Phases 2a–2d)

**Won't be solved by more bot batches — needs human action:**

- ~~**148-MOR The Moore** — RESOLVED in 25r via manual PDF read.~~
- **1 ACTIVE row still needs `max_frequency_days`** (out of 82 ACTIVE):
  - **194-PV Pura Vida 41** (id=72, GDO-03375) — bot returned M&L FOOD MARKET for that address; deferred for ops to confirm whether Pura Vida actually operates there.

- **3 duplicate client-row pairs in `public.clients`** that need ops merge:
  - `150-KOS Kosh` ↔ `025-GRO Grove Kosher LLC (Harding Ave)` — same business, 9477 vs 9467 Harding (10 doors apart)
  - `172-NU Nu Real food - Coral gables` ↔ `045-NU Nu Real Food` — same business, 3250 NE 1st vs 3252 Buena Vista (adjacent)
  - `175-PV Pura Vida Brickell 701` ↔ `050-PV Pura Vida Brickell` — same address 1104 S Miami Ave

- **2 typo'd duplicate `gdo_number` pairs** still in the table:
  - `GDO-05180` — one ACTIVE (id=85 `129-BSC Bet Shira Congregation`) and one INACTIVE (id=66 `198-ARY Aryeh Hochner`). Operationally fine since only 1 is ACTIVE.
  - `GDO-08912` — both ACTIVE (id=102 `139-LTG Lettuce and Tomato`, id=29 `144-LTG (Bakery) Lettuce and Tomato`). Likely another duplicate-client pair; needs ops merge.

### Phase 2 stats (this session)

- **6 migrations**: `25l` `25m` `25n` `25o` `25p` `25q`
- **~171 audit rows** generated (`app_source='sql'`)
- **53 demotes** to INACTIVE (audit-preserved per Rule 6)
- **80 `max_frequency_days` populations**
- **53+ stale-expiration fixes** (all ACTIVE rows now 2026-12-31)
- **8 in-place `gdo_number` corrections** (typo fixes + identified wrong assignments)
- **Casa Neos 3-permit disambiguation** (location_label populated)
- **Critical learning surfaced**: bot's `name_match` is unreliable in both directions. Added difflib similarity sanity check to the analyzer.

### What Phase 2 needs to deliver
1. `gdos.max_frequency_days` populated on all 131 ACTIVE rows (~6 done, ~125 to go via Phase 2b bot batches)
2. `gdos.location_label` populated for multi-GDO properties (Casa Neos's 3 done; the 15 pre-existing labels need an audit pass)
3. `gdos.permit_expiration` filled on the 15 ACTIVE rows currently `IS NULL` (net-new GDOs from prior backfill that never captured a date)
4. `gdos.permit_document_path` backfilled from AT GDO PDF (separate task — needs Supabase Storage bucket decision from Fred)
5. Resolve 3 typo'd duplicate `gdo_number` pairs (GDO-05180, GDO-08912, GDO-11433)

### Domain rule (confirmed via web research + Fred 2026-05-25)
- GDO permits are non-transferable; **issued GDO number never changes on renewal**
- Annual renewal cycle; all permits expire Dec 31
- Multi-GDO at one property = distinct facilities (e.g., kitchen/lounge/bar), NOT renewal history
- Casa Neos (property 42) is currently the only DB case with multiple active GDOs at one property

### The GDO Bot (workflow primary tool)
- Lives at `Slack/GDO Bot/` (Slack bot on Railway) + Python module `Slack/DERM/gdo_bot_prod/`
- Returns `frequency_days` from DERM permit PDFs and `pump_frequency_days` from inspection reports
- Already used by `scripts/sync/backfill_gdos_from_derm_bot.py` for net-new GDO inserts
- Phase 2a plan: write parallel script that calls `lookup_gdo_permit` for each of our 135 existing GDOs and UPDATEs `max_frequency_days`

### Viktor coordination
- Tag: `<@U0AKTMAMWP9>`
- Channel: `#viktor-supabase` (C0B08S21HHD)
- Poll cadence: every 3 min, max 3 attempts (9 min total)
- Use for: anything GDO Bot returns unconfident OR not-found

## Folder layout

- `README.md` — this
- `01-domain-model-critique.md` — assessment of Fred's stated model vs DB reality
- `02-phase-2a-plan.md` — execution plan for max_frequency_days backfill
- `02-phase-2a-sample-results.md` — 10-GDO sample run results (60/40 hit rate, surfaced bugs)
- `03-viktor-handoff.md` — record of Viktor message(s) + responses
- `99-restore.sql` — undo for any test mutations
- `probes/` — disposable scripts (`04..07` = sample-pick → apply → verify)

## Applied migrations (this phase)

- `docs/migrations/2026-05-25i_gdos_max_frequency_days.sql` — column add
- `docs/migrations/2026-05-25j_gdos_hardening.sql` — **REVERTED** (wrong domain assumption)
- `docs/migrations/2026-05-25k_revert_gdos_hardening.sql` — revert
- `docs/migrations/2026-05-25l_gdo_phase_2a_sample_applies.sql` — Phase 2a applies
- `docs/migrations/2026-05-25m_gdo_phase_2b_applies.sql` — Phase 2b applies
- `docs/migrations/2026-05-25n_gdo_phase_2c_applies.sql` — Phase 2c applies
- `docs/migrations/2026-05-25o_gdo_phase_2c_deferrals.sql` — Phase 2c deferrals
- `docs/migrations/2026-05-25p_gdo_phase_2d_applies.sql` — Phase 2d applies
- `docs/migrations/2026-05-25q_gdo_phase_2d_deferrals.sql` — Phase 2d deferrals
- `docs/migrations/2026-05-25r_gdo_the_moore_max_freq.sql` — The Moore max_frequency_days from manual PDF read
- `docs/migrations/2026-05-25s_customer_permits_from_gdos.sql` — Phase 3: rewire `customer.permits` view to read from `gdos`
- `docs/migrations/2026-05-25t_rewire_views_from_gdos.sql` — Phase 4a: rewire 6 dependent views (customer.clients, ops.service_configs, ops.v_derm_compliance, ops.v_gdo_expiry, ops.v_route_today, ops.v_service_due) to read permit fields from gdos. After this, ZERO views depend on legacy `service_configs.permit_*` columns. (this session)
- Webhook patched + deployed: `supabase/functions/webhook-airtable/index.ts` — Phase 5 dual-write to both `service_configs.permit_*` (legacy) and `public.gdos` (canonical), then Phase 4b removed the legacy write block entirely (canonical-only). Deploys via `npx supabase functions deploy webhook-airtable --project-ref wbasvhvvismukaqdnouk`.
- `docs/migrations/2026-05-25u_drop_service_configs_permit_cols.sql` — Phase 4b: dropped legacy `service_configs.permit_number`/`permit_expiration`/`permit_document_path` columns. (this session)
- `docs/migrations/2026-05-25w_merge_duplicate_clients.sql` — Phase 7: merged 4 duplicate-client pairs (Kosh→Grove Kosher, Nu Real Coral→Nu Real Food, Pura Vida Brickell→Brickell 701, Bakery L&T→Lettuce and Tomato). FK rewires across 11 dependent tables, conflict handling for 4 UNIQUE constraints (`entity_source_links` source_system, `properties` is_primary, `gdos` client+gdo, `derm_manifests` client+manifest#). (this session)
- Phase 6 PDF backfill: created private Supabase Storage bucket `gdo-permits`, uploaded 50 of 82 PDFs from bot results to `gdo/<gdo_number>.pdf`, populated `gdos.permit_document_path` for those rows. 32 remaining gdos need re-bot-lookups for their PDF URLs (Phase 2c JSON was overwritten by 2d, and Casa Neos's 3 weren't in the bot batches). (this session)
