# ADR 020 — Frozen leads live in Prod, in a private schema `leads`

**Date:** 2026-11-03
**Status:** Accepted, built (migrations `2026-11-03_1700`, `_1730`, `_1800`); 431 BSI Boca Raton records loaded
**Supersedes:** `Building Apps/04-supabase-schema.md`'s "prospects live in a separate DB by design" (lines 10-13)
**Related:** ADR 002 (entity_source_links), ADR 010 (audit trail); plan `docs/specs/2026-11-03-boca-bsi-leads-and-filing-plan.md`

## Context

Trello #165 / #166: scrape every Boca Raton restaurant from BSI Online (the City's grease program portal) and keep them
as "frozen leads" (Yan: *"we never contacted them, we know nothing about them"*) that become clients when a contract
is signed, without duplicating the clients we already have, readable by Viktor. Fred, 2026-11-03: *"should we create a
separate DB or add it to the current one, if so i want a generic leads one with 3NF as well, in case we get like another
source of leads too, so they merge, including a reference for their source obviously"*.

What already existed: Yan's Miami-Dade list in the HR Sandbox's `frozen_leads` schema (9,890 GDO permits, a CRM
prototype, marked never-touch), a newer Google Sheet, a paused "frozen leads" Supabase project, and the Sales App's
separate database. Prod's own `public.leads` (a copy-style lead table) was dropped on 2026-04-30.

## Decision

1. **Same database (Prod), one private schema `leads`.** Matching and converting a lead need real foreign keys into
   `properties` and `clients` inside one transaction, which two databases cannot give (no cross-database foreign keys,
   no two-phase commit in postgres_fdw). One backup, one audit trail and one RLS trigger cover it, at about $0. Two
   separate projects already failed here (the Client App Mirror's 154 silent failed refreshes; the Sales App's loose
   ids). A separate database is right only for a different lifecycle or a legal isolation duty; neither applies.
2. **A thin, generic model** (web research: HubSpot / Twenty / Odoo point a lead at shared master rows; MDM keeps source
   records as received; Data Vault versions content only when it changes):
   `establishments` (our decision only), `source_records` (one per outside record, its id in `entity_source_links`),
   `source_versions` (append-only content with `fetched_at` / `last_seen_at`), `match_decisions` (insert-only, who and
   why). A new source = one new `source_system` value and one staging view, no new table.
3. **"Frozen" is computed, never stored**: not linked to one of our properties and no possible client match waiting
   for a person. Matching is a review, never automatic in v1 (a strip mall shares address, parcel and phone).
4. **Private payloads.** CCNs and BSI's contacts are kept in `source_versions` by Fred's choice; no view anyone can read
   shows them. Viktor reads three postgres-owned views in `public`, SELECT for service_role only (his tools see `public`
   only).
5. **The client link is on the property**, the grain the filing bot (Trello #169) joins on.

## Consequences

- A new schema needed four edits (RLS function, RLS check, backup schema list, backup grants); the Supabase CLAUDE.md
  "FROZEN LEADS" section lists them.
- Nobody can contact a frozen lead yet: a release step, a do-not-contact list keyed by phone or email, and one contact
  rule come first (TCPA: an AI or prerecorded sales call to a mobile needs prior written consent).
- Google Places content: only the `place_id` may be stored long-term; phone, website and hours are fetched when shown.
- The Miami-Dade universe lands later through the same `leads.ingest` (a `derm` feed), from a fresh DERM list plus
  Yan's own decision columns; the HR Sandbox stays untouched.
