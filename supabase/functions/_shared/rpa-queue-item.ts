// ============================================================================
// _shared/rpa-queue-item.ts: the ONE shape of a GDO bot work item
// ============================================================================
// A row of public.v_derm_portal_fields (or a view built on it, like v_derm_portal_queue)
// becomes the item the GDO report bot files. Two senders use it, so the bot reads the same
// keys and values from both:
//   - rpa-derm-queue: the hourly queue (GET);
//   - gdo-bot-file-visit: the DERM Tracker "File it with the bot" button, which sends one
//     item to the bot's /gdo/process-one (Fred, 2026-10-29: "Button sends the details").
// Change the shape here only; the bot's reporter reads these exact keys.
// ============================================================================

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>

export function toQueueItem(r: Row, dryRun: boolean) {
  return {
    visit_id: r.visit_id,
    manifest_id: r.manifest_id,
    // 🛑 gdo_id is the PERMIT this item is for, and since 2026-08-31 a single
    // visit can legitimately be served SEVERAL items at once (Casa Neos has
    // three ACTIVE permits on one manifest, and DERM wants a report per
    // permit). Echo it back on the result POST: without it, rpa-derm-result
    // has to INFER the permit from the visit, which is only sound while one
    // permit is in flight at a time. Additive field; a bot that ignores it
    // still works, it just attributes by arrival order.
    gdo_id: r.gdo_id,
    dry_run: dryRun,
    client_code: r.client_code,
    client_name: r.client_name,
    client_email: r.client_email,
    address: r.address,
    city: r.city,
    zip: r.zip,
    county: r.county,
    gdo_number: r.gdo_number,
    service_date: r.visit_date,
    dump_ticket_date: r.dump_ticket_date,
    ticket_number: r.ticket_number, // the number to file (white OR yellow), 24d
    jurisdiction: r.jurisdiction, // 'dade' | 'broward' | 'unknown'
    white_manifest_number: r.white_manifest_number, // back-compat; NULL for Broward
    disposal_facility: r.disposal_facility,
    // 2026-10-18_2100: the county form takes no attachment and the bot never read these. Key kept, lists empty.
    documents: { address: [], receipt: [] },
  }
}
