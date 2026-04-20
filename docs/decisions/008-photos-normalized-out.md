# ADR 008 — Photos live in dedicated tables, not inline URL columns

- **Status:** Accepted (2026-04)

## Context

Early drafts had photo URLs inline on `inspections` and `visits`:

```
inspections.dashboard_photo_url
inspections.cabin_photo_url
inspections.front_photo_url
inspections.back_photo_url
...
visits.before_photo_url
visits.after_photo_url
visits.manifest_photo_url
visits.address_photo_url
visits.remote_photo_url
...
```

Two problems:
1. **Variable photo counts.** A DVIR inspection might have 3 photos or 15. Pre-allocating 15 nullable URL columns is wasteful; exceeding 15 requires a schema change.
2. **No metadata.** Each photo has a type (`before`, `after`, `manifest`), timestamp, caption. Inline columns can't carry that without the column name encoding it (e.g., `before_photo_caption`, `after_photo_caption`) — even more bloat.

## Decision

Photos live in two dedicated tables:

```
inspection_photos
  id PK
  inspection_id FK → inspections
  photo_type TEXT  — 'dashboard' | 'cabin' | 'front' | 'back' | …
  url TEXT
  created_at TIMESTAMPTZ

visit_photos
  id PK
  visit_id FK → visits
  client_id FK → clients
  photo_type TEXT
  url, thumbnail_url TEXT
  file_name, content_type TEXT
  caption TEXT
  taken_at TIMESTAMPTZ
  created_at TIMESTAMPTZ
```

Any number of photos per parent. Type + metadata are first-class columns.

## Consequences

**Positive:**
- Variable photo counts handled trivially.
- Caption, thumbnail, content-type, original-filename all queryable.
- Adding a new photo type = a new `photo_type` enum value, no schema change.

**Negative / accepted trade-offs:**
- One extra JOIN to fetch photos. Acceptable; typically we aggregate via `json_agg` at the query layer.
- Empty at present (0 rows each). The Jobber notes-photos migration will populate `visit_photos`; Fillout inspection photos will populate `inspection_photos`. See [docs/migration-plan.md](../migration-plan.md#jobber-notes--photos-migration).

**Storage:** photo *files* go to Supabase Storage buckets (e.g. `jobber-notes-photos`); the `url` column holds the storage path or public URL. Buckets are private by default; signed URLs are issued to clients via Edge Functions.
