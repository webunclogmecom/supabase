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
| question list for the app | `client.v_intake_questions` | `2026-09-23_1015_client_v_intake_questions.sql` |
| list rollup | `client.clients.intake_status`, `.intake_property_count` | `2026-09-23_0948_client_clients_intake_status.sql` |
| collector endpoint | edge fn `intake-submit`, `verify_jwt = false` | deployed 2026-09-22; v7 2026-09-23 (photo folder = intake id) |
| forms list (Picture Planner `/forms`) | `client.v_intake_submissions` | `2026-09-23_1855_intake_forms_viewer_read_surface.sql` |
| one form, read-only (`/forms/$id`) | `client.get_intake(bigint)` | same |
| staff photo read | storage policy `intake_photos_staff_read` (a copy of `reason_photos_staff_read`) | same |
| read-only roles | `grant execute on public.fn_intake_answered to pg_read_all_data` | same |

Office surface in the Client App (Lovable `dbf2133c-539c-48ff-864a-68eb284a569d`): the Clients-list
`Intake status` column (step 5.1) and the `Intake Form` button plus Schedule intake checklist on the
Edit property dialog (step 5.2), both live 2026-09-23.

Read surface for the Picture Planner forms viewer: **database half live 2026-09-23** (the list view,
`get_intake`, the photo policy). Picture Planner itself still has no backend, so nothing renders it yet;
the plan is `Building Apps/docs/2026-09-23_intake-forms-viewer-plan.md`, sections B to D.

NOT built: **the collector form the link actually opens** (the endpoint is live, the page is not; it
will be `/intake/$token` in Picture Planner), Picture Planner's login and `/forms` screens, the
published driver page, `Verified`, two-person approval, the client confirmation page, the Jobber
link, the New Client modal button and the office Accept screen.

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
login. The replacements are token-derived: the storage FOLDER is the intake the token resolves to
(its id, since intake-submit v7), attach checks the exact path shape the upload issued, slots are
capped, the signed URL is short-lived, the token expires and dies on submit.

**7. `Verified` is deliberately absent from `client.v_property_intake`.** It describes the published
page, which does not exist. The status column is Nothing / Incomplete / Complete only. When the page
ships, `Verified` becomes the highest rank and the `client.clients` rollup gains one arm.

**8. The Clients-list rollup takes the WORST status** across a client's live service properties, and
is NULL (not `Nothing`) when the client has no live service property. 463 clients have exactly one,
8 have more, the largest has six.

**9. Writing `site_map` does not reach Jobber.** `trg_properties_enqueue_outbound` fires only when
`grease_trap_size_gallons` or `lock_box_key` change. Asserted in the migration.

**10. 🛑 The token must never be copied into a path, a caption, or any column staff can read.** It is
the collector's capability: holding it lets anyone submit that form, and the raw submission is
immutable, so a stolen token can block the real collector permanently. A secret is exactly as
exposed as the least-protected column that copies it. `public.photos` carries three authenticated
SELECT policies with `qual true` and `client.photos` is an unfiltered view, so `storage_path` is
readable by every staff session. That is why the photo folder is the intake id.

**11. No function inside a `storage.objects` policy for this bucket.** Every permissive SELECT policy
on `storage.objects` is OR'd into every staff storage read in every bucket, and Postgres checks
EXECUTE when it initialises the expression. A predicate function there makes all staff photo reads
estate-wide depend on one grant. `intake_photos_staff_read` is `bucket_id = 'intake-photos' AND
auth.uid() IS NOT NULL`, nothing more. The product rule that an awaiting form shows no photos lives
in `client.get_intake`, where it belongs.

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

**🛑 A SUPABASE EDGE FUNCTION CANNOT SERVE THE COLLECTOR FORM. Measured 2026-09-23, do not retry it.**
Serving the form as HTML from a GET on `intake-submit` was the plan, and the gateway refuses it: it
rewrites an HTML response to `content-type: text/plain` and stamps
`content-security-policy: default-src 'none'; sandbox` on it. `sandbox` with no `allow-scripts` kills
the inline script, so even a rendered page would be inert. Confirmed in a browser: it displays the raw
source as text. JSON from the same function is untouched (`application/json`), which is how we know it
is HTML-specific rather than a blanket rewrite. It is an anti-abuse control on the platform and should
not be worked around. The form must live on a real web origin; `supabase/functions/intake-submit/form-page.ts`
holds the finished form, ready to port. The GET stays reserved as the future **302** to that host, so
that every link the office has already handed out keeps working and a change of form host is one
deploy instead of a reissue of every token.

**The Clients list is at `/`, not `/clients`.** `/clients` returns a real 404 and the app renders a
bare "Starting..." shell, which looks exactly like a broken deploy while every asset serves 200.

**The first viewer design leaked the token, and the premise was the bug, not the code.** It gated photos
behind "readable once submitted" because `authenticated` holds no grant on `public.property_intakes`, so
staff "cannot read tokens". True of that table, false of the system: the token was copied into
`photos.storage_path`, which every staff session can read. Two reviewers found it independently in an
adversarial pass before the migration shipped. **Before trusting "X cannot read the secret", list every
column the secret is copied into and ask who can read each one.** The fix removed the copy rather than
guarding it.

**A cleanup keyed on a shape you just changed deletes nothing and reports success.** After the folder moved
from token to id, the test harness still deleted `photos` by `intake-photos/<token>/%`, matched zero rows,
and its baseline check passed because it did not count `photos`. Two orphaned rows were found only by a
separate count. Count every table you wrote to, not the ones you expect to have cleaned.

**A backslash inside a JS template literal is swallowed.** The attach-path regex was written as
`` `...{12}\.(jpg|png)$` `` and compiled to `...{12}.(jpg|png)$`, so `<uuid>Xjpg` was accepted. Caught by
running the pattern against cases that must fail, before deploy. Write `\\.` in the template (two backslashes, so the compiled pattern keeps one), and test
a regex with inputs it must refuse, not only ones it must accept.
