# Test Matrix

Each test: ACTION → DB CHECK → SECONDARY APP CHECK → restore.

Status legend: ⏳ pending · 🔄 in progress · ✅ pass · ❌ fail · 🔧 fixed

## Group A — Manholes (Admin Review writes, FP/AR reads)

| # | Test | Action | Expected DB | Expected FP | Expected AR | Status |
|---|---|---|---|---|---|---|
| A1 | Property manhole > 0 | AR: set property X grease_trap_manhole_count = 5 | UPDATE properties; audit row hint=admin-review | FP visit detail shows "Manholes 5" | AR shows 5 immediately on re-render | ⏳ |
| A2 | Property manhole = 0 | AR: set property Y to 0 | UPDATE; audit row | FP shows "—" (NULLIF strips 0) | AR shows 0 in input | ⏳ |
| A3 | Visit-override > prop default | AR: set visit Z manhole_count = 8 (prop default ≠ 8) | UPDATE visits; audit row | FP shows "8" (override wins) | AR shows 8 | ⏳ |
| A4 | Override → null (use default) | After A3: clear visit override | UPDATE visits set manhole_count=null | FP falls back to prop default | AR shows "Use default" state | ⏳ |
| A5 | Read-after-write across Sandbox | A1 then immediately refresh AR — does AR see new value? | Sandbox not refreshed yet | Property visible from FP (Prod) | AR may show stale value (5h Sandbox refresh) | ⏳ |

## Group B — Photo classifications (Admin Review writes, FP reads)

| # | Test | Action | Expected DB | Expected FP | Expected AR | Status |
|---|---|---|---|---|---|---|
| B1 | Classify photo as before | AR: pick unclassified photo on visit V, set phase=before | INSERT/UPDATE photo_classifications | FP "Before" section shows the photo | AR shows photo with Before label | ⏳ |
| B2 | Reclassify as after | After B1, change phase=after | UPDATE photo_classifications | FP "After" section shows photo; "Before" loses it | AR shows photo with After label | ⏳ |
| B3 | Classify as extra | New photo, phase=extra | INSERT row | FP "Extra" section | AR shows Extra | ⏳ |
| B4 | Classify as internal | New photo, phase=internal | INSERT row | FP "Internal" section | AR shows Internal | ⏳ |
| B5 | Multi-photo visit, mixed phases | 3 photos: before, after, internal | 3 rows | FP groups correctly into 3 sections | AR shows mix | ⏳ |

## Group C — DERM manifest links (DERM Tracker writes, FP reads)

| # | Test | Action | Expected DB | Expected FP | Expected DT | Status |
|---|---|---|---|---|---|---|
| C1 | Link visit to manifest | DT: attach visit X to manifest M (visit currently unlinked, lacks derm) | INSERT manifest_visits(X, M); audit row hint=derm-tracker | FP visit detail now shows derm_manifest_url section | DT manifest M now lists visit X | ⏳ |
| C2 | Unlink visit from manifest | After C1, DT: unlink visit X | DELETE manifest_visits; audit hint=derm-tracker | FP loses derm_manifest_url | DT manifest M loses visit X | ⏳ |
| C3 | Move visit between manifests | DT: visit Y attached to M1, move to M2 | DELETE+INSERT manifest_visits | FP shows M2's derm_address_url | DT M1 loses Y, M2 has Y | ⏳ |
| C4 | derm_required=false | DT: toggle visit Z derm_required to false | UPDATE visits.derm_required=false; audit row | FP service history DOESN'T show visit Z (view filter excludes false) | DT visit moves out of "needs DERM" queue | ⏳ |
| C5 | derm_required back to NULL | After C4, toggle back | UPDATE visits.derm_required=null | FP service history reincludes Z | DT visit returns | ⏳ |
| C6 | Attach picker shows unlinked | After C2, DT picker for any manifest should find visit X by client | n/a (read) | n/a | DT picker shows visit X | ⏳ |

## Group D — Mixed sequences

| # | Test | Action | Expected | Status |
|---|---|---|---|---|
| D1 | AR + DT on same visit | AR set manhole=7 on visit, DT link to manifest | FP shows manhole=7 AND derm_manifest_url | ⏳ |
| D2 | AR re-classify before DT link | AR classify photo, then DT link manifest | FP shows photo classification AND derm section | ⏳ |
| D3 | DT toggle derm_required=false while AR has changes pending | derm_required=false then AR adds photo classification | FP excludes visit; AR can still classify (visit still in AR queue) | ⏳ |

## Group E — Architecture / cross-app oddities

| # | Test | Action | Expected | Status |
|---|---|---|---|---|
| E1 | Audit attribution chain | Each write across A1-D3 generates exactly one audit row with right hint | hint matches app | ⏳ |
| E2 | App_source via Origin fallback | Make a write with X-App-Source absent (only Origin set) — confirm app_source still attributed | app_source set, hint=null | ⏳ |
| E3 | Calendar wiring check | Visit `monthly-visitor-cheer.lovable.app`, capture network requests, confirm no Supabase calls | 0 supabase.co requests | ⏳ |
| E4 | FP customer schema isolation | FP reads only customer.* views, never public.* | confirmed via network log | ⏳ |
| E5 | Sandbox refresh visibility | After AR write to Prod, query Admin Review's Sandbox to measure lag | Sandbox lag documented | ⏳ |

## Group F — Idempotency + cleanup

| # | Test | Action | Expected | Status |
|---|---|---|---|---|
| F1 | Snapshot restore | Run 99-restore.sql, query all touched rows, compare to snapshot | identical rows | ⏳ |
| F2 | Audit row count | Count audit rows generated during run — should match number of writes | matches | ⏳ |

## Test data targets

| Slug | Client | Visit | Property | Use |
|---|---|---|---|---|
| 111-YC | Yann Couvreur | v4901 | property 66 (gtmc=6) | A1, A3 |
| 092-TCE | The Carrot Express | v3915 | property gtmc=0 | A2 (counter-case) |
| 043-MIL | Mila | v5128 | property 51 (gtmc=10) | A4 |
| 001-VIN | Vincenzos | v5130 | property 92 (gtmc=3) | A5 |
| 223-CHA | El Chaman | v5127 | — | C1, C2, C6 (manifest_visits ops) |
| 042-MT | Miami twist | v4742 | — | C3 (move test), D3 |
| TBD | TBD | TBD | TBD | B1-B5 (photo classifications, need to find visit with photos) |
