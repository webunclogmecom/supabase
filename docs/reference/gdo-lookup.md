# The GDO lookup (edge function `gdo-lookup`, Trello #242)

Built 2026-11-23/24 by the session named Supabase. Fred, on round 3 (2026-11-24): *"go with D1 and all recommended, build
it"* and *"when clicking view, put the Add button at the right bottom"*; earlier *"make them be aligned, always"*. Picks and
every default: `Building Apps/Ops Portal/docs/00-fred-picks-2026-11-24-gdo-lookup.md`; the three rounds of pictures are
local (`mockups/2026-11-23-gdo-lookup-242*.html`, real client codes).

Two screens use it, both in the Ops Portal:
- a Miami-Dade site's **City permits** section (Clients, Sites tab), in place of the blue Add permit card: it opens searched
  for the site's county parcels, and a permit is added to the site from it after a confirmation;
- the **GDO lookup** page under Compliance (`/derm/gdo-lookup`), read only.

The portal's side (screens, words, rules): `app/docs/modules/clients.md` (City permits) and `app/docs/modules/derm.md`
(the page), in the `unclogme/ops-portal` repo.

## The function

`supabase/functions/gdo-lookup/index.ts`. One POST, four actions. `verify_jwt = true` (pinned in `config.toml`) and
`hr.check_app_action` as the caller (`_shared/access-check.ts`):

| Action | Access action (`hr.check_app_action`) | What it does |
|---|---|---|
| `search {q?, site_id?, places?, places_ok?}` | `gdo_lookup`: Client App or DERM Tracker, View | The county's public document list (`https://api-ecmrer.miamidade.gov/derm/documents`, type OPERATING PERMIT, case numbers `GDO`), one entry per permit (its newest document, how many it has), and which of our records hold each number (`public.gdos` by the exact 6-digit number, with the client code). With `site_id` and no `q`: every permit on the site's county parcels and on the parcels of the permits already on the site. |
| `read {url}` | `gdo_lookup` | One permit file read: a text PDF by `_shared/gdo-permit-read.ts` (the reader `parse-gdo-permit` uses, moved there verbatim on 2026-11-24), with the holder's full name from the later page; a scan from its picture by Claude (below). Returns holder, facility location, effective and expiry dates, cleaning days. |
| `file {url}` | `gdo_lookup` | The county's file passed through as `application/pdf`. The county serves it as `application/octet-stream`, which a window downloads instead of showing. |
| `take {url, number}` | `gdo_lookup_take`: Client App, Edit | Copies the county's file into the `gdo-permits` bucket: `gdo/GDO-nnnnnn.pdf`, or `gdo/GDO-nnnnnn-county-<date>.pdf` beside a file already there (never over one, `parse-gdo-permit`'s rule). A text permit names its own file and must be the number asked (409 otherwise); a scan takes the county's number. The permit row itself is then saved by the portal through `client.upsert_gdo_permit`, with all its checks. |

Access migration: `docs/migrations/2026-11-23_1845_gdo_lookup_actions.sql` (two rows added to `hr.check_app_action` from
its live body, md5 guarded, applied 2026-11-23 about 6:50 PM ET; rollback beside it).

## What it searches, and how a query is read

