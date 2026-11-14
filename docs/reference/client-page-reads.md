# The reads behind the portal's Clients pages and the manifest dialog

*The database side of the Client App's move into the Ops Portal (Trello #161, Stage E). Plan:
`Building Apps/Ops Portal/docs/specs/2026-11-13-client-app-move-plan.md` (section "Outside the app, in the Supabase repo",
B1 to B4, and decision 3). Fred, 2026-11-14 about 12:40 AM ET: "AA to FF all yes, and all defaults".*

Every function here is read only, STABLE, SECURITY DEFINER owned by postgres with `search_path` pinned to `''`, EXECUTE
revoked from PUBLIC and anon by name and granted to `authenticated` only (the exceptions are named). Each starts with
`hr.fn_require_any_app(array[...], 'view')`, the gate `public.get_record_history` has, then the staff check of the DERM
reads. **Pick BB (decision 3):** a person with the Client App alone opens every Clients page and the manifest dialog, so
each read accepts the Client App OR the app whose page also calls it.

Standing check: `scripts/checks/client_page_reads.sql` (run as owner inside BEGIN ... ROLLBACK; it raises on a failure).

## The manifest row states: one core, two gated readers (2026-11-14_0135)

Migration `docs/migrations/2026-11-14_0135_derm_manifest_row_states_per_client.sql`, undo
`2026-11-14_rollback_derm_manifest_row_states_per_client.sql` (it refuses while `derm.get_manifest_dialog` exists).

| function | gate | returns |
|---|---|---|
| `derm.fn_manifest_row_states_core()` | none. SECURITY INVOKER, EXECUTE for the owner only (revoked from PUBLIC, anon, authenticated, service_role) | the Manifests list's row states, every ticket |
| `derm.manifest_row_states()` | DERM Tracker View, then the staff check (unchanged) | the core's answer |
| `derm.manifest_row_states_for_client(p_client_id bigint)` | Client App OR DERM Tracker View | the core's entries for the tickets holding a live manifest row of that client |

- **One copy of the rules.** The core is the 2026-11-13_0148 body of `derm.manifest_row_states()` byte for byte, without
  its gate; the wrapper keeps the gate and calls the core. The migration compared the old and the new answer on every row
  inside its own transaction, and the rehearsal checked the per-client read for all 204 clients holding a live manifest
  row (together their entries are exactly the 181 entries of the list).
- **Shape:** the same object as `derm.manifest_row_states()` (the CLAUDE.md section "THE MANIFESTS ROWS READ"): keys are
  the list's row keys (`Miami-Dade #<number>`, `Broward #<number>`), each entry with `manifest_ids`, `needs`, `worst`,
  `papers`, `stamps`, `copies`, `city`, `visit`, `sheets`. An entry's `manifest_ids` lists every row of its ticket, other
  clients' included (ids only). A client with no live row gets `{}`.
- 112-YA (client 381) today: `{"Miami-Dade #111111": {...}, "Miami-Dade #111112": {...}}`.
- **Cost:** the core reads every ticket (about 0.15 s), so the per-client read costs the same.
  ponytail: pass the client's keys into the core if a client page read gets slow.
- **A new reader of the row states calls the core from behind its own gate**; never copy the rows' rules.

## B1: a visit's gallons and a site's pumping figures (2026-11-14_0140, corrected by 2026-11-14_0350)

`public.get_pumping_figures(p_client_id bigint default null, p_visit_ids bigint[] default null) returns jsonb`.
Migration `docs/migrations/2026-11-14_0140_public_get_pumping_figures.sql`, undo `2026-11-14_rollback_public_get_pumping_figures.sql`.
Corrected by `docs/migrations/2026-11-14_0350_public_get_pumping_figures_line_item_kinds.sql` (three anchored edits of the
live body: a pumping and its kind from the line items, the trap size for a grease trap pumping only), undo
`2026-11-14_rollback_public_get_pumping_figures_line_item_kinds.sql` (the 0140 body back; run it before the 0140 undo).

