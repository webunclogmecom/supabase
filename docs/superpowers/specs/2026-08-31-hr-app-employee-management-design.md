# HR App: Employee Management, design

*2026-08-31 ET. Fred + Yannick. Status: agreed, not built.*

---

## 1. Scope

Yannick, in Slack 2026-08-28 (`C0B15CHQ1D4`, ts `1787950381.924659`), attaching
`unclogme-hr_19 (1).html`:

> *"Don't forget we are just doing the **driver detail** for the moment and after we work on the
> **drivers page**."*

with the recap:

```
HR
  + onboarding
      Details about Drivers (2 days)
          All the docs and info: w2 / 1099 / Emergency contact / docs
          Pay: pay/hour, pay/job bonus, pay/shift bonus
  + Driver page
      daily report from admin review with score and bonus
```

**In scope, in order:**

1. **Employee detail**: the record for one person, canonical fields, W2/1099, emergency contact,
   documents, pay rates.
2. **Employee list**: the searchable directory that links into the detail.

**Explicitly out of scope**, though the prototype file contains all of them: HR dashboard, candidate
sourcing, onboarding templates, equipment catalogue and handoffs, training. The daily-report bonus
from Admin Review is a later phase and is only referenced here where it constrains a decision.

⚠ **The prototype's sidebar is not wanted** (Fred). The app is the two screens above.

---

## 2. Decisions taken, and by whom

| # | Decision | Who |
|---|---|---|
| 1 | Build on **Prod** (`wbasvhvvismukaqdnouk`) against canonical `public.employees`, with HR state in a new **`hr.*` schema** | Fred |
| 2 | **Only office/admin staff use the app.** The directory nonetheless lists **every hired person**, technicians included | Fred |
| 3 | **Leave `employees.role` alone.** Driver / Helper / Plumber is deferred; roles stay `Technician`, `Admin`, `Owner`, `Office` | Fred |
| 4 | **Pay is current-value only** for now. Effective dating comes with the bonus report | Fred |
| 5 | **`employment_type` is DROPPED.** *"skip it we don't need it"* (Fred, 2026-08-31). No canonical change at all | Fred |
| 6 | Reads through `hr.*` views, writes through SECDEF RPCs | proposed, unchallenged |

**Decision 2 is the one to keep straight: the gate is on the CALLER, not on the rows.** Office and
admin staff sign in; everybody who has ever been hired appears in the table.

---

## 3. What is already true, measured 2026-08-31

Everything in this section was measured against live Prod, not assumed. It matters because **the
prototype's data model is largely fictional** and building against it would waste the two days.

### 3.1 🛑 The prototype's vocabularies do not exist

| the prototype assumes | Prod actually holds |
|---|---|
| `role`: `driver`, `helper`, `plumber`, `grease_trap_tech`, `office`, `admin` | `Technician` (4 active), `Admin` (2), `Owner` (1), `Office` (1) |
| `access_level`: `staff`, `admin` | `dev` (4 active), `field` (4), `office` (1) |

There is **no `driver` role in Prod at all**. Its role filter and pay-by-role logic would match
nothing as written.

### 3.2 The canonical table

`public.employees`: `id, full_name, role, status, shift, email, phone, hire_date, notes,
created_at, updated_at, access_level, color_hex`. 21 rows, 9 ACTIVE.

- **Audited** (`audit.log_change` trigger present), so a new column is captured automatically under
  rule 8 with no further opt-in.
- **RLS enabled AND forced.**
- `authenticated` holds **SELECT only**. 🛑 **So the app cannot write canonical fields directly.**
  Every canonical edit goes through a SECDEF RPC, the same shape as `client.update_client_status`.
- Only writers in the last 90 days: `employee-dedup-merge` and `sql`. No app writes it today.

### 3.3 Who can actually sign in

