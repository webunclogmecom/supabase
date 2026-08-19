# 2026-08-19 · Approval-proof images: storage, structure and whether the evidence is believable

*Fred: "is the whole process about how to store it, where to store it, relationship in our db about
the image, architecture, all that it takes to be saved in our db been processed, think it through for
it? good practices and good structure is fundamental. Do an audit."*

Five independent read-only investigations (storage layer, relational model, write path, read path,
architecture) against live Prod. Everything below is measured unless marked as inference.

---

## The verdict in one line

**The bucket is sealed. The evidence record is not.** Storage is the best-built photo path in this
system — genuinely private, proven with a positive control. But the thing the app actually *counts*
and *shows* — a row in `public.photo_links` — can be fabricated from a browser in one request, and
"Remove proof" does not remove anything.

---

## 1. What is genuinely well built (and better than the rest of the system)

| | evidence |
|---|---|
| **The bucket really is private** | `approval-proof`: `public=false`, `file_size_limit=5242880`, `allowed_mime_types={image/jpeg,image/png}`. Exactly **one** policy touches it: `approval_proof_staff_read`, `polcmd='r'`, `polroles={authenticated}` read from `pg_policy`, not from the policy name. |
| **Proven, not assumed** | 🛑 **Positive control:** the same instrument, with **no** Authorization, **no** apikey and no cookie, fetched a `GT - Visits Images` object and got **200 / 975,601 bytes**. The proof bucket refused. A sweep that returns "sealed" for everything would have returned it for both. |
| **Write path validates server-side** | `save-client-job` checks `content_type ∈ {image/jpeg,image/png}`, `PROOF_MAX = 3`, `PROOF_MAX_BYTES = 2_500_000` **before decode**, and gates on a staff email domain via `auth.getUser()`. |
| **Paths leak nothing** | `client-app/job-frequency/<jobId>/<uuid>.jpg` — no client name, no email, not guessable. |
| **Two previously-recorded defects ARE fixed** | The signing helper no longer hardcodes `GT - Visits Images` (it passes `approval-proof` explicitly), and a failed signature renders **"Unavailable" + Retry with `role="alert"`** rather than the documented empty frame. Both verified in the shipped bundle. |
| **The base table was locked down** | `public.job_frequency_changes` has RLS off but grants only to `postgres`/`service_role`/`yannick_readonly`; `has_table_privilege('authenticated', …)` is **false** for all four verbs. The 2026-08-07 `CREATE TABLE`-grants defect did not recur here. |

**So the storage design is right, and the "structure first" instinct that delayed this feature was
the correct instinct.** The problems are one layer up.

---

## 2. 🛑 THE CORE DEFECT: the proof record is forgeable from a browser

**Four of the five agents found this independently.**

`authenticated` holds the INSERT grant on `public.photo_links`, and the INSERT policy is only
`auth.uid() IS NOT NULL`. The guard trigger `trg_aa_photo_link_target_exists` validates
**`entity_type='visit'` and nothing else**. So a signed-in staff browser can `POST /rest/v1/photo_links`
with `entity_type='job_frequency_change'`, any `entity_id`, `role='approval_proof'` and any `caption`.

`client.job_frequency_changes.proof_count` is literally:

```sql
select count(*) from photo_links pl
 where pl.entity_type='job_frequency_change' and pl.entity_id=c.id
   and pl.role='approval_proof' and pl.deleted_at is null
```

⇒ **The forged row increments the number the Cadence history panel reports.** No image, no mime
check, no size check, no 3-image cap, no staff-domain gate, no client-ownership check, and `caption` —
the documented author field — is attacker-chosen.

**Why this matters more than a normal permissions gap:** this record exists specifically to hold
someone accountable for a cadence change. It is defeated by exactly the person it exists to check.
The edge function is a **front door, not a boundary**.

---

## 3. 🛑 "Remove proof" removes nothing

Measured on all 9 existing links (test fixtures on 112-YA, all soft-deleted, two reasoned
*"Removed in the Client App by fred@ayache.com"*):

