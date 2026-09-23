# Fillout shift-inspection intake

How a pre/post shift inspection reaches the warehouse, what the test phase proved, and how the two
live driver forms are mapped.

🟢 **LIVE ON BOTH REAL FORMS SINCE 2026-09-23.** `Pre Shift Inspection` (`7FeakRTGTDus`, published
snapshot 164774170) and `Post Shift Inspection` (`jBBi8r53nQus`, snapshot 164776238) each carry TWO
integrations now, `airtable` and `rest`. **The Airtable one was not touched**, and it is still the
system of record for shift inspections.

Built 2026-09-23. Fred: *"the idea is that later we will use a mobile app for the Drivers to do that
inspection, but for now we could try to also get the data when posted from the Fillout"*, and
*"the usual form the drivers do at fillout should still keep posting the data at Airtable, but it
should also fill our DB so we don't miss anything."*

---

## 1. Why this exists

Drivers fill two Fillout forms at each shift end. Those submissions land in **Airtable**, and that
pipeline is live and untouched by any of this.

What died in July 2026 was only the **feed from Airtable into this warehouse**. `public.inspections`
stopped on 2026-07-11 at 319 rows while the Airtable table kept filling and now holds 443. So the
data was never missing, it just stopped arriving here.

🛑 **Airtable is NOT being replaced.** This adds a *second* destination. The real forms keep posting
to Airtable exactly as before. See the corrected Airtable paragraph in `CLAUDE.md`: "Airtable is
retired" is true of the warehouse feeds and false of shift inspections.

---

## 2. The path

```
Fillout form ──> edge fn fillout-inspection ──> public.inspections
                         │                      public.entity_source_links (source_system 'fillout')
                         └─ enqueues file URLs ─> sync.inbound_file_queue
                                                         │
                          cron inbound-file-drain (*/5) ─┘
                                                         ↓
                                          edge fn inbound-file-drain
                                                         ↓
                              Storage 'GT - Visits Images' + photos + photo_links
```

**Objects added.** Only two, because everything else already existed:

| object | why |
|---|---|
| `sync.inbound_file_queue` | so the webhook can answer fast (see §4) |
| `public.fn_enqueue_inbound_file` / `fn_claim_inbound_files` / `fn_settle_inbound_file` | `sync` is not an exposed PostgREST schema, so an edge function cannot reach it directly. Same reason the `fn_outbound_*` wrappers exist |
| `public.v_inbound_file_queue_health` | empty is healthy |
| `public.fn_request_inbound_file_drain` + cron `inbound-file-drain` | the schedule |

**Nothing else changed, and that was verified rather than assumed**: `entity_source_links` and
`photo_links` already whitelist `inspection`, `photos.source` has no CHECK, `inspections.gas_level`
already stores exactly Fillout's four choices, `inspection_type` is `PRE`/`POST`, and all 15 photo
roles used here already exist in live data.

Migrations: `2026-09-23_0926`, `_0944`, `_0946`, `_1259`. Commits `56e391e`, `4839506`, `980a800`.

---

## 3. The contract

🛑 **The body shape is OURS, not Fillout's.** Fillout's REST integration in Advanced mode builds the
body as key → form-field pairs, so we define it. That is deliberate: **the driver mobile app is meant
to POST this identical body to this identical endpoint** with no server change.

`POST /functions/v1/fillout-inspection`, header `x-fillout-key`.

| body key | goes to | notes |
|---|---|---|
| `submission_id` | `entity_source_links.source_id` | **required**, the idempotency key. A Fillout UUID |
| `pre_post` | `inspections.inspection_type` | **required**, "Pre Inspection" / "Post Inspection" → `PRE`/`POST` |
| `date` | `submitted_at` + `shift_date` | `shift_date` is the **ET clock date**, never a UTC slice |
| `driver` | `employee_id` | resolved through an explicit alias map, §5 |
| `truck` | `vehicle_id` | explicit alias map, §5 |
| `gas_level` | `gas_level` | `1/4` `1/2` `3/4` `Full` pass straight through |
| `sludge_gallons`, `water_gallons` | same | separators stripped; unparseable is NULL, never 0 |
| `pre_post_default` | fallback for `pre_post` | **static literal per form**, §3a |
| `valve_closed` | `is_valve_closed` | ⚠ absent is NULL, not false. A form that never asked has not said "open". **Neither live form asks any more**, §3b |
| `has_issue`, `issue_note` | same | `has_issue` derives from a note when not asked explicitly |
| `photo_*` (19 keys) | queued → `photo_links.role` | §6 |