| access_level | active people | have an auth account |
|---|---|---|
| `dev` | Aaron, Diego, Serena, Yannick | 3 of 4 |
| `office` | Fred | yes |
| `field` | Grecia, Mark, Anthony, Michael Escobar | **none** |

Field technicians hold personal gmail/yahoo addresses, and the internal apps are restricted to
`@ayache.com` / `@unclogme.com`, which is why none of them can reach any staff app today.

⚠ **Aaron has no email on record**, so he cannot be resolved by a JWT gate and **cannot use the app
until he is given a company address and an account.** This is an operational prerequisite, not a
code problem.

### 3.4 Storage buckets

Six exist. **Three are `public: true`** (`GT - Visits Images`, `gdo-permits`, `manifests`) and two
are private (`rpa-evidence`, `approval-proof`). HR documents follow the private pattern; see §6.

---

## 4. Prerequisite: `access_level` is wrong, and this app is what makes it matter

Fred's correct grouping, 2026-08-31:

```
Admin:  Fred, Yannick
Office: Aaron, Diego, Serena
Field:  Grecia, Mark, Anthony, Michael Escobar
```

Prod disagrees on five active rows, and the vocabulary differs (`dev` should be `admin`):

| person | id | Prod | correct |
|---|---|---|---|
| Fred | 2 | `office` | **`admin`** |
| Yannick | 27 | `dev` | **`admin`** |
| Aaron | 26 | `dev` | **`office`** |
| Diego | 28 | `dev` | **`office`** |
| Serena | 42 | `dev` | **`office`** |
| Grecia, Mark, Anthony, Michael Escobar | | `field` | `field` ✓ |

Plus **id 16 `A Azoulay (admin)`**, INACTIVE, currently `dev`. 🛑 **That is not a separate person:
it is Aaron's retired duplicate** (`Azoulay` is his surname). Verified: id 16 holds **0**
`visit_team` rows and id 26 holds **58**, so the survivor carries the history, exactly the
consolidation pattern used for Michael Escobar on 2026-08-18. Set it to `office` to match the
person, which also lets the constraint below be VALIDATED rather than NOT VALID.

⚠ Both rows carry their own distinct Jobber link (`User/2599812` on the retired row,
`User/2930566` on the live one), so Jobber genuinely holds two user records for Aaron. Out of scope
here; noted so nobody reads it as corruption.

### 🛑 Why the correction is safe, and why it will not stay correct on its own

`access_level` is **decorative today**. Only `client.employees` reads it, as a passthrough column;
**no function gates on it** and **there is no CHECK constraint**. Nothing has ever depended on it,
which is precisely why it drifted.

**This app makes it load-bearing for the first time.** After that, a wrong or missing
`access_level` either locks a colleague out or lets the wrong person see pay. Nothing currently
maintains it when somebody is hired.

⇒ **Add `employees_access_level_chk` pinning it to `admin` / `office` / `field`**, so a typo fails
loudly at write time instead of silently changing who can see compensation. Validate it after the
six corrections above.

---

## 5. Data model

### 5.1 No canonical change

Fred, 2026-08-31: *"about the employment_type, skip it we don't need it."* So **`public.employees`
is not altered by this work at all.** Combined with decision 3 (leave `role` alone), the canonical
table is untouched: the only change it received is the `access_level` correction in §4, which is a
data fix rather than a schema change.

That is a genuine simplification. It removes the one migration that would have touched a shared
table every app reads.

✅ **AND THE W2/1099 CONCEPT GOES WITH IT. RESOLVED, not left open.**

Yannick's recap asks for it in writing (*"All the docs and info: w2 / 1099 / ..."*) and his mockup
renders it twice: a **Type** column on every directory row, and a `W2 · DRIVER` pill on the detail
hero. Fred, 2026-08-31:

> *"Drop it, we don't need it, remove it where it's shown, including it's column on the table, a
> employee type is it's role actually, yannick just created it twice."*

