# Handoff → Supabase session: `edit_calendar_visit` must accept + store line-item descriptions (2026-07-03)

**Routed by Fred (2026-07-03):** the `edit_calendar_visit` RPC change is **yours** (Supabase session's lane). The
matching frontend (drawer line-item edit UI) + the display render are **mine** (Building Apps, Visit Calendar Lovable
`6533c3ee-…`). Same split as the create flow (you did `create_calendar_visit`+`p_line_item_descriptions`, I did the
Create-Visit textarea, verified end-to-end 2026-07-02).

## Context
Fred wants line-item **descriptions** visible + editable in the Visit Calendar drawer.
- **Display half (mine, shipping now, independent):** `ops.v_calendar_visit_detail.line_items` already exposes
  `description` on every object (`json_build_object('name',…,'description', li.description,'quantity',…,'unit_price',…)`),
  so the drawer just needs to render it. No backend change. Done on my side.
- **Edit half (yours + mine):** the drawer's line-item Edit can't set/keep descriptions because the edit RPC drops them.

## The gap (verified 2-agent workflow)
`public.edit_calendar_visit(p_visit_id bigint, p_patch jsonb) RETURNS visits` (SECURITY DEFINER; `ops.edit_calendar_visit`
just forwards to `public`). It replaces line items by **DELETE-all + re-INSERT** in two mutually-exclusive branches, and in
**BOTH** it hardcodes `description = ''`:
- **(A) Catalog branch** — `p_patch ? 'service_line_item_ids'`: `INSERT INTO line_items (visit_id,name,description,quantity,unit_price,total_price,taxable) SELECT p_visit_id, s.title, '', … FROM service_line_items s WHERE s.id = ANY(...)`.
- **(B) Arbitrary branch** — `p_patch ? 'line_items'`: `INSERT INTO line_items (…,description,…) SELECT p_visit_id, li->>'name', '', … FROM jsonb_array_elements(p_patch->'line_items') li`.

The **change-detection signature** that gates the replace is `name|quantity|unit_price` ONLY (`v_inc` from incoming,
`v_cur` from existing; `IF v_inc IS DISTINCT FROM v_cur THEN delete+insert + bump visits.line_items_rev`).

**Consequences:**
1. You can't SET a description via edit (RPC ignores it, stores `''`).
2. **LATENT BUG (fix regardless of the feature):** editing qty/price on a visit that HAS descriptions (from
   `create_calendar_visit` or Jobber inbound) re-INSERTs with `''` → **wipes the descriptions**.
3. If you add descriptions but NOT to the signature: a description-only edit yields `v_inc == v_cur` → the DELETE+INSERT
   is skipped → `line_items_rev` not bumped → neither the DB row nor Jobber updates (silent no-op).

## What to change (`edit_calendar_visit` migration)
1. **Catalog branch (A):** accept `p_patch->'line_item_descriptions'` = jsonb map `{"<service_line_item_id>":"note"}` —
   the **same shape** `create_calendar_visit`'s `p_line_item_descriptions` uses (keyed by the catalog `service_line_items.id`,
   stringified). Re-INSERT `description = COALESCE(NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text),''),'')`.
2. **Arbitrary branch (B):** re-INSERT `description = COALESCE(NULLIF(btrim(li->>'description'),''),'')`.
3. **Change-detection signature:** append the (normalized/btrimmed) description to BOTH `v_inc` and `v_cur` so a
   description-only edit triggers the DELETE+INSERT + `line_items_rev` bump + Jobber push. (Match the existing
   round/normalize style so unrelated re-saves don't churn.)
4. Keep it **inside the existing `p_patch` jsonb** → NO new named param → NO signature change to `public.edit_calendar_visit`
   or the `ops.edit_calendar_visit` wrapper (no wrapper edit needed).
5. **Jobber push:** already handles description — `jobber-push-visit` `syncVisitLineItems()` does
   `select('name,description,quantity,unit_price')` + `...(desc ? {description: desc} : {})` (shipped 2026-07-02). No
   edge-fn change; just ensure the `line_items_rev` bump fires (see #3).
6. **Audit + verify:** `line_items` is audited. Verify: (i) an edit that SETS a description → persists + pushes to Jobber's
   LineItem.description; (ii) an edit that changes only qty on a line item that has a description → description is
   **PRESERVED** (wipe bug fixed); (iii) a description-only edit → rev bumps + pushes (not a no-op).

## Which branch does the drawer edit use?
The drawer's line-item Edit renders the **catalog service list** (09–24 service types, per-item qty/price) — same UI as
Create-Visit — so it almost certainly sends the **catalog branch** (`service_line_item_ids` + a `line_item_descriptions`
map). I'll confirm the exact `p_patch` shape when I wire the frontend. Recommend implementing **both** branches for safety.

## Coordination
- **Ping me** when the RPC is deployed + the exact `p_patch` contract (esp. the `line_item_descriptions` key shape). Then
  I add the per-line-item "Description / note" textarea to the drawer's line-item Edit (prefilled from the current
  description) + include descriptions in `p_patch`, and verify end-to-end (intercept the `edit_calendar_visit` payload +
  confirm store + Jobber push), exactly like I did for the create flow.
- Storage stays `public.line_items.description`. This is a Supabase-side migration only.
