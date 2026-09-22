# Review: Jonathan's "SSO button" ask (Tracker to Monthly Reporter)

*Fred, 2026-09-22: "read this Thread ... and i need you to do a full review on does he needs this? if
he does, why? how should we do it, what about his approach."*
Thread: Slack `C0BD3VDPB9S`, parent `1790060091.252309`, two replies. His written contract lives in
his repo at `docs/REQUIREMENTS_TRACKER_SSO.md`, which we have not seen; this reviews the Slack summary.
Our side of the same integration: [`postman/README.md`](../../postman/README.md) sections 2, 4c, 4d and
5, [`docs/integration.md`](../integration.md), and the design in
[`docs/specs/2026-08-24-lwt-monthly-endpoint-design.md`](../specs/2026-08-24-lwt-monthly-endpoint-design.md).

---

## 0. The short answer

**Two of his three reasons are real. His design solves the one that matters in the wrong place, and the
piece he needs from us that he thinks is hard is already free.**

- Reason (a), the identity on the compliance record, is **real and it is our problem, not his**. But
  none of his four requirements touch the code path that writes that identity into our database. SSO
  at his front door leaves `public.lwt_filings.filed_by_email` exactly as trustworthy as it is today.
- Reason (b), retiring the shared RUN_KEY, is **real and it is his problem**. Nothing we give him
  retires it by itself; that has to be a thing he switches off, and it should be written down as a
  date, not implied.
- Reason (c), one click, is **convenience for a task two people do once a month**. Fine, not a reason.
- **R1 (verification material) is already satisfied and is not a deliverable.** Our JWKS is public.
- **R1's fallback, the JWT signing secret, must be refused**, and the clean way to say no is that it
  is *useless to him as well as dangerous to us*.
- **R2 (the `can_file_monthly` claim) should not be built.** His own stated fallback is the correct
  answer and costs us nothing.
- **R3 is already satisfied**, 24 times over.
- **R4 is right** about the fragment, and stays right under every option below.

**And the thing worth raising before any of this gets scheduled: 37 in-scope tickets have no filing
recorded with us, including all 16 August offloads and all 11 September ones.** That is either a
compliance gap or a gap in what he posts back, and we cannot tell which from here. It outranks SSO.

---

## 1. What he is asking for

The Monthly Reporter is his web app that files the Miami-Dade LWT monthly report. Operators type a
shared `RUN_KEY` into it. He wants the DERM Tracker (`derm.unclogme.app`) to carry a button that opens
the Reporter already signed in.

| | ask | our answer |
|---|---|---|
| R1 | our JWKS URL, or the JWT signing secret out of band | **already public. Secret: no, and it would not work** |
| R2 | a boolean `can_file_monthly` claim on the JWT | **do not build it. Use his own fallback** |
| R3 | `exp` <= 24h, `iss`/`aud` populated | **already true, `jwt_exp` is 3600** |
| R4 | button navigates to `.../monthly#sso_token=<jwt>`, fragment not query string | **correct, keep it** |
| L2 | later: our backend calls his `POST /sso/code`, button uses `?sso_code=` | **right idea, wrong direction. Invert it** |

---

## 2. Does he need it? Reason by reason

### (a) "The compliance record. Today that's an email typed into a text box." REAL, and it is ours

He is describing **`public.lwt_filings.filed_by_email`**, a column in our database that his app fills
by posting `rpa-derm-monthly-filed` (section 4d of the Postman README). The only rule guarding it is:

```
lwt_filings_actor_markers_agree
  CHECK ((filed_by_email IS NOT NULL) = (COALESCE(run_id,'') LIKE 'manual-%'))
```

Present when the run id says a human did it, absent otherwise. **No format, no domain, no binding to
any session.** The table is RLS-on, audited, and `service_role` holds only `SELECT` and `INSERT`, so
once a value lands it cannot be corrected, which is deliberate and makes the input quality matter more,
not less.

What is actually in there (re-measured 2026-09-22, all six rows):

| id | run_id | filed_by_email | dry_run | tickets | what it really is |
|---|---|---|---|---|---|
| 15, 16, 65 | `bot-postman-*`, `atomic-verify-*` | null | **true** | 1, 1, 2 | our own rehearsals |
| 70 | `manual-2026-08-29-backfill-...` | jon.v@ayache.com | **true** | 82 | his rehearsal of the backfill |
| 73 | `manual-2026-08-29-backfill-...-a2` | jon.v@ayache.com | false | 81 | real, but a Jan to Jun **backfill by the integrator** |
| 74 | `manual-2026-09-18-sp00013840` | **fog@unclogme.com** | false | 15 | **the only real operator filing that exists** |

