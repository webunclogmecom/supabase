# Handoff → Supabase session: DERM docs → private, without breaking 21.5k visit photos (2026-07-02)

**From:** Building Apps session. **Owns after this:** Supabase session (buckets, `storage.objects`, `get-derm-doc`, the PDF service, DB URL columns). **Building Apps keeps:** the DERM Tracker **upload-path** repoint (Lovable app) + final live app verification.

## Why the original "flip both buckets private" plan is unsafe
`GT - Visits Images` is **not** a DERM bucket — it's the main visit-images bucket. Contents (verified 2026-07-02):

| bucket | prefix | objects | what |
|---|---|---|---|
| `GT - Visits Images` (public) | `visits/` | 16,418 | before/after service photos |
| | `airtable/` | 3,492 | legacy imported photos |
| | `notes/` | 1,611 | Jobber note photos |
| | `derm/` | **2,439** | DERM docs (the leak) |
| `manifests` (public) | `derm/` | **44** | DERM Tracker uploads |
| | `_brand/` | 1 | `unclogme-logo.jpg` (33 KB) |
| `gdo-permits` (public) | — | — | separate, stays public (2026-06-24 decision) |

`GT - Visits Images` holds **21,521 non-DERM objects** loaded via `/object/public/…` by the apps (FP before/after pics, Admin Review classifier; `public.photos` has 9,331 non-DERM storage paths). **`public=false` on that bucket 404s all of them.** So the leak must be closed by moving the DERM objects OUT of the public buckets, not by flipping `GT - Visits Images`.

## App repoints are DONE (prereq complete)
Both DERM apps already fetch signed URLs via `get-derm-doc` (verified live 2026-07-02, 0 `/object/public/`):
- **DERM Tracker** (`derm.unclogme.app`): manifests card, visit-detail galleries, lightbox, Edit-modal — all `/object/sign/`.
- **Field Portal** (`fp.unclogme.app`): the 2 WorkOrderView compliance-doc links (fog + manifest kinds) — published + verified (`/object/public/GT - Visits Images/derm/350/fog.pdf` → `/object/sign/…/derm/350/fog.pdf`).

Signed URLs work on **private** buckets, so making the DERM buckets private does **not** break the apps.

## How the DB references storage (critical — get-derm-doc derives bucket from the stored URL)
`public.derm_manifests` stores **full public URLs** (URL-encoded bucket), in 5 columns:
`derm_address_url`, `derm_manifest_url`, `fog_manifest_url` (text) + `derm_address_extra_urls`, `derm_manifest_extra_urls` (text[]).
Example: `https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/1251/fog.pdf`.
- `derm.manifests` VIEW passes these through: `address_photo_url = dm.derm_address_url`, `manifest_photo_url = dm.derm_manifest_url`, `*_extra_urls` from the grouped union (`array_remove`/`array_prepend`). `fog` is read straight from `derm_manifests.fog_manifest_url`.
- `get-derm-doc/index.ts` `toBucketPath()` parses the bucket out of each stored URL (`/object/(public|sign)/<bucket>/<path>`, then `decodeURIComponent`) and signs `storage.from(bucket).createSignedUrl(path, 3600)`. **So rewriting these URL columns to a new bucket auto-repoints get-derm-doc — no per-kind bucket logic to change.** Its raw-path fallback list is `['manifests','GT - Visits Images']` (line ~57) — add the new bucket there for robustness.

