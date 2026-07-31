# Jobber client naming + the `Client Code` custom field

*2026-07-31 · Executed by the Supabase session on Yannick's ask, Fred approved after reviewing
three verification scenarios. This is the reference for how client identity now flows from Jobber.*

---

## The convention (as of 2026-07-31)

| | before | after |
|---|---|---|
| Jobber Company Name | `027-HER Herzka Residence` | `Herzka Residence - 027-HER` |
| Jobber custom field | *(did not exist)* | **`Client Code` = `027-HER`** |
| `public.clients.name` | `Herzka Residence` | `Herzka Residence` *(unchanged)* |
| `public.clients.client_code` | `027-HER` | `027-HER` *(unchanged)* |

The DB shape is deliberately **identical before and after** — the whole point of the sync change
was that the convention flip must not disturb canonical data.

`Client Code` custom-field configuration GID (ALL_CLIENTS, text):
`Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzgyNTkyNw==`

## 🛑 The rule that makes it safe — do not regress it

**`webhook-jobber`'s client handler must NEVER go back to deriving the code from a name prefix.**
It reads the **custom field** first, then strips the code out of the display name *wherever it
sits* (suffix → parenthetical → legacy prefix). The old parser matched `^NNN-XX ` and stored the
remainder as `clients.name`; against `Herzka Residence - 027-HER` it matches nothing and stores the
**whole string, code included**, as the client's name — measured to affect all **274** renamed
clients within one `*/5` poll, propagating to every app that renders a client name.

Live proof this failure is real, not theoretical: **`131-M&U`** was the one client whose stored
name still carried its prefix, because the old character class was `[A-Z0-9]*` and could not match
`&`. It was a working preview of the fleet-wide bug; healed by a webhook replay after the fix.

## What was changed, and what was deliberately not

Measured across **453** Jobber clients (**438** linked to our DB):

| bucket | n | action |
|---|---|---|
| code is a name prefix | 268 | strip prefix → `name - CODE`, set field |
| code in parentheses | 1 | `Yan's Restaurant ( 112-YA )` → `Yan's Restaurant - 112-YA` (**not** doubled) |
| code in DB, absent from name | 5 | append → `Pari Pari - 298-PAR`, set field |
| **no `client_code` in our DB** | **162** | **SKIPPED — no rename, no field written** |
| not linked to our DB | 17 | skipped |

**Skip, never invent.** Writing a blank `Client Code` would make those 162 look "done" in Jobber
and hide that they still need codes assigned. They are leads, residential and inactive records.

## Execution order (repeat this if it is ever redone)

1. **Sync first.** Teach `webhook-jobber` to read the field. Deploy. *Nothing in Jobber has moved
   yet, so this is a no-op in production and pure insurance.*
2. **Field backfill** — additive, no name touched, fully reversible by clearing the field.
3. **Rename** — only after the field is verified populated.

Doing 3 before 1 corrupts every client name. Doing 3 before 2 leaves a window where the code exists
in neither the field nor a parseable prefix.

## Idempotency + verification

The backfill (`scratchpad/cc_backfill.js`, dry-run by default, `--field` / `--rename` / `--only=` /
`--limit=`) **re-reads each client live before writing** and skips anything already correct — it
never trusts its own snapshot for an idempotency decision. Every write is **read back** and
compared; a mismatch raises rather than counting as success.

Final verification, run independently against the API after the fact:

```
274/274 in the new "name - CODE" format
274/274 Client Code fields exactly match our DB
0 names still carrying an old prefix (i.e. zero doubling)
0 failures across 274 field writes + 274 renames
DB: 0 coded clients whose clients.name contains a code
```

## Traps caught along the way (all cost a real failed attempt)

- **`ClientEditInput`, not `ClientEditAttributes`.** Jobs use `*Attributes`, clients use `*Input`.
  Caught by a single-client canary before any fleet write.
- **The webhook payload shape** for a manual replay is `{topic, webHookEvent:{itemId}}` where
  `itemId` is the **base64 GID**, not the numeric id. HMAC-SHA256(base64) with the **read** app's
  `client_secret` (the webhook is registered under the read app).
- **Codes contain `&`.** Any regex over client codes must use `[A-Za-z0-9&]`, never `[A-Z0-9]`.
- **A shell-authored regex is not a regex.** The first classifier was built with a heredoc; bash ate
  the backslashes (`\s` → `s`) and it silently reported that every client needed its code appended,
  which would have produced `027-HER Herzka Residence - 027-HER` across 268 live clients. Regexes
  for this work live in **files, as literals, with positive controls that fail loudly**.
