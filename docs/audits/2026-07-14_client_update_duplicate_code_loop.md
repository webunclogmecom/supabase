# jobber CLIENT_UPDATE 18% error rate — diagnosis + INSERT-path hardening (2026-07-14)

**Trigger:** the Building Apps session flagged `jobber` `CLIENT_UPDATE` webhooks erroring **~18%
(966 / 5378) over 12 days** — a pipeline-health signal. Fred asked me to dig in.

## Finding — a historical loop from ONE duplicate client, already self-resolved

- The 966 failures are a **burst 2026-07-02 → 07-06** (~285/day), then it stops (only 2
  token-expired + 1 HMAC since; **0 duplicate-key failures in the last 3 days**). Not ongoing.
- **963 of the 966 are the SAME client:** `gid://Jobber/Client/113794289`, every ~5 min, each
  failing `Client update failed: duplicate key value violates unique constraint
  "clients_active_client_code_uniq"` (partial unique on `client_code WHERE status <> 'INACTIVE'`).
- That GID = **DB client 153** — "International Foods By Noni (Arepas Noni)", ACTIVE, `client_code =
  NULL`. It is a **Jobber-side DUPLICATE** of **client 152** (same business, `client_code = 145-NON`,
  ACTIVE, gid 113794149). Yan created the business twice in Jobber, both named "145-NON …".
- **Mechanism:** the handler's client-code self-heal saw client 153 had a NULL code and a Jobber name
  prefix "145-NON", so it tried to write `145-NON` onto 153 → collided with 152's active code → 23505
  → the */5 poll re-threw + replayed the same CLIENT_UPDATE forever.
- **Already fixed:** the UPDATE path got a guard on **2026-07-05** (only heal the code if no other
  non-INACTIVE client holds it). That's why the failures stop 07-06. The 18% is a *pre-guard*
  artifact in Building Apps' 12-day window — not a live problem.

## Fix — close the symmetric INSERT-path gap

The 2026-07-05 guard covered the UPDATE path only. The INSERT path (a brand-new Jobber client whose
name-parsed code collides with an existing active client) still set the code unconditionally and would
loop-fail the same way. Mirrored the guard in `webhook-jobber/index.ts` handleClient INSERT branch:
if a non-INACTIVE client already holds `parsedCode`, **drop the code and insert the client codeless**
(Jobber GID is source of truth); the existing `client_insert_potential_dup` warning + weekly dedup
audit surface it. Deployed to Prod (`wbasvhvvismukaqdnouk`). This is proactive hardening — no client
was hitting the INSERT path in the burst.

## Jobber cross-check (2026-07-14, Fred: "I don't see that dupe in Jobber")

Verified live against Jobber GraphQL — **the dupe is real in Jobber, not a DB artifact:**
`clients(searchTerm: "Noni")` → **totalCount 2**, both `isArchived: false`, same email
`arepasbynoni@gmail.com`, same billing `17030 West Dixie Highway, North Miami Beach FL 33160`, both
with jobs. So the DB faithfully mirrors Jobber (no sync staleness).

**Why it's easy to miss + the real tangle:** the two records are crossed vs our codes —
- **113794149** → DB **152**: Jobber name has **no code prefix** ("International Foods By Noni (Arepas
  Noni)"), `isCompany=true`, **2 jobs** incl. the recurring **Service Agreement** (job 815). Our DB
  put `client_code=145-NON` here (from Airtable enrichment), commercial.
- **113794289** → DB **153**: Jobber name **carries the "145-NON" prefix**, `isCompany=false`
  (residential), **1 job** (Service Call). Our DB left this one `client_code=NULL`.

So a Jobber search by **code "145-NON"** only surfaces 113794289 (the prefixed one) — the *other*
record hides under the plain "International Foods By Noni" name, which is likely why the dupe isn't
obvious in the UI. Neither client has any **visits or manifests** yet (jobs only, no service history).

## Broader duplicate-client scan (Fred asked, 2026-07-14)

Scanned ALL non-INACTIVE clients for the same pattern. Method: same-contact-email groups (37 — but
mostly legitimate CHAINS/management contacts, e.g. Pura Vida, Grove Kosher, Bagel Boss, town-of-
Surfside — NOT dupes); then narrowed to **same email AND same billing address** (12 candidate pairs);
then a 12-agent adversarial workflow (`dup-client-classify2.js`) classified each pair as
true-duplicate vs distinct co-located business using DB + live-Jobber data (names, codes, jobs,
visits, manifests, isCompany).

**Confirmed TRUE DUPLICATES — 3 (redundant twin = placeholder/stub, null code, 0 visits/manifests):**
| business | keep (canonical) | retire (redundant) | tell-tale |
|---|---|---|---|
| **Ava** (Coconut Grove) | 305 `168-AVA` "AVA" (23 visits) | **175** "Ava Coconut Grove **(NOT USE)**" (null code, 0 visits) | Jobber name literally says NOT USE |
| **Arepas Noni** | 152 `145-NON` | **153** (null code; Jobber name carries 145-NON = the code cross-up) | see above |
| **Ironside / Kaffe** | 222 `171-CAF` Ironside Cafe | **223** "**000-** Kaffe" (null code, 0 visits, stub property, isCompany=false) | *medium conf* — verify "Kaffe" isn't a genuine 2nd tenant in the Ironside complex |

**Verify before any action — 1:** **P4** — 476 "CU4 / HRB Wynwood LLC" is an empty placeholder (0
jobs/visits, null code, created 06-08) at the Wynd 28 building (233 `242-WYN`). Likely a distinct new
unit not yet serviced, but has the redundant-stub fingerprint — Fred to confirm.

**Distinct co-located (no action) — 8:** G7 Kitchens 34 / Kitchen 35; G7 Roof Top / G7 Kitchens; Mrs.
Pasta / Mr. Pasta Factory; Meir Fellig / Pummarola; Lettuce & Tomato / L&T Bakery; True Barista
grease-trap / temp-truck; MGM Construction / KC Market; Pura Vida Brickell 701 / Pura Vida Brickell
(two chain locations). Each side has its own code + real service history (visits + DERM manifests).

Merging any confirmed dupe is a **manual decision** (Rule 6 — soft-delete only; repoint the Jobber
GID + jobs to the canonical, then set the twin INACTIVE). All 3 redundant twins have 0 visits/0
manifests, so no service history is lost.

## Flagged for Fred/Yan — the real root of the CLIENT_UPDATE loop: a duplicate client

**Clients 152 + 153 are one business (Arepas Noni) entered twice in Jobber.** 152 holds `145-NON`;
153 is ACTIVE with a NULL code. This should be **merged** (link both Jobber GIDs to one DB client) or
one Jobber record archived — a manual decision (per the handler's own comment, "collapsing the two
Jobber records is a manual merge decision"). Until then, 153 shows as a separate code-less Arepas Noni
in reports/apps. Spawned a task for it.
