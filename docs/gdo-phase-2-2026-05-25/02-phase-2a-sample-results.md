# Phase 2a — Sample Run Results (2026-05-25 PM)

Ran 10 sample GDOs through the @GDO Slack bot before scaling to all 135.
**Hit rate: 60% confident (6/10), 40% mismatched (4/10)** — surfaced a real
data-quality issue and a systemic renewal-staleness bug.

## Bot threads (#gdo-permit, C0AL7A73DPY)

- Casa Neos x3: parent ts `1779725426.827959`
- GDO-01179 (058-SOH): ts `1779725663.820179`
- GDO-15328 (165-LPB): ts `1779725666.689249`
- GDO-00376 (021-GRA): ts `1779725669.473219`
- GDO-14336 (124-SAF): ts `1779725672.504849`
- GDO-01759 (122-BMN): ts `1779725675.287179`
- GDO-10822 (077-TCE): ts `1779725678.033069`
- GDO-11532 (032-LG): ts `1779725680.757749`

## Confident (6 rows)

| gdos.id | Client | gdo_number | Facility (bot) | max_freq | DERM exp | Our DB exp |
|---|---|---|---|---|---|---|
| 63 | 009-CN Casa Neos | GDO-10877 | CASA NEOS (KITCHENS) | 60d | 2026-12-31 | 2025-12-04 ⚠ |
| 64 | 009-CN Casa Neos | GDO-15062 | CASA NEOS (BARS) | 90d | 2026-12-31 | 2025-12-04 ⚠ |
| 65 | 009-CN Casa Neos | GDO-16389 | CN LOUNGE | 30d | 2026-12-31 | 2025-12-04 ⚠ |
| (varies) | 165-LPB La Plaza Bakery | GDO-15328 | LA PLAZA COFFEE AND BAKERY LLC | 90d | 2026-12-31 | 2026-12-31 ✓ |
| (varies) | 077-TCE TCE Kendall | GDO-10822 | CARROT LOVE DADELAND LLC DBA CARROT EXPRESS | 30d | 2026-12-31 | 2026-12-31 ✓ |
| (varies) | 032-LG La Granja 36th | GDO-11532 | LA GRANJA MIAMI CORP | 30d | 2026-12-31 | 2026-01-07 ⚠ |

## Mismatched (4 rows — DB has wrong GDO for these clients)

| Our DB record | What the GDO# actually belongs to |
|---|---|
| 058-SOH Soho Asian Bar ↔ GDO-01179 | APACHE LANDING BAR & GRILL (already known per Viktor's 2026-05-22 backfill) |
| 021-GRA Granada Condo ↔ GDO-00376 | McDonald's #11333 (multi-tenant @ 9341 E Bay Harbor Dr) |
| 124-SAF Jonny Safar ↔ GDO-14336 | TASTY DOUGH ENTERPRISE LLC (multi-tenant @ 3150 Sheridan Ave) |
| 122-BMN BMN Normandy ↔ GDO-01759 | COTRINA USA DBA LA VIDA DE DON POLLO (multi-tenant @ 1936 Normandy Dr) |

Bot says all 4 client names have NO matching DERM permit at their address.
Either operating without a permit, or our DB has the wrong assignment.

## Systemic issues

### Renewal expiration stale (likely all 135 rows affected)
Every bot-verified GDO has DERM exp `2026-12-31` (current annual cycle), but
our DB has prior-year dates. GDOs renew annually on Dec 31; sync isn't
pulling the new date.

### Multi-tenant address shows multiple permits
3 of the 4 mismatched addresses are multi-tenant buildings where multiple
businesses have permits at the same address. The bot returns all of them
and confirms which actually matches the client name.

## Missing from DB

- **GDO-15199 SARPINOS PIZZERIA** at 40 SW North River Drive (same address as
  Casa Neos). Separate tenant. Not in our gdos.

## Viktor handoff (sent #viktor-supabase ts `1779725868.955249`)

4 decisions requested:
1. Approve the 6 confident UPDATEs?
2. How to handle the 4 mismatches (demote / leave / clear link)?
3. Batch-fix renewal expirations across all 135 in this same pass?
4. Add Sarpino's as new gdos row + new client?

## What's blocked on Viktor

- All UPDATEs to gdos.location_label / max_frequency_days / permit_expiration
- The scale-to-135 question (until we know the mismatch protocol)
- Cleanup of the 4 misassigned rows
- Decision on Sarpino's

## Viktor's response (2026-05-25 PM, same thread)

Approved all 4 asks. TL;DR quote: *"Ship the 6 confident UPDATEs · INACTIVE
the 4 mismatches · batch-fix expirations (fast path preferred) · defer
Sarpino's. Ready to scale to 135 after these land."*

## Applied — migration `2026-05-25l` (2026-05-25 PM)

Pre → Post state on `public.gdos`:
- `active_count` 135 → 131 (−4 demotes)
- `stale_exp_active` (permit_expiration < 2026-01-01) 40 → 0
- `with_max_freq` 0 → 6
- `with_label` 15 → 18

Audit: 47 `UPDATE` rows on `public.gdos` with `app_source='sql'`.

**Spot-check (15 random ACTIVE rows)**: every `permit_expiration` is
`2026-12-31`. One row (`GDO-02118 / 188-ACA Hebrew Academy`) showed
`permit_expiration IS NULL` — surfaced a separate backlog of 15 ACTIVE rows
that never had an expiration date (net-new from prior backfill). These need
@GDO bot lookups in Phase 2b — not a `2026-05-25l` regression.

**Net-new finding to investigate**: 15 ACTIVE rows had `location_label`
populated before Phase 2a started (`with_label: 15` pre-state). README
previously claimed Casa Neos was "the only confirmed in-DB case" of
multi-GDO labeling. Reconcile in Phase 2b — these labels predate this
session and weren't part of the sample.