⇒ **Employee type and role are the same concept.** The prototype models a plumber as a 1099
subcontractor and a driver as W2, so the tax status was never independent information: it is
implied by what the person is. Carrying both would be storing the same fact twice, which rule 3
forbids anyway.

**So the following come OUT of Yannick's design, deliberately:**

| removed | was |
|---|---|
| the **Type** column in the directory table | a W2 / 1099 badge per row |
| the `W2 · DRIVER` prefix on the detail hero pill | becomes just the role |
| the W2-vs-1099 **split document checklists** | see §6 |
| `hr.document_requirement` | dropped from the schema entirely |

⚠ **This is a change to Yannick's design, made by Fred, not an omission.** Anyone comparing the
built screens against `unclogme-hr_19 (1).html` will find the Type column missing; this is why.

### 5.2 `hr` schema

| table | grain | holds |
|---|---|---|
| `hr.employee_profile` | 1:1 with `employees` | emergency contact name, relationship, phone; HR-only notes |
| `hr.pay_rate` | 1:1 with `employees` | `hourly_rate`, `per_job_rate`, `per_shift_rate`, `salary_amount`, `salary_period`, `task_based` |
| `hr.employee_document` | many per employee | `doc_type`, `storage_path`, `uploaded_at`, `uploaded_by`, `deleted_at` |

**All three opt IN to audit** under rule 8. Pay and personal documents are exactly what that rule
exists for, and none of them is a sync-only append table.

Money is `NUMERIC(12,2)` (rule 7). Nothing hard-deletes (rule 6): documents get `deleted_at`.

⚠ **No source-prefixed columns anywhere** (rule 1). The mockup's "External IDs" card reads
`public.entity_source_links`, which already holds the Jobber and Samsara links and is real.

### 5.3 Pay: flat now, effective-dated later

Per decision 4, `hr.pay_rate` is one row per employee holding the current values. Yannick's three
named rates map directly: `pay/hour` → `hourly_rate`, `pay/job bonus` → `per_job_rate`,
`pay/shift bonus` → `per_shift_rate`. Salary and task-based come from the prototype and cost
nothing to carry.

🛑 **Shape it so the later migration is mechanical.** Keep the table single-purpose, with no
columns that are not a rate. Adding history then means adding `effective_from`, dropping the 1:1
constraint, and adding a `hr.v_pay_rate_current` view over `DISTINCT ON (employee_id)`. Backfilling
`effective_from` for existing rows comes from `audit.logs.old_row`.

⚠ **The bonus report will need this.** A bonus computed from an Admin Review daily report needs the
per-shift rate **as it stood on that day**. Shipping flat is a deliberate trade for the two days,
not a claim that history is unnecessary.

---

## 6. Documents and storage

A **new private bucket**, `public: false`, following `rpa-evidence` and `approval-proof`. Files are
served through signed URLs; `hr.employee_document` holds only metadata and the storage path.

🛑 **This must be stated rather than inherited.** Three of the six existing buckets are public, so
the ambient default in this project is the wrong one for driver licences, I-9s and W-4s.

**There is no required-document checklist.** The W2 and 1099 sets in the prototype were keyed on
employee type, which was dropped as a duplicate of role (§5.1), so `hr.employee_document` is simply
the list of documents held for a person, each with a type label, uploaded and viewed by hand.

⚠ **If a required set is wanted later it keys on `role`**, per Fred's reasoning that type and role
are the same thing. It is deliberately not built now: today every active technician is `Technician`
and the Driver / Helper / Plumber split is deferred (decision 3), so a role-keyed requirement table
would have exactly one meaningful row and would encode a guess about which roles are contractors.

🛑 **Getting that wrong means asking a contractor for an I-9**, which is why it waits for the
role vocabulary rather than being approximated now.

---

## 7. Access model

**One gate, on the caller.** No per-row ownership, no self-view (decision 2).

`hr.caller_is_admin()` is SECURITY DEFINER with a **pinned `search_path`**. It resolves the caller's email
from the JWT and looks up `employees.access_level IN ('admin','office')`.

