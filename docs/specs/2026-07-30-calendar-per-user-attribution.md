# Per-user attribution for verified Calendar saves

*Spec only. No migration written, no DB change made, no edge function deployed. Audited 2026-07-30
against Prod `wbasvhvvismukaqdnouk`.*

---

## Headline: the premise was wrong. NO NEW COLUMN IS NEEDED, on `visits` or anywhere else.

@Building Apps and I both wrote that this needs "a column on `visits`", and I repeated it in
`2026-07-29d`'s header and in my reply to them. **Measuring first says otherwise:**

> **`audit.log_change` ALREADY captures an actor header.** It reads `x-actor-name` and stores it at
> `request_context.actor_name` (capped 120 chars). `webhook-jobber` has used exactly this since
> 2026-06-26 (P2b) via a dedicated per-write client, and **143 audit rows carry it today**.
> `get_record_history` already renders it.
>
> So this is a **two-line reuse of a proven mechanism**, not a schema change, and it needs no ADR-010
> opt-in decision.

This is the same lesson as the properties RPC cutover earlier tonight: the thing was already built, and
the only reason we were about to build it again is that nobody measured before designing.

## Measured state

```
audit.logs total rows                                    46,387
  rows with changed_by NOT NULL                               0     <- see below
  rows with jwt_claims->>'email'                          3,013
  rows with request_context->>'actor_name'                  143     (all app_source='jobber')
visits rows                                              14,610
  visits rows with jwt_claims->>'email'                   2,029
  app_source='visit-calendar' visits rows                  2,068
    ...of those, WITH an email                            2,015    (97.4%)
    ...of those, WITHOUT an email                            53    <- the verified path joins this bucket
ops.get_record_history                                   a WRAPPER over public.get_record_history
                                                         (619 chars) -> only ONE body to change
```

**🛑 `changed_by` IS A DEAD COLUMN: 0 of 46,387 rows. Do not try to revive it as the fix.** It is
populated from `current_setting('request.jwt.claim.sub')`, so it has never worked for anything, not
just for us. Making it work would require calling the RPC with the **caller's own JWT**, and
`edit_calendar_visit_verified` is deliberately `service_role`-only precisely so a caller cannot reach
it directly. Those two requirements are mutually exclusive. Attribution today comes from
`jwt_claims->>'email'`, not from `changed_by`.

**⚠ A finding neither of us noted, and it is worse than "unattributed".** `get_record_history` takes
`p_hide_system boolean DEFAULT true`, and that filter suppresses `app_source IS NULL OR = 'sql' OR LIKE
'other:%'`. So while verified saves were landing as `'sql'`, they were **not merely mislabelled in the
Activity history, they were INVISIBLE in it by default.** The `x-app-source` fix shipped in `e58ee34`
already makes them visible; this spec is only about naming the person.

## How `get_record_history` actually names a human

The human-app branch does **not** use `actor_name`. It uses the email, then maps it to a real name:

```sql
WHEN s.app_source IN ('visit-calendar','field-portal','derm-tracker','admin-review')
  THEN 'Edited in ' || initcap(replace(s.app_source,'-',' '))
    || COALESCE(' by ' || (SELECT e.full_name FROM public.employees e
                            WHERE lower(e.email) = lower(s.actor_email) ...),
                CASE WHEN actor_email <> '' AND actor_email <> 'unclogme@unclogme.com'
                     THEN ' by ' || s.actor_email ELSE '' END)
```

`actor_name_ctx` (`request_context->>'actor_name'`) is referenced **only** in the `app_source='jobber'`
branch. That asymmetry is the whole gap: the capture layer is generic, the render layer is not.

## Design

Two changes. Neither touches a table.

### 1. `save-calendar-visit` forwards the caller's email as `x-actor-name`

The function already decodes the caller's JWT (`bearerRole` does `JSON.parse(atob(...))` on the same
token), so the email is available with **no extra call and no extra round trip**. The gateway has
already verified that token's signature (`verify_jwt = true`).

Use a **dedicated per-write client**, not the module-level one, exactly as `webhook-jobber` P2b does:

```ts
// module-level client stays as-is for reads
const dbWrite = (actorEmail: string | null) => createClient(URL, SERVICE_KEY, {
  global: { headers: {
    "x-app-source": "visit-calendar",
    ...(actorEmail ? { "x-actor-name": actorEmail } : {}),
  } },
});
```

⚠ **Omit the header when there is no email** rather than sending an empty string. `audit.log_change`
uses `NULLIF(v_headers->>'x-actor-name','')`, and `jsonb_strip_nulls` drops the key, so an absent
header is clean while `"x-actor-name": ""` is merely equivalent-by-luck. A `service_role` caller (our
own tests) has no email and must produce no actor claim rather than a blank one.

⚠ **Send the EMAIL, not a display name.** It keys the existing `employees.full_name` lookup, which is
how every other human branch renders, and it degrades to a readable value when the person is not in
`employees`. Sending a name would create a second naming path to keep in sync.