| after "Remove" | state |
|---|---|
| `photo_links.deleted_at` | set ✅ |
| storage object | **still there** — 9 objects, 14 kB |
| `public.photos` row | **still there** — 9 rows |
| readable by other staff? | **yes** — `SET LOCAL ROLE authenticated` returns all 9 `storage_path` values (the three SELECT policies on `photos` are all `USING (true)`). Control: `anon` gets `42501`. |
| still fetchable? | **yes** — a signed URL for a "removed" object returned **200 / image/jpeg / 4,104 bytes** with no auth headers |

**The user is told the file is gone. It is not, and there is no path in the product that deletes it.**
The realistic case is an operator noticing their WhatsApp screenshot contains a phone number or an
unrelated conversation, hitting Remove, and reasonably believing they have fixed it.

---

## 4. Other findings, prioritised

| # | severity | finding |
|---|---|---|
| 1 | **HIGH** | **`public.photos` is the only table in the chain with no audit trigger, no soft-delete and no content hash.** Anyone with the service key can repoint `storage_path` or overwrite the object and **nothing records it**. Nobody could later show that the image displayed is the image filed. `audit.logs` holds **0** rows for `table_name='photos'`. |
| 2 | **HIGH** | **No server-side EXIF handling.** GPS stripping relies entirely on the browser canvas re-encode. Any other caller — a direct edge-function call, a future mobile client, a rebuilt UI that drops the canvas step — lands a phone photo with GPS, capture time and device model intact. This contradicts the standing rule to **normalise the INPUT, not the consumer**. |
| 3 | **HIGH** | **The dangling-link class is reintroduced for this entity kind.** `trg_aa_photo_link_target_exists` covers `entity_type='visit'` only, so a proof link can point at a `job_frequency_changes` row that never existed or was deleted (**three already were**). This is precisely what `2026-08-18_1450` was written to repair, for a different entity type. |
| 4 | **HIGH** | **No permit gate.** The proof evidences **client consent**, not **permissibility**. **26 job/GDO pairs already exceed the permitted cadence.** A perfectly evidenced approval for a cadence the permit forbids will read as well-supported everywhere downstream. "Did the client agree" is not the question a regulator asks. |
| 5 | **HIGH** | **Only the Client App path is covered.** A human editing frequency in Jobber's own UI produces no reason, no proof and no row — indistinguishable from a change that never happened. The docs call this deliberate; there is no instrument that ever surfaces it to an operator. |
| 6 | MEDIUM | The storage read policy is bucket-wide with **no client scoping**. Contained today only because all 6 auth users are on staff domains. |

---

## 5. What I recommend, in order

1. **Close the forgery hole first.** It is the cheapest and the most valuable: extend
   `fn_photo_link_target_exists` to validate `job_frequency_change` the way it validates `visit`, and
   **revoke `INSERT` on `photo_links` from `authenticated`** so the edge function is the only writer.
   The app already goes through `save-client-job`; nothing legitimate breaks.
2. **Make Remove actually remove** — delete the storage object and the `photos` row (or soft-delete
   `photos` and sweep the object), inside the same operation that soft-deletes the link. Until then
   the UI is making a promise the system does not keep.
3. **Audit + hash `public.photos`** — an `audit.log_change` trigger and a stored content hash. Without
   them this is evidence nobody can vouch for.
4. **Strip EXIF server-side** in `storeProofImages`, keeping the browser canvas step as an
   optimisation rather than the control.
5. Then, and only then, consider the permit gate (#4 above) — it is a genuine compliance gap but it
   is a *product* decision, not a defect.

## 6. Deliberately NOT recommended

- **A dedicated `proof_images` table.** The polymorphic `photo_links` bridge is the right structure
  and matches ADR 002; the problem is the missing CHECK/guard, not the shape.
- **Anything that adds ceremony for 15 rows and zero real images.** The failure mode in this system
  is over-engineering (the SA-as-reminder hack is the cautionary tale in the other direction).

---

*Method: five parallel read-only agents, each required to carry a control that must fire. Nothing was
written to the database, storage, or the repos by the audit. The forgery finding was reached
independently by four of the five.*