## Storage facts (for the move)
- `GT - Visits Images/derm/*`: 2,439 objects across **1,011** manifest folders. Filenames: `manifest.jpg` 918, `address.jpg` 897, `fog.pdf` 456, `address_p2.jpg` 130, `address_p3.jpg` 14, `manifest.png` 10, `address.png` 10, `address.pdf` 4. (PDF-service output.)
- `manifests/derm/*`: 44 objects across 18 folders. Messy DERM Tracker upload names (`address_1.JPG`, `manifest_1.JPG`, timestamped variants).
- **15 manifest folders exist in BOTH buckets, but 0 exact-path collisions** (GT uses `address.jpg`, manifests uses `address_1.JPG`) → safe to merge into one bucket.
- Path shape is `derm/{manifest_id}/{filename}`; note the `{manifest_id}` in the path can differ from the row `id` (e.g. row 1249's address URL points at `manifests/derm/1246/…`) — **always move/rewrite by the URL's own path, never reconstruct from row id.**

## Write paths that MUST be repointed (else new manifests re-leak)
- **PDF service** (`webunclogmecom/unclogme-pdf-service`, Railway) via edge fns `generate-fog-manifest` / `generate-derm-address-pdf`: writes `fog.pdf` / `address.jpg` / `manifest.jpg` → **`GT - Visits Images/derm/{id}/`** + stores the public URL in `derm_manifests`. Repoint the upload target + the stored URL to the new private bucket.
- **DERM Tracker upload** (Lovable app, Building Apps): writes raw images → **`manifests/derm/{id}/`**. ⟵ **Building Apps (me) will repoint this** once you tell me the final bucket name. Don't touch the Lovable app.

## Recommended plan (fully reversible until the final delete; NO bucket flip needed)
1. **Create a new PRIVATE bucket `derm-docs`** (private from creation; keeps `GT - Visits Images` + `manifests` public for photos/brand). *(Alt: consolidate into `manifests` + flip it private — but then the `_brand/unclogme-logo.jpg` public URL must be handled; a fresh `derm-docs` avoids that.)*
2. **Repoint write paths → `derm-docs`:** PDF service upload target + stored URL (you); DERM Tracker upload (me, after you confirm the name). Deploy first so new manifests land private.
3. **Copy** existing `GT - Visits Images/derm/*` (2,439) + `manifests/derm/*` (44) → `derm-docs/derm/{id}/{filename}` (preserve sub-path). **Back up the 5 URL columns first** (`select id, derm_address_url, derm_manifest_url, fog_manifest_url, derm_address_extra_urls, derm_manifest_extra_urls from derm_manifests where … is not null` → `backups/2026-07-02_derm_urls_backup.json`).
4. **Rewrite** the 5 URL columns: `replace(col, '/object/public/GT%20-%20Visits%20Images/derm/', '/object/public/derm-docs/derm/')` and the same for `/object/public/manifests/derm/` → `/object/public/derm-docs/derm/` (arrays via `array(select replace(unnest(col), …))`). (Leave them as `…/object/public/derm-docs/…` strings — get-derm-doc re-signs them regardless of the `public`/`sign` word in the stored URL; it only uses bucket+path.) `derm_manifests` is audited → `app_source='sql'` is fine.
5. **Add `derm-docs`** to `toBucketPath`'s fallback array + redeploy `get-derm-doc` (respect `config.toml` `verify_jwt=false`, origin-lock fp+derm).
6. **Verify** `get-derm-doc` returns `/object/sign/derm-docs/derm/…` 200 for fog/address/manifest from the fp+derm origins; ping me to re-verify DERM Tracker + FP live.
7. **Delete** the public originals `GT - Visits Images/derm/*` + `manifests/derm/*` (this closes the leak). `GT - Visits Images` (21.5k photos) + `manifests` (`_brand` logo) stay PUBLIC.
8. Confirm anon INSERT still works on the DERM upload path (DERM Tracker) against `derm-docs`.

## Coordination
- Tell me the **final bucket name** → I repoint the DERM Tracker upload path (Lovable) + re-verify both apps end-to-end on signed URLs.
- I've released my board claim on `get-derm-doc` / `storage.buckets` / `storage.objects (derm/)` — they're yours. I retain the DERM Tracker (Lovable) upload repoint + app verification.

## Verify queries (for you)
- Non-derm still public-loadable: `GT - Visits Images` + `manifests` still `public=true`.
- No derm left public: `select bucket_id, count(*) from storage.objects where bucket_id in ('GT - Visits Images','manifests') and name like 'derm/%' group by 1;` → 0 after delete.
- URL rewrite complete: `select count(*) from derm_manifests where (derm_address_url||derm_manifest_url||coalesce(fog_manifest_url,'')) like '%/derm/%' and (… like '%GT%20-%20Visits%20Images%' or … like '%/object/public/manifests/derm/%');` → 0.
