# Permits for every county and city: one table, the build plan (2026-11-02)

**Status: BUILT 2026-11-02** (migrations applied 15:01 ET, `6c6dbf2f`; the rehearsals, controls and live consumer checks are in that commit and the Client App changelog). Was: plan. Fred answered section 8 on 2026-11-02 (layout A, Field Portal every type, route GDO
first, county errors to Diego and Serena first) and said "yes go ahead, start tonight". Trello (Dev, Approved):
[sWPaXFZO](https://trello.com/c/sWPaXFZO) City permits, [iiOp4kSp](https://trello.com/c/iiOp4kSp) Counties.
Brainstorm and options: `2026-11-02-permits-model-brainstorm.md`. Consumer maps (read-only
sweeps of the database, 10 live app bundles, every edge function, the pdf-service, both bots, scripts, workflows):
summarised in section 3.

## 1. What Fred decided

- *"One table for every permit now"*: turn the GDO table into a general permits table with a type column, and make sure
  *"the DERM sheets, the filing bot and the portal still see only GDO ... keep in mind on what services, api, bots, cron
  jobs, etc fetches data from that"*.
- **The PDF is optional for every type**, GDO included (replaces the 2026-09-22 "no GDO number without its file" rule).
- **CCN is just a number**: "we don't hold any permit".
- **Move all Boca Raton properties to Palm Beach**, and the sync rule, after checking what reads county.
- Client App: section **City permits**, empty note *"File the permits issued by <county>"*, Add permit without the
  Property step, **1. Nickname, 2. Permit PDF**, and **File manually** with typed fields.

## 2. The shape

**Keep the table and column names** (`public.gdos`, `gdo_number`). Measured reasons, not taste:
- `client.get_client_activity` finds permit history by the logged table name `'gdos'`; a rename splits every client's
  permit history in two.
- The literal names live in the Client App bundle, the Slack GDO bot (REST path, embed, FK name
  `gdos_property_id_fkey`), the pdf-service embed, 6 edge functions, 4 scripts and the activity labels. Lovable apps
  cannot be released in the same transaction as a migration.
- Views bind to the table, not the name, so a rename protects nothing: the DERM readers see every row either way. What
  protects them is a type filter (below).
The app-facing view `client.gdos` exposes `permit_type` and `permit_number` (alias), as `customer.permits` already does.

**New lookup `public.permit_types`** (RLS on, policy SELECT to authenticated, audit opted in, anon holds nothing):

| column | note |
|---|---|
| `code text PRIMARY KEY` | `GDO`, `CCN`, `PSO` (a natural key: the readers filter `permit_type = 'GDO'` with no join) |
| `name text NOT NULL` | Grease Disposal Operating permit, ... |
| `issuing_authority text NOT NULL` | Miami-Dade DERM, City of Boca Raton; PSO's read off its own PDF (row 141) before seeding |
| `number_pattern text NULL` | GDO `^GDO-[0-9]+$`; CCN and PSO NULL (CCN is "just a number") |
| `reads_pdf boolean NOT NULL DEFAULT false` | GDO true: only those PDFs go to `parse-gdo-permit` and the label reader |
| `status text NOT NULL` | ACTIVE / INACTIVE, never deleted |

No `document_required` column: Fred made the PDF optional for every type, so it would be false everywhere (YAGNI).

**On `public.gdos`:**
- `permit_type text NOT NULL DEFAULT 'GDO' REFERENCES public.permit_types(code) ON UPDATE CASCADE`, indexed. The default
  keeps every existing writer correct until it learns the column (they all write GDO numbers today).
- `permit_effective date NULL`: the form's Effective date. The DERM PDF already parses it and nothing stores it.
- Drop `gdos_real_number_requires_document_chk` (Fred: PDF optional).
- Keep `UNIQUE (client_id, gdo_number)`: it also makes `get-permit-doc`'s lookup by number safe across types.
- New BEFORE trigger `trg_aa_permit_number_matches_type` (INSERT, UPDATE OF gdo_number, permit_type, status), for every
  writer: a row that is not INACTIVE must match its type's `number_pattern` when there is one, and **a number starting
  `GDO-` must be type GDO**. That second rule is what keeps the 20 readers that already test `^GDO-[0-9]+$` exactly as
  safe as a type filter, so they are not rebuilt (fewer DDL on the DERM chain, less risk). INACTIVE rows are exempt so
  the three historical malformed GDO rows (ids 29, 157, 164) stay as they are.
- Backfill: the 191 GDO-family rows get `GDO` (the default), row 141 (057-BAY `PSO-00025`) gets `PSO`.
- 3NF: authority, pattern and "do we read this PDF" depend on the type, so they live in `permit_types`. `client_id`
  stays (existing, with its consistency trigger); not moved in this change.

## 3. Who reads it, and what changes

Database side: 27 views, 61 functions (17 read the table directly), 9 triggers, 6 cron jobs, 7 permit references.
Code side: 25 consumers (17 GDO-only, 4 all types, 4 unclear). Full maps kept in the session scratchpad; the decisions:

**Already GDO-only by the number format, unchanged** (safe because of the new trigger): the DERM filing bot views and
functions (`v_derm_portal_fields` and its 8 children, `fn_resolve_gdo_id`, `log_rpa_derm_health`, ...), Stamp Studio
(`fn_ensure_permit_cards`, `add_extra_client_card`, `fn_card_printed_row`, `record_generated_sheet_preview`,
`v_stamp_rows` by id), `derm.visits`, `ops.v_calendar_visit`, `customer.gdo_reports`, the DUMP app
(`dump_visit_gdo_numbers`, `dump-visit-create`), the pdf-service `_active_gdos`, the external bot (reads the views).

**GDO-only in meaning but with NO filter today, so they get `permit_type = 'GDO'`** (each already shows 057-BAY's PSO):

| object | today |
|---|---|
| `derm.gdos` (DERM Tracker permit list) | no filter at all |
| `ops.v_derm_compliance` | first ACTIVE by id, any type |
| `customer.clients.gdo_permit_url` | first ACTIVE by id; 057-BAY's link is the PSO file |
| `derm.audit_pack` (fallback when a manifest has no permit), `derm.audit_pack_client` | first ACTIVE by id |
| `public.fn_check_gdo_on_visit` (trigger on visits: "Dade pumping visit with no GDO") | a PSO or CCN counts as a GDO |
| `public.fn_gdo_permit_label_targets` (label reader, cron 09:11 UTC + storage trigger) | sends any PDF to the DERM prompt |
| `rpa-derm-result` edge fn, its two direct `gdos` reads | a CCN `12345` and `GDO-12345` share its permit key |
| Slack GDO bot (`supabase_lookup.py`) | a CCN reads as a "placeholder record"; a CCN-only client drops off "missing GDO" |
| `scripts/sync/cron_gdo_permit_pdf_ingest.js`, `backfill_gdo_frequency_from_pdf.js` | would look CCN numbers up at DERM |

**Every type** (updated to know about types): `client.gdos` (adds `permit_type`, `type_name`, `issuing_authority`,
`permit_effective`, `permit_number`; `is_placeholder` only for GDO), `client.upsert_gdo_permit` (accepts `permit_type`
and `permit_effective`, no PDF requirement, refuses an unknown or INACTIVE type, messages say "permit" not "GDO"),
`ops.v_gdo_expiry`, `ops.v_client_call_policy` (any permit's maximum frequency is a real limit; unchanged),
`client.get_client_activity` (unchanged: name kept), `save-client-property` (label "permits"), `get-permit-doc`
(unchanged).

**Decided by Fred (section 8):**
- Field Portal permits card (`customer.permits`, customer-facing, reached by anon through the whole-row
  `customer.get_client_portal` / `get_work_order`): **every type**, card retitled **"Permits & Frequency"**. The view
  gains `permit_type` and `type_name`; the hard-coded area "Grease Trap" goes; the frequency comparison and the
  "compliant" chip are hidden for a permit with no maximum frequency (customer apps hide what we lack). The same rows
  feed the visit report's permit block (`derm.get_visit_report`), so it follows. `customer.clients.gdo_permit_url`
  stays GDO only (it is "the GDO permit link").
- `ops.v_route_today` / `ops.v_service_due`: **GDO first, else another type** (`order by (permit_type = 'GDO') desc, id`).
- Kept as they are, a permit is a permit: `public.visit_manhole_options` and the location seeding in
  `seed_visit_locations` / `webhook-jobber` (a location with any ACTIVE permit counts as served).

**PDF storage for other types.** `parse-gdo-permit` is the only uploader (the app has no INSERT policy on the bucket) and
refuses anything that is not a DERM permit. It gets a store-only branch: for a type with `reads_pdf = false` it checks
the file is a PDF under the size cap, stores it at `<type>/<client_code>-<number>.pdf` in the same bucket, reads
nothing, and returns the path. The label reader skips it through the targets filter.

**County (Boca Raton to Palm Beach), 13 code places + the DB:**
- Data: 15 Boca Raton property rows are Broward (8 live: 291, 668, 53, 62, 1012, 1117, 68, 4; 7 soft-deleted), 2 are
  already Palm Beach. All 15 move. `properties` is audited; county is not pushed to Jobber (the outbound trigger fires
  only on trap size and lock box), so the write stays in the DB.
- `webhook-jobber` `inferCountyFromCity`: drop `BROWARD_BY_CONVENTION`, map `boca raton` to `Palm Beach`, or every new
  Boca property lands Broward again.
  - Already shipped beside it (2026-11-02, `create-client` v54, a separate fix): a County picked in the New Client form
    (Calendar or Client App) is now written onto the new property after the import, so a Boca client created there
    with "Palm Beach" picked lands Palm Beach today. `inferCountyFromCity` still decides for properties created in
    Jobber and for "Not set", so this step is still needed. No conflict: `create-client` does not call it.
- `public.fn_admin_review_pending` (11 AM Slack): groups `county = 'Broward'` as "Broward" and everything else by city,
  so Boca visits move to their city heading. Left as it is: that is Diego's 2026-10-29 rule ("every Broward client is
  Broward; anywhere else, the city that gets the email"), and Boca Raton is the city that issues the CCN.
- Same behaviour, nothing to do: dump routing and Homestead hiding (`fn_dump_county_bucket` already folds Palm Beach
  into BROWARD), LWT scope (`county = 'Dade'`), the DERM queue. The FDEP sheet's County field will print "Palm Beach",
  which is correct.

## 4. Steps, each with its check

Every migration: copied from the live body (never retyped), one anchored edit, md5 guard on the old body,
`SET LOCAL lock_timeout = '3s'`, cheap VERIFY inside, heavy comparisons before and after, rollback file beside it,
applied outside ET business hours where it touches a view an app reads. WORKING-NOW claim before the first one.

| # | What | Check |
|---|---|---|
| 0 | Snapshot (JSON, scratchpad) of every guarded and unguarded reader's output for all live clients | the "nothing else moved" baseline |
| 1 | `permit_types` + seed + policy + audit trigger + `REVOKE ALL` from anon | `relacl` read back; authenticated reads 3 rows, anon 0 |
| 2 | `gdos.permit_type` + `permit_effective`, backfill (141 = PSO), FK, index, drop the document CHECK, the type trigger | counts: 191 GDO + 1 PSO; trigger refuses a CCN numbered `GDO-1`, a GDO numbered `12345`; INACTIVE id 29 still updates |
| 3 | `permit_type = 'GDO'` on the 7 DB objects in the unguarded table | 057-BAY's PSO gone from each; every GDO row identical to step 0 |
| 4 | `client.gdos` + `client.upsert_gdo_permit` (types, effective date, PDF optional, plain messages) | add / edit / remove a CCN on 112-YA as `authenticated` in a rolled-back probe; old RPC body as the control (must refuse a CCN without PDF) |
| 4b | `customer.permits` (type columns, no "Grease Trap", no comparison without a maximum), `ops.v_route_today` / `ops.v_service_due` (GDO first) | anon portal JSON for 057-BAY and 112-YA read back key by key (only the intended new keys); a GDO client's route line unchanged |
| 5 | Edge: `rpa-derm-result` (filter), `parse-gdo-permit` (store-only branch), `save-client-property` (label), `webhook-jobber` (Boca) | `scripts/probes/edge_deployed_body.js` with a control needle; `scripts/checks/rpa_derm_result_*.mjs` re-run |
| 6 | Slack GDO bot filter; the two scripts' filter | bot "missing GDO" and "expiring" lists identical before and after for real clients |
| 7 | County data move (15 rows) | backup JSON first; `fn_admin_review_pending()` lists the same visits before and after, Boca under its city |
| 8 | Client App (Lovable), the layout Fred picks | section 5 below |
| 9 | Standing check `scripts/checks/permits_gdo_only.sql` | must fail on the step-0 bodies (control), pass after |

## 5. Checks before it is called done

- **Rolled-back rehearsal with a CCN row on 112-YA** and the step-0 bodies as the control: the CCN must appear in
  `derm.gdos`, the compliance board and the portal link on the OLD bodies and in none of them on the new ones; it must
  appear in `client.gdos` and `ops.v_gdo_expiry` on both.
- **Nothing else moved:** every reader's output for every live client equals step 0, except 057-BAY's PSO leaving the
  GDO-only readers.
- **Smoke:** `rpa-derm-queue?mode=dryrun` returns the same items; a DERM sheet preview from the pdf-service has the same
  rows; Stamp Studio cards unchanged; the call-first and label crons run clean; every app request HTTP 200.
- **Visual (live sites, 1440 and 375, then reset):** Client App on 112-YA (add a CCN by hand, add a GDO PDF, edit,
  remove), then Grove Kosher (City permits, "File the permits issued by Palm Beach County"); DERM Tracker permit list
  for 057-BAY (no PSO); Field Portal 057-BAY; Calendar drawer for a Dade visit (unchanged) as the control.
- Fix what fails, then run all of it again.

## 6. Rollback

Newest first: the Client App release (Lovable revert), the county rows (backup JSON, restore by id), the edge functions
(redeploy the previous body), steps 4 to 1 (rollback files restore the md5-pinned old bodies, put the document CHECK
back only if no new row lacks a document, drop the trigger and columns, drop `permit_types`). A CCN row written in
between blocks dropping the type column; the rollback refuses and says so rather than deleting it.

## 7. Docs in the same cycle

`docs/schema.md` (gdos, permit_types), `docs/reference/` GDO notes that say "GDO table", this plan's status, the
`decisions-to-build.md` row (built + migrations), Client App `docs/08-changelog.md` + `CLAUDE.md` (permit types, PDF
optional, City permits), DERM Tracker changelog (057-BAY's PSO no longer listed), the Slack bot README, memory.

## 8. Decisions (Fred, 2026-11-02)

1. **Dialog layout: A** (typed fields in a bordered card, two columns; the PDF drop area stays full size).
2. **Field Portal: every type, card retitled "Permits & Frequency"** (section 3).
3. **Driver route and service-due list: GDO first, else another type.**
4. **Other county errors** (not covered by "move Boca"): Fred asked for a short message to Diego and Serena in
   #new-app-issues first (drafted in his Slack 2026-11-02, not sent). The list: 144-LTG North Miami Beach filed Broward
   (Miami-Dade: it would start being checked for a GDO and counted on the LWT report); 235-LOU West Palm Beach filed
   Broward (Palm Beach); no county on 310-LOU, 357-LOU, 277-VSS, Flea Market Oakland Park (Broward), 289-PER and North
   bay villa (Miami-Dade); 3 outside Florida left blank. Fixed only after they confirm, each with its effect stated.