### 3a. 🛑 `pre_post_default`, and why a "belt and braces" key is load-bearing

The Pre/Post dropdown is **not a required question on either live form**, and **10 of the 444
Airtable records have it EMPTY** (measured 2026-09-23). Without a fallback every one of those is a
400 from this function, which Fillout retries and then abandons: a shift inspection lost in exactly
the way this intake exists to prevent. So each form also sends a static literal naming itself.

The order is `pre_post` → `inspection_type` → `pre_post_default` → `?default_type=` on the URL, and
**the driver's own answer always wins**. That matters: a driver who opens the PRE form and picks
"Post Inspection" is recorded as POST by Airtable, and now by us too. The two destinations can never
disagree on a submission where the driver answered.

⚠ It is chained on `inspectionType()`, not on `??` over the raw values, because Fillout may send an
unanswered dropdown as `""` and `"" ?? x` is `""`.

⚠ **The URL arm exists because the editor cannot express a literal in a body value... or so it looks
at first.** The body VALUE control is a reference picker that answers "No references found" to typed
text. The literal is behind the **sixth icon in the picker's left rail ("Static value")**, which is
easy to miss, and that is how both `pre_post_default` rows are actually set. The URL arm is kept for
the driver mobile app, which will post a body rather than build a URL.

### 3b. What neither live form collects any more

| key | why it is never sent |
|---|---|
| `valve_closed` | both forms dropped the "Valve is closed" CHECKBOX. POST has `Closed Valve (David)`, which is a PHOTO. So `is_valve_closed` is NULL from here on, while 242 historical rows carry a value |
| `photo_expense_receipt` | the Airtable `Expense Receipt` / `Expense Note` fields still exist and neither form asks. 41 historical `expense_receipt` links exist |

Both keys are deliberately LEFT in the contract: the mobile app may ask again, and an unsent key
costs nothing. **Do not read their absence in the payload as a driver answering "no".**

**Auth is fail-closed.** A missing `FILLOUT_WEBHOOK_KEY` refuses every request. `config.toml` records
the 2026-07-29 incident where three functions gated on `if (KEY && header !== KEY)` and an unset
secret skipped the check entirely.

**`verify_jwt = false`** is required (Fillout cannot send a Supabase JWT) and pinned in `config.toml`.
🛑 **If intake goes quiet, check that first**: a redeploy defaults it to true and 401s every
submission at the gateway with nothing in the function log.

### 3c. The as-built mapping, per form

🛑 **THE TWO FORMS ARE NOT THE SAME FORM WITH DIFFERENT DEFAULTS.** PRE asks 16 questions, POST asks
27, and **five fields that mean the same thing carry different widget ids and different labels**.
Anyone editing one of these must read that form's own field list, never a copy of the other's.

Read off the published snapshots 2026-09-23. `PRE` and `POST` are the Fillout widget ids.

