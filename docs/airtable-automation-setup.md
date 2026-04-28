# Airtable → Supabase Live Sync Setup

**For:** Fred (one-time setup) · **Last updated:** 2026-04-27 · **Status:** ✅ All 10 automations live since 2026-04-23

This is the step-by-step to connect Airtable record changes into our Supabase DB via per-table automations. **~5 minutes per table × 5 tables = ~25 minutes total.**

---

## What's already done (by me)

- ✅ Edge Function `webhook-airtable` updated to accept Bearer-token POSTs from Airtable automations
- ✅ Deployed to prod (as of 2026-04-21)
- ✅ Supabase secret `AIRTABLE_WEBHOOK_TOKEN` set on the project
- ✅ Auth + error paths tested (no-auth → 400, wrong bearer → 401, unknown entity → 200 skipped, valid entity → routed to handler)

## What's on you

Create automations in the Airtable base (4 tables × 2 triggers = **8 automations**).

---

## 1. Open Airtable automations

1. Log into Airtable, open the Unclogme base
2. Top-right: **Automations** tab

---

## 2. For each of the 5 tables — create 2 automations

Table mapping (Airtable name → entity parameter for the script):

| Airtable table | `entity` value | Handler | Upserts into |
|---|---|---|---|
| Clients | `client` | `handleClientRecord` | `service_configs`, `clients.client_code`, `properties.zone`/`county` |
| DERM | `derm_manifest` | `handleDermRecord` | `derm_manifests` |
| Route Creation | `route` | `handleRouteRecord` | `routes` |
| Past due | `receivable` | `handleReceivableRecord` | `receivables` |
| PRE-POST insptection | `inspection` | `handleInspectionRecord` | `inspections` (maps Date, Pre/Post, Driver→employee, Truck→vehicle, SLUDGE Tank level, Gas Level) |

For each table, create two automations: one for **creation**, one for **updates**.

### 2.1 Automation skeleton

1. Click **+ Create automation** (top-right of Automations tab)
2. Name it: `<Table Name> — Live sync: <trigger>` (e.g. `Clients — Live sync: created`)
3. **Trigger:** "When record created" (or "When record updated" for the second automation)
4. Pick the table
5. **Action:** "Run a script"
6. In the script action's **Input variables** (left panel), add:
   - `recordId` — drag the "Record ID" field from the trigger's step
   - `tableName` — type the literal table name in quotes (e.g., `"Clients"`)
7. Paste the script below into the code panel (change the 2 constants at the top per automation)

### 2.2 The script (paste for every automation)

```javascript
// ============================================================================
// Airtable → Supabase live sync
// ============================================================================
// CHANGE THESE TWO CONSTANTS PER AUTOMATION:
const ENTITY = 'client';           // 'client' | 'derm_manifest' | 'route' | 'receivable'
const CHANGE_TYPE = 'updated';     // 'created' | 'updated'
// ============================================================================

const URL = 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-airtable';
const TOKEN = '<PASTE_AIRTABLE_WEBHOOK_TOKEN_HERE>';  // value lives in Supabase/.env (AIRTABLE_WEBHOOK_TOKEN) and Supabase secrets

const { recordId, tableName } = input.config();
if (!recordId || !tableName) {
    throw new Error('Missing recordId or tableName in input config');
}

const table = base.getTable(tableName);
const record = await table.selectRecordAsync(recordId);
if (!record) {
    console.log(`Record ${recordId} not found — skipping`);
    return;
}

// Serialize all fields by their NAME (not field ID)
const fields = {};
for (const field of table.fields) {
    const value = record.getCellValue(field.name);
    if (value !== null && value !== undefined && value !== '') {
        fields[field.name] = value;
    }
}

// POST to our Edge Function
const response = await fetch(URL, {
    method: 'POST',
    headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${TOKEN}`,
    },
    body: JSON.stringify({
        entity: ENTITY,
        recordId,
        fields,
        changeType: CHANGE_TYPE,
    }),
});

const responseBody = await response.text();
console.log(`POST ${response.status}:`, responseBody);

