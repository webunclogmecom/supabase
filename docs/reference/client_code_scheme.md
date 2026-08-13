# Client Code Scheme — how to read & create `client_code`

`public.clients.client_code` is the human-facing client identifier, e.g. `226-JER`, `050-PV`, `002-41`.
This is the canonical spec for understanding existing codes and **assigning new ones**.

---

## Format: `NNN-XXX`

A zero-padded **number**, a hyphen, then a short **brand tag**.

### `NNN` — the number (THIS is the unique key)
- 3-digit, zero-padded (`001`, `050`, `226`).
- Assigned **sequentially by onboarding order**. The number — not the letters — is what must be globally unique.
- **Gaps are normal and expected.** Deletions/renames leave holes (≈560 unused numbers in the 0–242 range). **Do NOT backfill gaps** — always take the next number up.
- **700+ is a reserved/vanity band**, not part of the sequence. Current example: `777-YA` = *Yan's Restaurant* (founder vanity code). Ignore the reserved band when computing "the next number."
- 🛑 **`000` IS A SECOND RESERVED BAND, AND IT IS SHARED BY MORE THAN ONE ROW ON PURPOSE.**
  `000-DP` (*DUMP Pompano*) and `000-DH` (*Homestead Dump*) are both ACTIVE and both hold number
  **0**. They are the disposal facilities we haul grease TO, carried as clients so work can be
  scheduled and costed against them, deliberately parked on `000` rather than consuming a customer
  number. **This is not a collision and they must not be renumbered.**
  ⚠ This section previously documented only the 700+ band, so a "find duplicate client numbers"
  sweep written from this page reports these two as a 247-style collision. One did, on 2026-08-12,
  and correctly refused a migration until the band was excluded. **Any uniqueness check on the
  number must bound itself to `1..699`.** It also means the sentence below, "the number is what
  must be globally unique", is true only within that range.
- **Next number = (highest normal number, i.e. < 700) + 1.** 🛑 **Do not read a number out of this
  document.** It used to pin "the next is `286`" as of 2026-07-06; by 2026-08-12 the real answer was
  `300`, and a stale number here is worse than none because it looks authoritative. Ask the endpoint
  (see *The live implementation* below), or compute it yourself, but do not trust a written constant.
- ⚠ **Read ALL rows, including `INACTIVE`, when computing the next number.**
  `clients_active_client_code_uniq` is a **PARTIAL** index (`WHERE status <> 'INACTIVE'`), so an
  INACTIVE row can hold a number the index will not defend for you. Two such pairs are live today
  (`050-PV`, `239-COM`).

### `XXX` — the brand tag (human-readable, NOT unique)
- A short mnemonic (2–4 chars) derived from the client **name**.
- **SHARED across every location of the same brand/chain.** A chain gets ONE tag; each location gets its own number:
  - `PV` = Pura Vida (26 locations), `TCE` = The Carrot Express (23), `LG` = La Granja (6), `BB` = Bagel Boss, `GRO` = Grove Kosher, `LOU` = Skinny Louie…
- Coining a tag for a **new** brand:
  - Drop noise words: `The`, `LLC`/`Inc`/`Corp`, `Miami`, `Restaurant`, `Cafe`.
  - Use initials or a recognizable short form: *Vincenzos*→`VIN`, *Bagel Cove*→`BC`, *Casa Neos*→`CN`, *Cine Citta Cafe*→`CCC`, *The Joyce*→`JOY`.
  - A leading number in the name can BE the tag: *41 Pizza and Bakery*→`41`.
  - Pick something not visually confusable with an existing tag for an unrelated brand.

---

## The golden rule: the NUMBER must be free in **BOTH systems**

Before assigning a number, verify it is unused in **DB + Jobber**. A DB-only check is NOT enough:
Jobber can hold a code that has not been written back to `public.clients.client_code`. (Real incident:
*Jerusalem Pizza* was `226-JER` in Jobber but `NULL` in the DB, so an Aromas `214→226` rename collided
with it. That is why the Jobber-side check exists and must not be dropped as redundant.)