So the entire live surface of reason (a) is **one row**. And that one row is the argument, because
**`fog@unclogme.com` is not a person and is not even an account**: our `auth.users` holds 8 accounts
(7 real), every one of them `@ayache.com` or `@unclogme.com`, and `fog@` is not among them. A shared
mailbox was typed into a text box and is now permanently recorded as the filer of a county report.

So he is right that this is weak. He is wrong about where the weakness is.

### (b) "The shared key has to go." REAL, and nothing here retires it on its own

A shared typed key cannot be revoked for one person and cannot tell people apart. True. But note that
**no option below deletes his RUN_KEY**; it only stops being the thing people use daily. If (b) is a
real goal it needs a date and an owner on his side, or we will ship (c) and call it (b).

Worth saying out loud because it cuts against us too: our own `x-rpa-key` is also one shared key, and
it is held by **both** the RPA bot and the Monthly Reporter. Revoking the Reporter today means breaking
the bot. That is acceptable for a server-to-server key living in a Railway variable, and it is worth
him knowing we see the asymmetry rather than lecturing him about shared credentials.

### (c) "One click for the operators." Real, minor

One human, once a month, pastes a key. Worth having, worth nothing on its own.

---

## 3. What his four requirements actually cost us (measured, not estimated)

**R1, verification material: already done, nothing to send.**
`https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/.well-known/jwks.json` returns **HTTP 200,
unauthenticated**, one ES256 P-256 key, `kid 7c7a6b3f-ee61-4b05-8a15-1afa5f6a8baf`. He can fetch it
right now. The only thing he needs from us is the project ref, which is in every URL he already calls.

**R1's fallback, the JWT signing secret: refuse, and refuse on the practical ground first.**
Two independent reasons, and the first is the one to put in the reply because it is not a trust
argument:

1. **It cannot do the job.** This project signs user sessions with **ES256** and verifies them from the
   JWKS above. The HS256 signing secret would not verify a single DERM Tracker token. Confirmed on our
   own side: the Admin Review auth gate calls `getClaims()`, which verifies locally via WebCrypto
   against that exact `kid` (changelog 2026-08-26).
2. **It is the crown jewel.** Our live `SUPABASE_SERVICE_ROLE_KEY` is an **HS256 JWT**,
   `role: service_role`, `iss: supabase`, **exp 2036-04-02**, signed by that same secret. We also
   already run a function, `emergency-session`, whose whole purpose is to use that secret to mint an
   `authenticated` session for an identity with **no row in `auth.users`** (shipped during the
   2026-08-31 GoTrue outage). So the secret demonstrably mints both "anyone" and "everything", for the
   next ten years, and it cannot be rotated without re-keying every app on the project.

**R3, token hygiene: already satisfied.** `jwt_exp = 3600`. He asked for 24h; we are at 1h.

**R3's `iss`/`aud` pin: draws a much weaker boundary than he thinks.** Every token this project mints
carries the same issuer and `aud: authenticated`. Pinning them proves "some account on our Supabase
project", and signup is open to **any** `@ayache.com` or `@unclogme.com` Google account (auth hook
`hook_before_user_created` to `public.fn_restrict_signup_domains`, which allows exactly those two
domains and rejects everything else with a 403). So R1 plus R3 together mean "an UnclogMe employee",
never "allowed to file to the county". **That makes R2 the only real authorization boundary in his
design, which is the opposite of how he presented it.**

**R2, the claim: do not build it, and tell him why he does not need it.**
There is no mechanism for it today. `hook_custom_access_token_enabled = false`, and
`raw_app_meta_data` on all 8 users carries nothing but `{provider, providers}`. Adding it means either
writing `app_metadata` per user, which rots on every hire, or enabling a custom access token hook,
which changes the shape of every token every app on this project receives. Neither is worth it, because:

- **The `email` claim is already in every access token**, signed by the IdP, and it is what our own
  gates key on today. His own stated fallback, a server-side allowlist, is therefore
  **cryptographically exactly as strong as the boolean claim he asked for**. His worry was that "the
  list lives (and rots) on our side", meaning his side. With 2 to 4 operators and a monthly cadence,
  that list rots slower than a per-user metadata write would.
