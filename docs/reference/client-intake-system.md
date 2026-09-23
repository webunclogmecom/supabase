# Client Intake System — what is built, and the rules that must not regress

**Last updated 2026-09-23.** Written while building it, from measurements, not from the design docs.

A site-visit survey: one person documents a property once (access, gate and code, grease traps,
truck parking, hours, photos, two GPS pins), the office curates it, and the output is a page a
driver opens before a job. Designed by Yan with Viktor across six swim lanes; Serena's August
meeting notes hold eight decisions; Fred settled ten more on 2026-09-22.

**Why it exists, measured 2026-09-23: 489 live service properties, SIX of them carry access notes.**

- Design and decisions: `Building Apps/docs/2026-09-23_client-intake-build-plan.md`
- The investigation and the adversarial review of it are beside that file.
- App-side behaviour: `Building Apps/Client App/docs/08-changelog.md`.

---

## What is SHIPPED

| | object | migration |
|---|---|---|
| raw submission | `public.property_intakes` | `2026-09-22_2043_property_intakes.sql` |
| accept provenance | `public.property_intake_accepts` | same |
| answered predicate | `public.fn_intake_answered(jsonb, text)` | same |
| key to column map | `public.fn_intake_accept_map()` | same, corrected `2026-09-23_0933` |
| status | `client.v_property_intake` | same |
| office compare | `client.get_intake_compare(bigint)` | same |
| schedule | `client.schedule_property_intake(bigint, text[], jsonb, text)` | same, reshaped `2026-09-23_0933` |
| accept | `client.accept_intake_answers(bigint, text[])` | same |
| photos | `photo_links` kind `property_intake`, bucket `intake-photos` | `2026-09-22_2120_property_intake_photos.sql` |
| site map | `public.properties.site_map`, `public.fn_site_map_problem`, `fn_site_map_round`, `client.update_property_site_map` | `2026-09-22_2210_property_site_map.sql` |
| question tree | `public.fn_intake_form_current()` | `2026-09-23_0933_intake_form_definition.sql` |
| list rollup | `client.clients.intake_status`, `.intake_property_count` | `2026-09-23_0948_client_clients_intake_status.sql` |
| collector endpoint | edge fn `intake-submit`, `verify_jwt = false` | deployed 2026-09-22 |

NOT built: the published driver page, `Verified`, two-person approval, the client confirmation page,
the Jobber link, and the office screens beyond the Clients-list column.

---

## The rules that must not regress

**1. 🛑 The photo kind is `property_intake`, NEVER `property`.**
`customer.client_access_photos` already selects `photo_links` where
`entity_type IN ('client','property')` and returns `caption` verbatim, and it is served by
`customer.get_client_portal`, which `anon` can EXECUTE on a guessable client code. Widening the CHECK
to `property` publishes intake photos and raw collector captions to a public feed on the first
migration. Proven reachable 2026-09-22: an anon-key POST with `Accept-Profile: customer` returns
HTTP 200. After section 2 the same call returns `access_photos` as an **array of length 0**.

**2. 🛑 Question keys are append-only.** A key (`access_entry.gate`) is stable text shared by
`form_snapshot`, `requested`, `answers`, the photo `role` and the accept map. A changed meaning gets a
NEW key. One key was corrected on 2026-09-23 (`sample_port.count` to `grease_trap.sample_ports`) and
that migration asserts zero stored intakes and zero accepts first, because it is the last moment a
rename is free.

**3. 🛑 The raw submission is immutable.** A trigger refuses any change to `answers`, `submitted_at`,
`collector` or `requested` once submitted. `accepted` and `cancelled_at` stay editable.

**4. `accept_intake_answers` CALLS the existing writers**, `client.update_property_operational` and
`client.update_property_capacity`, rather than touching `public.properties`. Change either signature
or allowlist and this calls you. That reuse is deliberate: it inherits the staff gate, the error
vocabulary, and the Jobber outbound push, which only fires because a real person's JWT is present.

**5. `intake-submit` is fully public.** Measured: it answers 200 with **no apikey header at all**.
The token is the only gate, which makes the ceilings in its header load-bearing rather than tidy:
`MAX_BODY_BYTES 262144`, `PHOTO_CAP 40`, `MAX_ANSWER_KEYS 200`, `MAX_VALUE_CHARS 4000`,
`MAX_COLLECTOR 120`, `SIGNED_UPLOAD_TTL 900`, plus token expiry and a single-submit compare-and-set.

**6. The reason-photos upload gates do NOT transfer.** All three are keyed on a signed-in staff
identity (`auth.uid()`, the staff domain, storage `owner_id`) and Fred's decision 6 removes the
login. The replacements are token-derived: the storage path is derived from the token, slots are
capped, the signed URL is short-lived, the token expires and dies on submit.

**7. `Verified` is deliberately absent from `client.v_property_intake`.** It describes the published
page, which does not exist. The status column is Nothing / Incomplete / Complete only. When the page
ships, `Verified` becomes the highest rank and the `client.clients` rollup gains one arm.

**8. The Clients-list rollup takes the WORST status** across a client's live service properties, and
is NULL (not `Nothing`) when the client has no live service property. 463 clients have exactly one,
8 have more, the largest has six.

**9. Writing `site_map` does not reach Jobber.** `trg_properties_enqueue_outbound` fires only when
`grease_trap_size_gallons` or `lock_box_key` change. Asserted in the migration.

---

## Traps paid for while building this

**A jsonpath CHECK was wrong twice.** Lax mode auto-unwraps the step before a filter, so v1 rejected
every legal arrow. v2 scored 24 of 24 on coordinates and still accepted seven malformed containers,
including `{"pins":42}` and `{"pins":{"gt":{}}}`, which Picture Planner's own "Clear G" button
produces. **Fix: drop jsonpath for one immutable validator function called by both the CHECK and the
RPC.** A CHECK may not contain a subquery but may call a function that does.

**The answered predicate was wrong twice.** v1 used `->>`, which renders `{}` and `[]` as non-empty,
so a blank intake scored Complete. v2 fixed that and still returned SQL NULL for an ABSENT key, which
the view read as answered, so an intake with zero answers scored Complete. **Fix: `coalesce(..., false)`
and `btrim`, and assert the VIEW rather than the function.** The function passing in isolation is what
hid it both times.

**Round before you size-check.** A maximal site map exceeds its own 16 KB cap at full double
precision, so whether a legal map saves would otherwise depend on how many decimals the map library
returned.

**A verify block's own assumption can be the bug.** The rollup verify assumed the test client had one
service property and expected `Incomplete`. 112-YA has more, so the worst-status rule correctly held
it at `Nothing` and the whole migration rolled back. The rule was right and the test was wrong.

**`ticket_number` is not a key on the LWT report.** Within one filing period there are 107 report rows
and only 20 distinct ticket numbers, and one ticket spans up to 9 different gallons values. This is
why the promised "snapshot gallons on `lwt_filing_tickets`" was NOT built: it would have been a
fiction. The risk it was meant to cover is already carried by the `audit_properties` trail and by
`property_intake_accepts`, which records old and new per accepted key.

**The Clients list is at `/`, not `/clients`.** `/clients` returns a real 404 and the app renders a
bare "Starting..." shell, which looks exactly like a broken deploy while every asset serves 200.