- 🛑 **Read the email from `request.jwt.claims` (plural).** The singular `request.jwt.claim.*` key
  is never set by PostgREST. That mistake is why `audit.logs.changed_by` has been NULL for its
  entire life across 54,756 rows, and the same bug shipped again in `derm.set_row_band`. Use the
  `derm._actor(text)` implementation as the reference.
- RLS **enabled and forced** on every `hr` table, with `USING (hr.caller_is_admin())`.
- Canonical edits go through `hr.update_employee(...)`, SECDEF, admin-gated, because
  `authenticated` holds SELECT only on `employees` (§3.2).

### 🛑 Two traps that have each cost this estate real incidents

**Assert `relacl` after creating every table, do not just write the GRANTs.** This project has 30
`pg_default_acl` entries, and `CREATE TABLE` hands out privileges *before* any GRANT in the
migration runs. `public.job_frequency_changes` shipped on 2026-08-07 with `authenticated` holding
SELECT, INSERT, UPDATE, DELETE and TRUNCATE while its own migration header asserted the opposite,
and every GRANT statement in it was correct.

**A permission probe over the Management API measures nothing.** That transport runs as `postgres`,
which owns the tables and holds `rolbypassrls`, so an owner bypasses the GRANT system entirely.
Assert with `has_table_privilege('authenticated', ...)`, or `SET LOCAL ROLE` first.

---

## 8. How the app talks to the database

**Reads through `hr.*` views, writes through SECDEF RPCs.** This is the `client.*` and `derm.*`
pattern already in use, it keeps the read surface inspectable, and it means screen changes do not
all need migrations.

Two alternatives were considered and rejected: everything through RPCs returning JSON (tighter, but
every UI change becomes a migration), and an edge-function API (only worth it if HR later needs
Indeed or Amazon integrations server-side, which is out of scope).

⚠ **A helper called from an owner-rights view runs as the CALLER.** A SECURITY INVOKER function
inside an `hr.*` view adds an invoker-side EXECUTE check to the read path, which is how
`fn_resolve_gdo_id` broke the Visit Calendar for every staff user and how the LWT `state` column
started returning `42501` to read-only roles. Any helper reached from a view is SECDEF with a
pinned `search_path`.

### 8.1 The five Quick actions

Yannick's detail screen carries a Quick actions card. Each was checked against what the database and
the estate can actually support:

| button | verdict |
|---|---|
| **Edit canonical fields** | Buildable. `authenticated` holds SELECT only on `employees`, so it is a SECDEF RPC, not a PostgREST write. `updated_at` is trigger-managed and must not be set by hand (rule 7). |
| **Update pay** | Buildable, but **its subtitle is wrong**. See below. |
| **Reassign equipment** | 🛑 **Nothing behind it.** Equipment is a separate module Yannick deferred; no catalogue, no assignment and no handoff data exists. Cut it from the first build rather than shipping a dead button. |
| **Request document** | 🛑 **Has no upload path.** See below. This is the one that needs a decision. |
| **View audit log** | Buildable, with a wrinkle: the `audit` schema is **not exposed to PostgREST**, so the app cannot read `audit.logs` directly even though `authenticated` holds SELECT on it. It needs an `hr` view or RPC. 90 audit rows already exist for `employees`. ⚠ Read the actor from `jwt_claims->>'email'`, never `changed_by`, which has been NULL for all 54,756 rows since the trigger was written. |

**"Update pay" says `Hourly + per-location + per-shift`, and per-location does not exist.** The
string appears in exactly three places in the prototype (a schema comment, a component comment and
this subtitle) and **nowhere in the data model or the edit modal**, both of which use
`per_job_rate`. Yannick's own Slack recap says *"pay / job bonus"*. So it is a stale label and the
three rates are **hourly, per-job, per-shift**, as §5.2 has them. Fix the label; do not build a
per-location rate.