| body key | PRE `7FeakRTGTDus` | POST `jBBi8r53nQus` |
|---|---|---|
| `submission_id` | Submission ID | Submission ID |
| `pre_post` | `gF33` Pre/Post | **`w2q8`** Pre/Post |
| `pre_post_default` | static `"Pre Inspection"` | static `"Post Inspection"` |
| `date` | `dbtv` Date | `dbtv` Date |
| `driver` | `4fF1` Driver | `4fF1` Driver |
| `truck` | `paHz` Truck | `paHz` Truck |
| `sludge_gallons` | `1QLQ` **sludge in gallons** | `1QLQ` **Tank level in gallons SLUDGE (1-3,800)** |
| `water_gallons` | `u4RX` WATER Tank level | **`vzcY`** WATER Tank level |
| `gas_level` | `4jFb` Gas Level | `4jFb` Gas Level |
| `has_issue` | not asked, derived from the note | `jffY` **Is there any issue to report** (Yes/No) |
| `issue_note` | `4J72` Report Issue | `4J72` Report Issue |
| `photo_cabin` | `iHpz` Cabin Pic | `iHpz` Cabin Pic |
| `photo_dashboard` | `esHK` Dashboard Pic | **`osui`** Dashboard Pic |
| `photo_left_side` | `2iZE` Left Side Pic | `2iZE` Left Side Pic |
| `photo_right_side` | `cmVR` Right Side Pic | `cmVR` Right Side Pic |
| `photo_front` | `cRoE` `Front  Pic` | `cRoE` `Front  Pic` |
| `photo_back` | `jBCk` Back Pic | `jBCk` Back Pic |
| `photo_issue` | `uMzK` Issue pictures | `uMzK` Issue pictures |
| `photo_boots` | `gg5W` **Pictures of the boots** | not asked |
| `photo_cabin_left` | not asked | `h7Hu` Cabin Side left |
| `photo_cabin_right` | not asked | `pKhz` Cabin Side right |
| `photo_sludge_level` | not asked | `dKEa` `level SLUDGE  Pic` |
| `photo_water_level` | not asked | `sCp5` Level Water PIC |
| `photo_remote` | not asked | `wDeE` Remote Pic |
| `photo_derm_manifest` | not asked | `7grB` `DERM manifest ` |
| `photo_derm_address` | not asked | `mA4z` **DERM Adress manifest** |
| `photo_closed_valve` | not asked | `353j` **Closed Valve (David)** |
| `photo_hose_extensions` | not asked | `dUSA` Hose Extensions |
| `photo_truck_off_switch` | not asked | `bZbm` Truck OFF switch (under seat) |
| | **18 keys** | **28 keys** |

**The semantics came from the human's own Fillout → Airtable mapping**, which is the authority for
"what should be what" and is readable straight off each published snapshot
(`flowSnapshot.template.integrations`). Every judgement below is that mapping, not a guess at intent:

- **`sludge in gallons` and `Tank level in gallons SLUDGE (1-3,800)` are the SAME field.** Both go to
  Airtable `SLUDGE Tank level`, and PRE's own label settles the unit. The `(1-3,800)` is Moises'
  capacity, written on the form because drivers were typing nonsense: 34 of our 290 stored values are
  between **4,560 and 18,900** on a fleet whose biggest tank is 3,800. We store what was typed.
- **`WATER Tank level` is gallons too**, though the label never says so. Live values run 60 to 3,800
  and cluster at 375, 785 and 1,000.
- **`0` sludge is a real answer, not an empty one** - a truck starts a shift empty, and PRE records
  carry 0 routinely. `num()` keeps it; only an unparseable value becomes NULL.
- `DERM Adress manifest` (the human's typo) is the multi-client ADDRESS SHEET; `DERM manifest ` (with
  a trailing space) is the white eManifest. The live link counts agree with that reading, 229 to 124.
- `Closed Valve (David)` names the one truck it applies to. It is a photo, not the old checkbox.
- `Cabin Side right` lands in the Airtable field named `Cabin Side right copy`. The " copy" is
  residue of a duplicated column and means nothing.

⚠ **Search terms matter when picking a reference in the editor.** `Cabin` matches three fields on
POST, `WATER` matches two, and `Issue` matches two. Use `Cabin Pic`, `WATER Tank`, `Report Issue`,
`Issue pictures`, `level SLUDGE`, `Level Water`. Then **verify the saved config rather than the
screen**: the whole body array is readable at
`GET https://server.fillout.com/admin/flows/fetch/<formId>` while signed in, which is how all 46
rows here were checked.

---

## 4. Why photos are queued and not fetched inline

**A POST submission can carry up to 85 files, not 17.** It has 17 upload FIELDS and each one accepts
**`maxFiles` 5** (measured on both forms; PRE has 8 fields, so up to 40). One file per field is the
normal case, which is where the "up to 17" in the original design note came from, and it is the
number to plan for, but the ceiling is what the queue has to survive.

