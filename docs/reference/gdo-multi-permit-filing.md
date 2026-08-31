# One manifest, several GDO permits: how the filing queue serves them

*Written 2026-08-31 after Jonathan flagged that Casa Neos had three permits and only one filed.
Supersedes the "queue grain = ONE ROW PER MANIFEST" rule from `2026-07-23_gdo_queue_dedup_per_manifest.sql`.*

## The shape of the problem

Some addresses hold several FOG facilities, each with its own DERM permit, behind one grease trap.
One pumping visit produces one manifest, and **DERM wants a report per permit**.

| client | active permits |
|---|---|
| **009-CN Casa Neos** | GDO-10877 (Kitchens), GDO-15062 (Bars), GDO-16389 (Lounge) |
| **242-WYN Wynd 28** | GDO-13814, GDO-16146, GDO-14760 |
| 043-MIL Mila | GDO-14117 (Bar/Lounge), GDO-11024 (Restaurant) |
| 148-MOR The Moore | GDO-14769, GDO-11226 |

Each permit lives on its own `client_locations` row, because `gdos.client_location_id` is UNIQUE.

## What was actually wrong (it was never the permit data)

All three Casa Neos permits filed off manifest 1763, but **one per run, 20 hours apart**:

| permit | filed (ET) | gap |
|---|---|---|
| gdo 63 GDO-10877 | 2026-08-27 16:32 | |
| gdo 64 GDO-15062 | 2026-08-28 13:01 | 20h29m |
| gdo 65 GDO-16389 | 2026-08-29 09:17 | 20h15m |

Those gaps are the `20:00:00` cooldown gate, not coincidence. Three of our own objects were keyed on
the **visit** rather than the **(visit, permit)** pair, and each one alone produces the symptom:

| object | was | effect |
|---|---|---|
| `v_derm_portal_queue` | `DISTINCT ON (manifest_id)` | offered one permit per ticket, lowest `gdo_id` first |
| its lease gate | no `gdo_id` at all | leasing one permit hid its siblings for 20h |
| `derm_portal_submissions` | `UNIQUE (visit_id, run_id)` | a second result in the same run was refused |
| `v_derm_portal_dryrun` | `DISTINCT ON (manifest_id)` | the QA queue could not exercise the fix either |

Fixed by `2026-08-31_0914` and `2026-08-31_0932`.

## 🛑 The rule that must not be undone

**A permit is a row in `gdos`, one per `client_locations` row. Never a comma-separated string.**

Jonathan proposed putting all three permits on the visit record comma-separated. It would have filed
**nothing**: `v_derm_portal_fields` selects permits with `g.gdo_number ~ '^GDO-[0-9]+$'`, and a
combined string matches neither that nor anything else. It also recreates `gdos` id 164
(`'GDO-10877, GDO-15062, GDO-16389'`, client-level, no location), which was demoted to INACTIVE in
July **because it passes the pdf-service `GDO-` filter and can print verbatim on an official county
sheet**. 043-MIL is the precedent in the other direction: its combined `"GDO-14117 / GDO-11024"` was
SPLIT into two proper rows on two locations, not merged.

## 🛑 Order is a safety property

The unique index had to widen **before** the queue did. If the queue serves three permits while
`UNIQUE (visit_id, run_id)` still stands, the second and third results in one run are **rejected**,
and `rpa-derm-result`'s own comment names that the catastrophic path: *a rejected result is a county
filing we have no record of, which then gets served and filed AGAIN*. Widening the index is purely
permissive and safe to land alone; widening the queue first is not.

## NULLS NOT DISTINCT is load-bearing in both indexes

`gdo_id` is nullable on both tables, and **524 of 542** existing submission rows have a NULL one
(dry-runs, and everything before the column existed). A plain `UNIQUE` treats every NULL as distinct,
so it would silently stop deduplicating all of them. Prod is PG 17.6, so the clause is available.
A NULL permit still deliberately blocks **every** permit on the ticket, in the leases table and in all
four queue gates: that is the under-serve direction, which is the correct way to be wrong here.

## The result endpoint no longer infers the permit alone

`rpa-derm-result` used to resolve the permit server-side from the visit
(`fn_resolve_rpa_permit` = lowest unfiled permit), and its comment said *"there is exactly one permit
this result can be for"*. **That guarantee is now deliberately gone.** With several permits in flight
the inference attributes by **arrival order**, which is right in the happy path and wrong on a partial
failure: if the bot files A and C and A fails, the failure is recorded against A and C's success is
then recorded against A too.

So since 2026-08-31:
- `rpa-derm-queue` returns **`gdo_id`** on every report (additive; a bot ignoring it still works).
- `rpa-derm-result` **prefers the bot's `gdo_id`**, validated against that visit's real permit set
  first, and falls back to the inference when the bot sends none. `gdo_number` stays accepted and
  ignored.

⚠ **This is the one part that needs Jonathan.** Until his bot echoes the `gdo_id` back, attribution is
by arrival order. Nothing breaks meanwhile, and the filings themselves are correct either way.

## Verification performed 2026-08-31

Rollback through the Management API was proven to work first (a temp table created and rolled back
really vanishes), so the write tests below committed nothing.

| test | result |
|---|---|
| queue offers the whole ticket at once | Casa Neos manifest 1763: **3** permits in one pass, was 1 |
| lease is permit-scoped | holding only gdo 63 leaves **2** siblings servable, was 0 |
| index allows a full run | three permits under one `run_id`: **3 rows**, was 1 then a rejection |
| negative control, true duplicate | same `(visit, permit, run)` still **BLOCKED** |
| negative control, null permits | two NULL-permit rows in one run still **BLOCKED** |
| deployed endpoint, dry-run mode | HTTP 200, 25 reports, **all 25 carry a non-null `gdo_id`**, **6 tickets served with more than one permit** (009-CN x3, 043-MIL x2) |
| permit validation | accepts gdo 63 and 65 for visit 6568; rejects a nonexistent id and a real permit of another client |
| 🛑 regression | the live queue was **0 rows before and 0 after**: widening the key must never re-serve something already filed |
| rollback integrity | all three real Casa Neos filings intact, zero `testrun%` rows left behind |

## Not tested, and why

`rpa-derm-result`'s new branch was **not exercised by a real POST**. That endpoint writes a
county-filing record and an HTTP call cannot be rolled back, so it was verified by its decision inputs
(the validation predicate above) and by reading the deployed code. The first real multi-permit filing
is the true end-to-end test, and it is worth watching.

## Related

- `docs/migrations/2026-08-31_0914_gdo_multi_permit_per_manifest.sql`
- `docs/migrations/2026-08-31_0932_gdo_dryrun_queue_multi_permit.sql`
- `docs/reference/gdo-rpa-bot-triggers.md` (John's document, verbatim, do not edit the body)
- `docs/migrations/2026-07-23_gdo_queue_dedup_per_manifest.sql` (the per-manifest dedup this refines:
  its purpose, stopping ONE dump being double-served across two visits of the same client, is intact.
  It over-reached only by collapsing genuinely different permits.)
