# GDO Phase 2 — Backfill max_frequency_days + location disambiguation

## Status as of 2026-05-25

### What's done
- **Phase 1**: `gdos.max_frequency_days INT` column added (`2026-05-25i`)
- **Phase 1 hardening (REVERTED)**: `2026-05-25j` attempted UNIQUE per active property + Casa Neos dedupe. Both wrong per Fred's corrected domain rule. Reverted by `2026-05-25k`.
- **State right now**: 135 gdos all ACTIVE. `max_frequency_days` is NULL on every row. Casa Neos's 3 GDOs all live with NULL `location_label`.

### What Phase 2 needs to deliver
1. `gdos.max_frequency_days` populated on all 135 ACTIVE rows
2. `gdos.location_label` populated for multi-GDO properties (Casa Neos's 3 are the only confirmed in-DB case today)
3. `gdos.permit_document_path` backfilled from AT GDO PDF (separate task — needs Supabase Storage bucket decision from Fred)
4. Resolve 3 typo'd duplicate `gdo_number` pairs (GDO-05180, GDO-08912, GDO-11433)

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
- `03-viktor-handoff.md` — record of Viktor message(s) + responses
- `99-restore.sql` — undo for any test mutations
- `probes/` — disposable scripts
