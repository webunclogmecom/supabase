# Boca Raton on BSI Online: frozen leads, the BSI scrape and the filing bot (plan, 2026-11-03)

Trello cards (all in Approved):
- **#165** `f3Q3Q55i`: scrape BSI Online restaurant data and enrich it with contacts.
- **#166** `IWJkqTq1`: add the scraped restaurants (frozen leads) and our current clients to the DB.
- **#169** `0lAWU6Ge`: a BSI Online filing bot that auto-files Boca Raton maintenance reports, like the Online GDO Report bot.

**Status.** This is the plan; nothing in the database has changed.
- **Done, read-only:**
  - all the research;
  - Yan's screen recording, read frame by frame;
  - the BSI scrape. Its raw data sits in the workspace `backups/` folder, never in a repo.
- **Waiting on:** the decisions in section 10, before any build step.

**What this document leaves out on purpose:**
- **CCN values.** BSI's own terms call the CCN a confirmation number that unlocks a customer's records, so it is handled like an access code.
- Contact names, phones and emails.
- Login details.

## 1. What was asked

**The cards, short:**
- **#165:** get every Boca Raton restaurant from BSI Online (name, address, interceptors, last and next pump date) to spot the non-compliant ones (Boca requires a filing every 3 months), then enrich them with manager, email and phone. "Same model we already run for Miami-Dade."
- **#166:** land them without duplicating anything. Scraped prospects become frozen leads, never contacted, and become clients once a contract is signed. Our current Boca clients must not be imported twice. Viktor must be able to read clients and leads.
- **#169:** after each Boca visit, file one report per interceptor on BSI Online and post the result to Slack. Yan files the first one by hand; the bot files the rest of Grove Kosher's pending reports and every future Boca visit.

**Yan, huddle of 2026-11-02 (Slack transcript):**
- *"We never contacted them. We know nothing about them."*
- *"I have the same thing with Miami-Dade where I have all the places in Miami-Dade."*
- *"I don't want to see it in my client's app."*
- *"My guess is the current database but with the new table."*
- *"Once it's frozen and we signed the contract, they're going to get out of the frozen table and become a client."*

**Fred, 2026-11-03:**
- *"design the best plan, with the best practices ... should we create a separate DB or add it to the current one, if so i want a generic leads one with 3NF as well, in case we get like another source of leads too, so they merge, including a reference for their source obviously"*.
- Which visits the bot files: *"Only line item 27 visits ... That are from Boca Raton."*
- The first real filing: Yan files it by hand.
- The scrape: use the main BSI account.
- Permits live in one table, `public.gdos`, typed GDO (Miami-Dade) or CCN (Boca Raton, Palm Beach).

## 2. What Yan's recording shows

The recording runs 6 min 13 s, from 12:26 to 12:33 PM on 2026-11-02; all 212 frames were read. **Nothing was filed.** Submit was never pressed, the cart stayed at 0, and BSI shows no drafts.

**Where it was not smooth:**

| When | What happened | Cause |
|---|---|---|
| 00:37 to 00:50 | Searched by FOG Location ID 134809: no results, then a pause | The search cannot find that number, and both Grove interceptors share it |
| throughout | The result list lagged about 1 s behind the typing, mixing in Fort Myers and Fernandina Beach | The search runs as you type and covers every BSI city |
| 00:57 | The typo "grovevkosher" found nothing | Every typed word must match |
| 00:15 to 03:52 | Opened Grove Kosher five times | He was showing three kinds of search |
| 01:55 | Paused between two identical "Broward County Wastewater Treatment Plant" rows | BSI lists that plant twice (ids 1 and 125) |
| 02:29 | Opened Upload media, then cancelled | Nobody had decided which document goes there |
| 02:43 | Hovered Submit and left | Nobody knew what Submit does: it only puts the report in a cart (section 3) |
| 04:00 to 04:37 | "marriot" showed 3 properties, 2 outside Boca; the Boca Marriott is listed as "AVR BOCA CENTER HOTEL LLC" | BSI often lists a property under the owner's legal name |