Fetching them in the webhook would hold Fillout's request open across that many sequential round
trips, **and Fillout retries a request it thinks timed out**, which creates a second inspection. It
would also be the third time this estate ran an edge function out of memory.

⚠ At BATCH 3 every 5 minutes the drainer clears 36 files an hour, so a maximal 85-file submission
takes about 2.4 hours and a normal shift's 17 takes under half an hour. Nothing expires while it
waits (§7), so the lag costs nothing. Raising BATCH is still the wrong first move.

⚠ **`acceptedFileTypes` is EMPTY on all 25 upload fields**, so a driver can attach a PDF or a video.
The drainer's content-type allow-list is what stops that becoming a broken image tile, and it skips
the row with a reason rather than retrying it.

So the webhook commits the row and enqueues the URLs; a cron drains 3 per run every 5 minutes.

⚠ **The claim is the safety property, and the first version of it was wrong.** The original claimed a
row by incrementing `attempts` and leaving `status='pending'`, relying on `FOR UPDATE SKIP LOCKED`.
The migration's own VERIFY caught it: SKIP LOCKED only excludes **concurrent** transactions, so the
moment the claim commits the next worker takes the same row, fetching one file into two storage
objects and carding it twice. Exclusivity now lives in the **row state** with a 10-minute lease, and
an expired lease is reclaimable so a worker killed mid-fetch gives the row back.

⚠ `fn_settle_inbound_file` **refuses `done` without a photo id**. A row marked done with nothing to
show for it is how a queue looks drained while the images are gone.

---

## 5. The alias maps, and why they are explicit

🛑 **Exact name matching resolves only 3 of the 12 driver choices.** A near miss does not error, it
silently drops the person, which is the same failure that made a driver vanish from the Visit
Calendar for weeks.

| Fillout | our `employees.full_name` |
|---|---|
| `Marc` | **Mark** |
| `Michael E` | **Michael Escobar** |
| `JEffry` | **Jeffry** |
| `(OLD) Ray` | Raymond Lee |
| `(OLD) Kevis` | Kevis Bell |
| `(OLD) Yan` | Yannick |
| `(OLD) Diego` | **Diego** |
| `Anthony`, `Grecia`, `Aaron`, `Steven` | same |

Fred on the prefix: *"It's the same one, it says OLD on some of them because they don't do it
anymore, it's a drivers job and diego is no driver."* So `(OLD)` is a statement about the person's
current role, not a different person.

Trucks: `Moises 3800` → Moises, `Goliath 5,000` → Goliath, `David 2,000` → David,
`Cloggy Pickup` → Cloggy.
⚠ **The number in the label is a nickname, not a capacity**, and it disagrees with the fleet record:
Goliath is 4,800 gallons and David is 1,800. Never parse it.

**An unresolved name is NULL and is REPORTED** in the response's `unresolved` array and in
`webhook_events_log.error_message`. It is never guessed, and it never drops the row: an inspection
with no driver is worth more than no inspection.

---

## 6. Photos

Sixteen of the nineteen roles already exist in live `photo_links` data, so a consumer meets no new
tile for them. Measured 2026-09-23: `left_side` 266, `back` 265, `right_side` 265, `cabin` 264,
`front` 264, `dashboard` 262, `derm_address` 229, `sludge_level` 131, `water_level` 131,
`derm_manifest` 124, `closed_valve` 100, `remote` 66, `expense_receipt` 41, `issue` 24,
`cabin_right` 22, `cabin_left` 22.

🛑 **THREE ARE NEW, AND AN EARLIER VERSION OF THIS SECTION SAID THERE WERE NONE.** It read *"every
role used here already exists in live data, so a consumer never meets an unknown tile"*, and cited
the `2026-09-23_0926` migration's VERIFY as the guarantee. **That was true of the 16 roles mapped for
the test form and is false of the live-form mapping.** The VERIFY ran against the earlier list and
cannot re-assert this one. Each of the three is argued on its own terms:

| role | count | why it is right |
|---|---|---|
| `boots` | **0** | It is in **ADR 009's own table already**, so nothing is being invented. It reads as unused only because the dead Airtable feed never mapped it: the PRE form asks for it and **110 of the 444 Airtable records carry the photo**. This is the ADR's value finally being used. |
| `hose_extensions` | 0 | New value. Was `other` while nothing was mapped to it. |
| `truck_off_switch` | 0 | New value. Was `other` while nothing was mapped to it. |

🛑 **THE LAST TWO ARE A DELIBERATE VOCABULARY EXTENSION AND THE REASONING IS THE REUSABLE PART.**
They are two DIFFERENT checks - are the hose extensions on the truck, and was the master cut-off
switch under the seat set. Both landing as `other` on the same inspection makes them
indistinguishable afterwards, which is the one thing an intake built so we "don't miss anything"
must not do. What made it cheap was measured, not assumed:

- **`photo_links.role` carries no CHECK constraint.** Only `entity_type` does
  (`photo_links_entity_type_chk`, 7 values), and `inspection` is in it.
- **No app enumerates inspection photo roles.** A sweep of every Building Apps repo for the role
  literals returned **0 code hits**, docs only. `other` would have been equally unknown to a
  consumer, since it has 0 live rows too.

⇒ So the cost was one row in ADR 009's table and one in `docs/schema.md`, both updated in the same
change. ⚠ **That is the standing rule, not a one-off:** a role appearing here for the first time gets
added to the ADR and the schema doc in the same change, or the two drift again.

⚠ The live vocabulary is still RICHER than ADR 009's original table, which listed `tires` (still
unused, no form asks) and omitted seven that are in use. **The data is the contract, the ADR is kept
honest against it.**

Storage path mirrors the Airtable convention: `fillout/inspection/<id>/<role>_<queue id>.<ext>` in
the **`GT - Visits Images`** bucket (public, same as the existing 2,369 `airtable/inspection/*`
objects).

---

## 7. What the test phase proved, and the bug only it could find

A duplicate of the Post form (`wqhXiiimYrus`) was wired to the endpoint with Airtable removed, and a
real submission was made through the real form UI.

🛑 **THE DEFECT: a Fillout file answer is an ARRAY OF OBJECTS, and the first parser turned it into
garbage that looked fine.**

```json
"photo_dashboard": [ {"url": "https://prod-fillout-oregon-s3.../probe-b.jpg",
                      "filename": "probe-b.jpg"}, {...} ]
```

The code did `v.map(String)`. `String({url:...})` is **`"[object Object]"`**, a non-empty string that
**passed** the URL filter. The queue took one row with `source_url = "[object Object]"`, and because
both files stringify identically the unique constraint **collapsed them into one**. Two photos lost,
one junk row burning its retry budget, and no error anywhere.

⚠ **Every synthetic test passed**, because every one of them sent strings. This is the estate's
recurring shape one layer along: a value of the **wrong shape** coerced into a plausible-looking one
and then used. Only a real submission could find it. That is the argument for the test phase.

**Verified after the fix by replaying the exact recorded payload** out of `webhook_events_log`:

```
replay -> inspection_id 370, replayed: true, photos_seen 2, photos_queued 2
drain  -> claimed 2, outcomes {done: 2}
stored -> 1,633,286 B and 2,241,687 B, byte-exact to what S3 reported
links  -> 2 photo_links, role dashboard
```

**Also measured:**

- **The submission UUID works as an idempotency key.** The replay resolved to the *same* inspection.
- **The file URLs do not expire.** They carry **no query string**, so they are unsigned public S3
  objects rather than presigned links; both fetched HTTP 200 with the right content-type. That is
  what makes queue-then-drain safe. ⚠ An observation about Fillout today, not a promise: the drainer
  still treats 404/403/410 as a link that has gone.
- **The ET date rule holds.** A `22:00Z` submission filed as `shift_date 2026-09-22`.
- Supabase Storage answers a **missing** public object with **HTTP 400**, not 404, so a missing file
  is deliberately not terminal in the drainer.

**Proven separately by direct POST** (same code path, after the raw payload confirmed the shapes):
the driver and truck alias maps, separator-stripped numbers, the valve boolean, unknown names
reported rather than guessed, a wrong key rejected 401, and a replay returning the same row.

