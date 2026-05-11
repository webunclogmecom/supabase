# 03 — Extending the schema

You can freely create new tables in your Sandbox. Those additions follow Unclogme's conventions so they merge cleanly to production when the app graduates. This file is the playbook.

**The big rule** — your Sandbox refreshes 5×/day on a 3-hour cadence (7am/10am/1pm/4pm/7pm ET). Canonical Production tables (clients, visits, invoices, photos, etc.) get TRUNCATE+RELOADed at every refresh. **Anything you store ON those rows is wiped within 3 hours.** That fact drives the "right pattern" vs "wrong pattern" decisions below.

---

## The pattern you'll use 99% of the time

### Pattern B (right) — New table with `external_<entity>_id`

You're building a prospect-search app. You need to mark each client as `Lead`, `Active`, or `Discarded`.

```sql
CREATE TABLE prospect_classifications (
  id BIGSERIAL PRIMARY KEY,
  external_client_id BIGINT NOT NULL,    -- ← refs clients.id, NO FK constraint
  classification TEXT NOT NULL,
  notes TEXT,
  classified_by_user_id UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT prospect_classifications_chk
    CHECK (classification IN ('Lead', 'Active', 'Discarded')),
  CONSTRAINT prospect_classifications_unique
    UNIQUE (external_client_id)          -- one classification per client
);

COMMENT ON TABLE prospect_classifications IS
  'Sales-app classification of each client. external_client_id is a loose FK to clients.id (no enforced FK so the canonical refresh doesn''t cascade). Survives every refresh.';

CREATE INDEX idx_prospect_classifications_client ON prospect_classifications(external_client_id);

-- updated_at trigger
CREATE TRIGGER trg_prospect_classifications_updated_at
  BEFORE UPDATE ON prospect_classifications
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- RLS
ALTER TABLE prospect_classifications ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth users can read all classifications"
  ON prospect_classifications FOR SELECT USING (auth.role() = 'authenticated');
CREATE POLICY "auth users can write classifications"
  ON prospect_classifications FOR ALL USING (auth.role() = 'authenticated');
```

Then your app reads classifications by JOINing:

```sql
SELECT c.id, c.client_code, c.name, pc.classification, pc.notes
FROM clients c
LEFT JOIN prospect_classifications pc ON pc.external_client_id = c.id
WHERE pc.classification = 'Lead' OR pc.classification IS NULL;
```

**How to prompt Lovable:**

> *"Create a new table `prospect_classifications` for my sales app. One row per client. Fields: id (bigserial PK), external_client_id (bigint, NOT NULL, refs clients.id but stored as plain bigint NOT a foreign key — we'll FK at merge time), classification (text NOT NULL, allowed: 'Lead', 'Active', 'Discarded'), notes (text), classified_by_user_id (uuid, FK to auth.users.id), created_at + updated_at (trigger-managed). UNIQUE(external_client_id). Standard updated_at trigger. Enable RLS, allow authenticated users to read and write all rows."*

### Pattern A (wrong, but documented so you know why) — Adding a column to a canonical table

❌ Don't do this:
```sql
ALTER TABLE clients ADD COLUMN client_type TEXT;
-- Then app sets clients.client_type = 'Lead' for some clients...
```

The column itself survives every refresh (it's schema, not data). But its **values** get wiped — at each refresh (7am/10am/1pm/4pm/7pm ET) the refresh does `TRUNCATE clients RESTART IDENTITY CASCADE` then INSERTs Production's clients back, and those INSERTs don't include `client_type` (Production doesn't have that column). So all your `client_type` values become NULL again within 3 hours.

If you ever genuinely need a per-row enrichment of a canonical table, do it in a separate table (Pattern B above) and JOIN at read time. There is essentially no scenario where Pattern A is the right answer.

---

### Another Pattern B example — outreach tracking

You're tracking every contact attempt with a prospect. Each touch is its own row.