**The smooth operation, for a person:**
1. On the BSI dashboard, open **Enter FOG Maintenance Report**.
2. Paste the property's **CCN** (taken from our Client App, or with BSI's "Copy CCN"). Wait until exactly one card shows. Never search by FOG Location ID.
3. **Select**. Check that Organization is "City of Boca Raton Utility Services", that the CCN matches, and that the Filing Fee is $0.00.
4. **Enter maintenance** on an interceptor we pumped. A property with two interceptors needs two reports.
5. Fill in the form:
   - Maintenance date: the visit date, today or earlier.
   - Hauling Company: already filled in as UNCLOGME LLC.
   - Performed By: Aaron Azoulay, the only name listed.
   - Disposal facility: the plant where that load was dumped.
   - Depths and gallons: leave empty for now.
   - Upload media: the agreed document.
6. **Submit maintenance report**. It reads "Maintenance report added to cart". **The report is not filed yet.**
7. After the last interceptor, open **Cart**. There should be one line per interceptor, at $0.00 in total.
8. **Checkout**, pay $0, and keep the receipt (Payments/Receipts).
9. Reopen the property. Its Next Pump Date should have moved and the cart should be empty.

## 3. BSI Online, measured read-only on 2026-11-03

**How it works.** BSI Online (app.bsionlinetracking.com) is a web app over a JSON API (`/api/...`). The login is a plain username and password with no CAPTCHA, and it returns a token. A script can therefore read or file with no browser robot.

**Our account.**
- Hauling company UNCLOGME LLC: testing company 30307, hauling company 871.
- Our only FOG tester is Aaron Azoulay (tester 52265).
- **Reports ever filed: 0.** The cart and drafts are empty.

**Calls:**

| Purpose | Call |
|---|---|
| Search properties | `GET /api/testing-company/fog/search` (name, address or CCN; 50 per page) |
| Property and its interceptors | `GET .../fog/properties/{id}`: next and last pump date, last report id |
| Disposal plants | `GET .../fog/disposal-facilities/{property}` |
| Testers | `GET .../fog/interceptor/{id}/testers` |
| File a report | `POST .../fog/property/{property}/interceptor/{interceptor}`, with maintenance_date, hauling_company, performed_by, tester, disposal_facility, the depths, gallons_removed, repairs and comment |
| Attach a file | `POST .../fog/{report}/media` (multipart), only after the report exists |
| Report history | `GET .../fog/maintenance-reports[/{id}]` |
| Cart and checkout | `GET .../cart/`, `.../cart/pending`, `GET .../checkout/payment-types`, `POST .../checkout/pay` |

**Submit only adds the report to a cart.** The web app's own text: "You must complete the checkout process for the test to be applied to the account." Filing is two steps: submit, then a $0 checkout.

**Disposal plants offered for Grove Kosher:** Broward County Wastewater Treatment Plant (listed twice: ids 1 and 125), Miami Dade County WWTP (3), City of West Palm Beach (134), East Central Regional (2, 15), and 7 others.

**BSI's published terms (written for backflow testers):**
- The CCN is a "Customer Confirmation Number", regenerated each year, that unlocks one customer's records. This is not confirmed for the FOG module.
- There is no clause about automated access or scraping.
- A user who breaks the terms can be barred from submitting.

## 4. The scrape (#165), 2026-11-03, read-only, main account

**How it ran.** Script `scripts/leads/bsi_boca_scrape.mjs`: one request every 3 seconds, about 470 requests, 14:01 to 15:01 ET, with no errors. The control passed: Grove Kosher came back with its 2 interceptors.

**Where the output is.** `backups/2026-11-03_bsi_boca_raw.json`, in the workspace backups folder and never in a repo, at 1.9 MB.

**Properties:**
- 431 commercial properties, all in the City of Boca Raton Utility Services program: 427 active, 4 pending.
- Each has a CCN, a $0 filing fee, and no required attachment.
- Searching the 15 Boca ZIP codes added no property beyond the 431. ZIP 33498 (West Boca, State Road 7) returns none.

**Interceptors: 446 active.**
- 409 properties have one, 16 have two, and 1 has five.
- By type: 280 external grease interceptors (our pumping work), and 166 small internal kitchen traps.
- **Overdue (next pump date before today):** 284 interceptors on 274 properties:
  - 55 by 1 to 30 days;
  - 52 by 31 to 90 days;
  - 99 by 91 to 365 days;
  - 78 by over a year.
- **Never pumped on record:** 182. **Filed by another hauler since BSI went live in June:** 264.