if (!response.ok) {
    throw new Error(`Sync failed: ${response.status} ${responseBody}`);
}
```

### 2.3 The 10 automations, in full

| # | Automation name | Trigger | ENTITY | CHANGE_TYPE | tableName input |
|---|---|---|---|---|---|
| 1 | Clients — Live sync: created | When record created (Clients) | `'client'` | `'created'` | `"Clients"` |
| 2 | Clients — Live sync: updated | When record updated (Clients) | `'client'` | `'updated'` | `"Clients"` |
| 3 | DERM — Live sync: created | When record created (DERM) | `'derm_manifest'` | `'created'` | `"DERM"` |
| 4 | DERM — Live sync: updated | When record updated (DERM) | `'derm_manifest'` | `'updated'` | `"DERM"` |
| 5 | Routes — Live sync: created | When record created (Route Creation) | `'route'` | `'created'` | `"Route Creation"` |
| 6 | Routes — Live sync: updated | When record updated (Route Creation) | `'route'` | `'updated'` | `"Route Creation"` |
| 7 | Past due — Live sync: created | When record created (Past due) | `'receivable'` | `'created'` | `"Past due"` |
| 8 | Past due — Live sync: updated | When record updated (Past due) | `'receivable'` | `'updated'` | `"Past due"` |
| 9 | Inspections — Live sync: created | When record created (PRE-POST insptection) | `'inspection'` | `'created'` | `"PRE-POST insptection"` |
| 10 | Inspections — Live sync: updated | When record updated (PRE-POST insptection) | `'inspection'` | `'updated'` | `"PRE-POST insptection"` |

**Important**: `tableName` must match the **exact** Airtable table name (case-sensitive, including spaces and typos). The PRE-POST inspection table is literally spelled `PRE-POST insptection` in Airtable — keep the typo.

### 2.4 For the "updated" triggers — select fields to watch

On the update trigger, Airtable asks which fields to watch. Select **all relevant fields** (or "Any field" if offered). You don't want an update to go unsynced because only one field changed.

---

## 3. Test one automation end-to-end

1. Enable the `Clients — Live sync: updated` automation
2. Edit any client in Airtable (change a note, edit pricing, whatever)
3. Back in Supabase → SQL Editor:

```sql
SELECT event_type, status, error_message, created_at
FROM webhook_events_log
WHERE source_system = 'airtable'
ORDER BY created_at DESC
LIMIT 5;
```

Expected result: one new row with `event_type = 'automation_client'` and `status = 'processed'`.

Also check the target table got the update:

```sql
-- Confirm the change landed in service_configs / clients / etc.
SELECT id, client_code, updated_at
FROM clients
ORDER BY updated_at DESC
LIMIT 5;
```

---

## 4. Troubleshooting

### `status = 'failed'` with `Invalid bearer token`
- The `TOKEN` in the automation script doesn't match the Supabase secret. Re-copy from `Supabase/.env` (`AIRTABLE_WEBHOOK_TOKEN=...`).

### `status = 'failed'` with `Missing entity or recordId`
- The Input variables aren't wired to the script. Check the script action config — `recordId` should be dragged from the trigger.

### `status = 'skipped'` with `no handler for <X>`
- Typo in `ENTITY` constant. Must be exactly one of: `client`, `derm_manifest`, `route`, `receivable`.

### `status = 'failed'` with handler exception
- Field name mismatch. The handler expects specific Airtable column names (e.g., `Grease Trap Frequency`, `Client Code`, `GDO #`). If your Airtable uses different column names, you'll see errors here — ping me with the failing `error_message` and I'll adjust the handler.

### No row appears in `webhook_events_log`
- The automation didn't actually run. In Airtable's automation detail page, check the "Run history" tab — failures show a red X with the error.

---

## 5. Token rotation

If the `AIRTABLE_WEBHOOK_TOKEN` ever gets exposed (committed to git, posted in Slack, etc):

```bash
# Generate a new one
NEW=$(node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))")

# Set it on Supabase
supabase secrets set AIRTABLE_WEBHOOK_TOKEN="$NEW" --project-ref wbasvhvvismukaqdnouk

# Update the TOKEN constant in all 8 automation scripts
```

---

## 6. Future enhancements (not needed now)

- **Deletion handling**: Airtable automations don't have a "when record deleted" trigger. If that becomes important, add a "Deleted" boolean column to each table + an automation that fires on that column turning true with `CHANGE_TYPE = 'destroyed'`. Our Edge Function already supports it.
- **Employees + Visits tables**: we have `employee` (9 rows) and `visit` (3,020 rows) Airtable sources but no handlers yet. Future work if those tables become actively edited before sunset.
- **Rate limiting**: if bulk edits in Airtable ever trigger hundreds of automations at once, we can add a per-entity queue. Not a concern at current volumes.
