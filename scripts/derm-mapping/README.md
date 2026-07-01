# DERM address-sheet → client-row mapping (one-time batch)

Maps every DERM FOG-manifest facility row to its client (blind Claude-vision, digit-anchored,
flag-don't-guess), stores it in `derm.address_row_map`, and renders Yannick's Confirmed/Unconfirmed
legend bundles per 2-week dump-date window. Design/spec/plan live in
`../../docs/superpowers/{specs,plans}/2026-07-01-derm-address-row-mapping*`.

## Pipeline

`01_prep` (candidates + images) → **match workflow** (3 blind vision passes/sheet + reconcile) →
`03_load` (idempotent upsert) → `04_render` (Confirmed/Unconfirmed PDF) → `05_audit` (linkage gaps).

Windows are processed **most-recent-first**; the **gazetteer** (`data/gazetteer.json`) of confirmed
`facility→client` carries forward across batches.

## One-time full run (operator = the main Claude session)

Prep for all 13 windows is already done (`data/sheets_*.json` + `data/images/`). Window 1 is loaded.
Process the rest in 3 batches (each carries the gazetteer forward). From `scripts/derm-mapping/`:

For each batch — windows `2 3 4 5`, then `6 7 8 9`, then `10 11 12 13`:

1. `node build_batch_wf.js 2 3 4 5`  → writes `data/gen_match_wf.js` (embeds those windows' sheets +
   the current gazetteer, so the workflow needs no args).
2. **Claude** runs `Workflow({ scriptPath: "<abs>/scripts/derm-mapping/data/gen_match_wf.js" })`.
   The full return value is saved to the Workflow task-output JSON file.
3. `node split_batch.js <task-output.json>`  → writes `data/match_<nn>.json` per window and merges each
   sheet's confirmed matches into `data/gazetteer.json`.
4. For each window N in the batch: `node 03_load.js data/match_0N.json` then `node 04_render.js N`.

After all batches: `node 05_audit.js`  → `data/linkage_audit.json` (UNMATCHED rows + linked-but-absent).

## Notes

- Re-running a window is **idempotent** (upsert on `(dump_folder,page,row_index)`); human `reviewed_*`
  edits are never overwritten.
- Bundles output to `C:/Users/FRED/Downloads/DERM_RowMap_Window_<nn>_<from>_to_<to>.pdf`.
- `data/` is git-ignored (images, intermediate JSON, generated workflow — never commit PII/PDFs).
- Server-side image reads currently use the still-public URLs; if the `manifests` bucket flips private,
  switch `01_prep.js` `dl()` to send the `service_role` key (no dependency on `get-derm-doc`).