**Contacts.** BSI holds a contact on 179 properties: a name on 165, a phone on 90 and an email on 21. They are mostly personal and stay in the backup file (decision F2).

## 5. Our Boca clients against BSI

The matches below are by street number and name. Yan confirms each one before anything links.

| Ours | Property | BSI property | Interceptors | Note |
|---|---|---|---|---|
| 022-GRO Grove Kosher | 4 | 957372 GROVE KOSHER MARKET | 2 | Our record has one 1,250 gal trap: which traps do we pump? |
| 064-TCE Carrot Express Boca | 62 | 430537 CARROT LOVE PALMETTO PARK LLC | 1 | BSI shows it due since May 2023 |
| 225-PV Pura Vida | 191 | 957315 PURA VIDA | 1 | BSI has ZIP 33432, we have 33496 |
| 240-TUR El Turco | 1012 | 957307 EL TURCO EXPRESS | 1 | No recurring job |
| 081-TCE Carrot West Boca | 68 | none | | ZIP 33498, probably outside the City |
| 135-BB Bagel Boss | 53 | none | | Nothing at 22107 Powerline |
| 319-CAP Capas Burger | 1117 | none | | ZIP 33498 |
| 361-SFG golf carts, Olympus, Alta | | none | | Not restaurants; Olympus and Alta are uncoded Jobber leads |

**Grove's plaza (22191 Powerline) has five other BSI restaurants:** Kingdom Sushi, Brooklyn Water Bagel, Hong Kong Palace, Jon's Place and Angela's Pizza Kitchen. They are good leads next to an existing stop, and they show why an address alone can never be a match key.

## 6. Database facts that shape the plan (read 2026-11-03)