- **Gate:** the Client App, the DERM Tracker, Stamp Studio OR Admin Review, at View (the manifest dialog opens from the
  first three; Admin Review's Grease page already shows these figures for every client, so it widens nothing).
- **Where:** `public`, because Z8 forbids any object in `derm`, `customer` or `client` to read the tank views. The manifest
  dialog's own read (B2) gives no gallons: the app calls this one with the ticket's visit ids.
- **Input:** a client (every completed, live visit of it, and its sites' figures), or a list of visit ids (exactly those
  completed, live visits; no site figures), or both (the client's visits among the ids). Neither raises 22023; more than
  2,000 ids raises 22023.
- **`visits`**, newest first: `visit_id`, `client_id`, `property_id`, `visit_date`, `source`, `gallons` (whole gallons).

  | source | gallons | the app shows |
  |---|---|---|
  | `tank` | the truck tank's reading, `v_visit_tank_service.sludge_collected_gallons`, trusted as the averages trust it: a volume visit, confidence high or medium, 40 to 3,840 gal | the gallons, measured |
  | `trap_size` | a GREASE TRAP pumping with no trusted reading: the trap size on file (`properties.grease_trap_size_gallons`, 0 is none), which is the grease trap's | the gallons, labelled as the trap size |
  | `none` | null: a pumping with neither; every lift station or grey water pumping with no trusted reading is one (the size on file is not its tank's) | "Not measured" |
  | `not_a_pumping` | null: no line item of the visit (or of its job) pumps anything | "No pumping on this visit" |

- **A pumping, and its kind, come from the line items, by the Calendar's own rule** (since `2026-11-14_0350`). B1 calls
  `ops.fn_visit_pump_kinds(visit, job)`, the function the Calendar's estimate (`ops.fn_grease_estimates_live`) and the
  averages call, so the rule lives in one place: the visit's own coded lines (01, 02, 09 grease trap; 03, 10 grey water;
  04, 11 lift station), else its job's job-scope lines, else old uncoded line names that say so. No pumping line:
  `not_a_pumping`, before anything else (on 2026-11-14 no visit had a trusted tank reading without one, so that order
  moved nothing). `visits.service_type` decides nothing: 91 completed 2026 visits disagree with their lines. Two shapes
  to know: 36 visits of service type Pumping (January to June 2026) carry only the plain line "Service Agreement", so
  they read `not_a_pumping`, as the Calendar's estimate counts them; and the tank view still takes a reading only on a
  visit of service type Pumping, so a pumping by its lines with another service type never has a `tank` reading.
- **The trap size is the grease trap's**, so only a visit whose kinds hold `grease_trap` falls back to it; a lift station
  or grey water pumping with no trusted reading is `none`. The Calendar's estimate does the same at a place with a grease
  trap service; at a place without one it still uses the size on file (its step 7), so on 2026-11-14 the two differ on
  47 completed visits (`none` here, the size on file there).
- **What the correction moved**, 2026-11-14: 215 of the 1,663 completed visits, all 2026 (none to not_a_pumping 80,
  trap_size to none 61, trap_size to not_a_pumping 38, not_a_pumping to none 25, not_a_pumping to trap_size 10, none to
  trap_size 1); the `tank` readings and the site figures did not move.
- **`sites`** (only with `p_client_id`), per live site and pump kind (`grease_trap`, `grey_water`, `lift_station`):
  `property_id`, `pump_kind`, `average_gallons`, `low_gallons`, `high_gallons`, `last_date`, `last_gallons`,
  `readings_in_average`. They are `ops.fn_client_sludge_averages` itself as of tomorrow ET, the Calendar's average and
  Admin Review's Grease page (the last 6 trusted readings of the place and kind), so low, high and the count are over the
  same readings as the average. A site with no trusted reading has no entry.
- **Never** `ops.visit_grease_frozen` (the Calendar's estimate) and never a figure the app works out itself.
- **The trust rule has three copies** (the averages' pool, `ops.calendar_grease_estimates`, this read). The VERIFY and the
  standing check compare this read with the averages over every completed visit, both ways: a reading the averages use is
  `tank` here with the same gallons, and every `tank` reading of a visit with a site is one the averages use.
- **And with the Calendar's estimate, both ways, on every completed 2026 visit** (`ops.fn_grease_estimates_live`, live,
  never the frozen rows; about 1.4 s): `not_a_pumping` exactly when the estimate finds no pump kind, `trap_size` only
  where its kinds hold a grease trap, never `none` on a grease trap pumping with a trap size on file. So if the Calendar
  ever finds pump kinds another way, the check fails rather than the two reads drifting apart. Its controls (the 0140
  body, each correction undone) fail it: 215, 70 and 152 visits differ.
- 112-YA today: 8 completed visits, 2 `trap_size` (30 gal, grease trap pumpings), 1 `none` (8742, a lift station
  pumping, line 11), 5 `not_a_pumping` (no pumping line; 5680 has no service type either), no site figure (no tank
  reading). Example entry: `{"visit_id": 8113, "visit_date": "2026-09-15", "property_id": 162, "source": "trap_size",
  "gallons": 30}`.
- **Cost** (measured 2026-11-14 as the owner, best of 3): 0.40 s with a client (the averages read every trusted reading
  once); 0.10 s for a ticket's visits. The correction left it so: 0.39 s for a client, 0.12 s for 200 visit ids.

## B3: a client's emails, and the emails to one contact (2026-11-14_0148)

`client.get_client_emails(p_client_id bigint, p_address text default null) returns jsonb` (`{"emails": [...]}`, newest
first). Migration `docs/migrations/2026-11-14_0148_client_get_client_emails.sql`, undo
`2026-11-14_rollback_client_get_client_emails.sql`.

- **Gate:** the Client App OR the DERM Tracker, at View. Today the browser cannot read To, Cc and Bcc
  (`public.derm_email_sends` and `public.visit_photo_email_sends` grant it nothing) nor the client's copies
  (`derm.redacted_manifest_docs`): this read is the way in.
- **An email** is a record with status `sent` that is not a test, the rule of `public.v_client_email_sends` and
  `public.v_visit_city_email_sends`: the DERM emails (to the client or the city) and Admin Review's city emails, which
  count for the client of their visit.
- **With `p_address`** (trimmed, any case): only the emails that carried that address in To, Cc or Bcc, each with
  `matched_as` (`to`, `cc`, `bcc`): a contact's Activity. A blank address raises 22023.
- **Each email:** `source` (`derm_email_sends` or `visit_photo_email_sends`) and `send_id`; `kind` (`client` or `city`);
  `sent_at`; `sent_by_email` and `sent_by_name` (the name from `public.employees`; null when nothing was recorded);
  `via` (`derm_tracker`, `admin_review`, `automatic`, read from `public.v_visit_city_email_sends`, which owns that rule; null
  for a client email or a city email of an unlinked manifest); `to`, `cc`, `bcc` as recorded (`cc` and `bcc` are null
  when not recorded, before 2026-08-28, and `[]` when there were none; no email carries a Cc today); `manifest_ids`,
  `manifest_numbers`, `visit_id`; `with_photos`; `copies` (the client's copies we hold of those manifests: `manifest_id`,
  `url`, `page`, `made_at`); `resend_email_id`; `delivery_status`, `delivery_at`, `delivery_detail`, straight from
  `public.v_email_delivery` (never computed here, Building Apps rule 1e).
- **No text:** we do not keep an email's text (decision 10), so there is none and the opened row says so. A later
  server function may ask Resend by `resend_email_id`.
- 112-YA today: 3 city emails (2 from Admin Review, 1 automatic), each with its copy of manifest 111111 and its delivery
  state (`opened`, `delivered_open_unknown`).
- **Cost:** 0.06 to 0.12 s for a client (2026-11-14).

## B2: the manifest dialog's data for one ticket (2026-11-14_0155)

`derm.get_manifest_dialog(p_number text) returns jsonb`, or null when no live manifest row carries that number (a blank
or null number too). Migration `docs/migrations/2026-11-14_0155_derm_get_manifest_dialog.sql`, undo
`2026-11-14_rollback_derm_get_manifest_dialog.sql` (run it before the undo of `2026-11-14_0135`).

- **Gate:** the Client App, the DERM Tracker OR Stamp Studio, at View: the three apps that open the dialog (decision 4,
  everywhere in one publish).
- **The ticket** is every live `public.derm_manifests` row whose number (`white_manifest_number`, else
  `yellow_ticket_number`) is `p_number`, the number every page links.
- **`number`**, and **`row_states`**: the ticket's entries of the Manifests list, exactly as
  `derm.fn_manifest_row_states_core()` gives them (the IC1 icons and their tooltips), keyed by the list's row key. A
  Miami-Dade and a Broward ticket sharing digits would come as two keys (none on 2026-11-14).
- **`clients`**, one per live row (one client on the ticket), by client code: `manifest_id`, `client_id`, `client_code`,
  `client_name`, `white_manifest_number`, `yellow_ticket_number`, `service_date`, `dump_ticket_date`, `dump_site`,
  `sheet_no`;
  - `papers`: `manifest_urls`, `sheet_urls` (the address sheet pages in order), `receipt_path`, `fog_manifest_url`, as
    stored on the row (the rows of 5 tickets hold different papers, so each row keeps its own);
  - `permits`: the client's live GDO permit numbers by the list rule (ACTIVE, type GDO, `GDO-<digits>`), never the frozen
    `derm_manifests.gdo_id`;
  - `stamp`: `cards`, `placed`, `last_placed_at` of the row's stamp cards (`derm.address_row_map.matched_manifest_id`);
  - `copies`: the client's copies (`derm.redacted_manifest_docs`): `url`, `page`, `made_at`;
  - `client_emails`: from `public.v_client_email_sends`: `sent_at`, `sent_by_name`, `to_count`, `with_photos`,
    `delivery_status`, `delivery_at`, `delivery_detail` (no address: B3 has them);
  - `visits`, the live visits linked to the row, by date: `visit_id`, `visit_date`, `visit_status`, `service_type`,
    `arrived_at`, `duration_minutes`, `property_id`, `site` (name, else address), `city`, `crew` (`name`, `color`),
    `truck` (`name`, `color`), `job_number`, `invoice_number`, `city_email` (`state` from
    `public.v_visit_city_email_state`; `sends` from `public.v_visit_city_email_sends`: `sent_at`, `via`, `app_label`,
    `sent_by_name`, `with_manifest`, `with_photos` and the delivery columns), `county_report` (`needed`: the visit is in
    `derm.gdo_report_status`; `report_state`; `filed`: `derm.visit_gdo_report` rows with `status`, `gdo_number`,
    `attempted_at`, `is_manual`, `portal_confirmation`, `screenshot_path`, `screenshot_missing_reason`).
- **No gallons:** it lives in `derm` and may not read the tank views (Z8). The dialog calls
  `public.get_pumping_figures(null, <the visit ids>)` (B1). `derm.manifests.gallons` is always null and is not read.
- 112-YA today, `derm.get_manifest_dialog('111111')`: 1 client, 1 visit (8113, Cloggy, crew Fred), 1 copy, a stamp
  placed, 2 city emails, row state `Miami-Dade #111111`.
- **Cost:** 0.15 to 0.2 s a ticket (the row states core is most of it).

## B4: the portal's search finds addresses, invoices and quotes (2026-11-14_0203)

`ops.portal_search(p_q text)`, the Ops Portal's "Search everything". Migration
`docs/migrations/2026-11-14_0203_ops_portal_search_addresses_invoices_quotes.sql` (one anchored edit of the
`2026-11-05_0230` body: a block before the final RETURN), undo
`2026-11-14_rollback_ops_portal_search_addresses_invoices_quotes.sql` (the old body verbatim, md5-guarded).

- **Unchanged:** the groups `clients`, `visits`, `requests`, `people`, their rules (a group only for an app the person can
  open, the bell's rule), its grants (authenticated and service_role) and its 2 to 80 character limit. The migration
  compared the four groups of the old and the new body for every term of a corpus read from the data and three people;
  the rehearsal did it for 402 terms and four people (1,608 answers, 0 differ).
- **New, for a person who has the Client App** (View or Edit), at most 5 each, best first:

  | key | finds | each result |
  |---|---|---|
  | `properties` | a live site whose address, name or city holds the words, or whose ZIP starts with them | `id`, `client_id`, `code`, `client_name`, `name`, `address`, `city`, `zip`, `is_billing`, `tab` = `sites`, `rank` |
  | `invoices` | an invoice whose number holds them | `id`, `client_id`, `code`, `client_name`, `invoice_number`, `status`, `issued` (the day sent, Eastern), `tab` = `billing`, `rank` |
  | `quotes` | a quote whose number or title holds them | `id`, `client_id`, `code`, `client_name`, `quote_number`, `title`, `status`, `archived` (last), `tab` = `billing`, `rank` |

  A result opens `/clients/<client_id>?tab=<tab>`, with `&site=<id>` for a site (decision 1). Rank: the exact number (0),
  a number or address that starts with the words (1), the rest. No email, phone, lock box, note or pay; no amount.
- **The live portal is unchanged until its next publish:** its search (`shell/search.tsx` on `main`, and the published
  chunk `header-D6xPtvxd.js` walked on 2026-11-14) reads only `clients`, `visits`, `requests` and `people`, three times
  each, and counts only those for "Nothing found"; the words `properties`, `invoices` and `quotes` appear nowhere in that
  chunk. So the new keys are ignored there.
- 112-YA today, as a person with the Client App: `ops.portal_search('112-YA')` returns its client and empty
  `properties`, `invoices` and `quotes` (none of them holds that text).

## The forms list opens to the Client App (2026-11-14_0213)

`client.v_intake_submissions` (Picture Planner's list of site survey forms): its gate `(hr.fn_app_open('picture_planner',
'view') OR hr.fn_pp_forms_open())` gained one arm, `OR hr.fn_app_open('client_app', 'view')`. Migration
`docs/migrations/2026-11-14_0213_client_v_intake_submissions_client_app_arm.sql` (one anchored edit of the live text, printed
with an empty search_path; the VERIFY checks the stored text is the old one plus that arm), undo
`2026-11-14_rollback_client_v_intake_submissions_client_app_arm.sql`.

- **Why:** the Clients pages' Schedule survey dialog (IntakeScheduleDialog) reads a site's waiting forms here. A person
  with the Client App alone saw 0 forms where Fred saw 32 (11 waiting), with no error: a silent hide, the only read of the
  Clients pages that failed that person (the sweep below).
- **Nobody's answer changed:** every active person with a sign-in read the same number of rows before and after (7
  people, measured in the rehearsal); everyone with the Client App also has Picture Planner or the forms switch today.

## A quote's Jobber address (2026-11-14_0721)

`client.quotes` gained a last column, `jobber_url` (`https://secure.getjobber.com/quotes/<Jobber id>`, built as `client.invoices.jobber_url` is, from the stored id in `entity_source_links`; NULL with no id), for a quote's "Open in Jobber" and "Send it in Jobber"; undo `2026-11-14_rollback_client_quotes_jobber_url.sql`.

## Every read of the Clients pages, as a person with the Client App alone (2026-11-14)

Measured in a rolled-back rehearsal: person 58 (the HR test person) made active with the Client App at View and every other
app None, against Fred, table by table and function by function (script `mockups/2026-11-14-clients-db/sweep.mjs`, local).

- **Work, the same answer as Fred:** the PostgREST request gate; every `client` view the pages read (clients,
  client_services_flat, properties, gdos, visits, v_visits_live, jobs, line_items, service_line_items, client_groups,
  status_changes, v_client_billing, v_client_past_due, visit_team, vehicles, employees, photo_links, photos,
  reason_photos, manifest_visits, invoices, quotes, client_contacts, jobber_contacts, derm_manifests, zones,
  permit_types, v_property_intake, v_intake_questions, job_activity, job_frequency_changes); `public.employees`,
  `public.vehicles`, `public.v_visit_city_email_sends`, `public.v_visit_city_email_state`, `public.v_client_email_sends`,
  `public.disposal_facilities`; `derm.visit_gdo_report`, `derm.gdo_report_status`, `derm.manifests`;
  `client.get_client_activity`, `client.get_property_activity`, `public.get_record_history('clients', ...)`,
  `client.preview_client_status_change`, `client.preview_job_action`, `client.recurring_eligibility`,
  `client.fn_derm_recipients`; the storage gate (`hr.fn_storage_open()`, signed photo links); the five new reads.
- **`client.saved_views`:** 3 rows against Fred's 4, by design (a person sees the shared views and their own).
- **Still refused, replaced by a new read:** `derm.manifest_row_states()` (by `derm.manifest_row_states_for_client`),
  `public.get_grease_by_client()` (by B1), `derm.redacted_manifest_docs` (by B2 and B3), `public.derm_email_sends` (by B3).
- **0 rows for everyone, Fred included:** `derm.address_row_map` and `derm.stamp_sheet_status` as `authenticated` (RLS
  with no policy for that role); the pages do not read them, B2 does.
- **Actions of another app** (Open on the Calendar, Send to city, Open the stamping screen) stay refused by their own
  server checks: decision 3 shows them greyed with the reason. Writes need the Client App at Edit.
