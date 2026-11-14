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

## B1: a visit's gallons and a site's pumping figures (2026-11-14_0140)

`public.get_pumping_figures(p_client_id bigint default null, p_visit_ids bigint[] default null) returns jsonb`.
Migration `docs/migrations/2026-11-14_0140_public_get_pumping_figures.sql`, undo `2026-11-14_rollback_public_get_pumping_figures.sql`.

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
  | `trap_size` | a pumping with no trusted reading: the trap size on file (0 is none) | the gallons, labelled as the trap size |
  | `none` | null: a pumping with neither, or a visit whose service type is not known | "Not measured" |
  | `not_a_pumping` | null: the service type is known and is not Pumping (or the visit is at a dump site) | "No pumping on this visit" |

  A pumping is the tank view's own rule: service type `Pumping`, not at a dump site. It is decided by the service type, not
  by the line items: on 2026-11-14, 54 completed 2026 Pumping visits had no pumping line and 37 other visits had one.
- **`sites`** (only with `p_client_id`), per live site and pump kind (`grease_trap`, `grey_water`, `lift_station`):
  `property_id`, `pump_kind`, `average_gallons`, `low_gallons`, `high_gallons`, `last_date`, `last_gallons`,
  `readings_in_average`. They are `ops.fn_client_sludge_averages` itself as of tomorrow ET, the Calendar's average and
  Admin Review's Grease page (the last 6 trusted readings of the place and kind), so low, high and the count are over the
  same readings as the average. A site with no trusted reading has no entry.
- **Never** `ops.visit_grease_frozen` (the Calendar's estimate) and never a figure the app works out itself.
- **The trust rule has three copies** (the averages' pool, `ops.calendar_grease_estimates`, this read). The VERIFY and the
  standing check compare this read with the averages over every measured visit, both ways: a reading the averages use is
  `tank` here with the same gallons, and a `tank` reading of a visit with a site and a pump kind is one the averages use.
- 112-YA today: 8 completed visits, 3 `trap_size` (30 gal, Pumping), 4 `not_a_pumping`, 1 `none` (no service type), no
  site figure (no tank reading). Example entry: `{"visit_id": 8113, "visit_date": "2026-09-15", "property_id": 162,
  "source": "trap_size", "gallons": 30}`.
- **Cost** (measured 2026-11-14 as the owner, best of 3): 0.40 s with a client (the averages read every trusted reading
  once); 0.10 s for a ticket's visits.

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
