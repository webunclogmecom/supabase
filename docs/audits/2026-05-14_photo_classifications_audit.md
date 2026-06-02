# Photo Classifications — Promotion to Prod Audit

**Date:** 2026-05-14
**Trigger:** Fred asked to promote Yannick's "before/after sorting" from the Admin Review App (Sandbox #1) into canonical Prod, *just the sorting part*. Need to confirm Option A is correct vs alternatives before any Prod write.
**Decision needed BEFORE Prod write:** which canonical shape + answers to Lovable questions.

---

## 1. What exists today

### Sandbox #1 (`ubtlwpcyntelgbykdatn`) — Yannick's Admin Review App

Table: `public.app_photo_classifications` — **103 rows**

| Column | Type | Notes |
|---|---|---|
| `id` | uuid (PK) | App-side surrogate |
| `external_photo_link_id` | bigint | FK to `photo_links.id` |
| `service_phase` | text | Values seen: `before` (26), `after` (42), `completion` (35) |
| classified_by / classified_at | (likely present — to confirm with Lovable) | |

**Cross-check just run:**
- All 103 `external_photo_link_id` values resolve to existing `photo_links.id` in **both** Sandbox #1 **and** Prod. No orphans. Safe to migrate as-is.

### Prod (`wbasvhvvismukaqdnouk`) — canonical

- `public.photos` — 7,365 rows, all have `storage_path` + `source`.
- `public.photo_links` — 9,379 rows: 4,320 visit / 2,476 inspection / 1,695 derm_manifest / 888 note.
- `photo_links.role` column already exists but with **different semantics** — it carries Jobber attachment categories (`'other'`, `'attachment'`, `'address'`, `'manifest'`, `'left_side'`, `'right_side'`, …). **Cannot be reused** for before/after. Different axis.

---

## 2. Options compared

### Option A — Add `photo_links.service_phase TEXT` column (CHECK constraint enum)

**Pros**
- One join less for `customer.wo_photos` and similar views.
- Tightly coupled to the entity it describes.

**Cons**
- Mixes two unrelated axes on `photo_links` (Jobber `role` + human-classified `service_phase`).
- ~99% NULL (only 103 of 9,379 photo_links rows classified today). Wide and sparse.
- No clean place for `classified_by` / `classified_at` audit metadata without further bloating photo_links.
- Awkward if we later add other classification axes (e.g. `damage_severity`, `requires_followup`).

### Option B — New canonical table `public.photo_classifications`  ← **RECOMMENDED**

```
photo_classifications (
  photo_link_id   bigint PRIMARY KEY REFERENCES photo_links(id) ON DELETE CASCADE,
  service_phase   text NOT NULL CHECK (service_phase IN ('before','after','completion', …)),
  classified_by   text,            -- email/user id from app auth
  classified_at   timestamptz NOT NULL DEFAULT now(),
  notes           text             -- optional
);
CREATE INDEX ON photo_classifications (service_phase);
```

**Pros**
- 3NF: classification is its own entity, with its own audit fields.
- Doesn't bloat `photo_links`; only carries rows that *are* classified.
- Future-friendly — add columns here without churning photo_links.
- Maps 1:1 to Yannick's current `app_photo_classifications` shape → trivial migration (just rename + FK target).
- Easy to JOIN in `customer.wo_photos` (`LEFT JOIN public.photo_classifications pc ON pc.photo_link_id = pl.id`).

**Cons**
- One extra LEFT JOIN in customer/field views.

### Option C — Generic `photo_tags(photo_link_id, tag_key, tag_value)` EAV

**Pros**
- Maximum flexibility.

**Cons**
- Loses typing/constraints on `service_phase` enum.
- Harder to query, no CHECK constraint, over-engineered for one current axis.

---

## 3. Recommendation

**Option B** beats Option A.

