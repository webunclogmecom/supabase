# Permits for every county and city: data model brainstorm (2026-11-02)

**Ask (Fred, 2026-11-02, Client App, Grove Kosher Boca Raton):** the property's permit section asks for a PDF and a GDO
number, but this client is not in Miami-Dade, so it has no GDO. Rename the section **City Permits** (for every client),
say *"File the permits issued by <county>"*, drop the Property step from Add permit, order it **1. Nickname, 2. Permit
PDF**, and add **File manually** with fields to type the data. Then, on the storage question: *"do a big thinking on
this, like a brainstorm, using our compliance for how do we build the Database, 3NF ... having a column called "Permit
type", "Permit Number" and a link for the link of the PDF as another column too? ... keep in mind we're gonna have one
called CCN which is for Boca Raton, and GDO is for Miami DADE"*. And: with File manually, **the PDF is optional**.

Status: **proposal, nothing built.** Decisions needed are at the end.

## 1. What exists today (measured 2026-11-02)

- One table, `public.gdos`, holds every permit. It is **Miami-Dade DERM GDO by construction**:
  `gdo_number text NOT NULL`, `UNIQUE (client_id, gdo_number)`, `CHECK (gdo_number !~ '^GDO-[0-9]+$' OR
  permit_document_path IS NOT NULL)` (a real GDO number needs its PDF, Fred 2026-09-22), status
  ACTIVE / EXPIRED / INACTIVE, `max_frequency_days` 1 to 365, `location_label` (the name on the permit), `nickname`,
  `notes`, `property_id`, `client_location_id`, `permit_expiration`, `permit_document_path`, `permit_thumbnail_path`.
- **192 rows.** 188 are `GDO-n`. The other four show the strain already:
  - `PSO-00025` (057-BAY): a Miami-Dade sewer permit stored as if it were a GDO. `derm.visits` once showed it as a
    GDO on 81 rows (fixed 2026-10-21 with a format check).
  - Three INACTIVE rows with two or three numbers packed into one cell, or a `-DUPMERGE-` suffix.
- **Who depends on it (32 readers):** 16 views (`client.gdos`, `customer.permits`, `customer.gdo_reports`,
  `customer.clients`, `derm.gdos`, `derm.v_stamp_rows`, `derm.visits`, `ops.v_calendar_visit`,
  `ops.v_client_call_policy`, `ops.v_derm_compliance`, `ops.v_gdo_expiry`, `ops.v_route_today`, `ops.v_service_due`,
  `public.v_derm_portal_fields`, `public.v_rpa_derm_stale_leases`, `public.visit_manhole_options`) and 16 functions
  (the DERM sheet cards, the audit packs, the GDO resolvers, `dump_visit_gdo_numbers`, `seed_visit_locations`,
  `log_rpa_derm_health`, `client.upsert_gdo_permit`, ...). Plus 6 foreign keys INTO it (`derm_manifests`,
  `derm.address_row_map`, `derm_portal_leases`, `derm_portal_submissions`, `gdo_bot_file_requests`,
  `gdo_permit_label_reads`) and 6 triggers on it (audit, client consistency, demoted guard, one-address rule,
  updated_at, the PDF label reader).
- Almost every one of those readers means **"the DERM GDO permit"**: what prints on a DERM sheet, what the bot files
  with Miami-Dade, the portal's compliance figure, the DUMP app's GDO line. A Boca Raton permit in that table would be
  filed with Miami-Dade DERM, printed on a DERM sheet and counted in the portal's DERM compliance.
- **The PDF reader (`parse-gdo-permit`) only reads DERM permits** and refuses Broward / Palm Beach PDFs by design. It
  is also the only thing that can store a permit PDF (the bucket has no INSERT policy for the app).
- **What a DERM PDF gives us:** stored: GDO number, expiration, cleaning frequency (every N days), status (derived from
  expiration). Read but not stored: effective date, "issued to" (the label reader stores it as `location_label`),
  facility location, capacity (GPM).

