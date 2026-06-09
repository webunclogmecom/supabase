# Fix spec — client `status` flapping (RECURRING clobbered to ACTIVE)

*Diagnosed + FIXED 2026-05-31. webhook-jobber no-clobber deployed; 70 clients re-synced from
Airtable via `scripts/sync/backfill_client_status_from_airtable.js` (RECURRING 76→139, 001-VIN
now RECURRING, 0 remaining mismatches for clients present in both systems). 8 AT clients whose
code isn't in our DB remain a separate data-completeness item.*

## Symptom

Airtable shows **141 RECURRING** clients; our DB shows only **76–77**. Example:
`001-VIN Vincenzos Pizzeria` is `Recurring` in Airtable but `ACTIVE` in the DB.

## Root cause — two sync paths fight over `clients.status`

`clients.status` (`ACTIVE | RECURRING | PAUSED | INACTIVE`) is written by **both** webhooks
with conflicting values:

| Writer | Code | Value written |
|---|---|---|
| `webhook-airtable` (`handleClientRecord`, ~line 205) | maps AT `ACTIVE/INACTIVE` field, normalizes `Recuring`→`RECURRING` | **correct** (RECURRING/ACTIVE/PAUSED/INACTIVE) |
| `webhook-jobber` (`handleClient`, ~line 254) | `status: c.isArchived ? 'INACTIVE' : 'ACTIVE'` | **clobbers** — Jobber has no "Recurring", so it overwrites `RECURRING`→`ACTIVE` |

`cron_jobber` replays every client through `webhook-jobber` frequently, so each replay
re-clobbers AT's status. The value **flaps** — `001-VIN` flipped RECURRING↔ACTIVE 5+ times
in a single day (audit.logs). Whichever ran last wins; right now Jobber won for 62 clients.

Per CLAUDE.md, **Airtable is canonical for client status** → Jobber must stop overwriting it.

## Impact (measured 2026-05-31)

68 clients mismatched (full list: `reports/_at_status_diff.json`):
- **RECURRING → ACTIVE: 62**  ← the main bug
- INACTIVE → ACTIVE: 3
- RECURRING → INACTIVE: 1, PAUSED → ACTIVE: 1, PAUSED → INACTIVE: 1

## Fix — part 1: stop the clobber (`webhook-jobber/index.ts`, `handleClient`)

Remove `status` from the always-written `clientRow`; set it only on archival /
reactivation / insert, never downgrading a richer AT status.

```ts
// BEFORE
const clientRow: Record<string, unknown> = {
  name: nameNormalized,
  status: c.isArchived ? 'INACTIVE' : 'ACTIVE',   // <-- clobbers RECURRING/PAUSED
  balance: c.balance ?? null,
}
...
if (existingId) {
  if (parsedCode) {
    const { data: cur } = await supabase.from('clients').select('client_code').eq('id', existingId).maybeSingle()
    if (cur && !cur.client_code) clientRow.client_code = parsedCode
  }
  const { error } = await supabase.from('clients').update(clientRow).eq('id', existingId)
  ...
} else {
  ... // insert
}

// AFTER
const clientRow: Record<string, unknown> = {
  name: nameNormalized,
  balance: c.balance ?? null,
}
if (typeof c.isCompany === 'boolean') clientRow.client_class = c.isCompany ? 'commercial' : 'residential'

if (existingId) {
  // Airtable is canonical for the ACTIVE/RECURRING/PAUSED/INACTIVE distinction.
  // Jobber only knows archived/active — do NOT clobber a richer AT-set status.
  const { data: cur } = await supabase.from('clients')
    .select('client_code, status').eq('id', existingId).maybeSingle()
  if (c.isArchived) {
    clientRow.status = 'INACTIVE'                 // Jobber archival = deactivation
  } else if (cur && cur.status === 'INACTIVE') {
    clientRow.status = 'ACTIVE'                    // reactivation only
  }                                               // else: preserve existing status
  if (parsedCode && cur && !cur.client_code) clientRow.client_code = parsedCode
  const { error } = await supabase.from('clients').update(clientRow).eq('id', existingId)
  ...
} else {
  // INSERT — Jobber-only default; AT webhook refines later if the client is in AT.
  clientRow.status = c.isArchived ? 'INACTIVE' : 'ACTIVE'
  if (parsedCode) clientRow.client_code = parsedCode
  ... // insert
}
```

Deploy: `supabase functions deploy webhook-jobber --project-ref wbasvhvvismukaqdnouk --no-verify-jwt`

> Note: the `client_class` line moved out of the shared `clientRow` initializer in the
> AFTER — keep it (added 2026-05-29). It is NOT affected by this change.

## Fix — part 2: re-sync status from Airtable (all clients)

**Run AFTER part 1 is deployed** (otherwise the next `cron_jobber` replay re-clobbers).
Re-assert AT-canonical status for every client with an AT record (~378). Idempotent.

Pseudo (a `scripts/sync/backfill_client_status_from_airtable.js` can be written to do this):
1. Pull AT `Clients` (`tbl5lXLtHKUWilDDj`), read `ACTIVE/INACTIVE` + `Client Code #3`.
2. Normalize (`RECURING`→`RECURRING`, uppercase/trim; skip blanks).
3. `UPDATE public.clients SET status = <at_status> WHERE client_code = <code> AND status IS DISTINCT FROM <at_status>` — via REST with `X-App-Source: webhook-airtable` (or `sql`).
4. Skips no-op rows (audit stays clean).

Expected: RECURRING climbs from ~76 → ~141; 68 mismatches → 0.

## Verification

```sql
SELECT status, COUNT(*) FROM public.clients GROUP BY status;   -- RECURRING ≈ 141
```
Then re-run `node scripts/probes/_smoke_session_2026_05_30.js` and confirm 001-VIN = RECURRING.
Re-check flap: 001-VIN should get no more RECURRING→ACTIVE rows in audit.logs after deploy.

## Architectural note (longer-term)

`status` conflates two axes — Jobber's archived/active and Airtable's subscription state.
The clean 3NF fix is to separate them (e.g. derive "recurring" from `service_configs` with
`frequency_days > 0` rather than storing it in `status`). Out of scope for this hotfix; worth
an ADR when Odoo takes over CRM.