The audit shifted my prior recommendation. Option A was fine when I treated `service_phase` as just one more column. The audit revealed:
1. Only ~1% of `photo_links` rows would have a non-NULL value → sparse column on a wide table is poor design.
2. `photo_links` already carries a *different* semantic axis on `role` — adding `service_phase` next to it muddies the table's purpose.
3. Lovable's Admin Review App already shapes the data as its own table (`app_photo_classifications`) — Option B is just renaming that shape canonical, which means the migration is essentially data-only and the app's logic doesn't fight the schema.
4. Audit metadata (who classified, when) belongs *with* the classification, not on photo_links.

So Option B is both cleaner and easier to migrate.

---

## 4. Mirror-DB pattern — confirmation

Fred asked to confirm the "mirror Prod for each Lovable app, then promote with our standards" workflow is correct. **Yes** — pattern holds:

- Sandbox #1 (`ubtlwpcyntelgbykdatn`) → Yannick's Admin Review App
- Field Portal Sandbox (`klgtrdwrasrlxbmfyvdh`) → Yannick's Field Portal app
- Prod (`wbasvhvvismukaqdnouk`) → canonical 3NF, schema-per-app for app reads/writes

Sandboxes are the experimentation ground; we then promote with our canonical standards (3NF, typed enums, FKs, audit cols). This audit *is* that promotion process working as designed.

---

## 5. Questions for Lovable (Admin Review App) — answer BEFORE Prod write

Please paste the following to Lovable and bring back answers:

1. **Full enum** — what's the complete set of allowed `service_phase` values today? We've observed `before`, `after`, `completion`. Are there any others (e.g. `during`, `damage`, `defect`)? Are these hardcoded in the UI or stored in a settings table?
2. **Audit metadata** — does `app_photo_classifications` have `classified_by` / `classified_at` (or similar) columns? If so, what's their exact shape? If not, can the app start writing them?
3. **Re-classification flow** — when a user re-tags a photo, does the app UPDATE the existing row or INSERT a new one? (We need this to decide whether `photo_link_id` is PK, or whether we keep an `id` surrogate and have `(photo_link_id)` UNIQUE.)
4. **Auth / write path** — which Supabase role does the app write with? `anon`, `authenticated`, `service_role`, or a custom JWT? We need to size RLS / GRANTs on the new canonical table.
5. **Read pattern** — does the app currently read its own table only, or does it JOIN against `photo_links` / `photos` already? Determines whether we expose a Prod view or whether the app can read canonical directly.
6. **Foreign keys** — confirm `external_photo_link_id` is always a `photo_links.id` (BIGINT). Any chance it's ever a `photos.id` or another table's id?
7. **Migration path** — is Yannick willing to rewire the Admin Review App to read/write `public.photo_classifications` (Prod) instead of `public.app_photo_classifications` (Sandbox #1)? Or do we keep the app pointed at Sandbox #1 and only mirror classifications down to Prod as a one-way sync?
8. **Other classification axes** — anything else the Admin Review App captures beyond `service_phase` (e.g. blur/quality flags, "include in client report" toggle)? If yes, list them — that informs whether `photo_classifications` is the right table name vs `photo_metadata`.

---

## 6. Once Lovable answers, the migration path

(For reference, **do not run until questions are answered.**)

1. Migration `2026-05-14d_photo_classifications.sql`:
   - `CREATE TABLE public.photo_classifications` (Option B shape).
   - GRANTs for canonical reads + writes (scope based on Q4).
   - Index on `service_phase`.
2. Backfill from Sandbox #1: `INSERT … SELECT` the 103 rows, mapping `external_photo_link_id → photo_link_id`.
3. Update `customer.wo_photos` to LEFT JOIN `photo_classifications` and surface `service_phase`.
4. Re-include `photos` + `photo_links` + `photo_classifications` in the Field Portal subset clone script.
5. Coordinate with Yannick to rewire the Admin Review App per Q7.
6. Eventually drop `app_photo_classifications` from Sandbox #1 (after app cutover).

---

## 7. What I have NOT done

- No writes to Prod.
- No writes to Sandbox #1 (per memory rule — sandbox refresh would wipe them anyway).
- No app/Yannick coordination — pending Fred's go-ahead and Lovable answers.
