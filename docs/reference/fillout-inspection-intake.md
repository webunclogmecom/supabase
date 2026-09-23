# Fillout shift-inspection intake

How a pre/post shift inspection reaches the warehouse, what the test phase proved, and what is still
needed to switch the real driver forms on.

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
| `valve_closed` | `is_valve_closed` | ⚠ absent is NULL, not false. A form that never asked has not said "open" |
| `has_issue`, `issue_note` | same | `has_issue` derives from a note when not asked explicitly |
| `photo_*` (18 keys) | queued → `photo_links.role` | §6 |

**Auth is fail-closed.** A missing `FILLOUT_WEBHOOK_KEY` refuses every request. `config.toml` records
the 2026-07-29 incident where three functions gated on `if (KEY && header !== KEY)` and an unset
secret skipped the check entirely.

**`verify_jwt = false`** is required (Fillout cannot send a Supabase JWT) and pinned in `config.toml`.
🛑 **If intake goes quiet, check that first**: a redeploy defaults it to true and 401s every
submission at the gateway with nothing in the function log.

---

## 4. Why photos are queued and not fetched inline

A submission carries up to 17 attachments. Fetching them in the webhook would hold Fillout's request
open across 17 sequential round trips, **and Fillout retries a request it thinks timed out**, which
creates a second inspection. It would also be the third time this estate ran an edge function out of
memory.

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

Every role used here **already exists** in live `photo_links` data, so a consumer never meets an
unknown tile. Measured 2026-09-23: `left_side` 266, `back` 265, `right_side` 265, `cabin` 264,
`front` 264, `dashboard` 262, `derm_address` 229, `sludge_level` 131, `water_level` 131,
`derm_manifest` 124, `closed_valve` 100, `remote` 66, `expense_receipt` 41, `issue` 24,
`cabin_right` 22, `cabin_left` 22.

⚠ **That live vocabulary is RICHER than the table in ADR 009**, which lists `tires`/`boots` (never
used) and omits six that are in use. **The data is the contract, not the ADR.** Two form fields
(Hose Extensions, Truck OFF switch) have no established role and are queued as `other` rather than
inventing one, because a new role value is a schema-shaped decision.

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

## 8. Still to do before the real forms are switched on

1. **Map the remaining body keys on BOTH live forms** (`7FeakRTGTDus` pre, `jBBi8r53nQus` post).
   Only 4 keys were mapped on the test copy, because the unknown was the file encoding. The full set
   is the table in §3. ⚠ **Add the webhook alongside the existing Airtable integration, do not touch
   Airtable.**
2. **The `x-fillout-key` header** on each, value from `Supabase/.env.fillout`.
3. **Decide the backfill**: Airtable holds ~124 inspections this warehouse never received. Importing
   them is a separate one-off, and they would carry `source_system='airtable'`, not `fillout`.
4. **Tell Viktor when it goes live.** He was told on 2026-09-23 to keep reading Airtable for
   inspections and to change nothing until told, because `public.inspections` is still the stale
   319-row mirror. That instruction expires the moment the forms are wired.

⚠ **The two forms differ.** The Post form has no "Valve is closed" checkbox (its `Closed Valve
(David)` is a photo field) and carries `Is there any issue to report`. Map each form from its own
field list, not from a copy of the other.