#### 🛑 "Request document" assumes the employee can upload, and they cannot

The button sends *"a templated email asking for upload"*. Two measured facts collide:

- **The app is office/admin only** (decision 2), and **no field technician has an auth account**.
  Emails are domain-restricted to `@ayache.com` / `@unclogme.com`; the technicians hold personal
  gmail and yahoo addresses.
- **Aaron and Grecia have no email address at all**, so the action cannot even reach them. Seven of
  the nine active employees have one.

So the person being asked for a driver licence has nowhere to put it. **Fred chose the signed
upload link** (2026-08-31), which is the widest new surface in this design, so it is specified in
full below rather than left as a bullet.

### 8.2 Signed document upload

**One sentence:** an admin requests a document, the employee gets an email with a one-time link, and
they upload a single file without ever logging in.

#### 🛑 The page CANNOT be served by the edge function

`*.supabase.co` force-rewrites any `text/html` response to `text/plain` + `nosniff`, on both edge
functions and storage. It is a domain-wide anti-abuse rule and it was proven on both surfaces on
2026-07-17, when a plan to serve the DUMP Schedule app from an edge function was abandoned for
exactly this reason. A browser would show the page source instead of rendering it.

⇒ **Two halves, and they live in different places:**

| half | where | why |
|---|---|---|
| the upload **page** | a public route in the HR Lovable app, Cloudflare-fronted (`*.unclogme.app`) | only a real host renders HTML |
| the upload **API** | edge function `hr-document-upload`, `verify_jwt = false` | JSON and multipart are unaffected by the rewrite |

#### The token is the gate, and origin is not a substitute

21 edge functions already run `verify_jwt = false`, gated by a shared secret (`x-rpa-key`), an
origin allowlist (`get-derm-doc`, `get-permit-doc`), or a manually verified user token. **This one
cannot use any of them.** The caller is a member of the public with no account, and an `Origin`
header is trivially forged outside a browser, so origin checking here is CSRF defence in depth and
**not authentication**. The token is the only thing standing between the internet and the bucket.

- **32 random bytes, base64url.** Guessing is the only attack, so entropy is the control.
- **Stored as a SHA-256 hash, never in plaintext.** `hr.document_request` holds `token_sha256`, and
  lookup is BY that hash. If the table is ever read by the wrong person, the tokens in it are not
  usable. Same reasoning as never storing a password.
- **Single use** (`used_at`), **time limited** (`expires_at`, default 7 days), **revocable**
  (`revoked_at`) so an admin can kill a link that went to the wrong address.
- 🛑 **An absent token is an explicit reject, never a fall-through.** This estate has already
  shipped a fail-open `KEY && ...` gate once; `verify_jwt = false` means nothing else is checking.

#### What the public endpoint must never do

- **Never return employee data.** `GET` returns `{doc_type, expires_at}` and nothing else. Not the
  name, not the email, not the role. A token proves someone holds a link, not who they are.
- **Never accept a storage path, a filename, or a doc_type from the client.** All three are derived
  server-side from the token row. The uploader choosing the path is how you get traversal and
  overwrite of somebody else's document.
- **Never list, read or download.** Upload only. There is no `GET` for file contents.
- **Never reuse.** One token, one document, one write.

#### Storage and validation

Files land in the **private** HR bucket (§6) at a server-derived path keyed on the request id.
Content type is checked against an allowlist (PDF, JPEG, PNG) and a size cap, both enforced in the
function rather than trusted from the client. On success the function writes the
`hr.employee_document` row and stamps `used_at` in the same operation, so a half-finished upload
cannot leave a consumed token with no document or a document with a still-live token.

⚠ **CORS: reflect the request headers, do not hand-write the allowlist.** A hand-written
`Access-Control-Allow-Headers` once blocked every app call at the preflight while manual probes
returned 200, because the failure is invisible to curl.

#### The table

