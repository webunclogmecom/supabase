# ADR 020 — Frozen leads live in Prod, in a private schema `leads`

**Date:** 2026-11-03
**Status:** Accepted, built (migrations `2026-11-03_1700`, `_1730`, `_1800`, `_1848_leads_privacy_fixes`,
`_2039_leads_label_mask_and_quiet_load`); 431 BSI Boca Raton records loaded. Facts corrected the same day, twice: see
the two "Corrections" sections at the end.
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

## Corrections (2026-11-03, after an adversarial check of the build; the decision itself is unchanged)

- **Supersedes line.** The sentence superseded in `Building Apps/04-supabase-schema.md` read, at its old lines 12-13,
  that the Sales App DB is separate by design because sales prospects are leads not yet clients. Building Apps commit
  `28f2a09` replaced it.
- **Decision 2, "a new source = one new `source_system` value and one staging view, no new table".** Also needed: allow
  the value in `leads.ingest` (it refuses anything but `bsi`) and in the views that name `'bsi'`. Still no new table.
- **Decision 4, "no view anyone can read shows them".** No API role (anon, authenticated, service_role) can read them.
  `leads.v_src_bsi` shows them to postgres, to `db_backup_reader` (the leads default privileges cover views) and to
  Supabase's platform roles (`supabase_admin`; `supabase_read_only_user` and `supabase_etl_admin` through
  `pg_read_all_data`), as for every table; every backup copy holds them.
- **Three gaps, fixed by `2026-11-03_1848_leads_privacy_fixes`:**
  - `owner_company` (BSI's mailing name) was a BSI contact person's name on 18 frozen leads. The public views now blank
    it when it equals a contact name.
  - `client.entity_source_links` let every signed-in staff user list the 431 BSI links. It now leaves them out.
  - The loader's dry run wrote the whole payload into the server log once (a failing statement is logged with its
    text). The loader now calls `leads.ingest_quiet`, whose statement never fails.
- **"Viktor reads three ... views, SELECT for service_role only".** They are for Viktor, and his first read is not tested
  yet. `db_backup_reader` also holds SELECT.

## Corrections (2026-11-03 ~20:50 ET, after a second adversarial check; the decision itself is unchanged)

- **The first Corrections section, "No API role (anon, authenticated, service_role) can read them".** True of the CCN
  and the contact fields, but on 3 records the BSI label (the restaurant name BSI shows) is a contact's name, and
  service_role read it in `public.v_frozen_leads.name`, `public.v_lead_interceptors.name` and
  `public.entity_source_links.source_name`. Fixed by `2026-11-03_2039_leads_label_mask_and_quiet_load`: the views blank
  the label when it is a contact's name (on `leads.fn_name_key`), `leads.ingest` no longer copies the label into the
  link, the 431 copies were cleared, and `scripts/checks/leads_integrity.sql` now tests every cell.
- **The same section, "the loader now calls `leads.ingest_quiet`, whose statement never fails".** It still could, in
  three ways: the casts of the loader's literals ran before the function, a lock wait over 1 s is logged with the
  statement, and a cancel is not caught by `WHEN OTHERS`. Fixed by the same migration (text arguments cast inside,
  `lock_timeout` 500 ms, the cancel caught by name; proven live). Left: `auto_explain` logs a statement of 10 s or
  more with its text; a load takes under 1 s.
