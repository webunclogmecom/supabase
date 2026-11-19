# GDO permit numbers: one form, `GDO-` plus 6 digits (Trello #227, reopened 2026-11-19)

## Fred's words (2026-11-19)

On the question "Diego typed GDO-014769 and it saved as a NEW permit, although GDO-14769 is on file":

> "One form, 6 digits. The database saves every GDO number as GDO- plus 6 digits (GDO-14769 becomes GDO-014769), so the
> check refuses the copy. The refusal also says which address holds the permit, since Diego was on a different site.
> So when there are more or less than 6 digits throw the error mentioning it. But with that we would need to change the
> GDO Bot we have in Slack, because nowadays it only shows 5 digits instead of 6. And once that is done, we need to check
> all the GDO Permits we have to see if all needs is a 0 now as the first of the 6 digits like The Moore is."

And on drag and drop: "Just make sure the error handler for it works good."

## What is true today (measured 2026-11-19)

- DERM prints 6 digits (`GDO-011226`). We store 5 on purpose: `parse-gdo-permit` line 176, "Printed zero-padded to 6
  ("GDO-000951"); we store 5 ("GDO-00951")". 189 GDO numbers are 5 digits; the 5 with 6 digits were typed by hand.
- The rule's one home: `public.permit_types.number_pattern` for GDO (`^GDO-[0-9]+$`), enforced by
  `public.fn_permit_number_matches_type` (INACTIVE rows skip it). Uniqueness: `gdos_client_gdo_unique (client_id,
  gdo_number)`, all statuses, and `client.upsert_gdo_permit`'s two exact-text checks ("This client already has permit %").
- Every DERM reader tests `gdo_number ~ '^GDO-[0-9]+$'` (6 digits pass unchanged). `rpa-derm-result` compares with the
  zeros stripped (safe). `get-permit-doc` matches the stored text (callers pass the stored text).