`hr.document_request`: `id, employee_id, doc_type, token_sha256, expires_at, used_at, revoked_at,
created_by, created_at`. **Opts IN to audit** under rule 8: it is the record of who asked whom for
what, and when a link was used, which is exactly the trail worth keeping. RLS admin-only for reads;
the edge function reaches it as `service_role`.

#### Sending the email

`RESEND_API_KEY` is an edge secret and is **not in vault**, so Postgres cannot send. Four functions
already do this (`send-derm-email`, `send-visit-photos-email`, `health-escalate`,
`auth-recovery-watch`) and are the pattern to copy.

⚠ **Aaron and Grecia have no email address**, so the request action must refuse loudly for them
rather than silently creating a token nobody receives. Seven of the nine active employees can be
reached.
⚠ Test sends go to `fred@ayache.com` only, never a real employee address, per the standing rule.

### 8.3 Admin-initiated password reset

Fred, 2026-09-01: *"in this HR app we should be able to 'RESET' a password of a user ... obviously
that only for the admins, and the admins shouldn't need to ask for a password."*

That instinct matches current practice exactly. What follows is what the research says, then the
local facts that change the answer.

#### The principle: the admin never sets, sees, or transmits a password

Guidance is consistent across Okta, OneLogin and the SSPR vendors: send a **reset link**, do not
issue a temporary password. A temporary password means at least two people know a working
credential, and it has to be conveyed somehow, which is the opening.

**NIST SP 800-63B Rev. 4** (finalised 2025, operationally normative through 2026) permits temporary
passwords only under constraints we cannot meet:

| requirement | our position |
|---|---|
| single use, invalidated server-side on first consumption | fine |
| delivered through a channel **distinct from the primary authentication path**, and *"email to the same address used for primary authentication is explicitly disallowed"* | 🛑 **we cannot satisfy this.** Email is our only channel to staff: no enrolled push app, no verified SMS |
| expiry in *"minutes to a few hours, not days"* | fine |
| never reused across users or time windows | fine |
| forced rotation before any other action proceeds | fine |
| full audit logging of issuance, delivery, consumption, expiry | fine |

⇒ **Temporary passwords are off the table for us**, on the out-of-band rule alone. The recovery link
is the mechanism, which is what Fred asked for anyway.

#### 🛑 The local fact that changes everything: nobody here has a password

Measured 2026-09-01. Every staff account in `auth.users` is **Google OAuth**:

| person | access_level | auth account | provider |
|---|---|---|---|
| Fred | admin | yes | google |
| Yannick | admin | yes | google |
| Aaron | office | **none yet** | to be google |
| Diego | office | yes | google |
| Serena | office | yes | google |

The only two non-Google accounts are `test.agent@ayache.com` and `unclogme@unclogme.com`, neither of
which is a person.

**So a "reset password" button would do the wrong thing for 100% of current users.** An OAuth-only
account has no password to reset. Triggering a recovery link for one does not restore access; it
**sets a password for the first time**, converting a federated account into one with a second,
weaker way in. That is a widening, not a repair, and it should be a deliberate choice rather than
the accidental result of clicking a button labelled "reset".

⚠ And for a Google-federated account the identity does not live in Supabase at all. Real recovery
for Fred, Yannick, Aaron, Diego or Serena is a **Google Workspace** operation at `admin.google.com`,
not something this app can or should do.

#### What the button should actually do

Make the action **context-aware on the account it is looking at**, and label it honestly:

| account state | action | mechanism |
|---|---|---|
| no auth account | **Send invite** | `auth.admin.inviteUserByEmail` |
| Google OAuth only | **no password reset offered.** Show "signs in with Google" and point at Workspace | none |
| has a password | **Send reset link** | `auth.admin.generateLink({type:'recovery'})`, emailed via Resend |

