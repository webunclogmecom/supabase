# 05 — The 7 rules (one-pager — pin this)

These keep your apps merge-friendly with the production warehouse. Break them and the merge becomes a manual rewrite.

---

## 1. Source-agnostic columns

❌ `jobber_client_id`, `airtable_record_id`, `samsara_vehicle_id` on any business table
✅ Use `entity_source_links` for cross-source IDs (already in the schema), or `external_<entity>_id BIGINT` for app-side refs to Main DB rows

## 2. 3NF — every column depends only on the primary key

For each new column ask: *"is this derivable from another column or a JOIN?"* If yes — make it a view, not a stored column.

❌ `clients.total_revenue NUMERIC` (derivable from invoices)
✅ View `clients_with_revenue` that computes it on read

## 3. Reference, don't copy

Two tables with the same concept → one holds the row, the other FKs (or `external_*_id`). Don't duplicate names/addresses/emails across tables.

❌ `sales_leads.client_name TEXT` (when `external_client_id` is also there)
✅ JOIN to clients for the name at query time

## 4. Soft-delete only

❌ `await supabase.from('x').delete().eq('id', y)`
✅ `await supabase.from('x').update({ deleted_at: new Date().toISOString() }).eq('id', y)` or `status: 'INACTIVE'`

Exception: truly transient data (form drafts, session cache) can be hard-deleted.

## 5. UTC + NUMERIC(12,2) + trigger-managed updated_at

- `TIMESTAMPTZ` everywhere, stored UTC. Convert to Eastern Time at display.
- Money: `NUMERIC(12,2)`. Never FLOAT.
- `updated_at` columns are managed by `BEFORE UPDATE` triggers — don't set them manually.

## 6. RLS on every new business table

```sql
ALTER TABLE my_new_table ENABLE ROW LEVEL SECURITY;
CREATE POLICY "..." ON my_new_table FOR SELECT USING (...);
```

Every business table must have RLS enabled before merging to production.

## 7. COMMENT every new column and table

```sql
COMMENT ON COLUMN clients.client_type IS 'Sales classification: Lead | Active | Discarded';
COMMENT ON TABLE outreach_touches IS 'Sales-app contact log';
```

Future-Fred reading the migration for merge needs to know *why* the column exists.

---

## Mental model

| Concern | Answer |
|---|---|
| Where do I read existing data? | Sandbox (your default supabase client) |
| Where do I write app-specific data? | Sandbox — same client |
| Where do photos live? | Production's public Storage bucket; URL = `https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/{path}` |
| What if I want to change a Main DB column? | Add it to your Sandbox + use it; Fred ports it to Main at merge |
| What about new tables? | Same — create in Sandbox, follow the 7 rules, Fred merges later |
| What stays out of Sandbox? | webhook deliveries (Jobber/Airtable/Samsara still hit Main, not Sandbox) |
| What survives a Sandbox refresh? | Your migrations (in `supabase/migrations/`). Test data does NOT. |

---

When in doubt, the answer is usually:

1. Re-read **03-EXTENDING-THE-SCHEMA.md**
2. Look at how an existing table does it (the schema is consistent)
3. Ask Fred (10 minutes of alignment now beats hours of rewrite later)

The system prompt (LOVABLE-SYSTEM-PROMPT.md) makes the AI follow these rules automatically — paste it once into Lovable's Knowledge / AI Context and forget about it.
