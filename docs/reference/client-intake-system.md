# Client Intake System — what is built, and the rules that must not regress

**Last updated 2026-09-25.** Written while building it, from measurements, not from the design docs.

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
| collector PAGE | `planner.unclogme.app/intake.html#code=<token>`, a static file byte-identical to `scripts/intake-collector/intake.html` (built from `form-page.ts` by `build.mjs`) | live 2026-09-25 (Supabase `c9213b4`, `42ee2a3`); `intake-submit` GET 302s there |
| collector endpoint | edge fn `intake-submit`, `verify_jwt = false` | deployed 2026-09-22; v7 2026-09-23 (photo folder = intake id); v8 2026-09-23 (cap on both steps, attach needs the object, status via the rule); v9 2026-09-24 (upload slots come from the ledger, attach needs a path the ledger issued); v10 2026-09-24 (photo answers come from real attachments); v11 2026-09-24 (numbers inside the question's range, an hours day without a real open and close refused naming the day, an attached but unclaimed photo counts on a shown question, a photo already under another question refused with 409); v12 2026-09-24 (a one-line text question refused at submit when it holds a line break or runs long, refusals name the section, unknown day keys refused); v14 2026-09-24 (byte body ceiling, NUL / lone surrogate refused naming the question, real pins only, hours refusals named); v13 2026-09-24 (the one-line check refuses what Postgres `[[:cntrl:]]` refuses, C1 included; the 4,000-character refusal names its question; an hours key must be an OWN key of the day names) |
| THE completeness rule | `public.fn_intake_applicable`, `public.fn_intake_missing` | `2026-09-23_1949_intake_applicability_and_token_redaction.sql` |
| token kept out of audit | `audit.redacted_columns` row `property_intakes.token` | same |
| forms list (Picture Planner `/forms`) | `client.v_intake_submissions` | `2026-09-23_1855_intake_forms_viewer_read_surface.sql` |
| one form, read-only (`/forms/$id`) | `client.get_intake(bigint)` | same |
| staff photo read | storage policy `intake_photos_staff_read` (a copy of `reason_photos_staff_read`) | same |
| read-only roles | `grant execute on public.fn_intake_answered to pg_read_all_data` | same |
| required = shown and not optional | `public.fn_intake_required`; `fn_intake_applicable` reads `>` and empty `=` | `2026-09-24_0233_intake_tree_conditions_and_bounds.sql` |
| tree conditions + `optional` | `fn_intake_form_current()` (16 conditional questions at 0233, 21 since 0426; `access_entry.obstacles` optional; keys unchanged) | same |
| upload ledger | `public.property_intake_uploads`, `public.fn_intake_claim_upload_slot` (60 slots per intake, ever) | same |
| hidden answers refused | `get_intake_compare` state `not_shown`; `accept_intake_answers` refuses it | same |
| token hidden from `yannick_readonly` | column-level SELECT on `property_intakes`, every column except `token` | same |
| standing check | `scripts/checks/intake-showif-mirror.mjs` (the grammar in its three places) | 2026-09-24 |
| one trim, the JS `trim()` set | `public.fn_intake_trim` (used by `fn_intake_answered` and `fn_intake_applicable`) | `2026-09-24_0311_intake_round4_gallons_pruning_trim.sql` |
| a follow-up only with its parent | `public.fn_intake_parent_key`, `public.fn_intake_prune_requested`; `schedule_property_intake` stores the pruned set and returns `dropped` | same |
| gallons OR measurements; grease-trap gating | `grease_trap.capacity_gallons` optional; photos / gallons / capacity photos only if `systems_count > 0` | same |
| one live link per intake photo | unique index `photo_links_intake_one_live_link_per_photo` | same |
| an optional question keeps its alternative | `public.fn_intake_normalise_requested`; `schedule_property_intake` returns `added` | `2026-09-24_0348_intake_round5_alternatives_ranges.sql` |
| the GT pin under the trap count; writer ranges in the tree | `site_map.gt_location` moved after `grease_trap.systems_count` (`>0`); gallons `min 1 max 20000`, manholes `max 50` | same |
| accept refuses what the writer cannot take | `client.accept_intake_answers`: whole numbers in range, lock box without control characters, trimmed | same |
| the lock box shape reaches submit; the outside note; no all-optional request | `lock_box_code` `"single_line": true, "max_chars": 100`; NEW key `access_entry.where_outside_note` (36 questions); `schedule_property_intake` refuses a request of only optional questions | `2026-09-24_0426_intake_round6_lockbox_outside_note.sql` |
| the list agrees with the detail; a dropped follow-up is refused in words | `client.v_intake_submissions` `photo_count` / `has_gt_pin` / `has_truck_pin` count only what the collector was shown (0450), and `photo_count` also only answered questions, as the detail does (0715); `schedule_property_intake` refuses EVERY follow-up whose parent was not ticked ("Pick the question each follow-up depends on as well.", DETAIL names the keys). ⚠ 0450 refused one only when pruning left nothing or only optional questions; a follow-up next to a required question was pruned silently until 0715 | `2026-09-24_0450_intake_round7_list_counts_orphan_reason.sql`, `2026-09-24_0715_intake_round8_photo_answered_every_orphan_refused.sql` |
| Picture Planner audit label | `audit.log_change` maps `planner.unclogme.app`, `%unclogme-pics-organizer%`, `%d9464151%` to `picture-planner` | `2026-09-24_0301_audit_origin_picture_planner.sql` |
| driver pages (build plan section 6) | `public.property_pages` (append-only versions), `public.property_page_links` (one 22-character driver link per property, redacted from audit), `public.property_page_opens` (throttled open log); `client.page_builder_list()`, `client.get_page_builder`, `client.submit_property_page`, `client.approve_property_page`, `client.rotate_driver_link`; helpers `fn_page_photo_ids`, `fn_page_content_problem`, `fn_page_source`, `fn_page_blocker`, `fn_page_person_name`, `fn_page_approver_ids/_names`; `app_config.page_approvers` | `2026-09-25_1330_property_pages.sql` (Supabase `44f50ae`) |
| driver page endpoint | edge fn `driver-page`, `verify_jwt = false`, calls `public.fn_driver_page` (service role only) | deployed 2026-09-25 |
| short collector link | Picture Planner route `/intake` (`src/routes/intake.ts`): **308** to `/intake.html`, empty body, `no-cache`; the fragment survives the redirect | live 2026-09-25 |
| Cancel form (staff only, from the Planner) | `client.cancel_intake(bigint)`; trigger `property_intakes_no_submit_after_cancel`; `public.fn_intake_link_url(text)` (the one SQL builder of the short link, used by `get_intake_link` and by `schedule_property_intake`, which now returns `url` next to `token`) | `2026-09-25_1705_intake_cancel_and_short_link.sql` (Supabase `0b8dbdc`) |
| Share form (re-show an awaiting link to staff) | `client.get_intake_link(bigint)` returns `https://planner.unclogme.app/intake#code=<token>`; each reveal logged in `public.property_intake_link_reveals` (no token, no URL, no app role reads it) | `2026-09-25_1600_intake_link_share.sql` (Supabase `48b4771`) |

Office surface in the Client App (Lovable `dbf2133c-539c-48ff-864a-68eb284a569d`): the Clients-list
`Intake status` column (step 5.1) and the `Intake Form` button plus Schedule intake checklist on the
Edit property dialog (step 5.2), both live 2026-09-23.

Read surface for the Picture Planner forms viewer: **database half live 2026-09-23** (the list view,
`get_intake`, the photo policy). **Picture Planner got its backend on 2026-09-24** (plan section B): a
Prod client, the shared staff session and the Command Deck login on a staff layout route, published at
`unclogme-pics-organizer.lovable.app` and, since 2026-09-24, `planner.unclogme.app` (live, primary). The `/forms` and `/forms/$id` screens
(section C) and a separate `/reset-password` page went live the same day, read-only and verified on the
published bundle. **The collector form (section D) is live since 2026-09-25** as a static page, see rule 17;
the plan is `Building Apps/docs/2026-09-23_intake-forms-viewer-plan.md`.

**Driver pages, database half live 2026-09-25** (rule 18): versions, two-person approval, the driver link and the
`driver-page` endpoint. NOT built yet: the Picture Planner screens that use them (builder wiring and the public
`/driver` route, plan `Building Apps/docs/2026-09-25_page-builder-and-driver-page-plan.md` P1 to P7), `Verified` in the
Client App status column, the client confirmation page, the Jobber link and the office Accept screen. (The New Client "Time to do the intake now?" step: see the Client App changelog.)

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
`collector` or `requested` once submitted. `accepted` stays editable. `cancelled_at` is set by people only through `client.cancel_intake` (rule 20): only on a form that is neither submitted nor already cancelled, and a submit that lands on a cancelled form is refused by trigger `property_intakes_no_submit_after_cancel`. The table does NOT yet refuse a raw service-role UPDATE that cancels a submitted form or clears `cancelled_at` (no such writer exists, measured 2026-09-25; open question for Fred), so any script that writes it must keep `and submitted_at is null and cancelled_at is null`.

**4. `accept_intake_answers` CALLS the existing writers**, `client.update_property_operational` and
`client.update_property_capacity`, rather than touching `public.properties`. Change either signature
or allowlist and this calls you. That reuse is deliberate: it inherits the staff gate, the error
vocabulary, and the Jobber outbound push, which only fires because a real person's JWT is present.

**5. `intake-submit` is fully public.** Measured: it answers 200 with **no apikey header at all**.
The token is the only gate, which makes the ceilings in its header load-bearing rather than tidy:
`MAX_BODY_BYTES 262144`, `PHOTO_CAP 40`, `MAX_ANSWER_KEYS 200`, `MAX_VALUE_CHARS 4000`,
`MAX_COLLECTOR 120`, plus token expiry and a single-submit compare-and-set. **Since v9 uploads are bounded by a LEDGER**:
`public.fn_intake_claim_upload_slot` hands out at most **60 upload slots per intake, ever**, under an
advisory lock, and returns the path itself (`<intake id>/<uuid>.<ext>`). Attach accepts only a path
the ledger issued to that intake, whose object exists in the bucket, with the content type storage
recorded (never the caller's). `PHOTO_CAP 40` is the product limit on ATTACHED photos; the 20 extra
slots are headroom for retries on a bad signal. History, both bypassed by a burst of calls: before v8
upload URLs were unlimited; v8 counted objects already stored, which a burst made before any object
landed still slipped past. A slot is never freed (a `ponytail:` note in the migration): a collector
who burns 60 uploads through retries is stuck until someone reclaims expired unused slots.
**Since v10 (fourth review):** one live link per intake photo is a unique index, so a parallel burst of
attaches of one file under many roles makes one link. **Since v11** a collision (or a sequential re-attach)
reads as `already_attached` only when the existing link is to the SAME question; another question gets a
409, because reporting "attached" there made the form record a photo that submit then dropped.
`PHOTO_CAP` is checked and then inserted without a lock, so parallel attaches can pass 40 by a few; the
hard bound is structural (links <= photos <= 60 ledger slots). At submit the server, not the client,
decides the answers the office acts on. A photos answer is the paths actually attached to that question
(dropped when none, so a claimed photo cannot count; since v11 an attached photo nobody claimed, after a
lost attach response or a lost draft, counts when its question was shown). A number must be a whole
number inside the question's `min`/`max` (the tree carries the writer's range; default 0 to 999,999,
the largest value accept's whole-number check takes), refused in words otherwise. Since v12 a text
question the tree marks `single_line` / `max_chars` (the lock box code, whose writer refuses a line break
or more than 100 characters) is refused at submit too, and every refusal names the question WITH its
section, because two questions read "How many manholes?". Since v13 "one line" means what the writer's
CHECK means: no character Postgres `[[:cntrl:]]` matches, which includes the C1 block (U+0085 is a line
break a JS `\u0000-\u001f` class let through). Submit ALSO refuses U+2028/U+2029, which `[[:cntrl:]]` on this
database does NOT match (measured 2026-09-24), so submit is stricter than the writer there, never looser. The
4,000-character refusal names its question too (v12 said "every refusal" while that one still read "One of
the notes is too long."), and since v14 so do the access-hours refusals. v14 also measures the 262,144 body
ceiling in BYTES (it counted UTF-16 units, up to 3x), refuses a NUL or a lone surrogate anywhere in an answer
or the collector name in words (Postgres refuses both, which was a 500 no retry fixed), and stores a map pin
only as a finite `{lat, lng, accuracy_m}` in range. A ticked hours day without a real `HH:MM` open and close is REFUSED naming the day ("For any
time, use 00:00 to 00:00"); v10 dropped it silently, which turned "any time" into "not that day" in an
immutable record. ⚠ There is no upload TTL of ours:
the old `SIGNED_UPLOAD_TTL 900` was declared and returned as `expires_in` but never applied. The real
lifetime is Supabase's, **measured at 7,200 s** from the signed-upload JWT's `exp - iat`.

**6. The reason-photos upload gates do NOT transfer.** All three are keyed on a signed-in staff
identity (`auth.uid()`, the staff domain, storage `owner_id`) and Fred's decision 6 removes the
login. The replacements are token-derived: the storage FOLDER is the intake the token resolves to
(its id, since intake-submit v7), attach checks the exact path shape the upload issued, slots are
capped on both upload and attach, each signed upload URL is good for one object (for Supabase's
2-hour lifetime, not a TTL of ours; see rule 5), the token expires and dies on submit.

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
🛑 **And `audit.logs` copies whole rows**, and `authenticated` holds SELECT on it (RLS `true`). Not
reachable through the API today, one config change away. `property_intakes.token` is therefore in
`audit.redacted_columns`, the estate's mechanism for exactly this. Audit rows written before
2026-09-23 19:49 ET still carry tokens; every one belongs to a deleted intake, so all are dead, and
scrubbing them would be an audit-trail rewrite needing Fred's OK. **This premise was wrong twice in
one evening** (first `storage_path`, then `audit.logs`), both times found by an adversarial review.
The question that finds them is not "who can read the table the secret lives in" but "every place
the secret gets copied, and who can read each".
✅ **ONE sanctioned re-display exists since 2026-09-25: `client.get_intake_link` (rule 19).** It returns the
link of ONE awaiting intake to a staff JWT, on a click, and logs who asked. It copies the token nowhere: the
log row holds no token and no URL. It does not change this rule; any new place the token lands still needs
the same review. **A mis-shared link is cancelled from the Planner**: "Cancel form" on the `/forms` card
(`client.cancel_intake`, rule 20). From then on every `intake-submit` request that starts after the cancel answers 404
"This link is no longer active." (one `resolveToken` gates load, upload, attach and submit). The raw UPDATE
(`... set cancelled_at = now() where id = <id> and submitted_at is null and cancelled_at is null`) is only a fallback:
it records no staff email.

**11. No function inside a `storage.objects` policy for this bucket.** Every permissive SELECT policy
on `storage.objects` is OR'd into every staff storage read in every bucket, and Postgres checks
EXECUTE when it initialises the expression. A predicate function there makes all staff photo reads
estate-wide depend on one grant. `intake_photos_staff_read` is `bucket_id = 'intake-photos' AND
auth.uid() IS NOT NULL`, nothing more. The product rule that an awaiting form shows no photos lives
in `client.get_intake`, where it belongs.

**12. 🛑 Completeness is ONE rule: `public.fn_intake_missing`. Call it, never re-implement it.** Since
2026-09-24 a requested key counts only if it is REQUIRED (`public.fn_intake_required`: shown AND not
`"optional": true`). `access_entry.obstacles` is optional (Fred: shown, never blocks Complete), and the
list's `applicable_count` / `answered_count` and `get_intake`'s counts are over required questions only.
**`grease_trap.capacity_gallons` is optional too (fourth review)**: the gallons and "Measurements, if the
gallons are not written anywhere" are either-or, so a site whose gallons are unknown can be Complete
without typing a false 0 (372 of 506 live properties hold no gallons). And the grease-trap photos,
gallons and capacity photos are asked only when `grease_trap.systems_count > 0`, the lift-station rule
applied to the third equipment section. **`site_map.gt_location` too, since 0348**: 0311 left it ungated
because in the site-map section it would have appeared ABOVE the collector after they answered the count;
0348 moved it (key unchanged) into the grease-trap section right after the count. Real no-trap sites exist
(057-BAY is a lift station). **The gallons carry `min: 1`**: 0 means nobody knows it, so it is refused at
submit and at accept, and the measurements take its place.
Before 2026-09-24 a requested key counted if it was APPLICABLE, i.e. the collector was shown it: every `show_if` in its chain
matches the submitted answers (`public.fn_intake_applicable`, the same comparison as the form's
`visible()`). Before 2026-09-23 19:49 ET status was "every requested key answered", so answering *No*
to "Is there a closed gate?" left the gate-code follow-up forever unanswered and the form read
Incomplete forever, and requesting both branches of a choice made Complete impossible. It was live
from 2026-09-22 and feeds the Clients-list Intake status column. `client.v_property_intake`,
`client.v_intake_submissions`, `client.get_intake` and `intake-submit` (via `rpc`, before the write)
all call it now; until v8 the edge function carried its own TypeScript copy, which also disagreed
with SQL on whitespace-only answers. Requested keys are normalised there too (NULL, blank and
duplicates ignored), so the list, the detail and the status count the same set.
⚠ **Blank means exactly what JavaScript's `trim()` removes** (TAB, LF, VT, FF, CR, SPACE, NBSP, U+1680,
U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000, U+FEFF), defined ONCE in
`public.fn_intake_trim` and used for answers AND conditions. Before 2026-09-24 seven Unicode spaces were
an answer in SQL and blank in the form, and (until 0311) the condition side still used plain `btrim`.
🛑 **The rule must never raise.** 0233's `>` guard tested `[[:space:]]*-?[0-9]+...` and then cast
`btrim(v_got)::numeric`; `[[:space:]]` accepts 19 Unicode spaces `btrim` leaves in place, so a count of
NBSP+"5" raised 22P02 inside `fn_intake_missing`, which `client.clients` calls for every staff read of the
Clients list. It never landed only because intake-submit computes status BEFORE writing. Since 0311 `>`
tests an ASCII number on the already-trimmed value, so the cast cannot see anything it would refuse.
⚠ **1949 was not enough**: it only helped a follow-up that CARRIES a `show_if`. With the live tree, all
35 keys requested and a truthful survey of a site with no lift station and no water tank, 8 keys were
still missing, 3 of them photo questions nobody can answer (you cannot photograph a lift station that
does not exist). The fix was conditions in the tree, not a looser rule.

**13. 🛑 The `show_if` grammar lives in THREE places, and they must agree.**
1. `public.fn_intake_applicable` (SQL: what counts toward Complete).
2. `visible()` in `supabase/functions/intake-submit/form-page.ts` (what the collector is shown).
3. The Client App's Schedule dialog helpers (which questions it ticks together as follow-ups).

The grammar: `key=value` (shown when the parent's trimmed answer equals `value`), `key=` with an
EMPTY value (shown when the parent was left blank), `key>N` (shown when the parent's answer is a number
above N). The operator is the FIRST `=` or `>`, both sides trimmed, and the parent chain is walked
(a hidden parent hides its children; depth capped at 10, a cycle ends as shown). **Change it reader
first, writer second**: the dialog shipped first (2026-09-24 02:35 ET), then SQL, then the form, so no
consumer ever met a condition it could not read.
**Run `node scripts/checks/intake-showif-mirror.mjs` after touching any of the three.** It reads the
live tree, the form's own functions out of `form-page.ts` (never retyped) and the parser out of the
LIVE Client App bundle, then compares every condition's parent key three ways and every question's
visibility in form vs SQL over 20 scenarios, with a positive control that must flip. Measured
2026-09-24 after 0426: 21 conditions parsed three ways, 720 cells, all agree. ⚠ It finds the dialog's
parser as the function the "only if" note renderer CALLS, not by position: a helper added between them
(the alternative helper, 2026-09-24) made the positional rule read the wrong function and the check
failed on 19 of 20 conditions, which is the check working.

**14. 🛑 Compare and accept honour whether a question was SHOWN.** The collector form keeps what was typed
into a follow-up when its parent later changes, so an abandoned lock-box code (how_access switched from
Lock box to Key) reaches the raw submission. `get_intake_compare` marks such a key `not_shown`, and
`accept_intake_answers` refuses it (`22023`, MESSAGE in plain words, DETAIL `blocker=not_shown ...`)
before anything is written, because accepting it would write `properties.lock_box_key` and push it to
Jobber. The raw submission stays immutable: the filter is at the consumer, never a rewrite of `answers`.

**15. 🛑 `yannick_readonly` reads `property_intakes` through a COLUMN grant that leaves out `token`.** It
is a LOGIN role with BYPASSRLS, and the public schema's default ACL had given it table-level SELECT,
live tokens included. A new column on `property_intakes` is therefore invisible to that role until
granted by name, which is the safe default; **never "fix" that by granting table-level SELECT again.**
The same default ACL handed it SELECT on `property_intake_uploads` the moment 0233 created it, while
0233's header said "service_role only"; 0311 revoked it and now asserts the whole `relacl`. **A new
table in `public` gets `yannick_readonly=r` by default: check every one.**
⚠ Separately, that role's password sits in the public repo
(`docs/handoffs/yannick-*/YANNICK-CLAUDE-CODE-SETUP.md`, since 2026-06-09). Fred chose (2026-09-24) to
have Yannick change it; the literals come out of the docs after he does, and scrubbing git history is a
force-push that needs Fred's OK.

**16. 🛑 A follow-up is only ever asked together with the question it depends on.** An empty `key=`
reads a parent that was never ASKED as "left blank", so a requested set with a follow-up but not its
parent asked the collector to measure a trap whose gallons the office already had. The Schedule dialog
produced exactly that set by default (its pre-check unchecks a question whose value we hold and left
the follow-up checked). Now closed twice: `client.schedule_property_intake` stores
`fn_intake_normalise_requested(snapshot, requested)` (prune since 0311: drops every key whose parent
chain is not requested; plus alternatives since 0348, below)
and returns what it dropped as `dropped`, refusing an all-orphan set in words; and the dialog's initial state
applies the same rule its uncheck path does (live 2026-09-24, `clients._id-DvCP4-eC.js`, verified by
executing the live code against property 162).
**And the converse, since 0348: an optional question is asked together with its ALTERNATIVE** (the
question whose `show_if` is `<that key>=`, today the measurements for the gallons). Without it a request
with the gallons but not the measurements read Complete with no capacity at all. The stored set is
`public.fn_intake_normalise_requested` (prune, then add), `schedule_property_intake` reports the
additions as `added`, and the dialog ticks and unticks the pair together.

**17. 🛑 THE COLLECTOR FORM IS ONE STATIC FILE, AND ITS TOKEN RIDES IN THE FRAGMENT AS `code` (2026-09-25).**
The office link stays `<supabase>/functions/v1/intake-submit?t=<token>` (every link already handed out keeps
working); its GET answers **302** (never 301, `no-store`) to `https://planner.unclogme.app/intake.html#code=<token>`,
and 400 "This link is not valid." for a missing or malformed token. Why each piece:
- **A static file, not a React route.** `intake.html` is `form-page.ts` (the reviewed form) plus four anchored edits in
  `scripts/intake-collector/build.mjs`: the analytics token guard as the first script, no-referrer + noindex, the endpoint
  URL, and the token read from `#code=`. There is ONE form. Change `form-page.ts`, rerun `build.mjs`, commit, and have
  Lovable download the file byte for byte into Picture Planner's `public/intake.html` (pin the commit in the raw URL,
  `main` is cached for minutes); then check the live SHA-256. **Never edit `public/intake.html` in Lovable.**
- **`#code=`, not `/intake/<token>` or `?t=`.** Lovable hosting's `/~flock.js` posts `location.href` (fragment
  included) to its analytics. `code` is a key the estate's guard already scrubs, so the guard stays byte-identical in all
  eight apps, and a fragment never reaches a server log or a Referer. Measured 2026-09-25: Lovable does NOT inject the
  tracker into this static file, and the page carries the guard anyway in case that changes.
- **It loads no Supabase code**: `fetch` to `intake-submit` and the signed storage upload, nothing else. Verified by the
  test's request log (0 calls to `/rest/v1` or `/auth/v1`).
- **Test:** `scripts/intake-collector`'s form is proven by an end-to-end browser run on a `[TEST]` intake of 112-YA
  (16 checks: bad links, the redirect, follow-ups, photo upload + attach, GPS pin, submit, the partial-submit
  confirmation, "Already submitted", the DB row). Clean up every `[TEST]` intake afterwards (storage objects through the
  Storage API first). `scripts/checks/intake-form-host.mjs` checks the source rules (`--source`) and then that the live
  file equals the source and the redirect carries `#code=` (it pointed at an abandoned path and `#t=` until 2026-09-25).
- **Traps the 2026-09-25 redesign paid for (two adversarial rounds; do not reintroduce):**
  - Rebuilding the question list while a pointer is down replaces the control under it and the click is lost. Rebuilds
    wait for the whole tap (`afterPress`: pointerdown, pointerup, then its click, 450 ms fallback). A typed text answer
    never rebuilds (only an answer a `show_if` reads does), and an hours time edit saves in place (rebuilding on each
    segment turned a typed 09:30 into 00:00).
  - Errors live in state (`ERR` per question, `GEO` for the location search, `#fmsg` in the bar) because every rebuild
    wipes the list; a message goes away only on OK or when its cause ends. Browser errors ("Failed to fetch") are shown
    as plain words.
  - Submit refuses while a photo uploads or the location search runs, and nothing writes the draft after the thank-you.
  - The draft (`intake-draft-<token>`) and the submit body are unchanged; the name (`-who`) and a copy of the load reply
    (`-form`, ignored once `expires_at` passes) sit under their own keys and are removed on submit.
  - Tapping a selected answer keeps it (a double tap used to clear it); a newly ticked day copies the first ticked day's
    hours.
- **🛑 MOBILE FIRST, THEN PC (Fred, 2026-09-25: *"the intake form where the collectors puts the data needs to be mobile
  responsive first, and then to be good looking on a PC"*).** Design and check every change at phone width (360 and 390)
  before tablet (768) and desktop (1280): 44px touch targets, inputs at 16px or more (iOS zooms below that), no sideways
  scroll, little fixed chrome, and the desktop layout aligned to one column. Screenshot all four widths, never only one.
- **THE PIN MAPS (2026-09-25, Fred: *"we need a map there, a pin that we can move, like an interactive map, like the
  Picture Planner has"*).** Each `gps_pin` question (`site_map.truck_parking`, orange "T"; `site_map.gt_location`, red
  "GT") shows a satellite (hybrid) Google map centred on the pin, else on the property (`property.lat`/`lng` in the load
  reply), else Miami. Tap places the pin, drag adjusts it, "Use my location" still works and moves it. A hand-placed pin is
  `{lat, lng}` rounded to 6 decimals with no `accuracy_m`; the server validator and the accept path are unchanged.
  - The key is the edge secret **`GOOGLE_MAPS_BROWSER_KEY`**, returned as `maps_key` by `op:'load'` (the Planner's own
    browser key, restricted by referrer to `planner.unclogme.app`). **No secret, a refused key (`gm_authFailure`), or no
    signal: no map, and the question works exactly as before** (both fallbacks tested). Maps loads only when a pin
    question is on screen.
  - `render()` rebuilds the list on every answer, so each map is built ONCE and its node moved into the new card (a new
    map would refetch tiles and lose the zoom). `gestureHandling: 'cooperative'`: one finger scrolls the page, not the map.
  - 🛑 **Measured before shipping: Maps sends Google the page's origin and path, never the fragment** (its
    `MapsJsInternalService` RPC carries `origin/path`; 0 of 27 to 43 Google requests per run carried the code). And the
    key works under the page's `no-referrer` policy (tiles drew on the real host), so the policy was NOT weakened.
  - Test: `scripts/intake-collector/tests/form-map.mjs <[TEST] intake id> <outdir>` serves the local build on the real host and
    injects the key into the load reply, so it runs before a deploy and before the secret exists. 4 widths; tap, GPS, the
    same map node after another answer, no code in any Google request; `none`/`bad` as a 4th argument test the fallbacks.
- **18. DRIVER PAGES (2026-09-25, `2026-09-25_1330_property_pages.sql`).** Plan:
  `Building Apps/docs/2026-09-25_page-builder-and-driver-page-plan.md`. The rules that must not regress:
  - 🛑 **Drivers see only an APPROVED version**, and nobody approves their own (a CHECK, the RPC, and the approver list
    `app_config.page_approvers`, auth user ids, today Diego, Serena and Yannick; only the service role can edit it).
  - 🛑 **A page photo is served only from the bucket its LINK KIND names, and only if that object exists there**
    (`fn_page_photo_ids` joins `storage.objects`). `photos.storage_path` is writable by any staff session, and a path like
    `../manifests/...` joined into a storage URL is normalised into ANOTHER bucket: the pre-apply review served an
    unredacted DERM sheet that way. `driver-page` never takes a path from the page content.
  - 🛑 **ONE answer to "will this link open": `public.fn_page_blocker`** (removed, billing, client INACTIVE). The driver
    function, submit, approve, the builder and the list all call it, so the office never sees "Live" on a dead link.
  - 🛑 **`fn_page_content_problem` reads tables: never make it a CHECK.** The table CHECK is only
    `jsonb_typeof(content -> 'photos') = 'array'`.
  - 🛑 **Submit requires the prefill baseline back** (`p_expected_source` = `get_page_builder.property.source`) and
    refuses when it changed (`blocker=source_changed`), and it strips the server-owned `site_map` and per-photo `rot`,
    so a stored version can be sent back as it is. The baseline compares the MAP BY CONTENT, not by `rev` (the rev
    repeats after a clear and moves on a no-op save).
  - 🛑 **Grants:** the three tables are revoked by name from `yannick_readonly` too (a login role with BYPASSRLS that the
    default ACL grants on every new public table); every `public` helper is revoked from anon and authenticated; the list
    is a SECURITY DEFINER function, not a view (a function inside a view runs with the caller's rights).
  - `property_page_links.public_id` is in `audit.redacted_columns`. The staff mark on an open is self-reported by the
    page: advisory only.
  - Fixtures: two approved `[TEST]` pages on 112-YA (properties 162 and 1164), approved by `test.agent@ayache.com`, made an
    approver for that one transaction only. Pages are append-only: fixtures stay; rotate their links if one leaks.

**19. SHARE FORM: staff can see an AWAITING intake's link again (2026-09-25, `2026-09-25_1600_intake_link_share.sql`).**
Fred: a "Share form" item on each `/forms` card, *"so the collector or any other person can open the form to fill in
case they need it again"*. Until then the token was shown once, by `schedule_property_intake`, and never again.
- **The link is `https://planner.unclogme.app/intake#code=<token>`, built in SQL.** Fred: *"can't we remove that
  `.html`?"* `/intake` is a Picture Planner server route answering **308** to `/intake.html` with an EMPTY body;
  browsers keep the fragment across it. 🛑 **Never make `/intake` serve the form itself**: Lovable hosting injects
  `~flock.js` and an og:image into HTML a worker returns (measured: 416 bytes added, the tracker loaded), and not
  into a static file, which is why the form stays `public/intake.html` and the route only redirects.
  `public/_redirects` is not supported there. Since `2026-09-25_1705` `schedule_property_intake` returns the same short
  link as `url` (built by `public.fn_intake_link_url`), and the Client App is to read it (prompt CA1, waiting on that
  project's owner); until then the office link stays `intake-submit?t=`, whose `?t=` lands in `function_edge_logs`.
  Old `?t=` links keep working (the GET still 302s).
- 🛑 **The FORM_URL coupling:** the host is written in two places, `public.fn_intake_link_url` and `intake-submit`'s redirect.
  Move the collector and both change together.
- **It refuses, in words, with `blocker=<code>` in DETAIL** (22023 unless noted): not signed in (28000), not staff
  (42501), no id, not found (P0002), cancelled, submitted, expired (`expires_at <= now()`), removed property, and a
  token that does not look like one. The app shows the MESSAGE only when DETAIL starts `blocker=`, a plain sentence
  otherwise.
- **The reveal log** `public.property_intake_link_reveals` (intake, who, email, when) is the trail, so it is not
  audited; FK `on delete cascade`; RLS on; revoked from public, anon, authenticated and `yannick_readonly`, sequence
  included, and the migration asserts the whole `relacl`. An app-driven write: the Picture Planner writes it through
  the RPC on every Share click.
- **The app half is live since 2026-09-25** (Picture Planner `/forms`, its CLAUDE.md rule 9): the link is fetched only on
  the click, a late reply for another card is dropped, and the MESSAGE is shown only for a `blocker=` refusal. Checked
  signed in: intake 160's link equalled `'https://planner.unclogme.app/intake#code=' || token` (compared as a SHA-256,
  never printed) and wrote exactly one reveal row.
- **Share widens where a link circulates.** Before this only the scheduler held it. That is Fred's call, made; the
  cancel half shipped the same day (rule 20).
- VERIFY V1 to V10 (whole ACLs, URL equality inside SQL, one reveal row per success and none per refusal, no audit
  row, no 16+ token-like run in any refusal MESSAGE, anon and non-staff refused, list and detail untouched) and seven
  mutants run before apply (anon grant, the office link, the old `.html` link, no log, a readable log, no
  removed-property or submitted refusal), each caught by that VERIFY.

**20. CANCEL FORM: only signed-in staff, only from the Planner (2026-09-25, `2026-09-25_1705_intake_cancel_and_short_link.sql`).**
Fred: *"Cancelling an intake form should only be possible at the Planner App, meaning a logged in staff can do it. Not
by a driver."*
- `client.cancel_intake(p_intake_id)` -> `{ok, intake_id, cancelled_at}`. EXECUTE to `authenticated` only (whole proacl
  asserted); the same staff gate as `get_intake_link`. The collector endpoint has no cancel operation and `anon` holds
  nothing, so nobody holding a link can cancel. ⚠ "Staff" means the `@ayache.com` / `@unclogme.com` allow-list, not a
  role: 0 of 4 active field employees had such an account on 2026-09-25. If a driver ever gets one, they could cancel
  (open question for Fred: require `employees.access_level` admin or office).
- Refuses in words with `blocker=<code>`: not signed in, not staff, no id, not found, already cancelled, submitted (a
  submitted form stays a record), and `changed` when the guarded write finds the row no longer awaiting. Allows an expired
  link and a removed property.
- 🛑 **Race-safe twice:** `FOR UPDATE` plus a guarded write (`... and submitted_at is null and cancelled_at is null`);
  VERIFY 1e asserts both stay in the body, because a single-session test cannot exercise a race. And trigger
  `property_intakes_no_submit_after_cancel` refuses a collector submit landing after a cancel (intake-submit's
  compare-and-set only checks `submitted_at`): the collector sees "Could not save the form, please try again.", a retry
  gets the 404. It keys on the TRANSITION, never on comparing timestamps (the edge function stamps `submitted_at` from
  its own clock).
- ⚠ An upload or attach already past its token check can still store a file or a photo link on a cancelled intake;
  nothing reads a cancelled intake's photos.
- Who cancelled is in `audit.logs` (`audit_property_intakes`, `jwt_claims->>'email'`, `app_source` picture-planner).
- VERIFY V1 to V10 plus 1e to 1g (lock and guarded write in the body, `search_path` pinned, SECURITY DEFINER / INVOKER
  IMMUTABLE flags); 15 mutants, each caught; a four-lens adversarial review before apply.

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
and a trim (`btrim` then; `public.fn_intake_trim`, the JS `trim()` set, since 0311), and assert the VIEW
rather than the function.** The function passing in isolation is what
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

**🛑 A SUPABASE EDGE FUNCTION CANNOT SERVE THE COLLECTOR FORM. Measured 2026-09-23, do not retry it.** (Resolved 2026-09-25 by rule 17.)
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

**A "0 violations" check was blind to the violation it existed for, TWICE, and the second fix was
wrong too.** 0233's V4a counts conditions whose parent key is missing, spelled wrong, or `>` on a
non-number. A plain `LATERAL` join to the parent would drop a missing parent's row, so it used
`LEFT JOIN LATERAL ... ON true`, and this document then said the row "survives and is counted". **It
survived the join and was dropped by the WHERE**: every branch of `NOT (A OR B OR C OR D)` compares
against the NULL parent, `NOT(NULL)` is NULL, and WHERE keeps only TRUE. Found by the fourth review.
0311's version wraps the test in `NOT coalesce(..., false)` and proves it with a MUTATED TREE (a
missing parent, no operator, an empty condition, an empty `=` on a missing key) that must count 4.
**A LEFT JOIN is necessary, not sufficient: ask whether the violating row reaches the final predicate
as TRUE, and keep one fixture that must fail.**

**A backslash inside a JS template literal is swallowed.** The attach-path regex was written as
`` `...{12}\.(jpg|png)$` `` and compiled to `...{12}.(jpg|png)$`, so `<uuid>Xjpg` was accepted. Caught by
running the pattern against cases that must fail, before deploy. Write `\\.` in the template (two backslashes, so the compiled pattern keeps one), and test
a regex with inputs it must refuse, not only ones it must accept.
