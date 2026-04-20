# ADR 009 — Unified `photos` + polymorphic `photo_links`

- **Status:** Accepted (2026-04-20)
- **Supersedes:** [ADR 008](008-photos-normalized-out.md) — Photos in dedicated per-entity tables
- **Deciders:** Fred Zerpa
- **Related:** [ADR 002](002-entity-source-links.md) (same polymorphic pattern), [ADR 005](005-3nf-standing-check.md)

## Context

ADR 008 (April 2026) chose dedicated per-entity photo tables: `visit_photos`, `inspection_photos`, and would have added `property_photos`, `note_attachments` as Unclogme expanded photo coverage from Jobber notes and Fillout inspections.

Revisiting during the Jobber photo migration scope, Fred surfaced a sharper architectural insight:

> **Before / After is not a property of the photo — it's a property of how the photo links to an entity.**

Example: a top-down shot of a grease trap can simultaneously be
- the "after" photo of Monday's visit
- the "before" photo of Friday's next visit
- the "overview" photo of the property

Under the dedicated-tables model, representing that requires duplicating the row in three tables (or three joins with no shared identity), and all the photo's intrinsic metadata (EXIF, GPS, uploader, file info) gets triplicated.

Strict 3NF says: intrinsic attributes on the photo, relational attributes on the link. This is structurally identical to `entity_source_links` (ADR 002) — polymorphic bridge from one domain entity to another.

## Decision

**One `photos` table** holding intrinsic file/EXIF metadata. **One `photo_links` table** linking photos to any entity with a `role`.

```sql
photos
  id PK
  storage_path TEXT UNIQUE           -- path in Supabase Storage
  thumbnail_path, file_name, content_type, size_bytes, width_px, height_px
  exif_taken_at, exif_latitude, exif_longitude, exif_device
  uploaded_by_employee_id FK → employees
  uploaded_at TIMESTAMPTZ
  source TEXT                         -- 'app' | 'jobber_migration' | 'fillout_migration' | 'admin'
  created_at

photo_links
  id PK
  photo_id FK → photos (ON DELETE CASCADE)
  entity_type TEXT                    -- 'visit' | 'property' | 'inspection' | 'note' | 'vehicle' | …
  entity_id BIGINT
  role TEXT                           -- semantics depend on entity_type; vocabulary in docs/schema.md
  caption TEXT
  created_at
  UNIQUE (photo_id, entity_type, entity_id, role)
```

**Role vocabulary by entity type** (controlled in app, not DB — matches `entity_source_links` style):

| entity_type | Valid roles |
|---|---|
| `visit` | `before`, `after`, `grease_pit`, `damage`, `derm_manifest`, `address`, `remote`, `other` |
| `property` | `overview`, `access`, `grease_trap_location`, `manhole`, `other` |
| `inspection` | `dashboard`, `cabin`, `front`, `back`, `tires`, `boots`, `sludge_level`, `water_level`, `derm_manifest`, `derm_address`, `issue`, `other` |
| `note` | `attachment` (generic) |
| `vehicle` | `general` |

Dropped tables: `visit_photos`, `inspection_photos`. Both were empty at the time of migration.

`properties.location_photo_url` (inline TEXT column) deprecated but retained temporarily; will be backfilled into `photos`/`photo_links` (`entity_type='property'`, `role='overview'`) and dropped in a follow-up migration.

## Consequences

**Positive:**
- **One photo, multiple uses.** A single file can be "after Monday's visit" AND "before Friday's visit" AND a property overview with three link rows and one file.
- **All photo metadata in one place.** EXIF, uploader, device — query once across every photo in the system.
- **Zero schema churn when adding a photo-owning entity.** New `entity_type` value is a new row, not a new table. Matches the `entity_source_links` pattern the team already works with.
- **Clean migration target.** The Jobber notes migration extracts photos from notes and inserts one `photos` row + one `photo_links` row per attachment, classified at insert time.

**Negative / accepted trade-offs:**
- **Polymorphic `entity_id` can't be FK-enforced.** `photo_links.entity_id` points at different tables depending on `entity_type`. Same trade-off as `entity_source_links` — acceptable given the pattern is already established.
- **Two tables instead of one per entity.** Every photo fetch needs a JOIN. Trivial cost at scale.
- **No per-entity photo count cap.** If someone uploads 500 photos to one visit, nothing in the schema prevents it. Enforce in the app layer if needed.

**What this rules out:**
- No new per-entity photo tables. Adding a `receipt_photos` table would violate this ADR.
- No inline photo URL columns on entities. `properties.location_photo_url` is a deprecated legacy; nothing new should follow the pattern.

## Migration

Migration file: `scripts/migrations/unified_photos_architecture.sql` (applied 2026-04-20).

Follow-up: `properties.location_photo_url` backfill + drop (pending). Will be handled in the Jobber photo migration pass that also populates visit and note photos.
