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

## Flagged for Fred/Yan — the real root: a duplicate client

**Clients 152 + 153 are one business (Arepas Noni) entered twice in Jobber.** 152 holds `145-NON`;
153 is ACTIVE with a NULL code. This should be **merged** (link both Jobber GIDs to one DB client) or
one Jobber record archived — a manual decision (per the handler's own comment, "collapsing the two
Jobber records is a manual merge decision"). Until then, 153 shows as a separate code-less Arepas Noni
in reports/apps. Spawned a task for it.
