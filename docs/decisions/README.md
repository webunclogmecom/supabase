# Architecture Decision Records

Each file in this directory documents one non-obvious decision with lasting architectural impact. The format is deliberately compact: **Status · Context · Decision · Consequences**.

An ADR is added when:
- A choice was made between ≥2 reasonable options, and future engineers will want to know *why*
- The decision constrains future work (e.g. "no source-prefixed columns" constrains every schema change)
- The decision reverses or supersedes an earlier one (note the supersession in the Status)

ADRs are **immutable** once merged. If a decision changes, write a new ADR that supersedes the old one — don't edit history.
Two edits are allowed, both dated and neither changing the decision: the Status line (built, superseded), and a
"Corrections" section appended at the end for facts the ADR got wrong (ADR 020 has two). Rewriting the original text is
not allowed.

The Title column summarises each ADR in a few words; the file's own heading is its title.

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
| [009](009-oversized-storage-and-jobber-webhooks.md) | Oversized attachment storage + Jobber webhook delivery path (a second file numbered 009) | Proposed |
| [010](010-drop-stored-derived-columns.md) | Drop stored derived columns; compute on read (3NF enforcement) | Accepted |
| [010](010-audit-trail.md) | Audit trail architecture (`audit.logs`; a second file numbered 010) | Accepted |
| [011](011-source-of-truth-canonicalization-2026-04-29.md) | Source-of-truth trust hierarchy: Jobber + Samsara canonical; Airtable best-effort except DERM/PRE-POST | Accepted |
| [012](012-visit-vehicle-id-derivation.md) | `visits.vehicle_id` derived from Samsara GPS cross-reference (not user input) | Accepted |
| [013](013-tiered-property-geocoding.md) | Tiered property geocoding (Jobber → Airtable → Samsara → Google Maps) | Accepted |
| [014](014-external-system-references-in-state-tables.md) | Source-prefixed columns allowed in private state tables (refines ADR 002) | Accepted |
| [015](015-supabase-native-recurring-visits.md) | Recurring visit schedule moves from Airtable to Supabase-native cron + `visits.source` + merge promotion | Accepted |
| [016](016-audit-app-source-attribution.md) | Audit log app-source attribution (`app_source`, `request_context`) | Accepted |
| [017](017-derm-address-sheet-privacy.md) | DERM "address" sheet privacy gate on `customer.work_orders` | Accepted (option 1 shipped; option 2 deferred) |
| [018](018-derm-required-from-line-items.md) | DERM-required derived from a visit's line items | Accepted |
| [019](019-derm-storage-private-signed-urls.md) | DERM storage: private buckets + signed URLs | Accepted (edge function shipped; bucket flip staged) |
| [020](020-frozen-leads-in-prod-private-schema.md) | Frozen leads live in Prod, in the private schema `leads` (one generic 3NF model, no new table per source; link on the property) | Accepted, built |
