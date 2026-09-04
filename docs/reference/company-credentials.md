# Company credentials: hauler licenses and vehicle decals

*Source: Fred, 2026-09-04. Canonical.*

Two different things, at two different grains, and they have been confused in this estate's own code
and docs. Get this right before printing anything on a regulatory form.

| | Miami-Dade | Broward |
|---|---|---|
| **Hauler license** (company) | `LW-1133` | `WT-26-0104` |
| **Decal** (per truck) Moises | `C1184` | `07675` |
| **Decal** (per truck) David | `C0976` | `07058` |

Cloggy and Goliath hold no decal in any jurisdiction. Fred's rule, 2026-08-05:
*"if the truck isn't here then we don't have its decal or is inactive."*

## Where each lives

| | table | grain |
|---|---|---|
| hauler license | **`public.company_hauler_licenses`** (new, `2026-09-04_1738`) | one ACTIVE row per jurisdiction |
| decal | `public.vehicle_decals` | one per (vehicle, jurisdiction) |

The decals were already correct and were **not touched** by that migration; the four live rows match
Fred's table byte for byte. Only the company-level license was missing, and it had no home anywhere in
the database. It existed solely as a hard-coded TypeScript literal, which is how it came to be marked
"From Database" on Yannick's Broward manifest config while being readable from no table at all.

## ✅ The shipped code was corrected on 2026-09-04

It used to disagree. `_shared/city-letter.ts` and `send-visit-photos-email/index.ts` each carried a
comment reading *"These are the company DECAL numbers, one per county. They are NOT the hauler licence
number (#1404-25)"* above a constant named `DERM_DECALS` holding both numbers.

Fred: *"yes fix city-letter.ts and the other copy."* Both were changed together:

| | before | after |
|---|---|---|
| constant | `DERM_DECALS` / `DERM_DECALS_TEXT` | `HAULER_LICENSES` / `HAULER_LICENSES_TEXT` |
| Dade value | `LW 1133` (space) | **`LW-1133`** (hyphen) |
| comment | "these are DECALS, NOT the hauler licence" | Fred's canonical table |

Deployed and **verified against the LIVE bodies, not the git tree**: `send-derm-email` **v51**,
`send-visit-photos-email` **v31**, each asserted for the new constant, the corrected date and the
absence of the old identifier, with `api.resend.com/emails` as the positive control.

⚠ **The rendered footer changed and it is regulator-facing.** Both emails now print
`Licensed Grease Trap Hauler` / `Miami-DADE: LW-1133 · Broward: WT-26-0104`, in the HTML and the
plain-text part. Only the hyphen moved. **The heading was always "Licensed Grease Trap Hauler", which
is the strongest evidence these were hauler licenses all along and the comment was the thing that was
wrong.**

⚠ **The hyphen is deliberate.** Fred, 2026-09-04: *"Keep the Hyphen over a white-space."* Do not
normalise it back.

## 🟡 One thing still open

1. **`#1404-25`.** `docs/company.md:16` calls it *"DERM License: Permit #1404-25 (active 2025-2026)"*
   and memory calls it the Miami-Dade Licensed Grease Trap Hauler number. If `LW-1133` is the Dade
   hauler license, these are either two different credentials or one of the two records is wrong.
   **No row is written for it.** Do not guess and backfill one.
2. ~~**Spelling.**~~ **RESOLVED 2026-09-04.** Fred kept the hyphen and the shipped code was brought
   into line. `LW-1133` everywhere.

## Where they are used

- **Broward Address** (FDEP form `62-705.300(3)`), `Hauler License #` field: `WT-26-0104`. Fred's
  decision, 2026-09-04. See `Building Apps/DERM Tracker/docs/broward-address-audit.md`.
- `customer.work_orders.decal` already resolves the right-county DECAL automatically, joining
  `vehicle_decals vd ON vd.vehicle_id = veh.id AND vd.jurisdiction = df.county` where `df` is the
  DUMP facility. That join works only because `vehicle_decals.jurisdiction` and
  `disposal_facilities.county` happen to share a vocabulary (`Miami-Dade` / `Broward`).
  `properties.county` uses `Dade` and will not join to either.
- `rpa-derm-monthly` serves `truck_decal` per manifest.

## Rules

🛑 **Never substitute one jurisdiction's decal for another's, and never substitute a decal for a
license.** The estate already has this written down at `rpa-derm-monthly/index.ts:366`: *"Never
substitute a capacity, a truck name, or another jurisdiction's decal: that would put a wrong permit
number on a county filing."* A NULL must make the caller refuse the ticket.

🛑 **`license_number` is the exact string as issued. Do not normalise spacing or punctuation.**

⚠ **`vehicle_decals` has no temporal validity** (no `valid_from` / `valid_to`), so a filed month is
not reproducible across a decal change. Same is now true of `company_hauler_licenses`: a superseded
license should be set `status='INACTIVE'` rather than deleted, and the partial unique index
(`WHERE status = 'ACTIVE'`) permits exactly that.

## Table shape

`public.company_hauler_licenses`, mirroring `public.vehicle_decals` exactly:

- audit trigger (`audit_company_hauler_licenses` -> `audit.log_change`), rule 8 opt-in
- `updated_at` trigger
- RLS enabled, `service_role` ALL, `authenticated` SELECT
- grants: `authenticated=r`, `yannick_readonly=r`, `service_role=arwdDxtm`. **No anon, of any kind.**
- CHECKs on jurisdiction (`Miami-Dade` | `Broward`), status (`ACTIVE` | `INACTIVE`), non-blank number

⚠ **`2026-09-04_1738` shipped `authenticated` with FULL DML on it and `2026-09-04_1750` fixed that
minutes later.** `CREATE TABLE` applied Supabase's default privileges before any GRANT in the body
ran, so a signed-in staff browser could have edited or truncated a credential printed on a state form.
`anon` was denied throughout. It was caught only by reading `relacl` after the fact and diffing it
against `vehicle_decals` -- the check CLAUDE.md prescribes, and the fourth or fifth time this estate
has hit it. **Every GRANT statement in the original migration was correct and every one was
irrelevant: a GRANT cannot remove what it did not create.**