### 2. `public.get_record_history` falls back to `actor_name` in the human-app branch

One `COALESCE`, in the branch quoted above: prefer `actor_email` (browser writes), fall back to
`actor_name_ctx` (headless writes that carried the header). Run the same `employees` lookup against the
fallback so both paths render identically.

`ops.get_record_history` is a wrapper, so **it needs no change** and must not be duplicated.

⚠ Keep `actor_type` = `'human'` for `visit-calendar`. It already is, and it is keyed on `app_source`,
not on whether a name was found, so a save with no resolvable actor still reads as a human edit rather
than flipping to "System".

## What NOT to do

- **🛑 Do not modify `audit.log_change`.** It is the AFTER trigger on all 14 audited tables (ADR 010),
  it is `SECURITY DEFINER` with `search_path TO ''`, and it already captures what is needed. Changing
  it to add another header or column risks every audited write in the system to gain nothing. The
  capture layer is not the gap; the render layer is.
- **🛑 Do not add a column to `visits`.** It would need backfilling, an ADR-010 note, and a write path
  in every RPC that touches visits, to store something `audit.logs` already holds.
- **🛑 Do not grant `edit_calendar_visit_verified` to `authenticated`** in order to get the caller's JWT
  into `jwt_claims`. That is the one thing its header forbids: it bypasses the Jobber push, so a direct
  caller could change a visit without Jobber ever hearing about it. Attribution is not worth reopening
  that.
- **🛑 Never use `actor_name` for authorization.** It is a caller-supplied header. Our edge function
  derives it from a gateway-verified JWT, but PostgREST will accept the header from anyone who can set
  one, so it is an **attribution hint only**. This is already true of `webhook-jobber`'s usage. Access
  control stays on the role, the grant and the RPC's own `auth.uid()` / staff-domain checks.

## Verification

Attribution is exactly the kind of claim that reads fine and is false, which is how the header in
`2026-07-29d` came to assert it without measuring. So:

1. **Positive, through the transport.** Save a visit from the **real Calendar UI** as a logged-in
   dispatcher, not via curl as `service_role` (a `service_role` call has no email and correctly produces
   no actor, so it cannot prove this). Then:
   ```sql
   SELECT app_source, request_context->>'actor_name' AS actor, jwt_claims->>'email' AS email
     FROM audit.logs WHERE table_name='visits' AND record_pk->>'id' = '<id>'
    ORDER BY changed_at DESC LIMIT 4;
   ```
   Expect `app_source='visit-calendar'` and a non-null `actor`. ⚠ `record_pk` is **jsonb**, so match
   `record_pk->>'id'`, not `record_pk = '<id>'` (that returns zero rows and looks like a broken audit
   trail; I made exactly that mistake tonight).
2. **The actual deliverable.** `SELECT actor_label, actor_type FROM public.get_record_history('visits',
   '<id>');` must name the dispatcher, e.g. `Edited in Visit Calendar by <Full Name>`. This is the only
   check that matters, because the point is what the drawer shows, not what the row contains.
3. **Negative control.** A `service_role` curl save must yield `app_source='visit-calendar'` with
   `actor_name` **absent**, and `actor_label` must still read `Edited in Visit Calendar` with no
   trailing `by` fragment and no crash.
4. **Regression.** Confirm the 143 `app_source='jobber'` rows still render `Created/Changed in Jobber by
   <name>`, i.e. the `COALESCE` did not disturb the branch that already worked.
5. **Two rows per save is expected**, not a bug: one from `edit_calendar_visit`, one from the
   `sync_state='confirmed'` UPDATE. Both should carry the same actor. Documented in `2026-07-29d`.

## Owner split

| Part | Whose |
|---|---|
| `save-calendar-visit` header change + deploy | either Supabase session |
| `public.get_record_history` COALESCE | either Supabase session |
| Confirming the drawer renders the name, and the UI-driven positive test | **Building Apps** (only they drive the real Calendar) |

Small enough for one session to do both DB-side parts in one migration, but step 1 of the verification
**cannot** be done from a Supabase session: it needs a real logged-in browser save. That is the same
transport gap that hid the dead `ops.retry_visit_push` button, so it should not be waved through.

## References

- `docs/migrations/2026-06-26_activity_attribution_p2b.sql` — where `x-actor-name` capture was added,
  and the `webhook-jobber` per-write-client precedent. **Read this first.**
- `docs/migrations/2026-06-26_activity_attribution_p1_p2a.sql` — the `actor_label` render design, and
  why it reads `jwt_claims->>'email'` rather than raw `jwt_claims` (15 PII keys).
- `docs/migrations/2026-07-29d_edit_calendar_visit_verified.sql` — the corrected RULE 8 header; the
  false "still attributed" claim and why logged ≠ attributed.
- `e58ee34` — the `x-app-source` fix that made these rows visible at all.
- ADR 016 (audit app-source attribution), ADR 010 (audit-trail standing check).