All test artefacts removed: 319 inspections, 2,476 inspection photo links, 0 queue rows, 0 objects.

---

## 8. Go-live, 2026-09-23

**Done.** Both live forms carry the webhook alongside their untouched Airtable integration, with the
`x-fillout-key` header (value in `Supabase/.env.fillout`, gitignored), and both were published.

Proven before publishing, because it is the thing that could have gone wrong silently:

- **Neither form had unpublished edits.** `flowSnapshot.id == flow.publishedSnapshotId` on both
  before any change, so publishing shipped ONLY the webhook and none of the human's in-progress work.
- Both saved bodies were read back from the server and compared row by row against §3c: **18 of 18**
  and **28 of 28** correct, headers present at 46 characters.
- The **published public snapshot** carries the integration on both.
  ⚠ Its `body` and `headers` come back EMPTY on the public page. **That is Fillout redacting the
  write config, not a failed publish**, and the control that settles it is the TEST form, which is
  proven end to end by a real submission and reads exactly the same way.

---

## 9. The backfill, 2026-09-23 (Fred: "Go ahead first with the backfill")

`scripts/migrate/airtable_inspection_backfill.js` (structured rows) and
`scripts/migrate/airtable_inspection_attachments.js` (their photos). Both are idempotent and both
only ever READ Airtable.

| | |
|---|---|
| Airtable records | 444 |
| already linked before | 319 |
| **imported** | **106** |
| refused, no `Pre/Post` value | 10 |
| refused by the shift unique index | 9 |
| `public.inspections` | 319 -> **425** |

The natural key is the **Airtable record id**, in `entity_source_links` (`entity_type='inspection'`,
`source_system='airtable'`). All 319 pre-existing rows carried one, so the gap was exactly computable
and a re-run imports nothing. 🛑 **`public.inspections` has no unique key of its own beyond the shift
index, so that link is the only thing between a second run and 444 duplicates.** The insert and the
link go in one statement.

🛑 **THE GO-LIVE CUTOFF IS A CORRECTNESS GUARD.** A submission made after the forms were wired sits
in Airtable AND arrives through the webhook, under two different natural keys, so nothing would stop
the script inserting a second copy. Records created at or after `--cutoff` are reported and never
imported. It was 0 on the day, and it will not be next time.

### 9a. 🛑 `idx_inspections_shift_unique` exists, and `pg_constraint` cannot see it

`CREATE UNIQUE INDEX idx_inspections_shift_unique ON public.inspections (shift_date, vehicle_id,
employee_id, inspection_type) WHERE vehicle_id IS NOT NULL AND employee_id IS NOT NULL`

It is a **partial unique INDEX, not a table constraint**, so the catalogue query that lists
constraints returns nothing for it. I read that silence as "no unique key" and found out from nine
23505s mid-run. ⇒ **Read `pg_indexes` as well as `pg_constraint` before calling a table unkeyed.**

**Those nine are second submissions for a shift we already hold** (a driver redoing a form). The
index refused them, which is the index working, so they stay unimported and Airtable keeps them:
`recBqDdFGTCgVnaPz` `recKsm5NhvqQ6MqP4` `recU4cDGXtO8L6N94` `recb2QLTg8Jf9hIii` `reccWay2Dtk8dnyJm`
`recd4PtzgzGeIbdqR` `recjV3ym6VXsRg6Mg` `recptjz4pr97KO2c3` `recrvDnjsoaXB5PhE`. Choosing which of two
conflicting records wins is a person's decision, not a script's.

🛑 **AND IT WAS A LIVE DEFECT, NOT JUST A BACKFILL ONE. FIXED IN v7, see §9b.** Measured: **19 shift
groups in Airtable hold 2 or more records, 38 of 444, about 4% of shifts.** Every one of those would
have hit the same 23505 in the webhook, thrown, returned 500, and been retried into the same 500 for
ever.

### 9b. A second submission for the same shift now MERGES (edge fn v7)

`insert` -> on `23505` -> find the row for that (shift_date, vehicle, driver, type) -> `update` it
with the new answers -> return 200 with `merged_into_shift: true`. **Later submission wins, whole
row**, because a redo is the driver correcting themselves and both forms require the fields that
matter.

