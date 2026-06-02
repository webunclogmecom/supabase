# Admin Review App — Cut-over from Sandbox #1 to Prod canonical

**Goal:** rewire the Admin Review App (Lovable, Yannick) so it reads/writes the canonical `public.photo_classifications` table on **Prod** instead of `public.app_photo_classifications` on **Sandbox #1**. After this, every classification flows into the single source of truth, and the Field Portal app picks it up automatically.

**Effort:** ~30 LOC across 4 files + a regenerated `types.ts`. Estimated 15-30 min.

---

## Pre-flight (already done — for awareness)

| Step | Status |
|---|---|
| Prod has `public.photo_classifications` (migration 14d) | ✅ applied |
| Prod has the customer schema + helper views (14, 14b, 14c) | ✅ applied |
| 103 existing classifications backfilled from Sandbox #1 → Prod | ✅ done |
| Anon RLS on Prod `photos`, `photo_links`, `visits`, `clients` (so the app can still read with publishable key) | ✅ added |

The app, after the rewire, can keep using the **anon publishable key** — no auth required yet.

---

## Step 1 — Get the Prod connection info

Open **Supabase Dashboard → project `wbasvhvvismukaqdnouk` → Settings → API**. Copy:

| Var | Where to find it |
|---|---|
| Project URL | "Project URL" — looks like `https://wbasvhvvismukaqdnouk.supabase.co` |
| Anon key | "Project API keys" → row labelled `anon` → `public` — the long JWT string |

---

## Step 2 — Update the app's environment variables

In the Lovable project's `.env` (or whatever it's called there — Lovable usually calls it "Project Secrets" or `.env.local`):

```diff
- VITE_SUPABASE_URL=https://ubtlwpcyntelgbykdatn.supabase.co
- VITE_SUPABASE_PUBLISHABLE_KEY=<the Sandbox #1 anon key>
+ VITE_SUPABASE_URL=https://wbasvhvvismukaqdnouk.supabase.co
+ VITE_SUPABASE_PUBLISHABLE_KEY=<the Prod anon key from Step 1>
```

> **Note:** `VITE_*` vars are build-time. If Lovable distinguishes "secrets" (runtime) from "env" (build-time), these go in the **build-time / env** bucket, NOT secrets.

---

## Step 3 — Rename the table reference

The canonical table is **`photo_classifications`** (Prod) instead of **`app_photo_classifications`** (Sandbox #1). The column that was `external_photo_link_id` is now just `photo_link_id`.

### File: `src/hooks/useSavePhotoClassifications.ts`

```diff
- .from('app_photo_classifications')
+ .from('photo_classifications')
  .upsert(
    classifications.map(c => ({
-     external_photo_link_id: c.photoLinkId,
+     photo_link_id: c.photoLinkId,
      service_phase: toServicePhase(c.phase),
    })),
-   { onConflict: 'external_photo_link_id' }
+   { onConflict: 'photo_link_id' }
  );
```

### File: `src/hooks/useVisitDetail.ts`

Look for the query that fetches classifications by `external_photo_link_id` IN list. Update:

```diff
- .from('app_photo_classifications')
- .select('external_photo_link_id, service_phase')
- .in('external_photo_link_id', photoLinkIds)
+ .from('photo_classifications')
+ .select('photo_link_id, service_phase')
+ .in('photo_link_id', photoLinkIds)
```

Then update the JS merge logic — wherever the code does `c.external_photo_link_id`, change to `c.photo_link_id`.

### File: `src/hooks/useQueueVisits.ts`

Same pattern — find the `app_photo_classifications` reference and the `external_photo_link_id` column reference. Same renames.

### File: `src/types/job.ts` (and any other type definitions)

Update any TypeScript types that reference the old table/column. E.g.:

```diff
- type AppPhotoClassification = {
+ type PhotoClassification = {
-   external_photo_link_id: number;
+   photo_link_id: number;
    service_phase: 'before' | 'after' | 'completion' | 'unknown';
  };
```

### Regenerate Supabase types (if Lovable does this for you)

If the app uses auto-generated `database.types.ts` from `supabase gen types`:
1. Re-run the Supabase types codegen pointed at Prod.
2. Or have Lovable regenerate them.

---

## Step 4 — Enum update (do at the same time as Step 3)

The enum changed 2026-05-15: `completion` → `internal`, plus new `extra`. The full set is now:
- `before` | `after` | `internal` | `extra` | `unknown`

In `src/components/PhotoClassifier.tsx`:
- Rename the "Completion" button → "Internal" (writes `'internal'`).
- Add an "Extra" button (writes `'extra'`).
- Existing `BUCKET_STYLES` / `BUCKET_RING` need entries for both new labels.

In `src/types/job.ts`:
```diff
- type PhotoClassification = 'before' | 'after' | 'completion' | null;
+ type PhotoClassification = 'before' | 'after' | 'internal' | 'extra' | null;
```

The DB already migrated existing `'completion'` rows → `'internal'` — no data work for Lovable. The CHECK constraint on Prod's `photo_classifications.service_phase` accepts the new enum.

---

## Step 5 — Smoke test

Once Lovable rebuilds:

1. Open the Admin Review App.
2. Navigate to **199-JZ (JZ Steak House)** — visit on **2026-04-28**. This visit has 14 classifications backfilled to Prod. You should see them pre-rendered as: **3 After, 2 Before, 9 Internal**.
3. Tag a fresh photo as **Extra**. Refresh. Confirm it persists.
4. Tag another as **Internal**. Refresh. Same.
5. **Cross-app check:** open the Field Portal app, navigate to **092-TCE on 2026-04-13**. The before/after grids should show 3 before / 5 after; "Additional Photos" should be empty (the 2 internal photos for that visit are now hidden from customer view per the `customer.wo_photos` filter).

---

## Step 6 — Tell Fred when it works

Once Step 5 is green, message Fred. The remaining cleanup is Fred's:

- Drop `public.app_photo_classifications` from Sandbox #1.
- Remove the preservation rule in `sandbox-refresh.yml` (since the table won't exist anymore).
- Re-clone Field Portal Sandbox from Prod to pick up any new classifications (until Field Portal app graduates to read Prod directly).

---

## If something breaks

| Symptom | Likely cause | Fix |
|---|---|---|
| Save returns "relation `app_photo_classifications` does not exist" | Step 3 incomplete — still a reference somewhere | Grep the project for `app_photo_classifications` and replace |
| Save returns "permission denied for table photo_classifications" | Anon RLS not set | Tell Fred — re-run the anon-RLS step |
| Visit list loads but classifications are blank | Read path still hits Sandbox #1's table | Verify Step 2 env vars actually deployed |
| `Cannot read column external_photo_link_id` | TS types not regenerated | Re-run types codegen |

---

## Why this matters

After this cut-over:
- **Single source of truth.** Admin Review App writes to Prod. Field Portal reads from Prod (via subset clone). Sandbox #1 auto-refreshes from Prod 5x/day, so the Admin Review App still sees fresh ambient data — but its own writes go to the canonical home.
- **No more manual data syncing** between Sandbox #1 and other apps.
- **DERM's app (next in the queue)** will read from the same Prod canonical and benefit automatically.