```sql
CREATE TABLE outreach_touches (
  id BIGSERIAL PRIMARY KEY,
  external_client_id BIGINT,         -- ← refs clients.id, no FK constraint
  touch_type TEXT NOT NULL,          -- 'call', 'email', 'visit'
  outcome TEXT,                      -- 'no_answer', 'left_msg', 'connected', 'meeting_set'
  notes TEXT,
  performed_by_user_id UUID REFERENCES auth.users(id),
  performed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE outreach_touches IS
  'Sales-app data: every contact attempt with a prospect or client. New table from Yannick''s app, not in production warehouse.';

-- updated_at trigger to keep that column accurate (we use this convention everywhere)
CREATE TRIGGER trg_outreach_touches_updated_at
  BEFORE UPDATE ON outreach_touches
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- RLS — start with permissive for development; tighten before merge
ALTER TABLE outreach_touches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth users can read their own touches"
  ON outreach_touches FOR SELECT
  USING (performed_by_user_id = auth.uid());
CREATE POLICY "auth users can insert touches as themselves"
  ON outreach_touches FOR INSERT
  WITH CHECK (performed_by_user_id = auth.uid());
```

**How to prompt Lovable:**

> *"Create a new table `outreach_touches` for my sales app. Fields: id (bigserial PK), external_client_id (bigint, optional, refs Main DB clients.id but stored as plain integer NOT a foreign key — we'll FK at merge time), touch_type (text, required, allowed: 'call', 'email', 'visit'), outcome (text), notes (text), performed_by_user_id (uuid, FK to auth.users.id), performed_at (timestamptz, default now()), created_at + updated_at (trigger-managed).*
>
> *Add the standard updated_at trigger using our `trg_set_updated_at()` function (already defined in the schema).*
>
> *Enable RLS. Add two policies: users can SELECT and INSERT only rows where performed_by_user_id = auth.uid()."*

---

## Pattern C — Views (no new table needed, just a derived query)

When you need to slice/aggregate canonical data, don't store the result — compute it. Views always reflect the freshest canonical data after each refresh, no maintenance.

```sql
-- "Clients with no visit in the last 60 days" — a stale-customer view
CREATE OR REPLACE VIEW v_stale_clients AS
SELECT
  c.id AS client_id,
  c.client_code,
  c.name,
  MAX(v.visit_date) AS last_visit_date,
  CURRENT_DATE - MAX(v.visit_date) AS days_since_last_visit
FROM clients c
LEFT JOIN visits v ON v.client_id = c.id AND v.visit_status = 'completed'
WHERE c.status IN ('ACTIVE', 'Recuring')
GROUP BY c.id, c.client_code, c.name
HAVING COALESCE(MAX(v.visit_date), '1900-01-01') < CURRENT_DATE - INTERVAL '60 days'
ORDER BY days_since_last_visit DESC;

COMMENT ON VIEW v_stale_clients IS
  'Clients we haven''t visited in 60+ days. Used by sales-app re-engagement screen.';
```

Your app reads it like any other table: `SELECT * FROM v_stale_clients`.

**How to prompt Lovable:**

> *"Create a view `v_stale_clients` showing every active client whose last completed visit was 60+ days ago. Columns: client_id, client_code, name, last_visit_date, days_since_last_visit. Order by days_since_last_visit descending."*

**When NOT to use a view** — when the query is expensive enough that you'd want to cache it. For that, materialize it (`CREATE MATERIALIZED VIEW`) and refresh it on a schedule from your app. Materialized views' data is NOT auto-refreshed by the canonical refresh.

---

## The 7 rules for schema extensions

These are summarized in **05-RULES.md**, but here's the elaborated version with the *why*.

### 1. Source-agnostic columns only

❌ `jobber_client_id`, `airtable_record_id`, `samsara_vehicle_id` columns directly on a business table

✅ For cross-source IDs, use `entity_source_links` (the polymorphic bridge already in the schema). For your app's references to existing entities, use `external_<entity>_id BIGINT` (it becomes a real FK at merge).

**Why:** when production gets re-architected (new source systems, schema migrations), source-prefixed columns break everything. Polymorphic bridge or loose `external_*_id` survives.

### 2. 3NF — every column depends only on the table's primary key

For each new column, ask: *"is this value derivable from another column in the same table, or via a JOIN to another table?"* If yes, it's a 3NF violation — make it a view, not a stored column.

