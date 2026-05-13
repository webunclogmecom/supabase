# 04 — Example Lovable prompts

Copy-paste these into Lovable to bootstrap features. Adapt freely.

These all assume you've connected Lovable to your Sandbox per **01-SANDBOX-SETUP.md** AND pasted **LOVABLE-SYSTEM-PROMPT.md** into Lovable's Knowledge / AI Context. With those two things done, Lovable will follow our conventions automatically.

---

## A — Today's visits dashboard

> *"Build a page at `/today` that fetches visits where `visit_date` is today (in Eastern Time). For each visit show: client name (join visits.client_id → clients.name), property address (join via property_id → properties.address), truck (join via vehicle_id → vehicles.name), visit_status as a colored badge ('COMPLETED'=green, 'scheduled'=blue, 'destroyed'=red), and start_at + end_at formatted as Eastern Time.*
>
> *Sort by start_at ascending. Render as a Tailwind table. Show 'No visits today' if empty."*

---

## B — Photos for a visit

> *"On `/visit/:id`, fetch the visit by id. Below the visit details, list all photos linked to it via:*
>
> ```
> SELECT pl.role, p.storage_path, p.file_name, p.content_type
> FROM photo_links pl JOIN photos p ON p.id = pl.photo_id
> WHERE pl.entity_type = 'visit' AND pl.entity_id = $visitId
> ```
>
> *Render each photo as a thumbnail. The image URL is `https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/${storage_path}`. Click to open in a lightbox. Show role as caption."*

---

## C — Prospect search app (your priority use case)

This is the feature you mentioned — searching for prospects, classifying them as Lead/Active/Discarded.

> *"Build a prospect search app with three pages:*
>
> *1. `/prospects` — main list page. Add a `client_type` column to the `clients` table (TEXT, allowed values 'Lead', 'Active', 'Discarded', nullable for now). Add a CHECK constraint enforcing those values. COMMENT the column saying it's maintained by my prospect search app.*
>
> *2. The list shows all clients filterable by `client_type`. Search bar searches name, address, client_code. Each row has a dropdown to change client_type. Save updates immediately to Supabase.*
>
> *3. `/prospect/:id` — detail page. Show the client's full profile, properties, recent visits, last invoice. Buttons: 'Mark as Lead' / 'Mark as Active' / 'Mark as Discarded'. Below, a notes textarea — save notes to a new `prospect_notes` table (id, external_client_id BIGINT, note TEXT, created_at, updated_at, created_by_user_id UUID). RLS: only authenticated users can read/write.*
>
> *Use Tailwind. Mobile-friendly. Default sort by `created_at` descending so newest leads appear first."*

When Lovable runs this prompt, it will:
- Create a migration to ALTER `clients` ADD `client_type TEXT CHECK ...`
- Create a migration for the new `prospect_notes` table
- Generate the React pages
- All tracked in `supabase/migrations/`

---

## D — Sales lead pipeline (writes new tables)

> *"Create a `sales_leads` table with: id (bigserial PK), contact_name, company_name, phone, email, address, city, state, zip, external_client_id (BIGINT, nullable, refs Main DB clients.id but NOT a foreign key), pipeline_stage (TEXT, allowed: 'new', 'contacted', 'qualified', 'won', 'lost'), estimated_revenue (NUMERIC(12,2)), notes, created_at + updated_at trigger-managed, deleted_at TIMESTAMPTZ nullable for soft-delete. RLS: authenticated users only.*
>
> *Build `/leads`: kanban board with columns for each pipeline_stage. Drag-and-drop between columns updates pipeline_stage. Click a lead to open a detail panel. 'Convert to client' button writes a row to `prospect_notes` and (later) we'll add the actual conversion flow.*
>
> *Use react-beautiful-dnd or similar for drag-drop. Tailwind."*

---

## E — DERM manifest browser

> *"Build `/derm`. List all `derm_manifests` ordered by `dump_ticket_date` DESC, paginated 50 per page. Show columns: White Manifest #, dump date (formatted ET), client name (join via client_id), `sent_to_client` and `sent_to_city` as checkboxes (read-only display).*
>
> *Click a row to open a side panel that shows BOTH the manifest receipt photo and the address photo. Query is:*
>
> ```
> SELECT pl.role, p.storage_path
> FROM photo_links pl JOIN photos p ON p.id = pl.photo_id
> WHERE pl.entity_type = 'derm_manifest' AND pl.entity_id = $manifestId
> ```
>
> *Photo URL pattern is the same as visit photos — `https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/${storage_path}`. Search bar filters by White Manifest # or client name."*