- 🛑 **The GDO bot TYPES the permit as the county portal's LOGIN USERNAME** (`reporter.py`: `page.fill('#MainContent_userName',
  clean_permit)`, where `clean_permit = normalize_permit('GDO-09853') = '09853'`). Today the 5-digit form logs in. Whether
  `009853` logs in is unknown and is not tested by any of our tools.
- 🛑 **The bot's ledger key keeps the zeros** (`normalize_permit`, `_permit_expr`): `GDO-009853` would key as `009853` and
  miss every history row keyed `09853`, so `is_already_reported` could say "not filed" and file again. Its integer
  matcher (`_permit_to_int`, the email matching) is already zero-blind.
- Permits: 138 ACTIVE (130 with a PDF), 4 EXPIRED (1), 55 INACTIVE (49). No trigger on `gdos` pushes to Jobber.

## The county login gate: PASSED (2026-11-19 ~11:50 PM ET)

Fred's rule: "Try 6 digits once ... if it works, the bot types 6 digits from then on ... And if it fails we stop all
about this change of digits, and keep the 5 digit, and fix what diego did with the 6 digits permits". Fred logged in
by hand on the county portal with `015675` (168-AVA, GDO-15675, a permit the bot filed for at 12:34 PM ET that day) and
the report form opened on AVA's facility. So the plan goes ahead, and the report bot types 6 digits.

## Two bots, not one

- The county **report** bot (`webunclogmecom/unclogme-gdo-report-bot`): types the permit as the login, keys its ledger
  on it, posts the Slack digest and alerts. Branch `gdo-six-digits-227`: the ledger key is zero-blind and stays on the
  5 digits every past row holds (`normalize_permit`, its SQL twin `_permit_sql`, and every stored-key comparison:
  `is_already_reported`, `get_reported_row`, acks, password slot, reruns, hand entries); the login types
  `login_username` (6 digits); Slack and the dashboard show `permit_label` (`GDO-` + 6 digits).
- The Slack **lookup** bot `@GDO` in #gdo-permit (`webunclogmecom/unclogme-gdo-bot`, local `Slack/GDO Bot`): this is the
  one that "only shows 5 digits" (`derm_lookup.py` padded with `zfill(5)` on purpose, its prompt said `GDO-NNNNN`).
  Branch `gdo-six-digits-227` (`6f3876f`): shows `GDO-` + 6 digits (`canonical_gdo`), accepts 4 to 6 digits typed,
  matches on the digits, and still searches DERM with the 5 digits DERM's index uses. It reads Prod read-only and never
  filters `gdo_number` by text, so it works before and after the rewrite.

## Step 1 result: every permit PDF (2026-11-19)

180 stored PDFs read (`pdftotext`). **Every readable one prints `GDO-0` plus 5 digits**: 155 print our number, 15 print
another number (also 6 digits with a leading 0). Not readable: 3 ACTIVE files that are TIFF images saved as `.pdf`
(126 058-SOH, 127 114-CI, 130 193-FRK) and 4 scans with no text (59 and 182 148-MOR, 183 036-LG, 189 233-AH).
Side finding, not changed (raised to Fred): 8 ACTIVE permits whose stored PDF is ANOTHER business's permit: 27 175-PV
(PDF GDO-011228, Pura Vida Brickell 1104 S Miami Ave), 73 091-SB (GDO-003271, El Dos Ru), 85 129-BSC and 94 012-DKC
(both GDO-003278, Fairfield Inn 4101 Collins Ave, the same file as INACTIVE 66), 89 037-LB (GDO-016296, Pauline
1801 Collins Ave), 99 171-CAF (GDO-010249, the 2022 permit of Pizza at Ironside), 104 176-SOU (GDO-014681, Pura Vida
12 NE 17 St), 147 155-PV (GDO-010891, Pura Vida Collins Loews). The report bot has never filed for any of them.

## Step 3, measured and rehearsed (2026-11-20)

189 numbers are rewritten (137 ACTIVE, 3 EXPIRED, 49 INACTIVE); 5 already had 6 digits; 3 INACTIVE rows holding
several numbers in one field (29, 157, 164) stay as they are. No two live permits of one client share digits (148-MOR
merged first). Three retired copies share digits with a live permit (132-PUM 144, 148-MOR 307 and 311), so
`gdos_client_gdo_unique` becomes a partial unique index (`WHERE status <> 'INACTIVE'`), and the duplicate checks in
`client.upsert_gdo_permit` count live permits only, by their digits, naming the address. Rehearsed rolled back as a
staff user: Diego's case (`GDO-014769`, and `GDO-14769`, on the service site) is refused with "This client already has
permit GDO-014769 at 4040 Northeast 2nd Avenue (active). Edit that permit instead of adding it again."; `GDO-99999`
gets "GDO-99999 has 5 digits. A GDO permit number is GDO- and 6 digits, as the county prints it: type GDO-099999.";
7 digits gets the count; re-saving a permit with its own number passes. Control on today's code: 5 and 7 digits
accepted, no address named. The rollback, rehearsed after the forward in one transaction, gives back the same rows,
pattern, constraint and function bodies (md5).

## The order (each step leaves the system working)

0. **Done 2026-11-19 17:39 ET:** 148-MOR's two duplicates merged (`2026-11-19_1740_gdos_148mor_merge_duplicate_permits.sql`).
1. **Check every permit against its PDF** (Fred's last sentence): read the printed number from every stored permit PDF
   (pypdf / pdftotext, PDFs only in a scratch folder, never in a repo) and compare with the stored number. Report: how
   many print `GDO-0` plus 5 digits (expected: all), any that print another number (a wrong permit, like 148-MOR's
   GDO-014768), any with no readable number. Nothing is changed by this step.
2. **The GDO bot, before the database changes** (sealed tests, Railway deploy, `/data` backup first):
   - the ledger key and its SQL twin become zero-blind (the bare integer, padded to 5), so `GDO-009853`, `GDO-09853` and
     `09853` are one permit and history still matches;
   - the county login keeps typing what logs in today (5 digits) until a live check proves the 6-digit form;
   - what the bot SHOWS (Slack digest and alerts, its dashboard) reads `GDO-` plus 6 digits.
3. **The database rule and the reader, together** (one migration and one deploy, rehearsed rolled back):
   - `permit_types` GDO pattern `^GDO-[0-9]{6}$`; the trigger's message names the count ("A GDO permit number has 6 digits
     after GDO-, like GDO-011226. GDO-14769 has 5.");
   - every GDO number rewritten to 6 digits (INACTIVE rows too, so history reads the same way);
   - `gdos_client_gdo_unique` counts live permits only (`WHERE status <> 'INACTIVE'`): a retired duplicate (148-MOR's
     307, 311) keeps its number, and both readers of the old index are checked;
   - `client.upsert_gdo_permit`'s refusal names the address holding the permit;
   - `parse-gdo-permit` stores `padStart(6)`, deployed in the same hour (the new pattern would refuse its 5-digit answer).
4. **The apps:** the permit field's example and hint say 6 digits (old Client App by Building Apps; the Ops Portal by the
   session named Supabase). The refusal sentences come from the database, so both show them unchanged.
5. **Drop errors, both apps** (Fred: "make sure the error handler for it works good"): with canned replies in the page
   (nothing saved), every failure says what happened and what to do: no file (an attachment dragged from a mail app), not
   a PDF, a scanned or unreadable PDF, another document, a field missing, a number already on file (names the address),
   the reader down or slow, the save refused.
6. **Checks:** the standing check `scripts/checks/permits_gdo_only.sql` and a new one (every live GDO number has 6
   digits; no client holds one number twice by integer value); the bot's next live run files with the same login;
   148-MOR, 238-PV, 112-YA in both apps at 1440 and 375.

## Rollback

Step 3: the reverse rewrite (6 to 5 digits) and the old pattern, in its own file, rehearsed. Step 2: redeploy the bot's
previous commit. Steps 4 and 5: the apps' previous versions.