- A client code first, even after the word permit (`permit 192-frk`, the Slack bot's order): that client's site addresses
  and the numbers we hold for it. A code that is no client and looks like an address (`650 Main`) is searched as one.
- A permit number in any form (`GDO-011423`, `GDO-11423`, `11423`): the county keeps 5 digits, so it is asked with
  `GDO-11423`, and only that exact number is kept (the county's case number filter matches the start).
- A house number first: an address (the house number and the ZIP, or the street name when there is no ZIP).
- Anything else: a business, by name anywhere in the county's list, plus the addresses where that business is: our sites
  whose client name matches, and up to three Google Maps places in Miami-Dade, which the PORTAL finds and sends as
  `places` (pick S). **Places refuses this function's server key** (HTTP 403 PERMISSION_DENIED, measured 2026-11-23), so the
  browser asks with the portal's site-restricted key (`findBusinessAddresses` in the portal's `AddressAutocomplete.tsx`).
  `places_ok: false` makes the answer say Google Maps did not answer.

## Rules that must not be regressed

- 🛑 **Never return a permit page as text.** Page 1 carries the contact's name and mailing address and the county's
  temporary password for its reporting site. Only the fields above leave the function; the scan prompt tells the model
  never to return a contact, a mailing address, a password or a PIN, and the schema has no field for them.
- 🛑 **Files only from the county's store** (`^https://stecmrerportal\.blob\.core\.windows\.net/dermdocuments/[0-9a-f]+\.pdf$`).
  Anything else is refused, so the function is not an open proxy.
- 🛑 **A county that does not answer is never "no permit".** Only a JSON body with a `data` list is an answer; anything else
  (HTTP error, HTML, no list, a timeout) is `county_down` (HTTP 502), which the portal shows as "The county's search did
  not answer ... Try again".
- 🛑 **The county's house number filter is not exact**: asking 650 brings 5650 too (measured 2026-11-23 on 650 NW 33 St,
  33127, which pulled a 5650 NW 2 Ave parcel into the test client's site). Every address-derived row is kept only when
  its house number equals the one asked (`sameHouse`).
- County calls are 0.5 s apart within a request (the Slack @GDO bot's courtesy); the portal reads permit files at most
  two at a time.
- The list's name is often an earlier tenant's; the permit is the record. Status comes from the permit's own dates,
  never the year: Active through, Renewed through (next year's permit already out), Expired.

## Reading a scan (pick E1)

`claude-opus-5-5`, effort low, a structured JSON output (permit number, issued to, facility location, valid from and
through, cleaning days, is it a permit), the default server-side refusal fallback, as `gdo-permit-label`. About 5 to 6 s
per scan. Measured on GDO-014655 (Presidente Bar, the county's only file a scan): every fact equal to the paper read by
eye. A file that cannot be read returns `read: false`, and the portal asks the person for the expiry date before adding
(an empty expiry date counts as active, decision 13, which is why it must be asked). Reads are kept an hour in the
browser; nothing is cached on the server and nothing is written by `read`.

Since 2026-11-24 (Trello #227) the reader lives in `_shared/gdo-permit-scan.ts` (`readScan`, `scanFields`, moved
verbatim) and `parse-gdo-permit` uses it too, for scans staff drop in the Client App. One fix there, for both: the
permit number is the first group of at most 6 digits after "GDO". Claude returns the permit years with it ("GDO-14769
2024-2025"), and the old rule took every digit: "GDO-1476920242025" on 3 of 3 of our own scans. Checked on the live
page after the move: GDO-015303 (a county scan) read as Lucciano's Usn 6 LLC, expired 2024-12-31, every 90 days.

## Checks

- `node scratchpad c242/live_lookup.mjs` (session scratch, not kept) ran every action live with the server key on
  2026-11-23: no token 401; site 217 (Wynd 28) 4 permits on 2 parcels, 3 already on the site; `GDO-011423` 1; a business
  with a Maps place at the mall 61; `242-WYN` 3; the mall address 53 (uncut); `Arepa Kingdom` 0; a text read (the
  Chipotle full name from page 4); the scan read; `file` 200 `application/pdf`; a foreign URL 400.
- A real add on the test client 112-YA (site 1164) through the screen on 2026-11-23 about 7:20 PM ET: `gdos` row 333
  (GDO-014655, EXPIRED, the scan's dates and 90 days, `gdo/GDO-014655.pdf`), audit INSERT `client-app` by Fred, then
  marked INACTIVE through its own menu. The file stays (a real add later goes beside it).
- The portal's tests: `src/lib/gdo-lookup.test.ts` (names, status, address line, the warnings, the order, the save's keys).