🛑 **`auth.admin.updateUserById({ password })` IS FORBIDDEN.** That is the one call that sets a
password on a user's behalf, and it is precisely what Fred ruled out. It must appear nowhere in this
app. Generating a link the *user* consumes is the whole point: the admin's power is to start
recovery, never to hold a credential.

Everything runs **server-side in an edge function with the service key**. `generateLink` creates
users for some link types and must never be reachable from the browser.

#### The real threat here is the admin, not the mechanism

The dominant 2024 to 2026 attack on this exact feature is social-engineering the person who can
press the button. Scattered Spider's documented playbook (CISA advisory AA23-320A) is to phone the
service desk posing as a locked-out employee, claim a lost phone, and have credentials or MFA reset.
A perfect mechanism does not help if the admin is talked into using it.

**Our position is unusually strong, and the spec says so rather than importing enterprise help-desk
theatre:** there are **two admins**, Fred and Yannick, **nine active staff**, and everyone knows
everyone personally. So:

- **Verify out-of-band on a channel you already hold for that person**, their known phone number,
  never a number supplied in the request.
- **Never act on an inbound email alone.** An emailed request to reset an account is the attack.
- ⚠ The risk grows with the team. This is a human habit today; if headcount passes the point where
  an admin recognises everyone, it has to become a written procedure.

#### Logging and notification

`hr.auth_action_log`, audited under rule 8: who requested, for whom, action type, issued at,
consumed at, expiry. NIST asks for issuance, delivery, consumption and expiry, and this is the trail
that answers "who reset Serena's account, and when".

**Notify the target user by email on every action against their account**, including when an admin
starts a reset. A user receiving an unexpected "an admin requested a password reset on your account"
mail is the last line of defence against a socially-engineered admin.

⇒ Rate-limit per employee, and keep the recovery link lifetime short. Supabase's default is
generous; NIST's "minutes to a few hours" is the target.

#### ✅ Auth was down, and came back on 2026-09-01

**Superseded, and kept because the reasoning still applies next time.** This section previously read
*"None of this is buildable today: Auth is DOWN"*, with `public.auth_recovery_state` at
`status='down'` and the staff apps in the temporary no-auth "Default" mode.

**Verified live 2026-09-01 10:58 ET** with `scripts/probes/auth_recovery_check.js`: jwks.json 200
with a real key, `/auth/v1/health` 200, `/auth/v1/settings` 200, and the login probe returning 400
on bogus credentials, which is GoTrue actually processing again rather than merely answering. The
emergency window was closed at **10:11 ET** (`app_config.emergency_access_until` set to the
`2000-01-01` sentinel), so the apps are back on normal login.

⇒ **The blocker is lifted.** Invites, recovery links and Aaron's account can all be built and
tested, and the `admin`/`office` gate is enforceable again.

🛑 **BUT THE WATCHDOG NEVER FIRED, AND STILL CANNOT.** `auth-recovery-watch` was deployed on
2026-08-31 to email Fred the moment Auth returned. It never did, and the reason is not a bug in the
function: **it has no cron job.** Checked against all 24 rows of `cron.job`, none is auth-related,
while `public.fn_request_auth_recovery_watch` exists and the edge function is deployed. It ran once
by hand at 09:17 ET, recorded `down`, and was never invoked again, so `auth_recovery_state` sat
stale at `down` for the hour and three quarters AFTER Auth had recovered.

⇒ This is the `never-executed` class exactly: a surface that is deployed, correct, and has never
run. `scripts/checks/never-executed.mjs` exists to make that state visible. **Arming it is a
one-line cron and it is the whole point of having built it**, because the next outage gets the same
silence otherwise.

⚠ Also left behind by the emergency mode: `public.emergency_whoami()` still exists. It is
SECURITY **INVOKER**, `anon` cannot execute it, and it only reflects the caller's own JWT claims
back at them, so it is leftover scaffolding rather than exposure. The documented revert order says
to drop it.

#### Sources