## 2. The rules this must follow (Supabase `CLAUDE.md`, the 8 non-negotiables)

- **3NF standing check:** every column depends on the key, the whole key and nothing else. Anything derivable is
  computed in a view, not stored.
- **Reference, never copy:** related data by FK. Who issues a permit depends on its TYPE, not on the permit, so it
  lives once in a lookup, not on every row.
- **Source-agnostic, no hard delete** (status INACTIVE), **audit opt-in** for human-edited tables, RLS on with a policy
  in the same migration (every new table in `public` gets RLS automatically and reads 0 rows until it has one).
- **Location-bound** (Fred 2026-05-25): a permit is issued to a place, not a business. A GDO number does not change on
  renewal; an expired permit keeps its row.

## 3. The shape every option shares

**A lookup of permit types**, so "Permit type" is a real reference, not free text:

```
public.permit_types
  id                 bigint identity PK
  code               text UNIQUE      -- 'GDO', 'CCN', 'PSO', ... (what staff call it)
  name               text             -- 'Grease Disposal Operating permit'
  issuing_authority  text             -- 'Miami-Dade DERM', 'City of Boca Raton'
  county             text NULL        -- applies county-wide (GDO -> 'Dade')
  city               text NULL        -- or to one city only (CCN -> 'Boca Raton'); city wins over county
  number_pattern     text NULL        -- optional format check, e.g. '^GDO-[0-9]+$'
  document_required  boolean          -- GDO true (the 9-22 rule); others false (Fred: PDF optional)
  pdf_reader         text NULL        -- 'derm_gdo' when we can read the PDF automatically, else NULL
  status             text             -- ACTIVE / INACTIVE (never deleted)
```

Seeded with `GDO` (Miami-Dade DERM, county Dade, reader `derm_gdo`, document required), `CCN` (City of Boca Raton,
city Boca Raton) and `PSO` (the Miami-Dade sewer permit 057-BAY already holds), and grown one row at a time as new
programs appear (Fort Lauderdale, Hollywood, Broward County...).

**One permit row** carries: type (FK), permit number, the place (`property_id`, plus the tenant `client_location_id`),
nickname, name on the permit (`location_label`), effective date, expiration date, cleaning frequency (days), status,
notes, PDF path (a storage path, not a URL: links are signed when read, so a stored URL would expire), timestamps.

3NF notes, column by column:
- `issuing_authority`, county / city scope, "do we read this PDF", "is the PDF required": depend on the TYPE, so they
  live in `permit_types`, never on the permit.
- `status = EXPIRED` is half derivable from the expiration date, but Fred's rule is that `status` decides inclusion
  and an expired permit keeps its row, so `status` stays a stored human decision, as in `gdos` today.
- `client_id`: the place belongs to a client (`properties.client_id`), so storing it again is a transitive dependency.
  `gdos` stores it today (with a consistency trigger); a NEW table should not, and its readers join through the
  property. The display text "File the permits issued by ..." is computed from the property's city / county matched
  against `permit_types`, never stored.
- Capacity (GPM) is on the DERM PDF but nothing uses it. Not stored (add it only when a screen needs it).

## 4. Three ways to hold the rows

### Option A: one physical table for every permit (Fred's idea, in full)
Rename `gdos` to `permits`, add `permit_type_id`, rename `gdo_number` to `permit_number`, relax the PDF rule to
"required when the type says so", and keep a `public.gdos` view (`WHERE type = GDO`) for compatibility.
- Cleanest model: one entity, one table.
- ⚠ The catch is real: Postgres views bind to the table, not the name. After a rename the 16 views follow the table
  and would see EVERY permit, Boca Raton included, until each is rebuilt to read the GDO view. The 16 functions resolve
  by name and would pick up the view, but each must be checked. The 6 triggers (the PDF label reader, the one-address
  rule, the demoted guard) must be scoped to the right types, and the 6 foreign keys keep pointing at the renamed
  table. This is the DERM compliance chain: sheets, the filing bot, the portal. Days of work with rehearsals, and one
  missed reader is a wrong filing.

