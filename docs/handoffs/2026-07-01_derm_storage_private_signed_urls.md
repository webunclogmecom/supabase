# HANDOFF → Supabase session: make DERM storage private + signed URLs

**Created 2026-07-01 by the Building Apps session.** Fred chose **"Private + signed URLs"**
for the DERM storage leak. The PDF-side privacy work (FOG manifest now redacts co-clients —
see below) is **done + live**; this remaining half is a storage migration + RLS + edge function
+ multi-app repoint, which per the hybrid-routing rule belongs to the Supabase session.

> This file is intentionally left **untracked** — commit it (or fold it into an ADR) when you
> pick the work up, so two sessions don't collide on the repo.

---

## The leak (what Fred is closing)

Two Supabase Storage buckets on Prod (`wbasvhvvismukaqdnouk`) are **public** with **enumerable
sequential paths**, so any one legitimate URL lets an attacker walk every manifest:

| Bucket | Written by | Path | State |
|---|---|---|---|
| `GT - Visits Images` | pdf-service `upload_pdf()` | `derm/{manifest_id}/{address\|fog\|manifest}.pdf` | `public=true` |
| `manifests` | DERM Tracker edit modal | `derm/{manifest_id}/{type}_{n}.jpeg` | `public=true` (`docs/migrations/2026-05-27_create_manifests_bucket.sql`) |

`manifest_id` is a sequential BIGINT, so `derm/1/…`, `derm/2/…` … are guessable.

**The actual exposure is the RAW multi-client sheet** — `derm_manifests.derm_address_url`
(the `address.pdf`, and the scanned JPEGs) rosters **every client on the shared dump ticket**.
Confirmed live during investigation (status-only, no PII downloaded): an unauthenticated GET of
`derm/{id}/address.jpg` returned `200 image/jpeg`. Of 91 distinct sheets, **75 are multi-client
(max 18 clients)** — so the blast radius is large.

> The customer-facing `fog_manifest_url` is now **per-client-safe** (redaction shipped today),
> and the Field Portal stopped serving the raw `address.pdf` back on 2026-05-20j (Path C). But
> the raw object is **still public + enumerable at its literal path** — that's the leak.

## Groundwork already written but NEVER run

- `scripts/migrations/security_hardening_2026_05_05.sql` **lines ~125-143** spell out the exact
  deferred step: `UPDATE storage.buckets SET public = false WHERE id = 'GT - Visits Images';`
  plus the `createSignedUrl(path, 3600)` migration plan — left as "a separate operational step
  coordinated with Lovable." It was never executed.
- A **dormant authenticated-read RLS policy** already exists on that bucket (same migration,
  ~line 88) — it activates the moment the bucket goes private.
- A repo-wide grep for `createSignedUrl` matches **only that comment block** → no signed-URL
  consumer code was ever shipped.

## Work to do (Supabase session owns 1-3)

1. **Write a `get-derm-doc` signed-URL Edge Function.** Input: `manifest_id` + `kind`
   (`fog` / `address` / `manifest` / image slot). It must **authorize the caller** — the Field
   Portal currently has **no auth beyond the QR slug** (`public_id` / `client_code`), so the
   function has to do the authorization the public bucket is doing implicitly today (validate the
   slug server-side, confirm the manifest belongs to that client). Returns
   `createSignedUrl(path, 3600)`.
2. **Flip both buckets to private:** `UPDATE storage.buckets SET public=false` on
   `GT - Visits Images` **and** `manifests`. (Drop/justify the `manifests` public SELECT policy in
   `2026-05-27_create_manifests_bucket.sql` ~lines 97-101.)
3. **Decide the raw-sheet contract.** pdf-service `supabase_client.py:upload_pdf()` currently
   **builds + stores a PUBLIC URL** into `derm_manifests.{derm_address_url, fog_manifest_url,
   derm_manifest_url}`. Once buckets are private those stored URLs **404**. Pick one:
   - pdf-service stores **paths**, consumers resolve via `get-derm-doc` (cleanest), **or**
   - consumers keep the stored value but treat it as a path and sign on read.
   Either way the URL-vs-path change in pdf-service must be **coordinated** with the consumer
   repoint so they don't break in between. (The pdf-service repo is the Building Apps session's —
   ping Fred to coordinate the contract change there.)

### Frontend repoint = Building Apps session's, AFTER you ship 1-2
- **Field Portal** (`customer.work_orders` → `fog_manifest_url` + `wwtp_receipt_url`) and
  **DERM Tracker** (`derm.manifests` view + the edit-modal image carousel) must call
  `get-derm-doc` instead of embedding the public URL.
- Do this **after** the edge fn + bucket flip are live, and **never run two sessions on the same
  Lovable project** (Building Apps trap #13). Hand back to Fred to sequence.

### Leave GDO permits PUBLIC (different posture)
The `gdo-permits` bucket was **deliberately made public** by Fred on 2026-06-24
(`2026-06-24_gdo_permits_public_bucket.sql`, "regulatory records, non-sensitive"). It's a
**different bucket** — keep it public. Only DERM goes private (DERM sheets name multiple clients;
GDO permits don't).

## ADR bookkeeping
- **Amend ADR 017** (`docs/decisions/017-derm-address-sheet-privacy.md`): its "Path B (blackout)
  rejected / always-hide chosen" decision was **partially adopted 2026-07-01** — a
  generated-PDF-only redaction shipped (co-clients blacked out on the authentic FOG manifest;
  leak-proof by construction, no rasterize needed). Add a status pointer at the top; don't rewrite
  the body (ADRs are immutable).
- **New ADR 019** for this storage decision: the 2026-05-20j "accept public for the interim" is
  now superseded — DERM storage goes **private + signed URLs**.

---

## Context: what already shipped (Building Apps session, 2026-07-01)
- `webunclogmecom/unclogme-pdf-service` `/generate/fog-manifest` now renders the **authentic DERM
  Address sheet** for the target client + **black redaction bars** over co-clients on the same
  `white_manifest_number` (single page: target row + ≤4 bars; sheet number stamped). No co-client
  text is ever drawn into the PDF → leak-proof by construction. Commits `6110e51`, `8466973`.
- **Fleet regenerated:** all 438 multi-client `fog_manifest_url`s re-rendered to the redacted
  style (401 first pass + 37 on serial retry — the 37 were transient Railway 500s under
  concurrency, not data bugs). Single-client sheets render identically (no co-clients to redact).
