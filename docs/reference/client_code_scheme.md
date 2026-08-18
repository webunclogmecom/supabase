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
- A short mnemonic derived from the client **name**.
  ⚠ **EXISTING tags are 2 to 4 chars and stay valid** (`PV`, `LG`, `BB`, `BC`, `CN` are all live).
  **NEWLY COINED tags are always exactly 3**, because `coinTag` in `create-client` ends with
  `.slice(0, 3)` after topping up. Describe the data as 2-4; coin at 3.
- **SHARED across every location of the same brand/chain.** A chain gets ONE tag; each location gets its own number:
  - `PV` = Pura Vida (26 locations), `TCE` = The Carrot Express (23), `LG` = La Granja (6), `BB` = Bagel Boss, `GRO` = Grove Kosher, `LOU` = Skinny Louie…
- Coining a tag for a **new** brand:
  - Drop noise words: `The`, `LLC`/`Inc`/`Corp`, `Miami`, `Restaurant`, `Cafe`.
  - Use initials or a recognizable short form: *Vincenzos*→`VIN`, *Cine Citta Cafe*→`CCC`,
    *The Joyce*→`JOY`.
  - 🛑 **The two-letter examples this line used to give are now WRONG as guidance**, though the
    codes themselves are live and correct. `coinTag` today takes the first three initials for a
    3+ word name, and for a 1-2 word name takes `w[0].slice(0,3)` topped up from the second
    word. So *Bagel Cove* coins **`BAG`** (not `BC`) and *Casa Neos* coins **`CAS`** (not `CN`).
    Do not "restore" the old examples: they describe how those specific clients were coded by
    hand years ago, not what the generator will propose now.
  - 🛑 **A TAG IS LETTERS. A LEADING NUMBER IN THE NAME IS SKIPPED, NEVER USED AS THE TAG**
    (Fred, 2026-08-17 — this REVERSES the previous rule, which read *"A leading number in the name
    can BE the tag: 41 Pizza and Bakery→41"*). So *1681 Lenox - Excel Plumbing Services inc.*→`LEP`,
    *9072 Froude LLC*→`FRO`, *609 Lenox LLC*→`LEN`, *16 Handles*→`HAN`.
    Fred hit it on the Generate button: `1681 Lenox…` proposed **307-1681**, and the field's own
    hint says the format is `123-ABC`.
    - ⚠ **Only a LEADING number is skipped. Digits later in the name still count**, and that is
      deliberate: *Wynd 28*→`W2`, *Pura Vida 41*→`PV4`, *Kitchen 35*→`K3`. Filtering every numeric
      word was written, measured and **rejected** — it changed the tag for 7 clients whose names do
      not start with a number and collapsed *Wynd 27* and *Wynd 28* both to `WYN`.
    - ⚠ **The 5 pre-existing numeric codes are NOT being changed**: `002-41` (41 Pizza and Bakery),
      `142-57`, `174-17`, `272-1265`, `306-16`. A live `client_code` change is a rename that pushes
      to Jobber's `companyName` **and** its `Client Code` custom field and strands `visits.title`
      rows — the Excelsior renumber needed exactly that cleanup. Only the **proposer** changed.
    - ⚠ **Those 5 tags will still PROPAGATE to siblings, and that is correct.** Tag-reuse for a known
      brand runs *before* coining, so a second *41 Pizza* location legitimately reuses `41`. Sibling
      consistency outranks the letters-only preference; do not "fix" that.
    - ✅ Corroboration the rule matches human judgement: *9072 Froude LLC* now coins `FRO`, and the
      code a human actually assigned that client is **121-FRO**.
  - Pick something not visually confusable with an existing tag for an unrelated brand.
  - ⚠ Two-letter tags are normal, not a bug: `042-MT`, and *57 Ocean Residences*→`OR`.

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

#### Removing a code (added 2026-08-18)

**A code can be REMOVED, and this page used to imply it could not.** Fred: *"We need to be able to put
an empty client code and it updates to be a empty client code."* Send `client_code: ""` to
`save-client-fields`; it clears **all three surfaces** — our column, Jobber's ` - CODE` suffix on
`companyName`, and Jobber's **Client Code custom field** — then verifies by re-read.

- ⚠ **Omitting `client_code` still means "leave it alone". An EMPTY STRING means remove.** One NULL
  cannot carry both meanings, which is why `fn_record_client_identity` gained an explicit
  `p_clear_code` flag rather than a sentinel. Before that its
  `client_code = coalesce(p_client_code, c.client_code)` made removal impossible at the DB layer, and
  clearing `609 Lenox LLC` needed a hand-written one-off that bypassed the saga.
- 🛑 **The custom field must be ACTIVELY cleared, not omitted.** `webhook-jobber`'s parser reads that
  field FIRST, so a stale value heals the code straight back on the next `*/5` poll and the removal
  silently undoes itself.
- **Does removal free the number for re-use?** Yes, mechanically: `clients_active_client_number_uniq`
  excludes NULL codes, so nothing stops the number being taken again. **That does not overrule the
  "do not backfill gaps" rule above** — a removal is for a client that should carry no code, not a way
  to recycle numbers. Take the next number up unless Fred says otherwise.

Full reasoning and the two-sided assertions:
[`docs/migrations/2026-08-18_0030_client_identity_allow_code_removal.sql`](../migrations/2026-08-18_0030_client_identity_allow_code_removal.sql).
App-side rules: `Building Apps/Client App/CLAUDE.md` item 2m.

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
- **Residential / no-code clients**: historically many Jobber clients had no `client_code` (residential, call-only). **Superseded by Fred 2026-07-06:** any client that had a **2026 visit** gets a code regardless of type/status (incl. residential person-name accounts). For a residential (`isCompany=false`) client, write the code into Jobber **Company Name**.
> 🛑 **CORRECTED 2026-08-13 — THE TWO SPECIFICS BELOW WERE BOTH STALE.** This used to say the format
> is a PREFIX, `"<code> <FirstName LastName>"` e.g. `281-MA Mr. Avi`, and that you should **leave
> firstName/lastName untouched**. Measured against nine coded clients in Jobber, neither holds:
> ```
> 281-MA   companyName "Mr. Avi - 281-MA"        firstName "Mr. Avi - 281-MA"    lastName ""
> 251-AS   companyName "Andrew Saka - 251-AS"    firstName "Andrew"   lastName "Saka - 251-AS"
> 297-MAR  companyName "Mark Aquinin - 297-MAR"  firstName "Mark"     lastName "Aquinin - 297-MAR"
> 300-EC   companyName "Excelsior Condo - 300-EC" firstName "Excelsior Condo - 300-EC"
> 295-NAD  companyName "Blue Suede Hospitality Group - 295-NAD"  firstName "Adam Nadler - 295-NAD"
> ```
> The live convention is a **SUFFIX** (`"<Name> - <code>"`), confirmed by Fred 2026-08-13
> (*"add the new clients codes on jobber suffix and in the custom field client code"*), and the code
> lands in **both** `companyName` **and** the first/last field, not companyName alone. `281-MA`, the
> example this document used for the prefix rule, is itself a suffix.
>
> ⚠ **The "don't corrupt the person's name" concern is real and is NOT resolved by current practice.**
> For `isCompany=false`, Jobber's display `name` is first+last, so `302-SAR` now reads
> *"Allison  Sarbin - 302-SAR"* to the client. Six existing clients are already like this, so it is
> the norm rather than a mistake, but if a code should never appear on client-facing output the fix
> is to set `companyName` only and restore first/last across all of them — a decision, not a cleanup.

**Also set the `Client Code` custom field** (Text, `ALL_CLIENTS`) to the bare code. Added by Yannick
2026-07-31 and it is now the **authoritative** source: `webhook-jobber` reads that field first and
only falls back to parsing the name. It also strips a trailing ` - CODE` from the display name, so
`public.clients.name` stays the clean business name through both naming conventions. Never-visited leads/one-offs (~160) are still intentionally left uncoded pending a separate decision.
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
  code straight into Jobber never touches that path.

> ✅ **CLOSED 2026-08-17 for every path that goes through us** (`2026-08-17_2355`, `efa470a`), after
> it recurred: Fred set `609 Lenox LLC` to **`168-609`** while **`168-AVA`** already held 168, from
> the Client App's Edit dialog, and every guard let it through for exactly the reason described
> above. **The app-side guards compared the whole string too** — `save-client-fields` did
> `.eq("client_code", targetCode)` and `create-client` the same — so the "our only constraint is on
> the WHOLE STRING" problem was three layers deep, not one.
>
> **`clients_active_client_number_uniq`** is now `UNIQUE (split_part(client_code,'-',1))`
> `WHERE client_code IS NOT NULL AND status <> 'INACTIVE' AND client_code NOT LIKE '000-%'`.
> Both edge functions check the number as well, so a collision returns a sentence naming the current
> holder instead of a raw `23505`. Verified by replaying Fred's exact edit: it now raises
> `23505 … Key (split_part(client_code, '-'::text, 1))=(168) already exists`, with a free number as
> the positive control so the rejection is not just "the index refuses everything".
>
> **The two exemptions are deliberate and must stay:** the `000` dump band shares a number by design
> (`000-DP` / `000-DH`), and `INACTIVE` is excluded so a retired client frees its number — two live
> pairs depend on that (`050-PV`, `239-COM`, each with one INACTIVE member).
>
> ⚠ **`create-client`'s number check used to be a WARNING on purpose**, justified by this very
> incident ("`247-EC`/`247-LOU` shows it also happens by accident, so: warn, never block"). That
> justification had **expired** — measured 2026-08-17, only `247-LOU` survives, and the only shared
> numbers left in the table are the two deliberate exemptions. A rule kept alive by a precedent that
> no longer exists is worth re-checking before quoting it.
>
> ✅ **THE JOBBER-SIDE PATH IS CLOSED TOO, SAME DAY.** For a few hours the index made an incoming
> collision **error** for that client, which was a real hazard rather than a theoretical one: writing
> a colliding number raises `23505`, `handleClient` throws `Client update failed`, and the `*/5` poll
> re-delivers the same `CLIENT_UPDATE` forever. **That is exactly the 288-failures/day `145-NON`
> replay loop** the full-string guards in that file were written to stop, one identity level up.
>
> `webhook-jobber` now carries **`liveNumberHolders()`**, used by BOTH the UPDATE heal branch and the
> INSERT branch. The client always syncs; only the **code** is withheld, and a
> **`client_code_number_collision`** warning row is written to `webhook_events_log` naming the current
> holder. Reporting matters here specifically: the pre-existing collision branch is deliberately
> silent because a code-keyed dedup audit would find it later — **a NUMBER collision is invisible to a
> code-keyed audit**, so nothing else would ever surface it.
>
> ⚠ **`liveNumberHolders` fails SAFE, and safe means WITHHOLDING the code.** A discarded error would
> return `[]`, read as "the number is free", and produce the 23505 and the loop. Claiming a collision
> costs a NULL code and a warning row; claiming freedom costs the sync.
>
> **Verified end-to-end 2026-08-17** by planting `168-609` back on the real Jobber record for
> `609 Lenox LLC`, flagging `needs_populate` and invoking `sync-jobber-poll` so the poll signed and
> POSTed the `CLIENT_UPDATE` itself:
>
> | check | result |
> |---|---|
> | `needs_populate` TRUE → FALSE | the replay actually ran — **the control**; without it "no failures" proves nothing |
> | client 160 | synced, name intact, `client_code` still **NULL** |
> | `webhook_events_log` | one `client_code_number_collision` warning naming `305/168-AVA/AVA` |
> | failures | **zero** |
>
> Jobber was reverted to the bare name afterwards, verified by re-read.
>
> ⚠ **The UPDATE path was exercised; the INSERT path was NOT.** It is the symmetric guard and was
> verified by reading, but exercising it needs a *new* Jobber client carrying a colliding code, and
> Jobber has no client delete — the residue is not worth it. Treat it as deployed-and-reviewed rather
> than proven.

**What to do about it in the meantime:** when assigning a code by hand, check the **number**, not the
code:

```sql
select client_code, name, status from public.clients
 where client_code like '247-%';      -- NOT  = '247-EC'
```

⚠ And do not read "no rows" from `= '<full code>'` as "the number is free". That is the same
one-directional mistake the duplicate NAME check had, and it is why this pair survived five weeks.

### ⚠ A RENUMBER DOES NOT REACH `visits.title`, AND THAT IS ESTATE-WIDE, NOT A BUG THIS RENUMBER CREATED

Immediately after the Excelsior renumber the Client App's activity timeline still showed
**`247-EC Excelsior Condo - Service Call`**. Measured rather than assumed:

- `jobs.title` holds plain `Service Call` — **no code**. Zero job titles anywhere embed one.
- `visits.title` holds the full Jobber-composed label, frozen at the time the visit was created,
  from the **old prefix-era** naming (`NNN-XX Name`), and nothing updates it afterwards.
- **56 live visits estate-wide** carry a title whose embedded code no longer matches their client
  (control: 1,615 live titles embed a code at all, so the zero-cases are meaningful).
  **53 of those predate this renumber**; Excelsior contributed 3.

**Whether a DB-side fix would stick depends on `visits.source`:**

| source | n | fixable in our DB? |
|---|---|---|
| `jobber` | 40 | **no** — Jobber-mastered, the poll rewrites `title` |
| `supabase_cron` | 13 | yes, `handleVisit` does not clobber ours |
| `visit-calendar` | 3 | yes, same |

`handleVisit` (webhook-jobber ~:755-775) refuses to touch `title` for visits we master
(`visit-calendar` / `supabase_cron`) and does write it for Jobber-mastered ones.

**UPDATE — Fred: *"fix those 3 visit titles too."* The three Excelsior ones WERE fixed** (this section
first said "nothing was changed", which was true for about an hour). `247-EC …` → `300-EC …` on visits
**7076, 7463, 7688**, in BOTH systems. **The other 53 are still untouched and still Fred's call.**

🛑 **THE INSERT PATH WOULD HAVE DOUBLE-PREFIXED IT — `trg_prefix_visit_title`.** That trigger
prepends `"<current code> <name> - "` to a `visit-calendar` / `supabase_cron` visit whose title does
not already start with the client's **current** code, so writing a bare base title produces:

```
300-EC Excelsior Condo - 247-EC Excelsior Condo - Service Call
```

The fix therefore writes the **full corrected string**, which already starts with `300-EC ` and makes
the trigger a no-op. Verified afterwards: **0 double-prefixed titles estate-wide.**

> 🛑 **CORRECTED 2026-08-18 — this block used to say the trigger also fires when "touching any other
> column on that row", i.e. on any UPDATE. THAT IS FALSE, and it is the kind of sentence that gets
> quoted into an app doc as a rule.** Measured against Prod:
> `CREATE TRIGGER trg_prefix_visit_title **BEFORE INSERT** ON public.visits FOR EACH ROW EXECUTE
> FUNCTION fn_prefix_visit_title()` — and it is the only trigger on `public.visits` that calls that
> function (checked `pg_trigger` joined to `pg_proc`, not the name). `2026-06-29e` agrees and no later
> migration recreates it.
> ⇒ **An UPDATE cannot double-prefix.** Every Visit Calendar title edit is an UPDATE (they route
> through `visitEdit`), so there is no such hazard there and the rule must NOT be copied into
> `Visit Calendar/CLAUDE.md`. What remains true is the narrower statement above: writing a BARE base
> title on an INSERT gets the prefix, which is why the fix wrote the full corrected string.

⚠ **It also pushes to Jobber, and that is wanted.** Jobber held the same stale title on all three, so a
DB-only fix would have left permanent drift. `trg_push_visit_update` fires `changed:['title']` and
`jobber-push-visit` (~line 415) sets **only** `attrs.title`; the complete/uncomplete path requires
`"completion"` in `changed`, which a title-only edit never adds. **All three are COMPLETED visits and
stayed completed** — same `completed_at` and `completed_by` (Diego, Grecia, Grecia) on our side, and
`COMPLETED` with `completedAt` intact in Jobber.

Backup: `..\..\backups\2026-08-12_excelsior_visit_titles_before.json`. Estate-wide stale count went
**56 → 53**, which is exactly the three.

⚠ **And do not "fix" the `audit.logs` copies.** 35 audit rows carry `247-EC` in their row snapshots.
Those are the record of what the values WERE, which is the entire point of an audit trail.