- 🛑 **One trap to hand him explicitly:** do not key authorization on anything in **`user_metadata`**.
  It rides in the token, and it carries Google's `hd` claim, so it looks perfect. It is also
  **user-writable** through `auth.updateUser`. `app_metadata` and the top-level `email` are safe;
  `user_metadata` is self-asserted.

**R4, the fragment: he is right.** Fragments do not reach server logs or `Referer`. Keep it whatever we
build. It is worth noting the residual he did not mention: a fragment still lands in browser history
and is readable by any script on his page. That matters a lot for a one-hour bearer token for our whole
project, and very little for a 60-second single-use code, which is one more reason to prefer the code.

---

## 4. What is wrong with his approach

**The main one: R1 to R4 harden the wrong door.**

His reason (a) is about a value in *our* database. That value arrives through
`POST /functions/v1/rpa-derm-monthly-filed`, authenticated by the shared `x-rpa-key`, carrying
`filed_by_email` as a free JSON string, **in a separate call made after the county form is submitted**.
Nothing in R1 to R4 goes anywhere near it. Build exactly what he asked for and the compliance record is
improved by zero: he would have a verified session, and would still hand us a string.

So **whatever we build must produce something we can resolve on the write path.** That is the
acceptance test for any of the designs below, and it is the sentence to put in the reply.

**Second: Level 2 points the wrong way.** He proposes that he exposes `POST /sso/code` and we call it.
That inverts the one property this integration has been built on since July. Postman README section 5:
*"There is no push from us, you don't expose any endpoint"*, and section 10: *"You expose nothing to
us, you poll."* His version creates our first outbound dependency on his service, a new secret on our
side, and an availability coupling at exactly the worst moment: if his endpoint is slow or down, our
button fails in our app.

**Third, minor: `aud`.** If he pins `aud`, he pins `authenticated`, which every one of our six apps
mints. It is not an audience restriction in any useful sense. Not a flaw in his thinking so much as a
thing he cannot know from outside.

**What he got right, and it is most of it.** Fragment not query string. Not putting the JWT in a query
string because of the leak class he has already paid for once. Offering a fallback for R2 rather than
blocking on it. Level 2 existing at all, which is the correct end state. Saying plainly that nothing
blocks on our timeline and the RUN_KEY stays as break-glass. And the closing line, *"if it is too
complicated for you to integrate let me know and I'll see another way"*, deserves a straight answer
rather than a slow one.

---

## 5. How we should do it

### Option C first, and it needs no SSO at all: record the filing from the Tracker

**This is the one I would ship, and it closes reason (a) completely.**

We already do exactly this, one grain down. `record-manual-gdo-report` exists because the RPA bot
sometimes cannot file a per-visit GDO report and a person files it by hand. It is `verify_jwt = true`,
gated on a signed-in `@unclogme.com` / `@ayache.com` staff session, and **the actor comes from the
session, never from the request body**. The DERM Tracker already renders its button at `/visits/:id`
(DERM Tracker CLAUDE.md rule 12).

The monthly version is the same shape: a "Mark this package filed" action in the Tracker, an edge
function that resolves the email from `auth.getUser()` and writes `lwt_filings` through the existing
RPC. The person files the county form in his Reporter, as they do now, then records it where we already
know who they are.

- Delivers (a) **in full and permanently**, because the free-text field stops being the source.
- Delivers nothing for (b) or (c).
- Costs: one edge function copied from a shipped pattern, one button, no new table, no new secret, no
  protocol, **and nothing at all from Jonathan**.
- `fog@unclogme.com` stops being a filer the day it ships, because it is not an account.

### If we also want (b) and (c), then SSO, and build Level 2 inverted

Not Level 1. **We mint, he redeems, against our API, with the key he already holds.**

1. New edge function, staff JWT gated (the `archive-client` / `record-manual-gdo-report` pattern:
   `verify_jwt` at the gateway plus an in-function `auth.getUser` and a domain check). It returns a
   single-use code with a short TTL. **The authorization decision happens here**, so R2 never needs to
   exist as a claim: we simply do not mint a code for someone who may not file.
2. The Tracker button navigates to `https://<reporter>/monthly#sso_code=<code>`. His page reads the
   fragment, clears it, and calls us.
3. His server redeems the code at a new endpoint on **our** API with the `x-rpa-key` it already has.
   We return the operator's email and display name, and he opens his own session as he does today.