🛑 **THE LINK CANNOT BE DUPLICATED, AND THE FIRST ATTEMPT AT THIS SHIPPED THAT BUG.** `idx_esl_entity_source`
is UNIQUE on `(entity_type, entity_id, source_system)` with **zero exceptions anywhere in the table**,
so an inspection holds exactly ONE `fillout` link. v6 updated the row and then threw 23505 inserting a
second link: data landed, caller got a 500, Fillout retried for ever. v7 keeps the FIRST submission's
id as the link and records the second in `webhook_events_log` under its own event id, which is what
that table is for. The response says which id the link carries (`linked_submission_id`).

⚠ **The index is PARTIAL**, so a merge cannot happen when the driver or truck did not resolve. Two
rows for one shift is then the correct outcome: we do not know they are the same shift, and guessing
is how one driver's inspection overwrites another's.

Proven with four cases and a control: first submission inserts; a second with new values merges into
it; **a retry of that second one is byte-identical and queues no duplicate photo**; a submission on a
different day still inserts separately.

### 9c. ⚠ OPEN FOR FRED: 75 legacy rows are dated one day late

The dead feed derived `shift_date` from a **UTC slice** of `submitted_at`. The estate's operating-date
rule is the **ET clock date**, which is what the webhook and this backfill both use. Measured across
every row that has a `submitted_at`:

| cohort | rows | match ET | match UTC |
|---|---|---|---|
| legacy (written before 2026-09-23) | 319 | 244 | **319** |
| backfilled 2026-09-23 | 106 | **106** | 74 |

100% and 100%, so this is not a guess about the old code, it is what the old code did. **75 legacy
rows sit on the day after the shift.** Re-dating them is a data correction with real consequences: it
is not audited (`public.inspections` carries no audit trigger), and **6 shift groups would collide on
the unique index** once moved, so it needs a backup and a decision about those 6 first. Not done.

⚠ One pair created by this backfill is a genuine double submission spanning ET midnight (ids 407 and
433, Aaron on Goliath, submitted 2 hours apart at 22:00 and 00:00 ET). The unique index cannot catch
that one, because two different ET dates is the correct reading of the rule.

### 9d. The photos

4,061 Airtable attachments across the 425 linked records; 2,476 were already mirrored, so **1,585 were
new**. `airtable_inspection_attachments.js` came back out of `_archive` for this and **three role
mappings were missing from it all along**: `Pictures of the boots`, `Hose Extensions`, and
`Truck OFF switch (under seat)` were landing nowhere, which is why `boots` read as an unused role.
Idempotency is `entity_source_links(entity_type='photo', source_system='airtable', source_id=<att id>)`
plus the unique `photos.storage_path`, so a re-run re-downloads nothing.

---

## 10. Still open

1. **Telling Viktor.** He was told on 2026-09-23 to keep reading Airtable for inspections and change
   nothing until told, because `public.inspections` was the stale 319-row mirror. Fred asked for him
   to be told once the live posting was on prod.
2. **The 75 mis-dated legacy rows** (§9c) and **the 19 unimported Airtable records** (§9a plus the 10
   with no `Pre/Post`, of which 3 are empty rows created when the table was set up and 7 are real
   May/June 2025 inspections from before the form had that question).
3. **The out-of-range sludge values.** 34 of the stored values are between 4,560 and 18,900 on a
   fleet whose largest tank is 3,800, nearly all of them one driver in mid-2025. Stored as typed,
   because inventing a correction is worse. The Post form's `(1-3,800)` label is the human's own fix.

⚠ **What has NOT been observed yet: a real driver submission through a live form.** The full path
was proven end to end on the test copy, and the live config was verified declaratively, but the
first real shift inspection is the only thing that proves the two together. Watch for it:

```sql
select id, event_type, status, event_id, entity_id, error_message, created_at
  from public.webhook_events_log
 where source_system = 'fillout' and created_at > '2026-09-23'
 order by id desc;
```

A submission that arrives but maps badly is still **recoverable**: the raw payload is logged before
anything can fail, so it can be replayed once the mapping is fixed.