---

## F — Client portal

> *"Build a client portal that authenticated users (clients themselves) can log into. Use Supabase Auth.*
>
> *Create a `client_portal_users` table that maps `auth.users.id` (UUID) to `external_client_id` (BIGINT, refs clients.id). Set up an RLS policy: when a logged-in user fetches anything, they see only data for their `external_client_id`.*
>
> *Pages:*
> *- `/portal/dashboard` — overview: their client name, status, balance, next service date (from `clients_due_service` view)*
> *- `/portal/history` — their last 12 visits with photos*
> *- `/portal/manifests` — their DERM manifests*
> *- `/portal/billing` — their invoices*
>
> *Tailwind, mobile-first."*

---

## G — Truck dashboard with live telemetry

> *"Build `/fleet`. Use the `v_vehicle_telemetry_latest` view to show a card per truck. Each card: truck name + photo, fuel % + computed gallons, engine state (On/Off/Idle) as colored indicator, minutes_ago, and lat/lng rendered on a small Leaflet map (OpenStreetMap, no API key needed).*
>
> *Auto-refresh the data every 30 seconds. ~300px wide cards in a grid."*

---

## H — Past-due invoices

> *"Build `/billing/overdue`. Query `invoices` where `invoice_status` IN ('PAST_DUE', 'OVERDUE') OR (due_date < now() AND outstanding_amount > 0). JOIN to clients for client name + primary email (from client_contacts where role='primary').*
>
> *Show as table sorted by due_date ASC. Days-overdue colored badge: red >30, orange 14-30, yellow 1-13. 'Send reminder' button copies primary email to clipboard for now."*

---

## I — Driver mobile (at-a-client view)

> *"Build a mobile-first page at `/driver/client/:id`. Use Supabase Auth — only logged-in drivers can access.*
>
> *Show:*
> *- Client name, address, access hours, days_of_week from properties*
> *- `grease_trap_manhole_count` from properties (how many manholes to check)*
> *- The last 3 visits to this client + their notes*
> *- The latest inspection for this property's truck if any*
>
> *Below, a 'Take photos' button that opens the camera. Upload photos to Sandbox Storage at path `driver/{client_id}/{date}/{filename}`. Insert rows into `photos` (storage_path, file_name, source='sandbox_driver_app') and `photo_links` (entity_type='visit', role='during', entity_id=upcoming visit id).*
>
> *NB: photos uploaded by this app live in the Sandbox's storage, not Main's bucket. Fred will figure out the merge path when the app graduates."*

---

## J — Search any prospect by name / address

> *"Build `/search`. A search bar that searches across:*
> *- clients.name (full-text)*
> *- properties.address*
> *- clients.client_code*
>
> *Show 10 best results with name, address, client_type (if set), and a 'View details' link to /prospects/:id.*
>
> *Use ILIKE matching for now (we can add proper full-text search via tsvector later)."*

---

## Tips for prompting Lovable well with our DB

1. **Use exact column names.** `visits.visit_status`, not `visits.status`. `employees.full_name`, not `employees.name`. The system prompt covers this but err on the side of being explicit.

2. **Mention "Eastern Time" when displaying dates.** Otherwise Lovable defaults to local time which is wrong for our ops.

3. **Be specific about RLS.** *"RLS: authenticated users can read; only the user who created the row can update or delete (set deleted_at)."* Saves debugging.

4. **Iterate small.** "Build /prospects with the basic list first, then we'll add filters" is faster than "build a full prospect-management app".

5. **When Lovable wants to break a rule**, push back with the rule. e.g. *"Use NUMERIC(12,2) for the revenue column per our schema conventions, not FLOAT."*

6. **Show it the existing data first.** *"Run `SELECT * FROM derm_manifests LIMIT 3` and explain the columns to me first."* Lovable can introspect Supabase — useful when you're not sure.

---

Next: **05-RULES.md** for the one-page summary.
