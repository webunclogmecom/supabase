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
- **Next number = (highest normal number, i.e. < 700) + 1.** As of **2026-07-06** the max normal is `285-NAH`, so the next is `286` (a 39-client wave assigned `247`–`285` — see the 2026-07-06 note below).

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

## The golden rule: the NUMBER must be free in **all three systems**

Before assigning a number, verify it is unused in **DB + Airtable + Jobber**. A DB-only check is NOT
enough: Airtable or Jobber can hold a code that hasn't been written back to `public.clients.client_code`
yet. (Real incident: *Jerusalem Pizza* was `226-JER` in Airtable but `NULL` in the DB, so an Aromas
`214→226` rename collided with it.)

Tooling:
```bash
# verify a candidate number (and optionally the exact code) across DB + Airtable + Jobber
node scripts/probes/check_client_code_available.js 243          # exit 0 = free, 1 = collision
node scripts/probes/check_client_code_available.js 243 PV       # also checks exact code 243-PV

# propose the next valid code for a client name (auto: brand-reuse + next free number + 3-source check)
node scripts/probes/propose_client_code.js "Pura Vida Coconut Grove"
node scripts/probes/propose_client_code.js "Joe's Bagels" --new   # force a brand-new tag
```

---

## Procedure to create a new code
1. **Tag** — if the client is a new location of a brand already in the DB, **reuse that brand's tag**
   (a new Pura Vida = `…-PV`). Otherwise coin a new 2–4 char tag from the name.
2. **Number** — take the next sequential number (highest normal + 1).
3. **Verify** — run `check_client_code_available.js <number> <tag>`; if it reports a collision, bump the
   number by 1 and re-check until free in all three systems.
4. **Assign** — write `client_code` on `public.clients` (and keep it consistent in Airtable/Jobber).

---

## Edge cases & gotchas
- **The number is the identity; the letters are cosmetic.** Two unrelated brands *could* share letters; the number keeps them distinct. Never rely on the tag for uniqueness.
- **INACTIVE tombstones may share a code with their ACTIVE successor** — that's the *same* client, not a collision (e.g. `050-PV` has one ACTIVE row + one old INACTIVE row, both Pura Vida Brickell).
- **Don't backfill gaps**; don't reuse a retired number.
- **Reserved band (700+)** is for vanity/special codes — don't auto-assign from it.
- **Residential / no-code clients**: historically many Jobber clients had no `client_code` (residential, call-only). **Superseded by Fred 2026-07-06:** any client that had a **2026 visit** gets a code regardless of type/status (incl. residential person-name accounts). For a residential (`isCompany=false`) client, write the code into Jobber **Company Name** as `"<code> <FirstName LastName>"` (e.g. `281-MA Mr. Avi`) and **leave firstName/lastName untouched** — the code is then searchable in Jobber without corrupting the person's name (note: the webhook parser reads first/last for `isCompany=false`, so a companyName code doesn't round-trip through it, but the DB `client_code` is authoritative). Never-visited leads/one-offs (~160) are still intentionally left uncoded pending a separate decision.
- **Renames/renumbers** are the riskiest operation — always run the 3-source check first (that's exactly what the check script exists for).

---

## 2026-07-06 wave — 39 code-less-but-visited clients coded (247–285)

Fred: "every client with a 2026 Jobber visit should be in the DB and have a code." Audit (4-agent workflow + adversarial critique) confirmed **all 220 Jobber-2026-visit clients were already in the DB** (0 missing), and **39** of them were code-less. Assigned `247`–`285` sequentially by created_at (2 tweaks: DUMP Pompano → `000-DP` dump-band, Millennium Mgmt → `271-MLN` to avoid a confusable "MM" dup with Mr. Madar) — all verified free across DB+Airtable+Jobber. **26 commercial + 13 residential** (10 person-name + 3 companyName-carriers).

**Write mechanism (the canonical client-code push):** `clientEdit(clientId, input:{companyName})` sets Jobber Company Name to `"<code> <name>"`, composed from a **fresh per-client Jobber read** with any existing `NNN-XX ` prefix stripped (never stack), `userErrors` checked, re-read to verify, **skip-if-already-correct**. Saga per client with strict rollback (DB `client_code` reverted to NULL if the Jobber push fails). Uses the write app (`jobber_write`) — but that app currently **lacks `write_clients` scope** (add it in the Jobber Developer Center + re-auth; the 2026-07-06 wave used the read app `jobber`/fbd14714 token which already carries `write_clients`). Backup: `backups/2026-07-06_client_code_wave_backup.json`; apply script recorded in this repo. Result: 39/39 DB=Jobber parity, 0 code-less-with-2026-visits remaining. The **echo is idempotent** — the */5 poll re-ingests the renamed client, `handleClient` parses our own code back (`cur.client_code` already set → no heal fight; name write is prefix-stripped-identical).