> 🛑 **This used to say "all three systems" and count Airtable as one of them. Airtable is FULLY
> RETIRED (2026-07-24): never read it, and never treat a missing Airtable check as an incomplete
> verification.** The Jerusalem Pizza incident above is often retold as an Airtable story; the DB/Jobber
> half is the part that still exists and still bites.

### The live implementation

**`create-client` is the sanctioned path and it implements everything on this page.** Ask it rather
than reimplementing the scheme:

```bash
# propose a code for a name: brand reuse, next free number, no writes, no Jobber calls
curl -s https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/create-client \
  -H "Authorization: Bearer <a staff user's access token>" \
  -H 'Content-Type: application/json' \
  -d '{"propose_only":true,"name":"Pura Vida Coconut Grove"}'
# -> {"ok":true,"proposal":{"code":"300-PV","tag":"PV","number":300,
#     "basis":"reused existing brand \"pura vida\" (26 locations)"}}
```

A full create (no `dry_run`) additionally checks the code against **Jobber** and refuses on a
collision, so the two-system rule above is enforced in code, not by remembering to run a script.

⚠ **The two probe scripts this section used to recommend are STALE. Do not reach for them first.**
`scripts/probes/propose_client_code.js` does not run at all (`Cannot find module 'dotenv'`), and both
it and `scripts/probes/check_client_code_available.js` still query **Airtable**, which no longer
exists. They are left in place pending a decision, not because they work.

---

## Procedure to create a new code
1. **Tag** — if the client is a new location of a brand already in the DB, **reuse that brand's tag**
   (a new Pura Vida = `…-PV`). Otherwise coin a new 2–4 char tag from the name.
2. **Number** — take the next sequential number (highest normal + 1).
3. **Verify** — confirm the number is free in **both** the DB (all rows, INACTIVE included) and Jobber;
   if it collides, bump by 1 and re-check.
4. **Assign** — write `client_code` on `public.clients` and keep it consistent in Jobber.

**In practice, do not do steps 1 to 4 by hand for a NEW client.** `create-client` performs all four,
in that order, and refuses rather than half-applying. Reserve the manual procedure for renames and
renumbers of clients that already exist.

---

## Edge cases & gotchas
- **The number is the identity; the letters are cosmetic.** Two unrelated brands *could* share letters; the number keeps them distinct. Never rely on the tag for uniqueness.
- **INACTIVE tombstones may share a code with their ACTIVE successor** — that's the *same* client, not a collision (e.g. `050-PV` has one ACTIVE row + one old INACTIVE row, both Pura Vida Brickell).
- **Don't backfill gaps**; don't reuse a retired number.
- **Reserved band (700+)** is for vanity/special codes — don't auto-assign from it.
- **Residential / no-code clients**: historically many Jobber clients had no `client_code` (residential, call-only). **Superseded by Fred 2026-07-06:** any client that had a **2026 visit** gets a code regardless of type/status (incl. residential person-name accounts). For a residential (`isCompany=false`) client, write the code into Jobber **Company Name** as `"<code> <FirstName LastName>"` (e.g. `281-MA Mr. Avi`) and **leave firstName/lastName untouched** — the code is then searchable in Jobber without corrupting the person's name (note: the webhook parser reads first/last for `isCompany=false`, so a companyName code doesn't round-trip through it, but the DB `client_code` is authoritative). Never-visited leads/one-offs (~160) are still intentionally left uncoded pending a separate decision.
- **Renames/renumbers** are the riskiest operation. Check the candidate against **both** the DB (all
  rows) and Jobber before writing anything. (This used to say "the 3-source check"; the third source
  was Airtable and it is gone. Two sources is now the complete check, not a degraded one.)

---

## 2026-07-06 wave — 39 code-less-but-visited clients coded (247–285)

