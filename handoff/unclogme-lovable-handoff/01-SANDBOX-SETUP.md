# 01 — Sandbox setup

**Goal:** connect Lovable to your Sandbox Supabase project (a fresh clone of Unclogme's production data) so you can build apps that already know about all our clients, visits, photos, manifests, etc.

You only need to do this once.

---

## What you have

Fred set up a separate Supabase project just for you — a Sandbox. It contains a fresh copy of Unclogme's data: 445 clients, 3,888 visits, 1,670 invoices, 9,544 photos, 963 DERM manifests, all of it. The schema mirrors production exactly.

**Sandbox refreshes 5×/day on a 3-hour cadence.** A GitHub Action runs at 7am, 10am, 1pm, 4pm, and 7pm ET (11/14/17/20/23 UTC) and replaces the data in the canonical Production tables (clients, visits, invoices, photos, etc.) with whatever's currently in Production. So you always work with data that's at most ~3 hours stale during business hours, ~12 hours overnight.

**Your own tables and columns survive every refresh** — only the canonical Production tables get reloaded. So:

You're free to:
- read everything
- create new tables for app-specific data (e.g. `sales_leads`, `prospect_classifications`) — these are NEVER touched by the refresh
- create views — these always reflect the freshest canonical data
- add columns to canonical tables (rare; usually wrong — see 03-EXTENDING-THE-SCHEMA)
- soft-delete (set `INACTIVE`) — never hard delete

You should NOT:
- modify rows in canonical tables (clients, visits, invoices, photos, etc.) — your changes get wiped at the next refresh (≤3h). Production owns those.
- add `FOREIGN KEY` constraints from your tables to canonical tables. Use `external_<entity>_id BIGINT` (a "loose FK") instead. Real FKs would block the refresh's TRUNCATE step.

When an app stabilizes, Fred ports your schema additions to the production database. Then your app re-points to production and runs against live, webhook-fed data.

---

## Step 1 — Get credentials from Fred

Your Sandbox is **`Unclogme - Sandbox`** at:
```
https://ubtlwpcyntelgbykdatn.supabase.co
```
(Project ref: `ubtlwpcyntelgbykdatn`)

The URL is in `.env.example`. The keys are not (security). Ping Fred via DM for:

```
SUPABASE_ANON_KEY=eyJ...           # Public anon key. Safe in browser code. RLS-gated.
SUPABASE_SERVICE_ROLE_KEY=eyJ...   # Admin-level. ONLY use server-side. Never in browser code.
```

Never paste these in shared channels.

---

## Step 2 — Connect Lovable to your Sandbox

Open [Lovable](https://lovable.dev), create a new project, then:

1. Click **"Connect Supabase"** (or *Cloud → Supabase → Connect*)
2. Paste:
   - URL: from Fred (your Sandbox URL)
   - Anon key: `SUPABASE_ANON_KEY` from Fred
3. Lovable detects the schema and auto-generates a `supabase` client

After this, in code you'll use:

```typescript
import { supabase } from '@/integrations/supabase/client'

// Reading a table that already exists:
const { data: clients } = await supabase
  .from('clients')
  .select('id, name, status, balance')
  .limit(20)

// Or with a join:
const { data: visits } = await supabase
  .from('visits')
  .select('id, visit_date, visit_status, clients(name), vehicles(name)')
  .gte('visit_date', '2026-01-01')
  .order('visit_date', { ascending: false })
  .limit(50)
```

That's it. No second client, no cross-DB joins. Standard Supabase patterns work directly.

---

## Step 3 — Paste our system prompt into Lovable

Open the [`LOVABLE-SYSTEM-PROMPT.md`](LOVABLE-SYSTEM-PROMPT.md) file in this handoff. Copy its entire contents.

In Lovable, go to your project's **Knowledge** / **AI Context** settings (the exact name depends on Lovable's current UI — look for a "Project Context", "Knowledge Base", or "Custom Instructions" panel). Paste the contents in.

This makes Lovable's AI follow Unclogme's schema conventions automatically on every prompt. Without it, the AI might suggest `jobber_client_id` columns or copy `client_name` into every table — both of which break our merge plan.

---

## Step 4 — Verify the connection

Prompt Lovable:

> *"Build a simple test page at `/test-connection`. Fetch the first 10 rows from the `clients` table — show their `id`, `name`, and `status`. Display them as a list."*

If you see real client names appear (Casa Neos, Pura Vida ..., Bagel Boss, etc.), you're connected.

---

## Step 5 — Photos: read from Main DB's public bucket

Photo files don't live in the Sandbox's Storage — they live in production's bucket, which is public-read. The `photos.storage_path` column gives you the path; the URL is:

```
https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/{storage_path}
```

Example query for a visit's photos:

```typescript
const { data: photos } = await supabase
  .from('photo_links')
  .select('role, photos(storage_path, file_name)')
  .eq('entity_type', 'visit')
  .eq('entity_id', visitId)

// Then in JSX:
<img src={`https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/${photo.storage_path}`} />
```

If your app needs to UPLOAD new photos (driver app, etc.), upload to the Sandbox's own Storage bucket. Fred will figure out the merge path when the app graduates.

---

## What about authentication?

When you need login (sales users, drivers, clients), use Lovable's built-in Supabase Auth. The auth tables (`auth.users`) live in your Sandbox by default.

To map app users to Unclogme employees: create a `user_profiles` table with `external_employee_id BIGINT` linking to `employees.id`. Standard pattern (see **03-EXTENDING-THE-SCHEMA.md**).

---

## Common mistakes to avoid

1. **Hardcoding credentials in source code.** Use Lovable's project secrets / environment variable system. Never put keys directly in components.

2. **Using the service role key in frontend code.** It bypasses RLS — anyone reading the browser source can do anything. Always use the anon key for client-side. Service role key only in Edge Functions or server-only code.

3. **Trying to connect Lovable to two Supabase projects at once.** Lovable's design is one Supabase per Lovable project. The Sandbox model means one connection — no need for two.

4. **Skipping the system prompt.** Without LOVABLE-SYSTEM-PROMPT.md pasted into Lovable's Knowledge, the AI will suggest things that break our conventions. Set it up once and forget about it.

---

Next: read **02-WHAT-DATA-EXISTS.md** to see what tables you can query.
