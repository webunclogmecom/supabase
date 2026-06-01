# DB Reliability Audit — Prod canonical (`wbasvhvvismukaqdnouk`)

**Date: 2026-06-01 · Verdict: the data is reliable.**

Run after a cross-source duplicate client was found, to verify trust in the canonical
data. Probe: `scripts/probes/_db_reliability_audit.js` · raw: `reports/_db_reliability_audit.json`.
~30 checks across duplicates, referential integrity, provenance, nulls, cross-source coverage.

## Headline
- **Referential integrity is spotless** — every foreign-key orphan check returned **0**.
- **391 clients**, 387 (99%) traceable to Jobber, 195 to Airtable.
- Only **4 non-zero findings** — **2 fixed, 2 are by-design** (not corruption). Nothing left open.

## Checks that passed clean (0 issues)
| Area | Result |
|---|---|
| Orphan `visits` → clients / properties / jobs / vehicles / invoices | 0 |
| Orphan `manifest_visits` → manifests / visits | 0 |
| Orphan `properties` / `service_configs` / `gdos` / `client_locations` / `derm_manifests` → parents | 0 |
| Orphan `entity_source_links` → client / visit / manifest targets | 0 |
| One Jobber gid (or AT rec) mapped to 2 client rows | 0 |
| One source id mapped to 2 entities (any type) | 0 |
| Null client name / null visit date / null visit client / null manifest client | 0 |
| Within-client duplicate manifest # / GDO # | 0 |

## The 4 findings
| # | Finding | Count | Verdict |
|---|---|---|---|
| 1 | Duplicate `client_code` | 2 | **FIXED** — `144-LTG` (AT row 147 → Jobber row 466) + `172-NU` (empty orphan 224 deleted). Cross-source merge gap from the 4/29 backfill + later Jobber sync. Backup: `docs/backups/merge_dup_clients_2026-06-01.json`. |
| 2 | Same client + same address on 2 property rows | 150 | **BY DESIGN.** 100% are the Jobber **billing-address vs service-address** split (one row flagged `is_billing`). Not corruption. |
| 3 | Visits with no source link | 454 | **BY DESIGN.** 100% are `source = supabase_cron` — the upcoming visits our own generator creates. Every *externally-sourced* visit IS traceable. |
| 4 | Clients with no source link | 3 → **0 (FIXED)** | 1 was the dup orphan (224, removed). The other 2 (`050-PV`, `150-KOS`) were Airtable-backfill clients; their AT source links were backfilled 2026-06-01 (recs `rechTby…`, `receK6e…`). **Every client is now traceable.** |

## What this means
The duplicate client you spotted (`144-LTG`) was **1 of only 2** such cases in the entire
database, and both are now consolidated. There is **no broader corruption**: foreign-key
integrity is perfect, no source id points to two records, and the two scary-looking counts
(150 property "dups", 454 source-less visits) are expected system patterns, not bad data.

**Root cause of the dup class (for prevention):** the 2026-04-29 Airtable backfill created
client rows; a later Jobber sync then created a *second* row for the same client instead of
matching the existing one (it matched on Jobber gid, which the AT-created row didn't have).
Only 2 slipped through. The AT-sunset wipe+repop (Jobber-canonical) eliminates this path; until
then, the duplicate-`client_code` check in this probe catches any new occurrence.

## Open
- **None.** All findings resolved or confirmed by-design. 391/391 clients traceable to a source;
  0 duplicate codes; 0 orphans.