### Option B: GDO stays where it is, other types get their own table, one view shows them all (recommended now)
- `public.gdos` untouched: **0 of the 32 readers change**, the DERM chain cannot see a non-GDO permit.
- New `public.city_permits` for every non-GDO type, with the shared columns above and `permit_type_id`. Its `id` draws
  from the same sequence as `gdos`, so a permit id is unique across both.
- New `public.permits` view = `gdos` (labelled type GDO) `UNION ALL` `city_permits`: one list of every permit with type,
  number, authority, dates, PDF. The Client App section, expiry reminders and (later) the portal read this.
- Writes: `client.upsert_gdo_permit` for GDO (unchanged), a new `client.upsert_city_permit` for the rest; the app picks
  by type. Manual filing and an optional PDF apply to city permits from day one.
- The 4 strange rows can move later (PSO-00025 to `city_permits` as type PSO).
- Cost: two physical tables for one idea. It is a partition by type, not a copy (each permit exists once), and it can
  graduate to Option A later, once the DERM readers read an explicit GDO slice.

### Option C: add a "permit type" column to `gdos` and stop there
Rejected. Every one of the 32 readers would have to learn to skip non-GDO rows, and the first one that does not files a
Boca Raton permit with Miami-Dade DERM.

## 5. What the Client App does with it (either A or B)

- Section title **City Permits**, for every client.
- Empty state: *"File the permits issued by <authority>"*, the authority taken from the permit type that matches the
  property (city first, then county): Miami-Dade DERM, City of Boca Raton, ... If no type matches, it falls back to the
  county name.
- **Add permit**: no Property step (the tab is the property). Order: **1. Nickname, 2. Permit PDF**, then a
  **File manually** checkbox that opens the typed fields: Permit type (pre-filled from the property), Permit number
  (required), Name on the permit, Effective date, Expiration date, Cleans at least every N days, Status (derived from
  the expiration, editable), Notes. The PDF is optional when filing manually (Fred), except where the type requires it
  (GDO, the 9-22 rule: see decisions).
- A DERM GDO PDF keeps being read automatically. Other PDFs are stored as they are (a small change so the edge
  function can store a non-DERM PDF without reading it, since the app cannot write to the bucket).

## 6. The county question found on the way

Boca Raton is in Palm Beach County, but the Jobber sync files it as **Broward on purpose**: `webhook-jobber`
`inferCountyFromCity` says *"Boca Raton is geographically Palm Beach but ops classifies as Broward"*, and county drives
DERM routing. Today 8 Boca Raton properties are Broward and 1 is Palm Beach. Other mismatches seen on the way: West Palm
Beach filed as Broward, North Miami Beach (a Miami-Dade city) filed as Broward on two rows (139-LTG, 144-LTG), and
about 10 real cities with no county (Oakland Park, Dania Beach, Coral Springs, Palmetto Bay, North Bay Village...).
Because the permit authority can come from the CITY (CCN = Boca Raton), the permit section does not need the county
to be right to say "City of Boca Raton". Changing 022-GRO to Palm Beach would make it the odd one out of the Boca
Raton stores in whatever ops reads by county, so it is held for Fred's call.

## 7. Decisions for Fred

1. Option A (one table now, a multi-day rebuild of the DERM readers) or Option B (GDO untouched, city permits beside it,
   one combined view; can become A later).
2. The PDF: optional for city permits (yes, per Fred). For a Miami-Dade GDO typed in by hand, keep the 9-22 rule
   ("no GDO number without its file") or make it optional too?
3. CCN: its full name and what the Boca Raton permit document looks like (one sample PDF), and which other programs to
   seed now (Fort Lauderdale, Hollywood, Broward County...).
4. The county: keep Boca Raton as Broward by the ops convention (and leave 022-GRO), or move all Boca Raton stores to
   Palm Beach together (and check what reads county first).
