# ADR 019 — DERM storage: private buckets + signed URLs

**Date:** 2026-07-01
**Status:** Accepted — edge fn shipped; bucket-flip staged (see Rollout)
**Supersedes:** the 2026-05-20j "accept public buckets for the interim" posture
**Related:** ADR 017 (address-sheet privacy — the customer-view + redaction half), ADR 010 (audit trail)

## Context

Two Supabase Storage buckets on Prod (`wbasvhvvismukaqdnouk`) hold DERM documents and were **public
with enumerable sequential paths**, so one legitimate URL let anyone walk every manifest:

| Bucket | Written by | Path | Was |
|---|---|---|---|
| `GT - Visits Images` | pdf-service `upload_pdf()` | `derm/{manifest_id}/{fog\|address\|manifest}.pdf` | `public=true` |
| `manifests` | DERM Tracker edit modal | `derm/{manifest_id}/{type}_{n}.{ext}` | `public=true` + an anon SELECT policy |

`manifest_id` is a sequential BIGINT, so `derm/1/…`, `derm/2/…` are guessable. The sensitive object is
the **raw DERM Address sheet** — it rosters **every client on a shared dump ticket** (of 91 distinct
sheets, 75 were multi-client, up to 18 clients each). Confirmed live: an unauthenticated GET of a raw
address object returned `200 image/jpeg`.

ADR 017 closed the **customer-view** half (the Field Portal stopped serving the raw address page, and
2026-07-01 the `fog_manifest_url` became a per-client **redacted** FOG — leak-proof by construction).
But the raw object was **still public + enumerable at its literal path** — that is the remaining leak
this ADR closes. (`gdo-permits` is a **separate** bucket, deliberately public since 2026-06-24 —
regulatory records, no co-client rosters — and stays public.)

## Decision (Fred, 2026-07-01): **private buckets + signed URLs**

1. **`get-derm-doc` edge function** (shipped — `supabase/functions/get-derm-doc/index.ts`, commit
   `cb7ed69`). Input `{ manifest_id, client_code, kind: 'fog'|'address'|'manifest' }`; returns
   short-lived (1 h) `createSignedUrl` for that kind's sheet(s). For `address`/`manifest` it reads the
   `derm.manifests` **view** so it returns the same **union** the apps render; `fog` (per-client) comes
   from the raw column. `verify_jwt=false` (the anon frontends hold no secret), origin-restricted to
   `fp.unclogme.app` + `derm.unclogme.app`.

2. **Authorization = slug-scoped ("slug-scope now, harden later").** The fn authorizes each call: the
   manifest must belong to the passed `client_code` (its own `client_id`, or a linked non-deleted
   visit's) — otherwise `403`. This stops the **blind `manifest_id` enumeration** the public bucket
   allowed. **Caveat:** `clients` has no per-client UUID/`public_id` today — the only slug is
   `client_code`, which is **guessable**, so a caller who already knows a client's code can still reach
   that client's *own* docs (same trust as the QR). Closing that residual (a real per-client token or
   app auth) is the deferred **"harden later"** step.

3. **Flip both buckets private** — `UPDATE storage.buckets SET public=false` on `GT - Visits Images`
   **and** `manifests`, and drop the `manifests` anon SELECT policy. A dormant `authenticated`-read RLS
   policy already exists on both and activates on the flip; the service-role edge fn reads regardless.
   **STAGED, not yet run** (see Rollout).

4. **Raw-sheet contract (pdf-service).** `upload_pdf()` stores **public URLs** in
   `derm_manifests.{derm_address_url, fog_manifest_url, derm_manifest_url}`; those 404 once private.
   `get-derm-doc` already tolerates **both** a stored public URL and a raw `bucket/path`, so pdf-service
   can switch to storing paths as a later cleanup without a flag day. Coordinate the pdf-service change
   (Building Apps' repo) so no consumer breaks mid-flight.

## Rollout — order matters (zero-downtime)

Signed URLs work on a *public* bucket too, so the flip must come **last**:

1. ✅ **Ship `get-derm-doc`** (done 2026-07-01, tested: valid→3 urls, wrong-client→403, unknown→404,
   signed URL resolves 200).
2. ⏳ **Building Apps repoints** Field Portal + DERM Tracker to call `get-derm-doc` instead of embedding
   the public URL — done **while buckets are still public** (a Lovable-app task; not the Supabase
   session's — never two sessions on one Lovable project).
3. ⏳ **Verify** the apps load docs via the fn.
4. ⏳ **Flip the buckets private** (the only breaking step) — after step 3, with Fred's go.

Doing the flip before the repoint would 404 every DERM image on the live customer Field Portal in
between — explicitly avoided.

## Consequences

**Positive:** the enumerable-path leak is closed (no walking `manifest_id`); access is authorized +
time-boxed (1 h); ops/customer rendering is unchanged (union preserved); `gdo-permits` untouched.

**Negative / residual:** `client_code` slug is guessable (→ harden later); every DERM image load now
costs a fn round-trip for a fresh signed URL; the pdf-service URL→path contract is a follow-up to keep
tidy. Server-side consumers (e.g. backfills, the address→client mapping engine) should read the private
buckets via the **service-role key directly**, not `get-derm-doc` (that's only for the anon frontends).

## References
- Edge fn: `supabase/functions/get-derm-doc/index.ts` (commit `cb7ed69`); config `verify_jwt=false`.
- Handoff/spec: `docs/handoffs/2026-07-01_derm_storage_private_signed_urls.md`.
- Staged flip groundwork: `scripts/migrations/security_hardening_2026_05_05.sql` (~L125-143 + dormant RLS ~L88); `docs/migrations/2026-05-27_create_manifests_bucket.sql` (anon SELECT policy to drop).
- Redaction half (shipped): pdf-service commits `6110e51`, `8466973`; ADR 017 (2026-07-01 update note).