- [NIST SP 800-63B Rev. 4 temporary password requirements](https://credentialgovernance.avatier.com/en/blog/temporary-password-best-practices-2026)
- [Specops, self-service password reset best practices](https://specopssoft.com/blog/password-reset-best-practices/)
- [OneLogin, help desk password reset best practices](https://www.onelogin.com/learn/help-desk-password-reset-best-practices)
- [Okta, reset a user password](https://help.okta.com/en-us/content/topics/users-groups-profiles/usgp-reset-individual.htm)
- [CISA advisory AA23-320A, Scattered Spider](https://www.cisa.gov/news-events/cybersecurity-advisories/aa23-320a)
- [Specops, Scattered Spider service desk defence](https://specopssoft.com/blog/scattered-spider-service-desk-defense-tips/)
- [Supabase, generateLink admin API](https://supabase.com/docs/reference/javascript/auth-admin-generatelink)
- [Supabase, inviteUserByEmail](https://supabase.com/docs/reference/javascript/auth-admin-inviteuserbyemail)
- [Supabase, password-based auth](https://supabase.com/docs/guides/auth/passwords)

---

---

## 9. Prerequisites outside the migrations

1. ✅ **DONE 2026-08-31.** `hr` schema created and exposed to PostgREST. `db_schema` went
   `public,graphql_public,customer,derm,ops,client` → the same list plus `hr`, appended by
   read-modify-write so no existing entry could be dropped. All six exposed schemas verified still
   serving afterwards with `scripts/probes/rest_smoke.mjs`.
2. ✅ **DONE 2026-08-31.** All six `access_level` rows corrected and
   `employees_access_level_chk` added VALIDATED (`2026-08-31_1330`). `scripts/populate/populate.js`
   changed in the same commit, because it was the writer that produced `dev` and would have
   re-introduced it.
3. ✅ **Aaron's email is set to `aaron@unclogme.com`** (`2026-09-01_0930`), so all five admin and
   office employees now resolve by JWT email. ⏳ **His auth account still has to be created**,
   which needs GoTrue back up.
4. ✅ **Supabase Auth is BACK** as of 2026-09-01, verified live (§8.3). The emergency window is
   closed and the apps are on normal login, so the gate is enforceable and auth work is unblocked.
5. ⏳ **Arm `auth-recovery-watch` with a cron job.** It is deployed but unscheduled, so it never
   sent the recovery mail it exists to send, and the next outage would be equally silent.
6. ⏳ **Drop `public.emergency_whoami()`**, the last step of the documented emergency revert.

---

## 10. Open

- ✅ **"Request document" is DECIDED**: signed upload link, specified in §8.2 (Fred, 2026-08-31). It is the widest new surface here, so build it last and review the token handling before it is exposed.
- **Driver / Helper / Plumber** is deferred by decision 3. When it returns, the sweep is small and
  already measured: no CHECK constraint on `role`, no function reads it, and all four dependent
  views (`client.employees`, `ops.v_calendar_driver`, `ops.v_calendar_visit`, `ops.v_driver_kpi`)
  pass it straight through. The remaining work is an app-side sweep for code badging on
  `'Technician'`.
- **Whether `shift` matters here.** The prototype shows a Shift column; Prod holds the column but
  its content has not been reviewed for this purpose.

---

## 11. Risks

| risk | mitigation |
|---|---|
| Building against the prototype's fictional roles and access levels | §3.1 lists the real values; the build reads them from Prod, never from the mockup |
| HR documents landing in a public bucket | §6, explicit `public: false`, signed URLs |
| New tables born with grants nobody wrote | §7, assert `relacl` against a sibling table in the migration itself |
| `access_level` silently drifting once it gates access | §4, CHECK constraint so a bad value fails loudly |
| Pay history needed sooner than expected | §5.3, table shaped so the migration is additive |
| Two days is optimistic once the access_level correction and bucket setup are counted | Those are §9 prerequisites and can be done ahead of the UI work |