- **No Boca client has a CCN on file.** The only CCN row is the 112-YA test row (id 294).
- **No Boca job, visit or invoice carries line 27** ("27 - GDO Online Reporting"). Under Fred's rule, the bot files nothing until the office adds it. `fn_visit_is_gdo_reporting` also counts job-level lines, so adding line 27 to Grove's job 1325 makes all of Grove's visits eligible, past visits included.
- **Grove Kosher (022-GRO) has 5 completed visits in 2026**, none of them filed:

  | Visit | Date | Dump plant on the manifest |
  |---|---|---|
  | 1384 | Feb 12 | Water and Wastewater Services (Broward) |
  | 1721 | Apr 27 | Water and Wastewater Services (Broward) |
  | 5851 | Jun 28 | South District WWTP (Dade) |
  | 5943 | Aug 27 | Water and Wastewater Services (Broward) |
  | 5944 | Oct 27 | Water and Wastewater Services (Broward) |

  For 5943 and 5944 (and Bagel Boss's 6326 and 6327), Samsara's first dump after the pickup is at South District, not at the plant on the manifest. A person settles these before they are filed.
- **Our plants:** Water and Wastewater Services (Broward, `disposal_facilities` 3, 242 manifests) and South District WWTP (Dade, 2, 683 manifests).
- **The service location has no property link.** The 4 matched clients' "Main" `client_locations` have no `property_id`, while all their visits do. The link to BSI therefore has to sit on our **property**.
- **Viktor reads only `public`.** He uses the Supabase REST tools (Pipedream, service-role key). His one try at a non-public object (`ops.v_ar_aging`, 2026-10-27) returned 404.
- **A new schema has to be added in four places.** The backup (`services/db-backup/backup.sh`) dumps a fixed schema list, and `public.rls_auto_enable()` covers a fixed list too. A new schema must be added to both, plus `scripts/checks/rls_on_app_tables.sql`, plus grants for `db_backup_reader`.
- **`entity_source_links.entity_type` is a CHECK list of 17 values.** A new kind of link needs a migration.
- **Today's Miami-Dade queue would misroute Boca.**
  - `v_derm_portal_fields` keeps every line-27 visit but joins only `GDO-` permits. A Boca line-27 visit would therefore sit in `v_derm_portal_queue_held` as `no_permit`.
  - `log_rpa_derm_health()` would then email a daily "enter the client's GDO permit" item for each visit and each client. That is wrong advice for Boca.
  - It has not fired only because no Boca job has line 27 yet.

## 7. Research (web, 2026-11-03): what best practice says

**Data model**
- The CRMs that avoid duplicates (HubSpot's Leads object, Twenty, Odoo with `partner_id`) all make a lead a **thin record that points at shared master rows**. Salesforce instead copies the company onto the lead and merges it later, which is why "lead-to-account matching" tools exist.
- **Keep every outside record as received**, versioned only when it changes (Data Vault hash check, dbt snapshots). Show each value with its source and date, following the W3C PROV ideas: derived from, generated at, attributed to.
- **Record "same restaurant" decisions in an insert-only log.** That makes a wrong merge undoable, as Informatica's unmerge and Reltio's not-a-match flag do.
- **Match keys, strongest first:** the regulator's id, then Google `place_id`, then address with suite, then normalized name. **Never** match on parcel, phone, owner mailing address or name alone. A strip mall shares all of them.

**Same database, not a separate one**
- Matching and converting a lead need real foreign keys into clients and properties, inside one transaction. Two Postgres databases offer neither: no foreign keys across them, and no two-phase commit in postgres_fdw.
- One backup, one audit trail and one RLS trigger already cover Prod. Extra projects already failed here twice: the Client App Mirror's 154 silent failed refreshes, and the Sales App's loose ids.
- The isolation comes from a **private schema** instead. It is not exposed to the API, has no default grants, and Viktor reads only views made for him.

**Law and vendor terms (not legal advice)**
- **Calls.** An AI or prerecorded **sales call to a mobile number needs prior written consent** (TCPA; the FCC counts AI voices as artificial, 2024). A cold robot call to a business landline is not banned federally but must identify us. Live calls by a person to business lines are the low-risk path.
- **Email.** Cold business email must follow CAN-SPAM: opt-out, postal address, no harvested addresses.
- **Google Places.** Only the `place_id` may be kept. Phone, website and hours must be fetched when shown, not stored. Yelp's API cannot be used for leads at all.
- **Public records.** Sunbiz (company officers) and Florida DBPR food-service licences are free. Boca Raton's FOG list itself is a City record, open to a Chapter 119 request.
- **BSI.** Its terms have no anti-scraping clause, so the legal risk of a slow read with our own login is low. The real risk is BSI suspending the account that files our reports.

## 8. The design

### 8.1 Frozen leads (#166): Prod, one private schema `leads`

**Where.** Prod, in a new private schema `leads`: not exposed to the API, no default grants, RLS on. Viktor reads three views in `public`, postgres-owned with the owner's rights, selectable by `service_role` only. No Supabase setting changes.

**Tables:**
- **`leads.establishments`** is the restaurant. It holds only our decisions: which of our properties it is, if any, plus its status. Nothing descriptive is copied into it.
- **`leads.source_records`** is one outside record: a BSI property now, a DERM permit or a web form later. Its id in that source lives in `public.entity_source_links` (new entity type `source_record`, source `bsi`), following the house rule for external ids.
- **`leads.source_versions`** is what the source said, kept append-only:
  - A new row is written only when the content changed. Otherwise only `last_seen_at` moves.
  - Payloads are allow-listed.
  - A CHECK refuses any key containing "ccn".
- **`leads.match_decisions`** is insert-only: who decided that a record is or is not one of our clients, when, why, and on which version.

**Views:**
- **`public.v_frozen_leads`:** frozen BSI restaurants, with interceptor counts, overdue counts, the next pump due and days overdue (computed against today's ET date), and the source and as-of date.
- **`public.v_lead_interceptors`:** one row per BSI interceptor in every state. This is the bridge #169 reads.
- **`public.v_lead_review`:** the review queue.

**"Frozen" is computed, never stored.** A restaurant is frozen when all of these hold:
- it is not linked to a client, a Jobber lead ("warm") or a former client;
- no possible client match is waiting for a person.

A possible match is either:
- the same house number and first street word in the same city (ZIP and unit ignored, because Pura Vida's ZIP differs); or
- a name score of at least 0.8 in the same city.

Measured on today's file, this gives **11 records to review**:
- Grove and its 5 plaza neighbours;
- Carrot Love, Pura Vida, Bento Boca and El Turco;
- THE STANDARD, possibly Alta's.

Plus **5 clients with no BSI record**, and nothing against a test client: **16 items, about 20 minutes with Yan.**

**Linking and undoing.** One function, `leads.decide_client(...)`, records same / different / absent. It refuses a non-staff `p_by`, a test client or an empty reason. Undoing is a `different` decision; nothing is deleted.

The link is to our **property** (section 6), and it is the **only** place where our property and its BSI record are tied. The bot reads it; there is no second copy.

**Converting a lead.**
1. The office creates the client in the Client App. Jobber is created first, then `webhook-jobber` copies it in.
2. One `decide_client(..., 'same', 'contract signed <date>')` call links the restaurant.
3. The office types the CCN on the Permits tab (`client.upsert_gdo_permit`, type CCN).

The leads schema never writes `clients`, `properties` or `gdos`.

**Provenance.** Every value shown carries:
- its source and source id;
- `as_of`: when that content was first seen;
- `confirmed_at`: last seen unchanged;
- `first_seen_at`;
- `in_latest_run`.

Each load writes one `sync_log` row (`leads:bsi`).

**Guards:**
- **No CCN of a non-client is stored** (decision F1).
- **Google content:** `place_id` only.
- **No contact value, owner street or free text in any view.**
- **Frozen leads cannot be contacted.** There is no release step until a do-not-contact list (keyed by phone or email) and one contact rule ship together.

**Deferred, with the trigger for each:**
- **Before any outreach:**
  - release step;
  - do-not-contact list;
  - consent and line-type records;
  - attempt log.
- **When Yan works the leads:** the CRM pipeline (stages and activities, with the current stage computed).
- **At a second source:**
  - people and organizations;
  - merging non-client restaurants;
  - best value per field.
- **When Miami-Dade outreach is planned:** the Miami-Dade import, the permit key and a 10,000-row speed test.
- **Before free text or contact values reach his views:** Viktor's own read-only database role.
- **When refreshes become recurring:** a scheduled refresh.

**Miami-Dade.** The HR Sandbox `frozen_leads` schema stays untouched. When Miami-Dade outreach is planned, the source is a fresh DERM list plus Yan's own decision columns from the 2026-10-07 Sheet. Google and Perplexity contact columns are never imported.

### 8.2 Scrape and enrichment (#165)

**Load.**
- A new `scripts/leads/load_bsi.mjs` (about 60 lines). It refuses unless the file is complete, has at least 400 properties, and the Grove control is present.
- It keeps organization 135 only and allow-listed keys only, and strips every key containing "ccn".
- It calls `leads.ingest('bsi', ...)` once. A `--dry-run` runs the same call inside a rolled-back rehearsal.

**Refresh.**
- **No scrape on a timer.** The bot re-reads our own clients each time it files.
- For sales data, send the City a **Chapter 119 records request** for the FOG program list. It is free and clean.
- Fallback: at most one slow scrape a quarter, with Fred's OK each time, never before 4 clean weeks of bot filing.
- Any 403 or 429 from BSI ends scraping.

**Enrichment: a free pilot on 20 records first.**
- **Sample:** 10 independents, 4 chains, 3 institutional kitchens and 3 markets. At least 5 are overdue, and none is ours.
- **Sources, in order:**
  1. BSI's own contact (scored only, not stored);
  2. Sunbiz officers (free);
  3. the DBPR licence list (free; tells the operator from the landlord);
  4. Google Places with `place_id` stored, phone and website fetched on demand (free for 431);
  5. Apollo last, free plan, email only.
- **Never:** emails crawled from websites, or Yelp.
- **Ground truth:** 10 calls by hand, to business lines.
- **Rule:** buy Apollo or Hunter credits only if they add verified named contacts on at least 20 to 25 percent of rows, or cost under about $1 to $2 per verified contact.
- **Output:** a CSV in `backups/`. Nothing enters Prod until the pilot decides.
- **Setup needed:** a Google key restricted to Places API (New), with a daily quota and a budget alert, plus a free Apollo account.

### 8.3 The filing bot (#169)

**Who is filed.** A visit qualifies when all of these hold:
- it is completed and not deleted;
- it carries line 27 (`fn_visit_is_gdo_reporting`);
- the client files with BSI.

**Routing (ships before any Boca job gets line 27).** A new rule, `public.fn_client_files_with_bsi(client)`, is true when:
- the client has **no** live GDO permit, which always wins; **and**
- it has a live Boca Raton property. Test clients may route through a CCN instead.

Three objects get one anchored edit each: `v_derm_portal_fields`, `v_gdo_reporting_derm_mismatch` and the client part of `log_rpa_derm_health()`. Every other DERM reader goes through `v_derm_portal_fields`.

**Proof, inside one rolled-back transaction:**
- Today, 0 rows move, and the row hashes of the live objects equal those of their rehearsed copies.
- **Positive control:** add a job-level line 27 on Grove's job 1325. The live view then shows Grove's visits and the copy does not.
- **After the apply:** the bot's `peek` returns the same JSON, the next DERM health details are unchanged, and a Miami line-27 visit still shows its GDO block.

**Links and settings (no new business columns):**
- **Our property to its BSI property:** the leads link (8.1).
- **Our plant to BSI's plant:** `entity_source_links` (new type `disposal_facility`), two rows:
  - South District WWTP to BSI 3;
  - Water and Wastewater Services to BSI 1 or 125, whichever BSI confirms.
- **`app_config` keys** (all audited):
  - `bsi_interceptors`: per property, which BSI interceptors we pump. The bot stops if BSI's list changes.
  - `bsi_filing_mode`: off, dry or live. Missing means off.
  - `bsi_backlog_visit_ids`.
  - `bsi_disposal_checked_visit_ids`.
- **Cutoff:** `public.bsi_launch_cutoff()`, the day the routing ships.

**Queue view `public.v_bsi_filing_queue`:**
- One row per eligible visit, using the visit's ET date as the maintenance date.
- It shows whether a CCN exists, never its value.
- It gives the first reason the visit is held, or none:

| Reason | Meaning |
|---|---|
| `test_client` | a test client |
| `no_ccn` | no live CCN on the property |
| `no_bsi_link` | the property is not linked to BSI |
| `interceptors_not_confirmed` | no `bsi_interceptors` entry for the property |
| `withdrawn` | a person withdrew it |
| `filed_date_changed` | a filed visit's date has since changed |
| `already_filed` | filed |
| `in_progress` | being filed |
| `needs_person` | a stop that needs a person |
| `before_launch_cutoff` | before the cutoff and not in the backlog list |
| `cooldown_20h` | a retryable stop in the last 20 hours |
| `same_day_sibling` | another visit at the same property and date wins |
| `no_manifest` | no manifest linked |
| `no_disposal_map` | the manifest's plant has no BSI link |
| `disposal_disagrees` | Samsara's first dump is in another county than the manifest's plant |
| `waiting_for_older_visit` | an older visit at the same property is still due, so BSI's dates stay in order |

**The record: `public.bsi_filings`**, one row per (visit, BSI interceptor).
- **States:** claimed, posting, in_cart, filed, stopped, withdrawn.
- **Unique keys:** (visit, interceptor) and (interceptor, maintenance date). A row that holds a BSI report id can never be retried. Audited.
- **Kept as evidence:** what BSI showed before the write, the request exactly as sent (never a header or the login), the report, and the receipt.
- **Functions:**
  - `fn_bsi_begin_run` takes the lock and refuses when the mode is off or a run is in flight.
  - `fn_bsi_takeover` deals with idle rows.
  - `fn_bsi_claim_visit` refuses unless the mode is live, nothing is in flight, and the interceptor set is the confirmed one.
  - `fn_bsi_resolve` (retry or withdraw, with who and why) is the only human write.
- **Never put BSI rows in `derm_portal_submissions`.** Every DERM reader treats a row there as a Miami-Dade filing.

**The worker: edge function `bsi-filing`, run by pg_cron at 10:05 AM ET, one visit per run in the first month.**
- **Why not the GDO bot's Railway service:** BSI is plain JSON with about 20 calls a visit, and that service is contractor code. GitHub schedules run hours late here.
- **Access:** `verify_jwt` on, POST only, an exact `x-bsi-key` match, then `fn_bsi_begin_run`.
- **Steps:**
  1. Log in and check the profile is UNCLOGME LLC.
  2. Read the property live. Check organization 135, that BSI's CCN equals the CCN on our property, a $0 fee, and that the interceptor set matches.
  3. Claim the visit.
  4. Check our plant is in BSI's list and that Aaron (tester 52265) is listed.
  5. Fetch the attachment, at most 4 MB.
  6. **Never-file-twice read-back:**
     - a report on our date from hauling company 871 is recorded as filed and not posted again;
     - any other report within 7 days stops for a person;
     - the cart must be empty, or hold only this visit's reports.
  7. Per interceptor: write the request, POST, and store the report id first. **Never resend** after a timeout or an unreadable answer.
  8. Upload the media and read the report back.
  9. **Pay only $0:**
     - the cart holds exactly our ids at $0.00, read twice;
     - only the payment type seen at Yan's checkout is used;
     - the cart is read again just before paying;
     - any amount above $0 stops for a person and turns the bot off.
  10. Read back the report, the property (its last report and last pump date are now ours) and the empty cart, then mark the row filed.
  11. Post to Slack and close the `sync_log` row.
- **Breaker:** any 401, 403, 429 or non-JSON answer from BSI turns the mode off, posts once to Slack, and waits for Fred.

**Dry run.** `scripts/probes/bsi_dry_run.mjs` runs steps 1 to 6 with no write. It prints the exact body it would send, `held_by`, and "CCN matches: yes/no", never the CCN.

**Yan's first filings, captured read-only:**
- `scripts/probes/bsi_readback.mjs` saves the property, reports, cart, payment types and plants before and after, to `backups/`.
- Yan files the two oldest Grove visits by hand, **1384 (Feb 12) then 1721 (Apr 27)**, including the checkout. Optional: a browser network log.
- That capture fixes the request shape and answers the 11 open questions:
  - what Submit returns;
  - how empty fields are sent;
  - the $0 payment type;
  - whether filing moves Next Pump Date;
  - whether BSI refuses a duplicate;
  - how far back a date is accepted;
  - and five more.
- It is written down in `docs/reference/bsi-online-filing.md`.

**Slack.**
- **Where:** #apps-notifications, through the shared bot and header format, named "Boca Raton reports".
- **When:** one post per run that filed something or stopped for a person. Diego is tagged only when a person is needed. Never a CCN; `[TEST]` on 112-YA.

**Health.**
- `log_bsi_filing_health()` at 8:19 AM ET gives one item per held visit, with what to do, plus "no run in 26 hours" and "bot not live while visits wait".
- It is registered in `ops.v_health_items` and `ops.v_health_status`.
- First, a one-line fix to `fn_health_alert_scan` (`DISTINCT ON` in its insert): two items sharing a key would otherwise fail the whole scan.

**Where staff see it.** Slack, `bsi_filings` and the queue view, all readable by Viktor. No app chip for now.

## 9. Build order

Each stage is done and checked before the next. **Visual checks are in bold.** Every migration is rehearsed rolled back first, with a control that must fail.

| # | Stage | Checks |
|---|---|---|
| S0 | Repo prep (no DB): scraper `fetched_at` on resume; remove the dead `leads` table name from `populate.js`, `dedup_jobber_links.js` and `probe.js`; ADR 020 (leads in Prod, private schema); update `Building Apps/04-supabase-schema.md` ("separate by design") and `docs/schema.md` | `rg` finds no stale reference |
| S1 | Leads M1: schema `leads`; `entity_source_links` CHECK + `source_record` and `disposal_facility`; the 4 tables; `rls_auto_enable` list + check script; backup grants; then `backup.sh` | md5 pins before and after; a table made in `leads` comes out RLS-on (a `raw` one does not); exact grants by `aclexplode`; the CCN CHECK refuses a nested CCN key; the next backup heartbeat succeeds with 4 more tables |
| S2 | Leads M2: helpers, `ingest`, `decide_client`, views; the loader; `scripts/checks/leads_integrity.sql`. Rehearse on the real file, then load | 431 records; review queue = the 16 items in 8.1; `v_frozen_leads` = 420; same file again adds 0 versions; one changed date adds 1; the views refuse anon and authenticated (42501); each view under 1 s as service_role |
| S3 | **Review sitting with Yan** (16 items); the office types the 4 CCNs in the Client App | queue empty; the 4 read `client`; **Grove's Permits tab shows "Boca Raton CCN"**; `permits_gdo_only.sql` passes |
| S4 | Health scan `DISTINCT ON` fix, then the routing migration and `scripts/checks/bsi_routing.sql` | the proof in 8.3; next morning's DERM health identical |
| S5 | BSI access and **Yan's two hand filings, captured** | before: 0 reports, empty cart; **after: Next Pump Date moved**, cart empty; reference doc written |
| S6 | Bot migration: `bsi_filings`, settings, cutoff, queue view, the 4 functions, cron wrapper, health logger, ops registration | every gate proven by changing one piece of data (with a control); claim refusals; a CHECK refuses a retry with a report id; `relacl` equals `derm_portal_submissions` |
| S7 | Edge function + `scripts/checks/bsi_filing.mjs` (fake BSI); secrets; deploy; read the deployed body back; **Slack mockup to Fred** | every stop rule; no POST in dry mode; no resend after a timeout; no payment with a foreign item, a fee or a changed cart; the breaker; no token in any stored JSON; mutation test: removing the $0 or cart checks must fail the suite |
| S8 | 112-YA smoke test (rolled back); settle 5943 and 5944; the office adds line 27 to job 1325; **dry runs on 5851, 5943, 5944 read by Fred and Yan**; go live on 5851 while watching, then one visit a morning; cron on | Grove's visits in the BSI view and in no DERM view; **Yan checks Grove in BSI**: one new report per interceptor, cart empty, receipt $0 |
| S9 | Enrichment pilot (independent, after S2) | the pilot's measures; nothing in Prod unless it passes |

**Documentation, in the same cycle as each stage:**
- this file;
- ADR 020;
- `docs/reference/bsi-online-filing.md`;
- Supabase `CLAUDE.md` (the PERMITS section, plus a new BSI and leads section);
- `schema.md`;
- `slack-notifications.md`;
- `scheduled-jobs.md`;
- `gdo-report-bot.md` (the routing);
- DERM Tracker `08-changelog.md` (no GDO block for a Boca visit);
- `decisions-to-build.md` rows;
- memory.

## 10. Decisions

**For Fred:**
- **F1. CCNs of restaurants that are not our clients.** Recommended: never store them. The loader strips them, a CHECK refuses them, and only our clients' CCNs live in `public.gdos`.
- **F2. BSI's contacts on 179 properties.** Recommended: keep them only in the backup file for now. They enter the DB only through the enrichment pilot's sources and the deferred contact rules.
- **F3. The bot's BSI login.** Recommended: a separate user with FOG rights only, created by Yan. Then rotate the main password, which was pasted in the huddle thread. Before that, a 3-request test shows whether a new login ends another session (the bot must not sign Yan out every morning).
- **F4. How BSI data is refreshed.** Recommended: a Chapter 119 records request to the City; no recurring scrape on the account the bot files with.

**For Yan** (asked in #new-app-issues, simple wording, with Fred's OK):
- Confirm the 4 matches in section 5, and Pura Vida's ZIP.
- Which traps the drivers pump at Grove, Carrot Express and Pura Vida. BSI lists 2 at Grove; our record has one.
- Which Broward row is ours (1 or 125). Ask BSI if unsure.
- What to attach. Recommended: the visit report PDF (the DERM Tracker's Download Report), or nothing, since BSI marks media optional.
- Line 27 on the Boca jobs. Recommended: at $0 on job 1325 now, then on jobs 1427 and 1624 once their CCNs are in. Note that the invoices will read "GDO Online Reporting".
- What the bot files first. Recommended:
  - Grove's 5851, 5943 and 5944 in date order, after his hand filings of 1384 and 1721;
  - then every Boca line-27 visit from the routing day on;
  - one catch-up each for 064-TCE (6645) and 225-PV (6535).
- Settle 5943 and 5944 with Diego: which plant took the load.
- Confirm no card is stored in BSI.

## 11. Risks and open questions

- **Losing the BSI account.** If BSI suspends us, filing stops. That is the reason for the slow, one-off scrape, the breaker, and a separate bot user.
- **The CCN may change every year.** The bot compares BSI's live CCN with ours before every filing and stops with "copy the new CCN".
- **The cart and checkout are untested.** Yan's capture (S5) is required before the bot writes anything.
- **Line 27 is both the on switch and a billing line.** It must not reach a Boca job before S4 ships.
- **Plant disagreements.** Samsara and the manifest disagree on 4 visits, which are held until a person decides.
- **"Lead" now means three things:** Jobber leads (147 uncoded ACTIVE clients), the Sales App's warm leads, and frozen leads. Every name here says "frozen".
- **Calling and emailing rules** need a lawyer before anything automatic. The plan contacts nobody.