Fred: "every client with a 2026 Jobber visit should be in the DB and have a code." Audit (4-agent workflow + adversarial critique) confirmed **all 220 Jobber-2026-visit clients were already in the DB** (0 missing), and **39** of them were code-less. Assigned `247`–`285` sequentially by created_at (2 tweaks: DUMP Pompano → `000-DP` dump-band, Millennium Mgmt → `271-MLN` to avoid a confusable "MM" dup with Mr. Madar) — all verified free across DB+Airtable+Jobber. **26 commercial + 13 residential** (10 person-name + 3 companyName-carriers).

**Write mechanism (the canonical client-code push):** `clientEdit(clientId, input:{companyName})` sets Jobber Company Name to `"<code> <name>"`, composed from a **fresh per-client Jobber read** with any existing `NNN-XX ` prefix stripped (never stack), `userErrors` checked, re-read to verify, **skip-if-already-correct**. Saga per client with strict rollback (DB `client_code` reverted to NULL if the Jobber push fails). Uses the write app (`jobber_write`) — but that app currently **lacks `write_clients` scope** (add it in the Jobber Developer Center + re-auth; the 2026-07-06 wave used the read app `jobber`/fbd14714 token which already carries `write_clients`). Backup: `backups/2026-07-06_client_code_wave_backup.json`; apply script recorded in this repo. Result: 39/39 DB=Jobber parity, 0 code-less-with-2026-visits remaining. The **echo is idempotent** — the */5 poll re-ingests the renamed client, `handleClient` parses our own code back (`cur.client_code` already set → no heal fight; name write is prefix-stripped-identical).

---

## 2026-08-12 — the `247` collision, and what it proves about the check

**Two live clients shared the number 247 for five weeks**, and nothing surfaced it. Resolved on
Fred's instruction by renumbering Excelsior Condo **`247-EC` → `300-EC`** (Jobber custom field +
display name first, verified by re-read, then `public.clients`; backup in
`..\..\backups\2026-08-12_renumber_excelsior_before.json`).

**How it happened, from `audit.logs` rather than from reasoning:**

| when | what |
|---|---|
| 2026-07-03 | `Skinny Louie Coral Gables` imported from Jobber with `client_code` **NULL** |
| 2026-07-06 | the bulk wave assigns **`247-EC`** to Excelsior Condo (`app_source='sql'`). 247 was genuinely free. |
| 2026-07-14 | Skinny Louie gets **`247-LOU`**, arriving via `app_source='jobber'` — i.e. **a human typed it into Jobber**, eight days later |

🛑 **THE LESSON: THE COLLISION CAME IN THROUGH JOBBER, AND NOTHING IN THE SYSTEM COULD SEE IT.**

- **Jobber enforces nothing.** It has no concept of our numbering. Both records look perfectly normal
  in its UI: `Excelsior Condo - 247-EC` and `Skinny Louie Coral Gables - 247-LOU`, each with its own
  `Client Code` custom field. Nothing anywhere shows that they share `247`.
- **Our only constraint is on the WHOLE STRING.** `clients_active_client_code_uniq` is
  `UNIQUE (client_code)`, and `247-EC` ≠ `247-LOU`, so it never fired. The rule at the top of this
  document says the NUMBER is the identity and the tag is cosmetic — **and that had never been
  enforced by anything, anywhere.**
- **`handleClient`'s duplicate guard also keys on the exact code**, so the `*/5` poll imported
  `247-LOU` without a murmur.
- **The `create-client` reservation added the same day does NOT close this hole.** It makes two
  concurrent *app* creates mutually exclusive on both the code and the number, but a person typing a
  code straight into Jobber never touches that path. **This remains open.** Closing it would mean a
  number-aware guard in `handleClient` (warn, not block — `000-DP`/`000-DH` is a legitimate shared
  band) or a periodic sweep.

**What to do about it in the meantime:** when assigning a code by hand, check the **number**, not the
code:

```sql
select client_code, name, status from public.clients
 where client_code like '247-%';      -- NOT  = '247-EC'
```

⚠ And do not read "no rows" from `= '<full code>'` as "the number is free". That is the same
one-directional mistake the duplicate NAME check had, and it is why this pair survived five weeks.
