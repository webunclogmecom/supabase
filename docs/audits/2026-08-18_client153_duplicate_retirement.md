# 2026-08-18 — duplicate client 153 (Arepas Noni) retired, two dead Jobber links dropped

*Triggered by a single unexplained row: property 304 was the 1 of 459 that failed to resolve
during the seeding of `sync.source_field_shadow`, and it burned a wasted `webhook-jobber`
round trip on every fleet-wide property replay.*

## It was not a stale link. It was a duplicate client.

We held **two client rows for the same business**, at the same address.

| | client 152 | client 153 |
|---|---|---|
| `client_code` | **145-NON** | NULL |
| Jobber client | `113794149` — **live** | `113794289` — **absent** |
| primary property | 213 -> `Property/120774855` (live) | 304 -> `Property/120775026` (absent) |
| billing pseudo-property | 835 | 906 |
| jobs / invoices / GDOs / service configs | 2 / 3 / 1 / 1 | 1 archived / 0 / 0 / 0 |

Client 153 had therefore been receiving **zero** Jobber updates since its Jobber record
vanished (last staged 2026-07-02), which is also why its `client_code` was NULL while Jobber
carries `145-NON` in the client name.

## How it was verified, and the control that makes it mean something

`client(id:)` and `property(id:)` lookups returning null prove nothing on their own — Jobber
sheds load with an **HTML waiting room at HTTP 200**, so a naive check reads an outage as a
deletion. Every query went through the shared `gql` helper, which rejects a non-JSON
content-type, and each lookup was paired with a **positive control that had to be found**:

```
CONTROL property 133252370 -> FOUND (127 Northwest 27th Street suite 105)
TARGET  property 120775026 -> NOT FOUND
CONTROL client   126142048 -> FOUND (Wynd 28 - 242-WYN, 6 properties)
TARGET  client   113794289 -> NOT FOUND
SEARCH  "Noni"             -> Client/113794149 "…(Arepas Noni) - 145-NON", not archived,
                              owning Property/120774855 at 17030 West Dixie Highway
```

Both live ids were **already linked** to client 152 and property 213, which is what settles it
as a duplicate rather than a repointing job.

## Not systemic — measured, not assumed

All 445 of our Jobber client links were diffed against a **complete** Jobber client list
(460 of 460 fetched; the walk asserts it reached the end and refuses to diff on a short read,
because a partial pull would manufacture false "dead" verdicts).

**2 dead links in 445.** Client 153, and client 493 (Courtyard by Marriott SOBE) which was
already INACTIVE. Client 153 was the only ACTIVE record disconnected from Jobber.

⇒ Worth knowing: **nothing detects a vanished Jobber client.** The poll pulls with an
`updatedAt` filter, so a deleted client simply stops appearing and no branch ever fires. The
sweep above is the detector; it does not run on a schedule.

## What was done (Fred's call, 2026-08-18)

1. **Client 153 -> INACTIVE**, `status_source='manual'`. Rule 6: soft-delete, never a hard
   delete. `public.properties` has **no** soft-delete column at all, so properties 304 and 906
   were not touched; they simply belong to an inactive client now.
   ⚠ `client.update_client_status` is the sanctioned path but **refuses the Management API**:
   it requires `auth.uid()`, and that transport has no request context. Its effects were
   reproduced exactly rather than faking a JWT — status + `status_source`, plus the mandatory
   `client_status_changes` row so the "no reason, no change" discipline still holds, with the
   actor recorded as `maintenance:claude-session` instead of as a person.
2. **Dropped 2 dead `entity_source_links` rows** (ids 306, 1117) and the **stale
   `raw.jobber_pull_properties` row**, which is what actually burned the replay (476 -> 475).
3. **Backup first**, because `public.entity_source_links` carries **zero triggers** — a DELETE
   there leaves no record of any kind and the file is the only restore path:
   `backups/2026-08-18_client153_duplicate_retirement.json` (outside the repo; it contains
   client PII). Both deletes are pinned to the primary key **and** re-assert the premises that
   make the row an orphan (the duplicate is retired, and a different row already holds the live
   Jobber id), so they delete nothing if the world changed since the investigation.

## Left in place deliberately

- **Property 906's billing pseudo-link** (`…113794289_billing`, link id 76450). Dead by the same
  measurement, but Fred approved two specific rows and expanding a delete beyond an approval is
  not a judgement call to make unilaterally. Harmless: it is inert on an inactive client.
- **Property 304's Samsara link** (`samsara=322485296`). A different source system, never
  verified against Samsara, so nothing here justifies touching it.
- **Job 1566** (#99900786, archived, 0 visits) and **contact 207**. Business data; rule 6.
  The contact carries no information client 152 does not already hold — same email
  `arepasbynoni@gmail.com`, and 152's copy also has the phone number.

## Verified after

```
client 153            INACTIVE, status_source=manual, 1 client_status_changes row
audit.logs            1 row, ACTIVE -> INACTIVE, app_source='client-dedupe-maintenance'
dead links remaining  0 of 2        raw rows 476 -> 475
client 152            ACTIVE, untouched
fleet gallons 74,327  shadow rows 458   (both unchanged)
```