4. 🛑 **The half that actually delivers reason (a), and the reason this is not just a nicer login:**
   the redeem also returns a **filing actor reference**, and `rpa-derm-monthly-filed` starts accepting
   it. When it is present we resolve `filed_by_email` ourselves from the code we issued and **ignore
   the string in the body**. Without this step the inverted design is open to exactly the criticism
   this review makes of his: it binds the login, not the filing.

Why this shape:

- No JWKS dependency, no custom claim, no secret handover, no JWT for our whole project riding in a
  browser.
- **Keeps the direction of travel.** He still only ever calls us. No new outbound dependency, no new
  secret on our side, and his service being down cannot break our button.
- The authorization list lives with us, where the accounts are.
- Honest cost that his pitch and the first draft of this review both skipped: it needs **one small
  table** for the codes, and in this estate a new table is not free. Rule 8 means it opts in to
  `audit.logs` in the migration header, it needs RLS, and it needs explicit grants, because
  `2026-08-26_1815_lwt_filings_lock_down.sql` exists precisely because a `CREATE TABLE` here silently
  handed `UPDATE` / `DELETE` / `TRUNCATE` to `authenticated` through default privileges.
- Residual to accept and say out loud: a code we issue becomes a session **in his app**, and our
  sign-out is global across `unclogme.app` by construction but has no reach into his session. A short
  Reporter session lifetime is the only control, and that is his to set.

### What I would not do

- **Not the JWT signing secret.** Ever, and it would not work anyway.
- **Not `can_file_monthly` as a JWT claim.** The `email` claim plus a list is equally strong and costs
  nobody a migration.
- **Not his Level 2 as written**, with us calling him.
- **Not a domain move.** Putting the Reporter on `*.unclogme.app` would let it read our shared session
  cookie (`sb-wbasvhvvismukaqdnouk-auth-token`, `Domain=.unclogme.app`, deliberately not HttpOnly).
  That is real and it is tempting, and it is wrong: it hands a third-party app our live tokens by
  default rather than a scoped, expiring credential on purpose.

### Sequencing, and one thing that must not be a surprise

If we do tighten `filed_by_email`, **do not flip it**. His integration is live and the call happens
*after* the county form has been submitted, so a new 400 there would fail at the worst possible moment
and produce exactly the "did it file or not" ambiguity the whole design was built to prevent. Accept
both shapes, watch until the old one stops being used, then close it.

---

## 6. What to put to him before scheduling any of this

**37 in-scope tickets have no filing recorded with us** (measured 2026-09-22, `derm.v_lwt_monthly_rows`
in scope, against `derm.v_lwt_ticket_reported`):

| offload month | in scope | recorded | **not recorded** |
|---|---|---|---|
| Jan to May | 74 | 74 | 0 |
| Jun | 11 | 10 | **1** |
| Jul | 20 | 11 | **9** |
| Aug | 16 | 0 | **16** |
| Sep | 11 | 0 | **11** |

⚠ **This does not prove August was not filed.** `reported` means we hold a mark-as-filed record, and
the filing window is his invoice package, not our month. He may have filed and not posted
`rpa-derm-monthly-filed`. **That ambiguity is the point**: today the only way we know whether a county
report exists, and who filed it, is what he chooses to post back. That is the same weakness as reason
(a), one level up, and it is worth more than the SSO button.

Also open from 2026-09-18 and never answered: whether he wants `month=` or `unreported=1` for the
period, and the Cloggy no-decal case on ticket 310590.

Questions that do have to go to him for the SSO itself: the Reporter's exact origin, what his session
lifetime is once he has one, and who he considers authorized to file, since that list is the thing that
replaces R2.

---

## 7. How this was checked

Every number here is from the live project or the repo on 2026-09-22, read-only, no writes and no
deploys. JWKS by public `curl`. Auth config and the signup hook through the Management API and
`pg_get_functiondef`. Accounts, filings, constraints, grants and the unreported table through
`tools/qf.js`. The service-role key was decoded locally for its header and non-secret claims only; no
secret was printed, logged or written.

**A correction worth recording, because the first draft of this review was wrong.** It said three
filings carry a typed identity and read that as "3 in 3 weeks". Four of the six rows are `dry_run`
rehearsals and one of the two real ones is the integrator's historical backfill, so the true figure is
**one** real operator filing. An adversarial pass caught it and I re-measured rather than accepting
either version. The corrected number is a stronger argument than the one it replaced, not a weaker one,
which is the second time on this integration that a right conclusion was sitting on a wrong count.