❌ Store `total_visits_this_year` as a column on `clients`. (It's derivable: `COUNT(*) FROM visits WHERE client_id = ... AND visit_date >= '2026-01-01'`.)

✅ Define a view `clients_with_visit_counts` that computes it. Or just compute in the query at display time.

**Why:** stored derivables go stale silently. They look correct until someone forgets to update the cache.

### 3. Reference, don't copy

Don't store the client name or address on a row that already FKs to `clients`. The name might change in Jobber; the join will track the change automatically.

❌ `outreach_touches.client_name TEXT`
✅ `outreach_touches.external_client_id BIGINT` + `JOIN clients ON ...` at query time

**Exception**: snapshot data — e.g. a sent quote should NOT change if the client renames later. Make this exception explicit and rare.

### 4. Soft-delete, never hard-delete

Set `status = 'INACTIVE'` or add a `deleted_at TIMESTAMPTZ` column. Never `DELETE FROM`.

❌ `await supabase.from('outreach_touches').delete().eq('id', x)`
✅ `await supabase.from('outreach_touches').update({ deleted_at: new Date().toISOString() }).eq('id', x)`

**Exception**: truly transient data (drafts, session caches, etc.) can be hard-deleted.

### 5. UTC timestamps + NUMERIC(12,2) money

- Every timestamp: `TIMESTAMPTZ` stored in UTC. Convert to Eastern Time at display.
- Every money column: `NUMERIC(12,2)`. Never `FLOAT` or `DOUBLE`.
- `updated_at` is trigger-managed (`BEFORE UPDATE` triggers using `trg_set_updated_at()`).

### 6. RLS on every new business table

Production requires RLS on every public table. Start permissive in your sandbox if needed (just to unblock building), but every table must have RLS enabled with at least one policy before merge.

```sql
ALTER TABLE my_new_table ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth users can do their stuff" ON my_new_table FOR ALL USING (...);
```

### 7. Comments on every column

```sql
COMMENT ON COLUMN clients.client_type IS 'Sales classification: Lead | Active | Discarded';
COMMENT ON TABLE outreach_touches IS 'Sales-app contact log';
```

Why: when Fred reviews your migration for merging, COMMENTS tell him *why* the column exists. Without them, "what is this `xyz` column for?" requires a back-and-forth.

---

## Tracking your migrations

Lovable maintains a `supabase/migrations/` folder for you. Every schema change you prompt becomes a `<timestamp>_<description>.sql` file there. Don't manually edit these files — let Lovable generate them.

When the app graduates, Fred reads the `supabase/migrations/` folder, hand-reviews each file, and applies the approved ones to Main DB. Files with violations of the 7 rules above get bounced back for fixes before merge.

If your Sandbox gets refreshed (Fred re-snapshots Main DB into your Sandbox), Lovable's migrations are reapplied on top automatically — your schema additions survive the refresh, your test data does not.

---

## When to ask Fred before adding something

- Adding more than ~5 new tables → ping Fred for a 10-min review of how they'll fit into the warehouse
- Modifying a column type on an existing Main DB table → ask Fred (some columns have downstream consumers like Viktor's skills)
- Adding triggers, RPC functions, or extensions → these don't auto-merge cleanly, ask Fred
- Naming feels wrong but you're not sure → just ask. Cheap to align early, expensive after a UI is built on top.

For everything else (new columns, new tables, new views), follow the rules and build.

---

## Anti-pattern catalog (things Lovable's AI will sometimes suggest)

| Lovable suggests | Don't | Do |
|---|---|---|
| `client_name TEXT` on a row that already FKs to `clients` | ❌ | JOIN at query time |
| `jobber_id TEXT` on a business table | ❌ | Use `entity_source_links` (already populated) |
| `DELETE FROM x WHERE id = y` | ❌ | `UPDATE x SET deleted_at = now() WHERE id = y` |
| Storing `total_revenue NUMERIC` as a column | ❌ (derivable) | Define a view that computes it |
| `created_date DATE NOT NULL DEFAULT CURRENT_DATE` | ❌ (use TIMESTAMPTZ) | `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` |
| `price FLOAT` for money | ❌ | `NUMERIC(12,2)` |
| Disabling RLS to "make queries work" | ❌ | Enable RLS, add policies that match your auth model |

If Lovable insists, override and say *"per Unclogme's schema conventions, use [the right pattern]"*. The system prompt (LOVABLE-SYSTEM-PROMPT.md) makes this less common, but it still happens.

---

Next: read **04-EXAMPLE-PROMPTS.md** for ready-to-use Lovable prompts that follow these rules.
