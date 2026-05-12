# Architecture Decision Records

Each file in this directory documents one non-obvious decision with lasting architectural impact. The format is deliberately compact: **Status · Context · Decision · Consequences**.

An ADR is added when:
- A choice was made between ≥2 reasonable options, and future engineers will want to know *why*
- The decision constrains future work (e.g. "no source-prefixed columns" constrains every schema change)
- The decision reverses or supersedes an earlier one (note the supersession in the Status)

ADRs are **immutable** once merged. If a decision changes, write a new ADR that supersedes the old one — don't edit history.

| # | Title | Status |
|---|---|---|
| [001](001-webhooks-over-cron.md) | Webhooks over nightly cron | Accepted |
| [002](002-entity-source-links.md) | `entity_source_links` replaces source-prefixed columns | Accepted |
| [003](003-service-configs-3nf.md) | `service_configs` table is 3NF (one row per service type) | Accepted |
| [004](004-intentional-denormalization.md) | Keep `visits.truck` and `visits.completed_by` as text denorms | Accepted |
| [005](005-3nf-standing-check.md) | Every schema proposal must pass a 3NF audit; reference all data | Accepted |
| [006](006-no-quickbooks.md) | No QuickBooks — Jobber is the payment source of truth | Accepted |
| [007](007-samsara-permanent.md) | Samsara integration is permanent (survives Jobber/Airtable sunset) | Accepted |
| [008](008-photos-normalized-out.md) | Photos live in dedicated tables, not inline URL columns | Superseded by 009 |
| [009](009-unified-photos-architecture.md) | Unified `photos` + polymorphic `photo_links` (replaces dedicated tables) | Accepted |
| [010](010-drop-stored-derived-columns.md) | Drop stored derived columns; compute on read (3NF enforcement) | Accepted |
| [011](011-source-of-truth-canonicalization-2026-04-29.md) | Source-of-truth trust hierarchy: Jobber + Samsara canonical; Airtable best-effort except DERM/PRE-POST | Accepted |
| [012](012-visit-vehicle-id-derivation.md) | `visits.vehicle_id` derived from Samsara GPS cross-reference (not user input) | Accepted |
| [013](013-tiered-property-geocoding.md) | Tiered property geocoding (Jobber → Airtable → Samsara → Google Maps) | Accepted |
| [014](014-external-system-references-in-state-tables.md) | Source-prefixed columns allowed in private state tables (refines ADR 002) | Accepted |
| [015](015-supabase-native-recurring-visits.md) | Recurring visit schedule moves from Airtable to Supabase-native cron + `visits.source` + merge promotion | Accepted |
