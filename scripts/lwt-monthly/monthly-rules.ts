// monthly-rules.ts -- the rules of the bot's /monthly page (static/monthly.js at
// d00636a), with the DOM removed. It decides the POST body of the monthly county
// report, so it is proven equal to the original: see README.md and golden/.
//
// One file, no imports. The DERM Tracker's copy is byte-identical to this file.
// Never edit the app's copy. Change this one, run run.mjs and the golden, then
// download it again.
//
// Each method keeps the old function's name, or names it in a comment. Rules are
// kept as they were, including the ones that look odd; README.md lists those.
// All strings that reach a finding are byte-for-byte the old page's, written with
// \u escapes so this file stays ASCII.

// ---- Shapes ----------------------------------------------------------------

export interface Facility {
  name?: string;
  address?: string;
  county?: string | null;
  in_dade?: boolean;
  // Where a client on a hand row came from. Everything with a leading _ is
  // stripped from the signed body by payload().
  _src?: 'picked' | 'typed';
  _from?: 'visit';                 // NEW: picked from a real visit (still _src: 'picked')
  _visit_id?: string | number;     // NEW
  _visit_date?: string;            // NEW: the visit's recorded date, ISO
  [k: string]: unknown;
}

export interface Load {
  ticket_number?: string | null;
  pickup_date?: string | null;
  offload_date?: string | null;
  gallons?: number | null;
  decal?: string | null;
  facilities?: Facility[];
  trucks?: string[];
  disposal_facility?: string | null;
  out_of_county?: boolean;
  gallons_sources?: unknown[];
  sizes_missing_clients?: string[];
  feed_conflicts?: string[];
  // Page state, never signed: payload() strips every one of these.
  _excluded?: boolean;             // un-ticked
  _manual?: boolean;               // the tick is a hand decision
  _decal_src?: 'manual' | 'invoice';
  _decal_feed?: string | null;     // what the system said, kept under the paper's
  _decal_pinned?: boolean;         // a correction: set after the paper priced it
  _paper?: boolean;                // a hand row, entered from the paper
  _offload_src?: 'typed' | 'invoice' | 'operator';
  _offload_pinned?: boolean;       // true: correction. false: guess. absent: feed
  _offload_feed?: string;
  _offload_guess?: string;
  _hand_replaced?: string;
  _restored?: boolean;
  _ord?: number;
  _ordBlock?: 'on' | 'off' | 'held';
  [k: string]: unknown;
}

export interface Finding {
  rule: string;
  detail: string;
  row_key?: string | null;
  expected?: boolean;
}

export interface FetchResponse {
  loads?: Load[];
  fetch_findings?: Finding[];
  meta?: Record<string, unknown>;
  archived?: Record<string, ArchiveRecord>;
  archived_rows?: Record<string, Load>;
  filed_tickets?: Record<string, {period?: string; filed_at?: string}>;
}

export interface ArchiveRecord {
  reason?: string;
  reason_text?: string | null;
  duplicate_of?: string | null;
  by?: string;
  at?: string;
  still_sent?: boolean | null;
}

export interface InvoiceParse {
  tickets?: string[];
  invoice_id?: string | null;
  decals?: Record<string, string>;
  service_dates?: Record<string, string>;
  decal_conflicts?: {detail: string; row_key?: string | null}[];
  parse_warnings?: string[];
  total_mismatch?: string | null;
  near_tickets?: {guess: string; as_read: string}[];
  other_sixdigit?: string[];
  outside_column?: string[];
  decals_inferred?: unknown[];
  source?: string;
}

export interface PayloadBody {
  year: number;
  month: number;
  invoice_id: string | null;
  invoice_tickets: string[] | null;
  loads: Load[];
  excluded_tickets?: string[];
  candidate_pool?: {ticket_number: string; offload_date: string; out_of_county?: boolean}[];
  fetch_findings?: Finding[];
  approved?: boolean;
  preview_token?: string | null;
}

export interface PayloadResult { err?: string; body?: PayloadBody }

export interface PaperForm {
  clients: Facility[];
  pickup: string;
  query: string;
  typing: {name: string; address: string} | null;
  msg: string;
  t?: string;
  offload?: string;
}

export interface SavedInvoice {
  text: string;
  invoice_id?: string;
  source?: {name?: string; b64?: string} | null;
}

export interface SavedFile {
  schema?: number;
  loads: Load[];
  fetch_findings?: Finding[];
  invoice?: SavedInvoice;
}

export type DecisionKind =
  | 'number_no_ticket'     // on the invoice, no ticket in the system
  | 'archived_on_invoice'  // on the invoice, archived on our side
  | 'dumped_not_billed'    // dumped inside the invoice's dates, not billed
  | 'date_differs'         // offload date differs from the invoice
  | 'truck_differs'        // truck differs from the invoice
  | 'truck_set_by_hand'    // a truck the operator set, the invoice silent or agreeing
  | 'waiting_on_size'      // out of county, no quantity yet
  | 'not_manifest_number'  // not six digits
  | 'unresolved_gallons'   // on the filing, no gallons
  | 'pickup_after_offload' // the two dates cross
  | 'hand_row'             // entered by hand from the paper
  | 'client_typed'         // a client typed on a hand row
  | 'hand_replaced'        // the system's row replaced a hand row and differs
  | 'feed_conflict'        // the system's rows disagree
  | 'row_finding'          // any other finding on a row
  | 'off_form'             // a finding from the last check on a ticket not on the list
  | 'fetch_note'           // a fetch finding on a ticket not on the list
  | 'month_note'           // a finding about the month, no ticket
  | 'reader_candidate'     // a number the invoice reader offered, not committed
  | 'report_shape';        // most of the report is outside the report month

export interface Decision {
  kind: DecisionKind;
  ticket: string | null;   // null: about the month
  index: number | null;    // position in LOADS, for the index-based acts
  rule: string | null;     // the rule behind it, for ruleInfo()
  title: string;
  tone: string;            // block | warn | hold | policy
  detail: string;
  counted: boolean;        // what the old "N to decide" pill on the row counts
  [k: string]: unknown;    // the values needed to decide, per kind
}

// ---- The tables /monthly/config.js serves ----------------------------------

export const DECAL_GALLONS: Record<string, number> = {C1184: 3800, C0976: 2000};
// reconcile.INVOICE_AMOUNT_DECAL. NOT served by config.js, so configDrift cannot
// check it, and the old page never read it: the bot's parser applies it.
export const PRICE_TO_DECAL: Record<string, string> = {'357.20': 'C1184', '188.00': 'C0976'};
export const NO_TICKET_KEY = '<no ticket>';
export const RECEIPT_RULES: string[] = ["operator_excluded_ticket", "operator_set_client", "operator_set_offload"];
// rule -> [title, tone, explain]. monthly_report.RULE_INFO at d00636a.
export const RULE_INFO: Record<string, string[]> = {
  ticket_without_gallons: ["Missing gallons", "warn",
    "This ticket has no gallon amount yet. Drop the county invoice on the page and it will fill in from the Decal column."],
  ticket_without_facilities: ["No pickup locations", "block",
    "This ticket lists no pickup locations at all -- the data needs fixing before it can print."],
  out_of_county_facility_excluded: ["Out-of-county stops left off", "policy",
    "Stops outside Miami-Dade were removed from this ticket, as decided: they report under their own county's program. The ticket itself stays."],
  offload_outside_dade_ticket_excluded: ["Ticket disposed outside Miami-Dade (old rule)", "policy",
    "Recorded under the rule in force until 2026-09-17: a ticket disposed outside Miami-Dade was left off this form entirely. Those loads are ON the report now, with their real destination."],
  offload_county_unknown_ticket_set_aside: ["County of disposal unanswered", "warn",
    "The data system does not say which county this waste was disposed in, so the ticket is set aside instead of being assumed onto this form. An unanswered county is not a Dade county. Answer it upstream and fetch the month again."],
  out_of_county_ticket_on_report: ["Dumped out of county", "policy",
    "This ticket was picked up in Miami-Dade and disposed at another county's plant, so it belongs on this report and prints its real destination. Its gallons come from the client's trap size on file, not from a truck decal, and the county invoice does not bill it -- so it is not missing from the invoice, it was never on it."],
  out_of_county_gallons_held: ["Waiting on a trap size", "hold",
    "This ticket is not on the county invoice, so its gallons can only come from the clients' trap sizes on file -- and one of them has none yet. The form prints nothing for it until the size is added in the Client App. Dropping the invoice will not resolve this one: the invoice never carried it."],
  out_of_county_without_destination: ["Nowhere to print as the destination", "block",
    "This ticket was disposed outside Miami-Dade and the data system did not say at which plant. The form prints one destination per page, so there is nothing truthful to put on its page -- and the county's own plant is exactly what it is not. Fix the disposal facility upstream and fetch the month again."],
  out_of_county_destination_unmapped: ["Destination address not on file", "warn",
    "This load went to a plant whose form name and address are not on file yet. Its page prints the plant's name as the data system sent it and leaves the address blank -- an address is never guessed. Check the destination on the paper before approving."],
  out_of_county_other_month: ["Dumped in another month", "policy",
    "This out-of-county ticket was dumped outside the month this report covers, so it is not on it. These loads are picked by their dump date -- the county invoice, which picks the window for everything else, never carried them. Filing it means deciding which month it belongs to, which is not a decision this page can make for you."],
  out_of_county_no_dade_pickup: ["Not this county's load at all", "policy",
    "This ticket was disposed outside Miami-Dade and has no Miami-Dade pickup on it either, so no part of it belongs on this form. It reports under its own county's program."],
  out_of_county_sizes_missing: ["Waiting on a trap size", "hold",
    "One or more clients on this ticket have no grease-trap size on file, so the ticket is held: the form cannot print part of a load, and this class has no decal to fall back on. Add the size in the Client App for the clients named, then fetch again."],
  out_of_county_total_mismatch: ["Two answers for one quantity", "block",
    "The data system's total for this ticket is not the sum of the rows it sent. Neither number prints until someone says which is right."],
  out_of_county_feed_contract_broken: ["The gallons data does not add up", "block",
    "The data system's own summary of this ticket contradicts the rows it sent, so nothing can be printed from it. This is an upstream fix, not a decision for this page."],
  out_of_county_ticket_excluded: ["Ticket kept, locations omitted", "policy",
    "Every pickup on this ticket was outside Miami-Dade, so it keeps its number and gallons but lists no locations -- the decided county rule."],
  feed_rows_conflict: ["The system's rows disagree", "warn",
    "Different rows of the same ticket say different things (dates or trucks). The safest value was kept -- confirm it against the paper before approving."],
  invoice_ticket_missing_from_report: ["On the invoice, not in this report", "block",
    "The county billed this ticket but it is not in the report. Find it in the manifests app and add it, or investigate a lost paper or county error."],
  ticket_in_window_not_billed: ["Dumped in this window, not billed", "warn",
    "This ticket was disposed between the invoice's own first and last dates, it is not billed on the invoice, and it is not in this report. Check the paper: either the county under-billed, or a number was lost reading it."],
  ticket_not_on_invoice: ["In this report, not on the invoice", "block",
    "This ticket is loaded but the county's invoice for this window does not bill it -- it probably belongs to next month's package. Un-tick it, or verify the paper."],
  membership_unverified: ["Invoice not entered", "block",
    "No invoice ticket list was provided, so nothing verified WHICH tickets belong in this report. Drop or type the county invoice."],
  operator_set_decal: ["Truck set by the operator", "warn",
    "Truck set by the operator on the filing page. The truck sets the gallons; check it against the Decal column on the county invoice before approving."],
  operator_decal_vs_invoice: ["Not the invoice's truck", "warn",
    "The operator overruled the truck the invoice's billed price names. Their choice is what the form files, so the gallons follow it. Check the paper; \u201cUse <truck>, the invoice's\u201d on the row takes the invoice's back."],
  operator_excluded_ticket: ["Left out by you", "warn",
    "You un-ticked this ticket, so it will not be filed. Make sure it belongs to another invoice package."],
  invoice_decal_conflict: ["Invoice didn't read cleanly", "warn",
    "The invoice's truck or price column did not match what we know for this ticket -- check the paper before trusting the gallons."],
  invoice_parse_warning: ["Invoice partially read", "warn",
    "Part of the invoice file could not be read -- some tickets may be missing from what was filled in. Check against the paper."],
  rows_without_pickup: ["Rows with no pickup date", "warn",
    "These rows will print with the Pick up Date cell empty. The county has accepted empty cells before, so this is not a refusal -- it is the month asking to be looked at: confirm the dates are truly unknown, not lost upstream."],
  manual_load_from_paper: ["Entered by hand from the paper", "warn",
    "The manifests system has no ticket for this number; the row was typed from the county's invoice, the way the manual filings did it. There is no system record to check it against, so the paper IS the source: verify the number, the gallons and the offload date against it before approving."],
  client_typed: ["Client typed \u2014 not in this month's list", "warn",
    "The operator typed this client because this month's client list (the clients on the fetched tickets) did not have it. DERM will see the name as typed; the Tracker will not know it. Check the spelling and the address against the manifest."],
  operator_set_client: ["Clients picked by the operator", "policy",
    "Set on the filing page from this month's client list, on a row entered by hand. Name and address came with the pick."],
  offload_vs_invoice: ["Not the invoice's date", "warn",
    "The invoice bills this ticket on another day than the row's offload date, and the invoice's Service Date is the offload date. Check the paper; \u201cUse <date>, the invoice's\u201d under the ticket takes the invoice's."],
  operator_set_offload: ["Offload date set by the operator", "policy",
    "Set on the filing page from the invoice's Service Date, over the date the system had. Have the system record corrected."],
  manual_load_replaced_by_feed: ["Entered by hand, now in the system", "warn",
    "This ticket was entered by hand from the invoice before the system had it. The system's ticket replaced the hand row when the month was reloaded, and it differs from what was typed; the detail says where. Check it against the paper."],
  archived_ticket_in_report: ["Archived, but in this report", "block",
    "This ticket was archived on our side (a test, a duplicate, not ours), so it must not be filed. Restore it on the page if it is real, or reload the month to leave it out."],
  manifest_number_shape: ["Not a manifest number", "warn",
    "Every manifest number we hold is six digits. This one is not, so it is probably a real pickup filed under a wrong number. Leave it un-ticked and have the number fixed in the Tracker; it comes back as a new ticket. Archiving it would hide real gallons."],
  saved_month_predates_decal_check: ["This saved month is from an older build", "block",
    "It was saved before the page kept what the system said about each truck, so a disagreement between the system and the invoice cannot be raised from it -- and the truck decides the gallons. Press Reload to pull the month from the system again."],
  invoice_total_mismatch: ["The invoice does not add up", "block",
    "The paper's own Total Invoice Amount disagrees with the rows that were read off it. Billed work may be missing from this filing, which is money the county was charged for and never told about. The note says which rows to check -- do that before approving."],
  unrecognized_state_value: ["Address problem from the system", "block",
    "A client address arrived with a state that is not a real state code. It was left off the form -- report it to the data team."],
  client_without_address: ["Client has no address on file", "block",
    "This client's address is empty in the system. The property record must be fixed before this ticket can print."],
  data_quality_unchecked: ["System check did not run", "warn",
    "The data system's own quality check failed to run for this pull. Re-fetch before filing."],
  pickup_after_offload: ["Pickup dated after disposal", "block",
    "This ticket says the pickup happened AFTER the waste was disposed, which is impossible -- one of the dates is wrong."],
  out_of_month: ["Date outside the report month", "warn",
    "A date falls outside the calendar month. Normal when the ticket is on this window's invoice; a problem when it is not."],
  duplicate_ticket_business: ["Same ticket twice", "block",
    "This ticket number appears more than once in the data -- a manifest must print exactly once."],
  ticket_number_missing: ["Row without a ticket number", "block",
    "A row arrived with no manifest number, which is the form's primary key. The data needs fixing."],
  unreadable_row: ["Unreadable data", "block",
    "A row could not be read at all. The data needs fixing."],
  invalid_gallons: ["Gallon amount looks wrong", "block",
    "A gallon figure is negative, not a number, or not whole -- it cannot go on a county form as-is."],
  total_in_thousands_suspected: ["Total looks like thousands", "warn",
    "This total is far larger than a tanker can hold -- it looks like a figure typed in gallons where thousands were meant. Check the paper."],
  decal_feed_vs_invoice: ["System and invoice name different trucks", "block",
    "The decal decides the gallon amount, so two answers are two quantities. The invoice wins here -- it is the document the county is paid against -- and the disagreement is recorded so the system's record can be corrected at the source."],
  total_not_positive: ["Total is zero or negative", "block",
    "A total came through as zero or below, which cannot be a hauled quantity. The data needs fixing."],
  offload_near_month_boundary: ["Disposed right at the month edge", "warn",
    "This load was disposed within a day or two of the month change, so which month's report carries it depends on the invoice, not the calendar. Check the paper."],
  unknown_decal: ["Truck not recognized", "warn",
    "This truck decal has no known gallon amount. Check the invoice or the fleet list."],
  unparseable_date: ["Date could not be read", "block",
    "A date arrived in a format that could not be understood."],
  day_month_swap: ["Day and month may be swapped", "warn",
    "This date looks like its day and month were flipped. Check the paper; a suggested correction is shown."],
  invoice_amount_decal_mismatch: ["Invoice price doesn't match the truck", "warn",
    "The billed amount implies a different truck than the one printed -- one of the two columns is wrong. Decide from the paper."],
  invoice_amount_unknown: ["Unfamiliar price on the invoice", "warn",
    "A billed amount matches no known truck rate -- a rate change or a misread. Verify against the paper."],
  ticket_number_collision: ["Same ticket number given twice", "block",
    "The invoice list carries this ticket number more than once, so the reporting window could not be verified. Check the paper for a typo before anything else."],
  unparseable_ticket_number: ["Ticket number could not be read", "block",
    "An entry in the invoice list is not a readable ticket number -- fix the typed list against the paper; the window is unverified until then."],
};

// What a live /monthly/config.js says differently from the tables above, one
// line per difference. [] means no drift. Text that cannot be read is a drift.
export function configDrift(configJsText: string): string[] {
  const m = /window\.MONTHLY_CONFIG\s*=\s*([\s\S]*?);?\s*$/.exec(String(configJsText || '').trim());
  let cfg: {rule_info?: Record<string, string[]>; decal_gallons?: Record<string, number>;
            receipt_rules?: string[]; no_ticket_key?: string};
  try { cfg = JSON.parse(m ? m[1] : ''); }
  catch (e) { return ['could not read the config text: ' + (e as Error).message]; }
  if (!cfg || typeof cfg !== 'object') return ['could not read the config text: not an object'];
  const out: string[] = [];
  const cmp = (what: string, ours: Record<string, unknown>, theirs: Record<string, unknown>) => {
    for (const k of Object.keys(ours)) {
      if (!(k in theirs)) out.push(what + '.' + k + ': here, not on the server');
      else if (JSON.stringify(ours[k]) !== JSON.stringify(theirs[k]))
        out.push(what + '.' + k + ': here ' + JSON.stringify(ours[k]) + ', server ' + JSON.stringify(theirs[k]));
    }
    for (const k of Object.keys(theirs))
      if (!(k in ours)) out.push(what + '.' + k + ': on the server, not here');
  };
  cmp('rule_info', RULE_INFO, cfg.rule_info || {});
  cmp('decal_gallons', DECAL_GALLONS, cfg.decal_gallons || {});
  const a = RECEIPT_RULES.slice().sort().join(','), b = (cfg.receipt_rules || []).slice().sort().join(',');
  if (a !== b) out.push('receipt_rules: here ' + a + ', server ' + b);
  if (cfg.no_ticket_key !== NO_TICKET_KEY)
    out.push('no_ticket_key: here ' + NO_TICKET_KEY + ', server ' + cfg.no_ticket_key);
  return out;
}

// ---- Constants of the page -------------------------------------------------

export const SCHEMA_VERSION = 2;
export const STALE_SAVE_RULE = 'saved_month_predates_decal_check';
export const INVOICE_RULES = ['invoice_decal_conflict', 'invoice_parse_warning', 'invoice_total_mismatch'];
export const DECAL_MISMATCH_RULE = 'decal_feed_vs_invoice';
export const DECAL_VS_INVOICE_RULE = 'operator_decal_vs_invoice';
export const ARCHIVE_REASONS = [
  ['test_data', 'Test data', 'A test manifest, never a real pickup'],
  ['duplicate', 'Duplicate', 'Another ticket is the real one'],
  ['not_ours', 'Not ours', 'Another hauler\u2019s, or never our job'],
  ['other', 'Other', 'Say why in a few words']];
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
                     'August', 'September', 'October', 'November', 'December'];
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;
const pl = (n: number) => (n === 1 ? '' : 's');

// ---- Pure helpers ----------------------------------------------------------

export function monthLabel(ym: string | null | undefined): string {
  const m = /^(\d{4})-(\d{2})$/.exec(String(ym || ''));
  return (m && +m[2] >= 1 && +m[2] <= 12)
    ? MONTH_NAMES[+m[2] - 1] + ' ' + m[1] : 'no month picked';
}

export function offloadMonth(d: string | null | undefined): string | null {
  const s = String(d || '');
  let m = /^(\d{4})-(\d{2})/.exec(s);
  if (m) return m[1] + '-' + m[2];
  m = /^(\d{1,2})\/\d{1,2}\/(\d{4})/.exec(s);
  return m ? m[2] + '-' + m[1].padStart(2, '0') : null;
}

export function reportShape(loads: Load[], ym: string) {
  const dated = loads.filter(l => !l._excluded && !isOutOfCounty(l))
                     .map(l => offloadMonth(l.offload_date)).filter(Boolean) as string[];
  const out = dated.filter(m => m !== ym);
  if (!dated.length || out.length * 2 <= dated.length) return null;
  const by: Record<string, number> = {};
  out.forEach(m => { by[m] = (by[m] || 0) + 1; });
  const top = Object.keys(by).sort((a, b) => by[b] - by[a] || a.localeCompare(b))[0];
  return {out: out.length, total: dated.length, top: top, topN: by[top],
          suggest: by[top] * 2 > dated.length ? top : null};
}

export function ruleInfo(rule: string): {title: string; tone: string; explain: string} {
  const r = RULE_INFO[rule];
  if (r) return {title: r[0], tone: r[1], explain: r[2]};
  const w = String(rule).replace(/_/g, ' ');
  return {title: w.charAt(0).toUpperCase() + w.slice(1), tone: 'warn',
          explain: 'Review this against the paper before approving.'};
}

export function worstTone(fs: {rule: string}[]): 'block' | 'warn' {
  return fs.some(f => ruleInfo(f.rule).tone === 'block') ? 'block' : 'warn';
}

export function isOutOfCounty(l: Load | null | undefined): boolean {
  return !!l && l.out_of_county === true;
}

export function resolvedGallons(l: Load): number | null {
  if (l.gallons != null) return l.gallons;
  if (isOutOfCounty(l)) return null;
  if (!l.decal) return null;
  const g = DECAL_GALLONS[String(l.decal).trim().toUpperCase()];
  return g == null ? null : g;
}

export function isHeld(l: Load): boolean {
  return isOutOfCounty(l) && resolvedGallons(l) == null;
}

export function gallonsProvenance(l: Load): string {
  if (isOutOfCounty(l)) {
    const n = (l.facilities || []).length;
    return 'sizes on file' + (n ? ' for ' + n + ' client' + (n === 1 ? '' : 's') : '');
  }
  return l.decal ? 'truck decal' : '';
}

// The one question of the truth table: had the paper spoken for this ticket?
export function setAfterPaper(paper: Record<string, string>, t: unknown): boolean {
  return !!String(paper[String(t || '')] || '').trim();
}

export function withoutReplacedDecalNotes(list: Finding[], md: Finding[]): Finding[] {
  const over: Record<string, boolean> = {};
  md.forEach(f => { if (f.rule === DECAL_VS_INVOICE_RULE) over[String(f.row_key)] = true; });
  return list.filter(f => !(f.rule === DECAL_MISMATCH_RULE && over[String(f.row_key || '')]));
}

export function handVsSystem(o: Load, n: Load): string {
  const out: string[] = [];
  const cmp = (what: string, sys: unknown, typed: unknown) => {
    if (String(sys || '') !== String(typed || ''))
      out.push(what + ' \u2014 the system has ' + (sys || 'none') + ', typed ' + (typed || 'none'));
  };
  cmp('offload', n.offload_date, o.offload_date);
  cmp('pickup', n.pickup_date, o.pickup_date);
  if (n.decal) cmp('truck', String(n.decal).toUpperCase(), String(o.decal || '').toUpperCase());
  const names = (l: Load) => (Array.isArray(l.facilities) ? l.facilities : [])
    .map(f => String((f && f.name) || '').trim()).filter(Boolean);
  const sn = names(n), tn = names(o);
  if (sn.slice().sort().join('\n') !== tn.slice().sort().join('\n')) {
    const named = 'clients \u2014 the system has ' + (sn.join(', ') || 'none') +
                  ', typed ' + (tn.join(', ') || 'none');
    out.push(named.length <= 120 ? named
      : 'clients \u2014 the system has ' + sn.length + ', typed ' + tn.length + ', not the same');
  }
  return out.join('; ');
}

export function clientDetail(name: unknown, address: unknown): string {
  return (String(name || '').trim() + ' \u2014 ' + String(address || '').trim() + '.').slice(0, 300);
}

export function clientNames(l: Load): string[] {
  const fa = Array.isArray(l.facilities) ? l.facilities : [];
  return fa.map(f => String((f && (f.name || f.address)) || '').trim() || '(unnamed client)');
}

export function shortCounty(facility: unknown): string {
  const f = String(facility || '').toLowerCase();
  if (f.indexOf('broward') !== -1) return 'Broward';
  if (f.indexOf('palm beach') !== -1) return 'Palm Beach';
  return 'another county';
}

export function pickupAfter(pickup: unknown, offload: unknown): boolean {
  return ISO_DAY.test(String(pickup || '')) && ISO_DAY.test(String(offload || '')) &&
         String(pickup) > String(offload);
}

export function parseTickets(text: string): string[] | null {
  const t = String(text).trim();
  if (!t) return null;
  const out: string[] = [];
  t.split(/[\s,;]+/).filter(Boolean).forEach(x => {
    if (out.indexOf(x) === -1) out.push(x);
  });
  return out;
}

export function withTicket(current: string, num: string): string {
  const have = parseTickets(current) || [];
  if (have.indexOf(num) !== -1) return current;
  return (String(current).replace(/\s+$/, '') + '\n' + num).replace(/^\n/, '');
}

export function defaultExcluded(l: Load, inv: string[] | null): boolean {
  if (isOutOfCounty(l)) return isHeld(l);
  return inv === null || inv.indexOf(String(l.ticket_number || '')) === -1;
}

export function blankForm(clients?: Facility[] | null, pickup?: string | null): PaperForm {
  return {clients: (clients || []).map(f => Object.assign({}, f)),
          pickup: pickup || '', query: '', typing: null, msg: ''};
}

export function reasonLabel(r: unknown): string {
  const x = ARCHIVE_REASONS.find(a => a[0] === r);
  return x ? x[1] : String(r || '');
}

// What is still missing in the archive panel, or '' when ready.
export function archiveMissing(st: {reason?: string; text?: string; dup?: string}): string {
  if (!st.reason) return 'Pick a reason.';
  if (st.reason === 'duplicate' && !/^\d{6}$/.test(st.dup || ''))
    return 'Type the real ticket\u2019s number (six digits).';
  if (st.reason === 'other' && !(st.text || '').trim()) return 'Say why in a few words.';
  return '';
}

// X-Filing-List: percent-encoded JSON.
export function filingList(h: unknown): string[] {
  try {
    const v = JSON.parse(decodeURIComponent(String(h || '')));
    return Array.isArray(v) ? v.map(String) : [];
  } catch (e) { return []; }
}

export function bytesToB64(u8: Uint8Array): string {
  let s = '';
  for (let k = 0; k < u8.length; k += 0x8000)
    s += String.fromCharCode.apply(null, u8.subarray(k, k + 0x8000) as unknown as number[]);
  return btoa(s);
}

export function b64ToBytes(b64: string): Uint8Array {
  const s = atob(String(b64));
  const u8 = new Uint8Array(s.length);
  for (let k = 0; k < s.length; k++) u8[k] = s.charCodeAt(k);
  return u8;
}

// The bot's refusal, in the operator's words.
export function explainError(status: number, raw: unknown): string {
  const t = String(raw || '');
  if (t.indexOf('unresolved gallons') !== -1)
    return 'The file cannot be generated yet: at least one ticket has no ' +
      'gallon amount, and the county form cannot print a quantity nobody ' +
      'knows.\n\nSee "Gallons missing" just below \u2014 for each ticket, ' +
      'either name the truck that hauled it (the Decal column on the ' +
      'invoice) or leave that ticket off this filing.';
  if (t.indexOf('zero tickets') !== -1)
    return 'There is nothing to file: every ticket is un-ticked in the list. ' +
      'Tick at least one.';
  if (t.indexOf('stale or missing preview') !== -1)
    return 'Something on this page changed after the preview ran, so the ' +
      'approval no longer matches the data. Run the preview again, read ' +
      'it, then approve.';
  if (t.indexOf('unreviewed finding') !== -1)
    return 'The file will not generate until a person has reviewed the ' +
      'findings. Read the result of the check, then tick the approval box.';
  if (status === 401 || status === 403)
    return 'That access key was not accepted. Check your access key, or ' +
      'ask the admin for your own.';
  if (t.indexOf('county template missing') !== -1)
    return 'The county\u2019s official form is missing on the server, so ' +
      'nothing can be rendered on it. This one is for the engineers.';
  return 'Error ' + status + ': ' + t;
}

// recordCard, without the markup: what the answer to Record means.
// ok: true / false / null (no answer: may or may not have landed).
export function recordOutcome(ok: boolean | null, raw: string) {
  if (ok === null) return {state: 'no_answer' as const, recorded: false};
  if (!ok) {
    let why: unknown = raw, who = 'The server';
    try {
      const j = JSON.parse(raw);
      why = j.detail || raw;
      if (j.refused_by === 'tracker') who = 'The Tracker';
    } catch (e) { /* the raw text is the reason */ }
    return {state: 'refused' as const, recorded: false, who,
            why: typeof why === 'string' ? why : JSON.stringify(why)};
  }
  let said: {dry_run?: boolean; state?: string; what?: string; on?: string; dates?: string;
             filing_id?: string} | null = null;
  try { said = JSON.parse(raw).said; } catch (e) { /* no sentence from the server */ }
  if (!said) said = {dry_run: false, state: 'unconfirmed'};
  if (!said.dry_run && said.state === 'already') return {state: 'already' as const, recorded: false, said};
  if (!said.dry_run && said.state !== 'recorded') return {state: 'unconfirmed' as const, recorded: false, said};
  if (said.dry_run) return {state: 'test' as const, recorded: false, said};
  return {state: 'filed' as const, recorded: true, said};
}

// ---- NEW: a client picked from a real visit --------------------------------
// It counts like a client picked from the list (_src: 'picked', a receipt, adds
// no decision). The pickup comes from the visit: with several, the latest stop's
// recorded date (Yan, 2026-09-03), never computed and never typed.

export function clientFromVisit(v: {name: string; address: string; county?: string | null;
    in_dade?: boolean; visit_id?: string | number; visit_date: string}): Facility {
  const c: Facility = {name: v.name, address: v.address};
  if (v.county !== undefined) c.county = v.county;
  if (v.in_dade !== undefined) c.in_dade = v.in_dade;
  c._src = 'picked';
  c._from = 'visit';
  if (v.visit_id !== undefined) c._visit_id = v.visit_id;
  c._visit_date = v.visit_date;
  return c;
}

export function latestVisitDate(clients: Facility[] | null | undefined): string {
  let best = '';
  (clients || []).forEach(f => {
    const d = (f && f._from === 'visit' && f._visit_date) ? String(f._visit_date) : '';
    if (d > best) best = d;
  });
  return best;
}

// ---- The page's state and acts ---------------------------------------------

export class MonthlyRules {
  // What were globals on the page.
  LOADS: Load[] = [];
  FETCHF: Finding[] = [];
  INV_DECALS: Record<string, string> = {};
  INV_DATES: Record<string, string> = {};
  INVOICE_SRC: {name: string; b64: string} | null = null;
  INVOICE_READ: string[] | null = null;
  INVOICE_SETTLED = true;
  HAND_ADDED: Record<string, boolean> = {};
  PAPER_DATES: Record<string, string> = {};
  PAPER_DECALS: Record<string, string> = {};
  PAPER_FORM: Record<string, PaperForm> = {};
  PAPER_EDIT: PaperForm | null = null;
  ARCHIVED: Record<string, ArchiveRecord> = {};
  ARCHIVED_ROWS: Record<string, Load> = {};
  FILED_TICKETS: Record<string, {period?: string; filed_at?: string}> = {};
  JUST_ARCHIVED: {t: string; name: string; rec: unknown}[] = [];
  JUST_DATED: Record<string, unknown>[] = [];
  RESENT: string[] = [];
  RESTORE_NOTE = '';
  PREVIEW_FINDINGS: Finding[] = [];
  previewedPayload: string | null = null;
  previewToken: string | null = null;
  GENERATED: {id: string | null; ym: string; invoice: string | null; tickets: number; list: string[]} | null = null;
  // What were form fields on the page.
  ym: string;
  invoiceText = '';                // #invoice, the source of truth for the list
  invoiceId = '';                  // #invid
  approvalDisabled = true;         // #approved.disabled: only a check opens it
  approved = false;                // #approved.checked
  invoiceStatus: {text: string; tone: string} | null = null;   // #invstat, after a read
  lastError = '';                  // #error
  candidates: {near: {guess: string; as_read: string}[]; other: string[]; outside: string[]} =
    {near: [], other: [], outside: []};

  constructor(ym?: string) { this.ym = ym || ''; }

  // Small readers
  invoiceTickets(): string[] | null { return parseTickets(this.invoiceText); }
  isHeld(l: Load): boolean { return isHeld(l); }
  resolvedGallons(l: Load): number | null { return resolvedGallons(l); }
  isOutOfCounty(l: Load): boolean { return isOutOfCounty(l); }
  reportShape() { return reportShape(this.LOADS, this.ym); }
  indexOfTicket(t: unknown): number {
    return this.LOADS.findIndex(l => String(l.ticket_number || '') === String(t));
  }

  // refreshAll: everything else it does is drawing.
  private refreshAll(): void {
    if (this.LOADS.length && this.LOADS.some(l => l._ord == null)) this.resequence();
    this.refreshGate();
  }

  // ---- The fetch -----------------------------------------------------------

  // fetchMonth(false): a clean pull. The first open of an empty page, or the
  // one-month audit view: it carries nothing.
  adoptFetch(resp: FetchResponse): void { this.fetchMonth(resp, false); }

  // fetchMonth(true), the Reload button: keeps the acts that depart from the
  // default (carryOperatorWork). A Dade tick is NOT carried: the invoice re-ticks.
  reload(resp: FetchResponse): void { this.fetchMonth(resp, true); }

  private fetchMonth(j: FetchResponse, unreported: boolean): void {
    this.lastError = '';
    this.setArchiveState(j, true);
    this.replaceLoads(j.loads, unreported ? {carryFrom: this.LOADS} : null);
    this.setFetchFindings(j.fetch_findings);
    this.mergeDecals();
    this.refreshAll();
  }

  // setFetchFindings: resets replace everything except the invoice's rules.
  setFetchFindings(newOnes?: Finding[] | null): void {
    const keep = this.FETCHF.filter(f => INVOICE_RULES.includes(f.rule));
    this.FETCHF = keep.concat((Array.isArray(newOnes) ? newOnes : [])
      .filter(f => !INVOICE_RULES.includes(f.rule)));
  }

  replaceLoads(newLoads?: Load[] | null, opts?: {carryFrom?: Load[]} | null): void {
    const before = (opts && opts.carryFrom) || null;
    this.LOADS = Array.isArray(newLoads) ? newLoads : [];
    this.JUST_DATED = [];
    const carry: Record<string, string> = {};
    Object.keys(this.HAND_ADDED).forEach(t => { if (this.PAPER_DECALS[t]) carry[t] = this.PAPER_DECALS[t]; });
    this.LOADS.forEach(l => { delete l._manual; l._excluded = true; });
    if (before) this.LOADS = this.LOADS.concat(this.carryOperatorWork(before, this.LOADS));
    this.PAPER_DATES = {};
    this.PAPER_DECALS = {};
    this.PAPER_FORM = {};
    this.PAPER_EDIT = null;
    this.PREVIEW_FINDINGS = [];
    this.INVOICE_SETTLED = true;
    this.applyInvoiceToLoads();
    this.LOADS.forEach(l => {
      const t = String(l.ticket_number || '');
      if (isOutOfCounty(l)) return;
      if (carry[t] && !l.decal) {
        l.decal = carry[t]; l._decal_src = 'manual';
        if (this.pinsAgainstPaper(t, carry[t])) l._decal_pinned = true;
      }
      else if (carry[t]) this.PAPER_DECALS[t] = carry[t];
    });
  }

  // Reload keeps the operator's work (M1). Returns the hand rows to append; the
  // fresh rows are changed in place.
  carryOperatorWork(before: Load[] | null, fresh: Load[]): Load[] {
    const byT: Record<string, Load> = {};
    fresh.forEach(l => { byT[String(l.ticket_number || '')] = l; });
    const hand: Load[] = [];
    (before || []).forEach(o => {
      const t = String((o && o.ticket_number) || '');
      const n = byT[t];
      if (o._paper) {
        if (this.ARCHIVED[t]) return;
        if (!n) { hand.push(o); return; }
        const diff = handVsSystem(o, n);
        if (diff) n._hand_replaced = diff;
        return;
      }
      if (!n) return;
      if (o._hand_replaced) n._hand_replaced = o._hand_replaced;
      if (isOutOfCounty(n)) {
        if (isOutOfCounty(o) && o._excluded && !defaultExcluded(o, null) &&
            !defaultExcluded(n, null)) {
          n._excluded = true;
          n._manual = true;
        }
        return;
      }
      if (o._offload_src === 'operator' && o._offload_pinned === true &&
          String(n.offload_date || '') !== String(o.offload_date || '')) {
        n._offload_feed = String(n.offload_date || '');
        n.offload_date = o.offload_date;
        n._offload_src = 'operator';
        n._offload_pinned = true;
      }
      const sys = String(n.decal || '').trim().toUpperCase();
      if (o._decal_src === 'manual' && o.decal && (o._decal_pinned || !sys)) {
        if (sys) n._decal_feed = n.decal;
        n.decal = o.decal;
        n._decal_src = 'manual';
        if (o._decal_pinned) n._decal_pinned = true;
      }
    });
    return hand;
  }

  handReplacedFindings(): Finding[] {
    return this.LOADS.filter(l => !l._excluded && l._hand_replaced).map(l => ({
      rule: 'manual_load_replaced_by_feed', row_key: String(l.ticket_number || ''),
      detail: 'Entered by hand before the system had this ticket; Reload put the ' +
              'system\u2019s row in its place. It differs from what was typed: ' +
              l._hand_replaced + '. Check it against the paper.'}));
  }

  // restoreLoads: the saved month is the operator's own state.
  restoreLoads(savedLoads: Load[] | null | undefined): void {
    this.LOADS = Array.isArray(savedLoads) ? savedLoads : [];
    this.LOADS = this.LOADS.filter(l => {
      const t = String((l && l.ticket_number) || '');
      if (this.ARCHIVED[t]) { this.ARCHIVED_ROWS[t] = l; return false; }
      return true;
    });
    this.JUST_DATED = [];
    this.PAPER_DATES = {};
    this.PAPER_DECALS = {};
    this.PAPER_FORM = {};
    this.PAPER_EDIT = null;
    this.PREVIEW_FINDINGS = [];
    const inv = parseTickets(this.invoiceText);
    this.LOADS.forEach(l => {
      if (!!l._excluded !== defaultExcluded(l, inv)) l._manual = true;
      else delete l._manual;
    });
    this.applyInvoiceToLoads();
  }

  // ---- Ticks ---------------------------------------------------------------

  // setIncluded plus what its checkbox handler does next. "File it" on a dumped-
  // but-not-billed row is this same act: setIncluded(i, true).
  setIncluded(i: number, on: boolean): void {
    const l = this.LOADS[i];
    if (l) {
      l._excluded = !on;
      l._manual = true;
    }
    this.refreshAll();
  }

  applyInvoiceToLoads(): void {
    const inv = parseTickets(this.invoiceText);
    this.LOADS.forEach(l => {
      if (l._manual) return;
      l._excluded = defaultExcluded(l, inv);
    });
    this.resequence();
  }

  resequence(): void {
    const view = this.LOADS.map((l, i) => ({l: l, i: i}));
    const nothingFiled = !this.LOADS.some(l => !l._excluded && !isHeld(l));
    const rank = (l: Load) => isHeld(l) ? (nothingFiled ? 2 : 1)
                                        : (l._excluded ? (nothingFiled ? 1 : 2) : 0);
    view.sort((a, b) => {
      const ax = rank(a.l), bx = rank(b.l);
      if (ax !== bx) return ax - bx;
      if (ax === 0) {
        const ad = isOutOfCounty(a.l) ? String(a.l.disposal_facility || 'zz') : '';
        const bd = isOutOfCounty(b.l) ? String(b.l.disposal_facility || 'zz') : '';
        if (ad !== bd) return ad.localeCompare(bd);
      }
      return String(b.l.offload_date || '').localeCompare(String(a.l.offload_date || ''));
    });
    view.forEach((vr, n) => {
      vr.l._ord = n;
      vr.l._ordBlock = isHeld(vr.l) ? 'held' : (vr.l._excluded ? 'off' : 'on');
    });
  }

  // Which block a load sits in. Until an invoice puts a row 'on', all but held read 'on'.
  blockOf(l: Load): 'on' | 'off' | 'held' {
    const split = this.LOADS.some(x => x._ordBlock === 'on');
    return split ? (l._ordBlock || 'off') : (isHeld(l) ? 'held' : 'on');
  }

  manualLoads(): Load[] { return this.LOADS.filter(l => l._manual); }

  matchInvoiceExactly(): void {
    this.LOADS.forEach(l => { delete l._manual; });
    this.applyInvoiceToLoads();
    this.refreshAll();
  }

  // ---- Truck ---------------------------------------------------------------

  mergeDecals(): number {
    const found: Finding[] = [];
    let n = 0;
    this.LOADS.forEach(l => {
      const paper = this.INV_DECALS[String(l.ticket_number)];
      if (!paper) return;
      if (l._decal_pinned) return;
      const own = ('_decal_feed' in l) ? l._decal_feed : l.decal;
      if (!own || l._decal_src === 'manual') {
        l.decal = paper;
        l._decal_src = 'invoice';
        n++;
        return;
      }
      if (own === paper) {
        if (l._decal_src === 'invoice') {
          l.decal = paper; delete l._decal_feed; n++;
        }
        return;
      }
      l._decal_feed = own;
      l.decal = paper;
      l._decal_src = 'invoice';
      n++;
      found.push({
        rule: DECAL_MISMATCH_RULE,
        row_key: String(l.ticket_number || ''),
        detail: 'the system says truck ' + own + ' hauled this ticket and the ' +
                'invoice says ' + paper + '. The invoice decides, so ' + paper +
                ' is what this form uses -- the gallon amount comes from the ' +
                'truck. Check the paper, and have the system record corrected.'
      });
    });
    this.FETCHF = this.FETCHF.filter(f => f.rule !== DECAL_MISMATCH_RULE).concat(found);
    return n;
  }

  clearInvoiceDecals(): void {
    this.LOADS.forEach(l => {
      if (l._decal_src !== 'invoice') return;
      l.decal = ('_decal_feed' in l) ? l._decal_feed : null;
      delete l._decal_feed;
      delete l._decal_src;
    });
  }

  // Truth table: before the paper a guess, after it a correction (pinned).
  setLoadDecal(i: number, decal: string): void {
    const l = this.LOADS[i];
    if (!l || isOutOfCounty(l)) return;
    const d = String(decal || '').trim().toUpperCase();
    if (!d || !(d in DECAL_GALLONS)) { this.refreshAll(); return; }
    const paper = String(this.INV_DECALS[String(l.ticket_number || '')] || '').toUpperCase();
    if (paper && d === paper) { this.useInvoiceDecal(i); return; }
    l.decal = d;
    l._decal_src = 'manual';
    if (setAfterPaper(this.INV_DECALS, l.ticket_number)) l._decal_pinned = true;
    else delete l._decal_pinned;
    this.refreshAll();
  }

  pinsAgainstPaper(t: unknown, d: unknown): boolean {
    const paper = String(this.INV_DECALS[String(t || '')] || '').trim().toUpperCase();
    return setAfterPaper(this.INV_DECALS, t) && String(d || '').trim().toUpperCase() !== paper;
  }

  // The ONE path that clears a pin.
  useInvoiceDecal(i: number): void {
    const l = this.LOADS[i];
    if (!l) return;
    const paper = this.INV_DECALS[String(l.ticket_number || '')];
    if (!paper) return;
    l.decal = paper;
    l._decal_src = 'invoice';
    delete l._decal_pinned;
    this.mergeDecals();
    this.refreshAll();
  }

  setNumberDecal(num: unknown, decal: unknown): void {
    const t = String(num || '');
    const d = String(decal || '').trim().toUpperCase();
    const i = this.LOADS.findIndex(l => String(l.ticket_number || '') === t);
    if (i !== -1) { if (d) this.setLoadDecal(i, d); return; }
    if (d && d in DECAL_GALLONS) this.PAPER_DECALS[t] = d; else delete this.PAPER_DECALS[t];
    this.refreshAll();
  }

  // The paper row's truck select (a listener on #mismatch): stored as chosen.
  setPaperDecal(t: string, v: string): void { this.PAPER_DECALS[t] = v; }

  // "Gallons missing" panel (handlers inside renderBlockers). This path does not
  // pin and does not validate, unlike setLoadDecal. Kept as it was.
  blockerSetDecal(i: number, value: string): void {
    const l = this.LOADS[i];
    if (value) { l.decal = value; l._decal_src = 'manual'; }
    else if (l._decal_src === 'manual') { l.decal = null; delete l._decal_src; }
    this.refreshAll();
  }

  // "Leave it off". Sets no hand mark, unlike setIncluded, so the next read of the
  // invoice can tick the row again if the paper bills it. Kept as it was.
  blockerLeaveOff(i: number): void {
    this.LOADS[i]._excluded = true;
    this.refreshAll();
  }

  // ---- Offload date --------------------------------------------------------

  pinOffload(l: Load): void {
    l._offload_pinned = setAfterPaper(this.INV_DATES, l.ticket_number);
    delete l._offload_guess;
  }

  // "Use <date>, the invoice's". On a fetched row it departs from the default (the
  // feed's), so it persists as a pinned correction. Its way back is Undo.
  useInvoiceDate(t: unknown): boolean {
    const tk = String(t || '');
    const l = this.LOADS.find(x => String(x.ticket_number || '') === tk);
    const paper = this.INV_DATES[tk];
    if (!l || !paper || isOutOfCounty(l)) return false;
    const prev = this.JUST_DATED.find(x => x.t === tk && this.rowAsClickLeft(x, l));
    const was: Record<string, unknown> = prev ? Object.assign({}, prev, {paper: paper})
                     : {t: tk, date: String(l.offload_date || ''), paper: paper};
    if (!prev) ['_offload_src', '_offload_pinned', '_offload_feed', '_offload_guess'].forEach(k => {
      if (k in l) was[k] = l[k]; });
    if (!l._paper && !('_offload_feed' in l)) l._offload_feed = String(l.offload_date || '');
    l.offload_date = paper;
    l._offload_src = l._paper ? 'invoice' : 'operator';
    this.pinOffload(l);
    was.src = l._offload_src;
    this.syncEditOffload(tk, paper);
    this.JUST_DATED = this.JUST_DATED.filter(x => x.t !== tk).concat([was]);
    this.refreshAll();
    return true;
  }

  // Undo of the one click, only while the row is as the click left it.
  undoInvoiceDate(t: unknown): boolean {
    const tk = String(t || '');
    const was = this.JUST_DATED.find(x => x.t === tk);
    const l = this.LOADS.find(x => String(x.ticket_number || '') === tk);
    if (!was || !l || !this.datedLineTrue(was, l)) { this.refreshAll(); return false; }
    this.JUST_DATED = this.JUST_DATED.filter(x => x.t !== tk);
    l.offload_date = was.date as string;
    ['_offload_src', '_offload_pinned', '_offload_feed', '_offload_guess'].forEach(k => {
      if (k in was) l[k] = was[k]; else delete l[k]; });
    this.syncEditOffload(tk, was.date as string);
    this.refreshAll();
    return true;
  }

  private rowAsClickLeft(x: Record<string, unknown>, l: Load | undefined): boolean {
    return !!l && String(l.offload_date || '') === x.paper && l._offload_src === x.src;
  }

  private datedLineTrue(x: Record<string, unknown>, l: Load | undefined): boolean {
    return this.rowAsClickLeft(x, l) && this.INV_DATES[x.t as string] === x.paper;
  }

  // justDatedLines, as data: the undoable "now dumped <date>" lines still true.
  datedLines(): {t: string; paper: string; was: string; hand: boolean; pickupAfter: boolean}[] {
    const out: {t: string; paper: string; was: string; hand: boolean; pickupAfter: boolean}[] = [];
    this.JUST_DATED.forEach(x => {
      const l = this.LOADS.find(y => String(y.ticket_number || '') === x.t);
      if (!this.datedLineTrue(x, l)) return;
      out.push({t: x.t as string, paper: x.paper as string, was: x.date as string,
                hand: !!(l && l._paper), pickupAfter: !!l && pickupAfter(l.pickup_date, l.offload_date)});
    });
    return out;
  }

  private syncEditOffload(t: unknown, v: string): void {
    if (this.PAPER_EDIT && this.PAPER_EDIT.t === String(t)) this.PAPER_EDIT.offload = v;
  }

  // A new paper replaces a GUESS; a correction, a feed date or an older file's stay.
  mergeDates(): number {
    let n = 0;
    this.LOADS.forEach(l => {
      const paper = this.INV_DATES[String(l.ticket_number || '')];
      if (!paper || l._offload_pinned !== false || isOutOfCounty(l)) return;
      if (String(l.offload_date || '') === paper) return;
      if (!('_offload_guess' in l)) l._offload_guess = String(l.offload_date || '');
      l.offload_date = paper;
      l._offload_src = 'invoice';
      this.syncEditOffload(l.ticket_number, paper);
      n++;
    });
    return n;
  }

  // ---- The findings --------------------------------------------------------

  manualDecalFindings(): Finding[] {
    const out: Finding[] = [];
    this.LOADS.forEach((l, i) => {
      if (l._excluded || l._decal_src !== 'manual' || !l.decal) return;
      if (isOutOfCounty(l)) return;
      const paper = this.INV_DECALS[String(l.ticket_number || '')];
      if (l._decal_pinned && paper &&
          String(paper).trim().toUpperCase() !== String(l.decal).trim().toUpperCase()) {
        out.push({rule: DECAL_VS_INVOICE_RULE,
          row_key: String(l.ticket_number),
          detail: 'Truck chosen by hand (' + l.decal + ') \u2014 the billed price ' +
                  'names ' + paper + '.'});
        return;
      }
      const g = DECAL_GALLONS[String(l.decal).trim().toUpperCase()];
      out.push({rule: 'operator_set_decal',
        row_key: String(l.ticket_number || ('<row ' + (i + 1) + ' without ticket>')),
        detail: 'Truck set by the operator: ' + l.decal + ', which files ' +
                (g == null ? '?' : g.toLocaleString('en-US')) + ' gal for this ' +
                'ticket. Check it against the Decal column on the county ' +
                'invoice before approving.'});
    });
    return out;
  }

  paperLoadFindings(): Finding[] {
    return this.LOADS.filter(l => !l._excluded && l._paper).map(l => ({
      rule: 'manual_load_from_paper',
      row_key: String(l.ticket_number || ''),
      detail: 'entered by hand from the county\u2019s paper; the manifests ' +
              'system has no ticket for it. ' + this.paperProvenance(l)}));
  }

  // "...; pickup 2026-09-10 typed; 2 clients picked from this month's list."
  // CHANGED only for a visit pick, where the old words would be false (README).
  paperProvenance(l: Load): string {
    const fa = Array.isArray(l.facilities) ? l.facilities : [];
    const nt = fa.filter(f => f && f._src === 'typed').length;
    const nv = fa.filter(f => f && f._src !== 'typed' && f._from === 'visit').length;
    const np = fa.length - nt - nv;
    const parts: string[] = [];
    parts.push(l.offload_date
      ? 'Offload ' + l.offload_date + (l._offload_src === 'invoice'
          ? ('_offload_guess' in l
              ? ' from the invoice, replacing ' + (l._offload_guess || 'none') + ' typed before it'
              : ' from the invoice, confirmed')
          : ' typed')
      : 'No offload date');
    parts.push(l.pickup_date
      ? 'pickup ' + l.pickup_date + (latestVisitDate(fa) === l.pickup_date ? ' from the visit' : ' typed')
      : 'no pickup date');
    if (!fa.length) parts.push('no clients');
    if (np) parts.push(np + ' client' + pl(np) + ' picked from this month\u2019s list');
    if (nv) parts.push(nv + ' client' + pl(nv) + ' picked from recorded visits');
    if (nt) parts.push(nt + ' client' + pl(nt) + ' typed');
    return parts.join('; ') + '.';
  }

  clientFindings(): Finding[] {
    const out: Finding[] = [];
    this.LOADS.forEach(l => {
      if (l._excluded || !l._paper) return;
      (Array.isArray(l.facilities) ? l.facilities : []).forEach(f => {
        if (!f || (f._src !== 'typed' && f._src !== 'picked')) return;
        out.push({rule: f._src === 'typed' ? 'client_typed' : 'operator_set_client',
                  row_key: String(l.ticket_number || ''),
                  detail: clientDetail(f.name, f.address)});
      });
    });
    return out;
  }

  offloadInvoiceFindings(): Finding[] {
    return this.LOADS.filter(l => !l._excluded && !isOutOfCounty(l)).filter(l => {
      const read = this.INV_DATES[String(l.ticket_number || '')];
      return read && l.offload_date && String(l.offload_date) !== read;
    }).map(l => ({rule: 'offload_vs_invoice', row_key: String(l.ticket_number),
      detail: 'The invoice bills this ticket on ' + this.INV_DATES[String(l.ticket_number)] +
              (l._paper || l._offload_src === 'operator'
                ? '; the row says it was offloaded ' + l.offload_date + '.'
                : '; the system has it offloaded ' + l.offload_date + '.')}));
  }

  operatorOffloadFindings(): Finding[] {
    return this.LOADS.filter(l => !l._excluded && !l._paper && !isOutOfCounty(l) &&
                                  l._offload_src === 'operator').map(l => ({
      rule: 'operator_set_offload', row_key: String(l.ticket_number || ''),
      detail: 'Offload date set by the operator: ' + l.offload_date +
              (l.offload_date === this.INV_DATES[String(l.ticket_number || '')]
                ? ', the invoice\u2019s Service Date' : '') +
              '. The system said ' + (l._offload_feed || 'nothing') + '.'}));
  }

  // Findings of the last check that ask a question about a ticket.
  findingsByTicket(): Record<string, Finding[]> {
    const by: Record<string, Finding[]> = {};
    this.PREVIEW_FINDINGS.forEach(f => {
      if (f.expected || RECEIPT_RULES.indexOf(f.rule) !== -1) return;
      const k = String(f.row_key || '');
      if (!k) return;
      (by[k] = by[k] || []).push(f);
    });
    return by;
  }

  // Every flag on every row, before or after a check. The "to decide" count reads it.
  combinedFlagsByTicket(): Record<string, Finding[]> {
    const by = this.findingsByTicket();
    const has = (tk: string, rule: string) => (by[tk] || []).some(f => f.rule === rule);
    const add = (tk: string, rule: string, detail: string) => {
      if (has(tk, rule)) return;
      (by[tk] = by[tk] || []).push({rule: rule, detail: detail});
    };
    const md = this.manualDecalFindings();
    withoutReplacedDecalNotes(this.FETCHF, md).forEach(f => {
      if (f.expected || RECEIPT_RULES.indexOf(f.rule) !== -1) return;
      const k = String(f.row_key || '');
      if (k) add(k, f.rule, f.detail);
    });
    md.forEach(f => add(String(f.row_key), f.rule, f.detail));
    this.clientFindings().concat(this.offloadInvoiceFindings()).concat(this.handReplacedFindings()).forEach(f => {
      if (RECEIPT_RULES.indexOf(f.rule) !== -1) return;
      const k = String(f.row_key || '');
      if ((by[k] || []).some(g => g.rule === f.rule && g.detail === f.detail)) return;
      if (f.rule === 'offload_vs_invoice' && has(k, f.rule)) return;
      (by[k] = by[k] || []).push({rule: f.rule, detail: f.detail});
    });
    this.LOADS.forEach(l => {
      const tk = String(l.ticket_number || NO_TICKET_KEY);
      (Array.isArray(l.feed_conflicts) ? l.feed_conflicts : []).forEach(c =>
        add(tk, 'feed_rows_conflict', String(c)));
      if (l.ticket_number && !/^\d{6}$/.test(String(l.ticket_number)))
        add(tk, 'manifest_number_shape',
            '\u201c' + String(l.ticket_number) + '\u201d is not a six-digit manifest ' +
            'number. Leave it un-ticked; have the number fixed in the Tracker.');
      if (!l._excluded && l._offload_src && pickupAfter(l.pickup_date, l.offload_date))
        add(tk, 'pickup_after_offload', 'pickup ' + l.pickup_date + ' after offload ' +
            l.offload_date + ' \u2014 one of the two dates is wrong.');
      if (!l._excluded && l._paper)
        add(tk, 'manual_load_from_paper',
            'entered by hand from the county\u2019s paper \u2014 the manifests ' +
            'system has no ticket for it. Check the number, the gallons and ' +
            'the offload date against the invoice. ' + this.paperProvenance(l));
      if (isHeld(l) && !has(tk, 'out_of_county_sizes_missing'))
        add(tk, 'out_of_county_gallons_held',
            'this ticket was disposed outside Miami-Dade, so its gallons ' +
            'come from each client\u2019s trap size on file' +
            ((l.sizes_missing_clients || []).length
              ? ' \u2014 and ' + (l.sizes_missing_clients as string[]).join(', ') +
                ' ' + ((l.sizes_missing_clients as string[]).length === 1 ? 'has' : 'have') +
                ' none yet. Add it in the Client App and fetch the month ' +
                'again. There is nothing to decide here.'
              : '. It has no quantity yet \u2014 see the other note on this ' +
                'ticket for why.'));
      else if (!l._excluded && resolvedGallons(l) == null)
        add(tk, 'ticket_without_gallons',
            'no gallon amount and no truck decal. Name the truck (the Decal ' +
            'column on the paper) in "Gallons missing" below, or un-tick ' +
            'this row.');
    });
    return by;
  }

  // ---- The invoice against the data ----------------------------------------

  invoiceWindow(): {from: string; to: string} | null {
    const inv = parseTickets(this.invoiceText);
    if (inv === null) return null;
    const ds = this.LOADS.filter(l => inv.indexOf(String(l.ticket_number || '')) !== -1)
                    .map(l => String(l.offload_date || ''))
                    .filter(Boolean).sort();
    return ds.length ? {from: ds[0], to: ds[ds.length - 1]} : null;
  }

  invoiceOnlyTickets(): string[] {
    const inv = parseTickets(this.invoiceText);
    if (inv === null) return [];
    const have = this.LOADS.map(l => String(l.ticket_number || ''));
    const out: string[] = [];
    inv.forEach(t => {
      const k = String(t);
      if (have.indexOf(k) === -1 && out.indexOf(k) === -1 && !this.ARCHIVED[k]) out.push(k);
    });
    return out;
  }

  invoiceArchivedTickets(): string[] {
    const inv = parseTickets(this.invoiceText) || [];
    const have = this.LOADS.map(l => String(l.ticket_number || ''));
    return inv.map(String).filter((t, i, a) => a.indexOf(t) === i && !!this.ARCHIVED[t]
                                              && have.indexOf(t) === -1);
  }

  inWindowNotBilled(): Load[] {
    const w = this.invoiceWindow();
    if (!w) return [];
    const inv = parseTickets(this.invoiceText) || [];
    return this.LOADS.filter(l => {
      if (inv.indexOf(String(l.ticket_number || '')) !== -1) return false;
      if (isOutOfCounty(l)) return false;
      if (!l._excluded) return false;
      const d = String(l.offload_date || '');
      return !!d && d >= w.from && d <= w.to;
    });
  }

  // ---- The invoice list ----------------------------------------------------

  // invoiceTyping: mid-sentence. It ticks, but does not accuse.
  invoiceTyping(text: string): void {
    this.invoiceText = text;
    this.INVOICE_SETTLED = false;
    this.applyInvoiceToLoads();
    this.refreshAll();
  }

  // invoiceFinished: they left the box. The list is a statement.
  invoiceFinished(text?: string): void {
    if (text !== undefined) this.invoiceText = text;
    this.INVOICE_SETTLED = true;
    this.applyInvoiceToLoads();
    this.refreshAll();
  }

  setInvoiceId(v: string): void { this.invoiceId = v; this.refreshGate(); }

  // applyMonth: re-labels the report, re-locks approval, reloads nothing.
  applyMonth(ym: string): void {
    if (!/^\d{4}-\d{2}$/.test(String(ym || ''))) return;
    this.ym = ym;
    this.refreshAll();
  }

  removeInvTicket(num: unknown): void {
    const keep = (parseTickets(this.invoiceText) || []).filter(t => String(t) !== String(num));
    this.invoiceText = keep.join('\n');
    delete this.HAND_ADDED[String(num)];
    if (this.PAPER_EDIT && this.PAPER_EDIT.t === String(num)) this.PAPER_EDIT = null;
    this.INVOICE_SETTLED = true;
    this.applyInvoiceToLoads();
    this.refreshAll();
  }

  acceptCandidate(num: string): void {
    this.invoiceText = withTicket(this.invoiceText, num);
    this.INVOICE_SETTLED = true;
    // The chip's click removed the chip: same thing, on the list.
    this.candidates.near = this.candidates.near.filter(c => c.guess !== num);
    this.candidates.other = this.candidates.other.filter(c => c !== num);
    this.candidates.outside = this.candidates.outside.filter(c => c !== num);
    this.applyInvoiceToLoads();
    this.refreshAll();
  }

  // addInvTicket: "Add number". Returns the status line beside the field.
  addInvTicket(raw: string, decal?: string): {ok: boolean; text: string; tone: string} {
    const num = String(raw || '').replace(/\D/g, '');
    if (!/^\d{6}$/.test(num)) return {ok: false, text: 'A ticket number is 6 digits', tone: 'bad'};
    this.HAND_ADDED[num] = true;
    this.acceptCandidate(num);
    const d = decal ? decal : '';
    if (d) this.setNumberDecal(num, d);
    const row = this.LOADS.find(l => String(l.ticket_number || '') === num);
    const inSys = !!row;
    const set = d && (row ? String(row.decal || '').toUpperCase() === d.toUpperCase()
                          : this.PAPER_DECALS[num] === d);
    return {ok: true, tone: inSys ? 'ok' : 'warn',
      text: num + ' added' + (set ? ' with ' + d : '') + (inSys ? '.'
        : '. It has no ticket in the system \u2014 copy its offload date in ' +
          '\u201cCheck these against the paper\u201d below and press Add from the paper.')};
  }

  // applyInvoiceParse: the bot's answer for a dropped invoice. Atomic: no tickets
  // read, nothing touched but the offered candidates.
  applyInvoiceParse(p: InvoiceParse, source: string): boolean {
    const tickets = p.tickets || [];
    this.candidates = {near: (p.near_tickets || []).slice(), other: (p.other_sixdigit || []).slice(),
                       outside: (p.outside_column || []).slice()};
    if (!tickets.length) {
      this.invoiceStatus = {text: 'No ticket numbers found in ' + source +
        ' \u2014 fields left unchanged; type the invoice from the paper', tone: 'bad'};
      return false;
    }
    this.invoiceText = tickets.join('\n');
    this.invoiceId = p.invoice_id || '';
    this.clearInvoiceDecals();
    this.HAND_ADDED = {};
    const newDecals = p.decals || {};
    Object.keys(this.PAPER_DECALS).forEach(t => {
      if (newDecals[t] && !this.pinsAgainstPaper(t, this.PAPER_DECALS[t])) delete this.PAPER_DECALS[t];
    });
    this.INV_DECALS = newDecals;
    this.INV_DATES = p.service_dates || {};
    this.mergeDates();
    const merged = this.mergeDecals();
    const dconf: Finding[] = (p.decal_conflicts || []).map(c => ({
      rule: 'invoice_decal_conflict', detail: c.detail, row_key: c.row_key }) as Finding)
      .concat((p.parse_warnings || []).map(w => ({
        rule: 'invoice_parse_warning', detail: w, row_key: null })))
      .concat(p.total_mismatch
        ? [{rule: 'invoice_total_mismatch', detail: p.total_mismatch, row_key: null}] : []);
    this.FETCHF = this.FETCHF.filter(f => !INVOICE_RULES.includes(f.rule)).concat(dconf);
    this.INVOICE_SETTLED = true;
    this.applyInvoiceToLoads();
    this.refreshAll();
    let msg = tickets.length + ' ticket(s) detected in ' + source +
      (p.invoice_id ? ' (invoice ' + p.invoice_id + ')' : ' \u2014 no invoice number found');
    const nd = Object.keys(this.INV_DECALS).length;
    if (nd) {
      msg += '; ' + nd + ' decal(s) read from the paper' +
        ((p.decals_inferred || []).length
          ? ' (' + (p.decals_inferred as unknown[]).length + ' matched by billed amount)' : '');
      if (merged) msg += ' \u2014 gallons will resolve for ' + merged + ' loaded ticket(s)';
    }
    const cand = (p.near_tickets || []).length + (p.other_sixdigit || []).length +
                 (p.outside_column || []).length;
    if (cand)
      msg += '; ' + cand + ' number(s) the reader could not commit to are ' +
        'offered below';
    if (p.source === 'ocr')
      msg += ' \u2014 read by OCR from a scan: count the ticket rows on the paper ' +
        'against the number detected, and check every digit';
    this.invoiceStatus = {text: msg + ' \u2014 verify against the paper before previewing', tone: 'warn'};
    return true;
  }

  // parseDroppedInvoice, after the bot answered. The bytes are kept so the saved
  // month can carry the paper, only once the parse has landed.
  adoptDroppedInvoice(p: InvoiceParse, name: string, b64: string): boolean {
    if (!this.applyInvoiceParse(p, name)) return false;
    this.INVOICE_SRC = {name: name, b64: b64};
    this.INVOICE_READ = (p.tickets || []).slice();
    return true;
  }

  // ---- Hand rows -----------------------------------------------------------

  // Clients on opts.clients keep where they came from (_src: picked | typed; a
  // visit pick is _src: picked, _from: visit, see clientFromVisit). Picked visits
  // give the pickup: their latest date wins over opts.pickup.
  addPaperLoad(num: unknown, offload: unknown, decal: unknown,
               opts?: {clients?: Facility[]; pickup?: string | null; offloadSrc?: string} | null): boolean {
    const o = opts || {};
    if (!ISO_DAY.test(String(offload || ''))) {
      this.lastError = 'Copy the offload date from the paper first \u2014 ' +
                       'it is printed on the ticket\u2019s row.';
      return false;
    }
    if (this.LOADS.some(l => String(l.ticket_number || '') === String(num)))
      return false;
    const dk = String(decal || '').trim().toUpperCase();
    const named = !!dk && DECAL_GALLONS[dk] != null;
    const clients = (o.clients || []).map(f => Object.assign({}, f));
    const fromVisit = latestVisitDate(clients);
    const row: Load = {ticket_number: String(num), gallons: null,
                decal: named ? dk : null,
                _decal_src: named ? 'manual' : undefined,
                pickup_date: fromVisit || o.pickup || null, offload_date: String(offload),
                facilities: clients,
                _offload_src: o.offloadSrc === 'invoice' ? 'invoice' : 'typed',
                _paper: true, _excluded: true};
    this.LOADS.push(row);
    if (named && this.pinsAgainstPaper(num, dk)) row._decal_pinned = true;
    this.pinOffload(row);
    delete this.PAPER_DATES[String(num)];
    delete this.PAPER_DECALS[String(num)];
    delete this.PAPER_FORM[String(num)];
    this.INVOICE_SETTLED = true;
    this.applyInvoiceToLoads();
    this.mergeDecals();
    this.lastError = '';
    this.refreshAll();
    return true;
  }

  // The clients the feed knows, each once. County and in_dade ride along.
  knownClients(): Facility[] {
    const seen: Record<string, boolean> = {}, out: {name: string; address: string; county?: string | null; in_dade?: boolean}[] = [];
    this.LOADS.forEach(l => {
      if (l._paper) return;
      (Array.isArray(l.facilities) ? l.facilities : []).forEach(f => {
        const name = String((f && f.name) || '').trim();
        const address = String((f && f.address) || '').trim();
        if (!name) return;
        const k = (name + '|' + address).toLowerCase();
        if (seen[k]) return;
        seen[k] = true;
        const c: {name: string; address: string; county?: string | null; in_dade?: boolean} = {name: name, address: address};
        if (f.county !== undefined) c.county = f.county;
        if (f.in_dade !== undefined) c.in_dade = f.in_dade;
        out.push(c);
      });
    });
    return out.sort((a, b) => a.name.localeCompare(b.name) || a.address.localeCompare(b.address));
  }

  searchClients(q: string): Facility[] {
    const words = String(q || '').toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return [];
    return this.knownClients().filter(c => {
      const hay = (c.name + ' ' + c.address).toLowerCase();
      return words.every(w => hay.indexOf(w) !== -1);
    }).slice(0, 8);
  }

  // The form behind "Add from the paper" and Edit (paperForm's state, no markup).
  formFor(t: unknown): PaperForm {
    const k = String(t);
    if (this.PAPER_EDIT && this.PAPER_EDIT.t === k) return this.PAPER_EDIT;
    return this.PAPER_FORM[k] || (this.PAPER_FORM[k] = blankForm());
  }

  formOffload(t: string, st?: PaperForm | null): string {
    if (st && st.offload !== undefined) return st.offload;
    if (this.PAPER_DATES[t] !== undefined) return this.PAPER_DATES[t];
    return this.INV_DATES[t] || '';
  }

  offloadSource(t: string, v: string): 'invoice' | 'typed' {
    return (v && this.INV_DATES[t] && v === this.INV_DATES[t]) ? 'invoice' : 'typed';
  }

  pfQuery(t: string, q: string): void { this.formFor(t).query = String(q || ''); }
  pfPick(t: string, k: number): void {
    const st = this.formFor(t);
    const c = this.searchClients(st.query)[k];
    if (!c) return;
    st.clients.push(Object.assign({}, c, {_src: 'picked' as const}));
    st.query = ''; st.msg = '';
  }
  // NEW: a stop tapped from the truck's real visits.
  pfPickVisit(t: string, v: Parameters<typeof clientFromVisit>[0]): void {
    const st = this.formFor(t);
    st.clients.push(clientFromVisit(v));
    st.query = ''; st.msg = '';
  }
  pfRemove(t: string, j: number): void { this.formFor(t).clients.splice(j, 1); }
  pfTypeOpen(t: string): void {
    const st = this.formFor(t);
    st.typing = {name: st.query, address: ''};
  }
  pfTypeCancel(t: string): void { this.formFor(t).typing = null; }
  // The exit when the list lacks the client. The address is REQUIRED.
  pfTyped(t: string, name: string, address: string): boolean {
    const st = this.formFor(t);
    const n = String(name || '').trim(), a = String(address || '').trim();
    if (!n || !a) {
      st.typing = {name: n, address: a};
      st.msg = !n ? 'Type the client\u2019s name.' : 'Type the address \u2014 the form prints it.';
      return false;
    }
    st.clients.push({name: n, address: a, _src: 'typed'});
    st.typing = null; st.query = ''; st.msg = '';
    return true;
  }
  pfPickup(t: string, v: string): void { this.formFor(t).pickup = String(v || ''); }
  pfOffload(t: string, v: string): void {
    const st = this.formFor(t);
    if (this.PAPER_EDIT && this.PAPER_EDIT.t === String(t)) st.offload = String(v || '');
    else this.PAPER_DATES[t] = String(v || '');
  }
  pfUseInvoiceDate(t: string): void { if (this.INV_DATES[t]) this.pfOffload(t, this.INV_DATES[t]); }

  // NEW: the pickup the form will carry. Picked visits decide; else what was typed.
  formPickup(st: PaperForm): string { return latestVisitDate(st.clients) || st.pickup || ''; }

  datesCross(t: string, st: PaperForm): boolean {
    const off = this.formOffload(t, st), pu = this.formPickup(st);
    return !!(pu && off && pu > off);
  }

  formDirty(st: PaperForm): boolean {
    const l = this.LOADS.find(x => String(x.ticket_number || '') === st.t && x._paper);
    if (!l) return false;
    const strip = (fa?: Facility[]) => JSON.stringify((fa || []).map(f => [f.name, f.address, f._src || '']));
    return strip(st.clients) !== strip(l.facilities) ||
           String(this.formPickup(st)) !== String(l.pickup_date || '') ||
           String(st.offload || '') !== String(l.offload_date || '');
  }

  // The line beside the button: red only when the act cannot happen.
  formLine(t: string, st: PaperForm, mode: 'add' | 'edit'): {tone: string; text: string} {
    const off = this.formOffload(t, st);
    if (!off)
      return {tone: 'bad', text: 'Type the offload date first \u2014 it is the Service ' +
                                 'Date on the ticket\u2019s row.'};
    const tone = this.datesCross(t, st) ? 'warn' : '';
    if (mode === 'edit' && this.formDirty(st))
      return {tone: tone, text: 'Not saved yet \u2014 Save puts it on the row.'};
    const gaps: string[] = [];
    if (!st.clients.length) gaps.push('no client');
    if (!this.formPickup(st)) gaps.push('no pickup date');
    if (gaps.length)
      return {tone: tone, text: (mode === 'edit' ? 'Saved with ' : 'Can be added with ') +
                                gaps.join(' and ') + ' \u2014 the row will say so.'};
    return {tone: tone || 'ok', text: 'Ready: ' + st.clients.length + ' stop' +
                                      pl(st.clients.length) + ', offload ' + off + '.'};
  }

  // "Add from the paper", from the form as it stands. The select the old page read
  // first is setPaperDecal here.
  addPaperFromForm(tk: unknown): boolean {
    const t = String(tk);
    const st = this.formFor(t);
    const off = this.formOffload(t, st);
    return this.addPaperLoad(t, off, this.PAPER_DECALS[t] || '',
                             {clients: st.clients, pickup: st.pickup,
                              offloadSrc: this.offloadSource(t, off)});
  }

  openPaperEdit(tk: unknown): boolean {
    const t = String(tk);
    const l = this.LOADS.find(x => String(x.ticket_number || '') === t && x._paper);
    if (!l) return false;
    if (!(this.PAPER_EDIT && this.PAPER_EDIT.t === t)) {
      this.PAPER_EDIT = Object.assign(blankForm(l.facilities, latestVisitDate(l.facilities) ? '' : l.pickup_date),
                                      {t: t, offload: String(l.offload_date || '')});
    }
    return true;
  }

  cancelPaperEdit(): void { this.PAPER_EDIT = null; }

  savePaperEdit(): boolean {
    const st = this.PAPER_EDIT;
    if (!st) return false;
    const l = this.LOADS.find(x => String(x.ticket_number || '') === st.t && x._paper);
    if (!l) { this.cancelPaperEdit(); return false; }
    if (!ISO_DAY.test(String(st.offload || ''))) {
      st.msg = 'The offload date is required \u2014 copy it from the paper.';
      return false;
    }
    l.facilities = st.clients.map(f => Object.assign({}, f));
    l.pickup_date = this.formPickup(st) || null;
    l.offload_date = st.offload;
    l._offload_src = this.offloadSource(st.t as string, st.offload as string);
    this.pinOffload(l);
    this.JUST_DATED = this.JUST_DATED.filter(x => x.t !== st.t);
    this.PAPER_EDIT = null;
    this.refreshAll();
    return true;
  }

  // ---- The archive ---------------------------------------------------------

  setArchiveState(j: FetchResponse | null | undefined, fromFetch: boolean): void {
    this.ARCHIVED = (j && j.archived) || {};
    if (j && j.filed_tickets) this.FILED_TICKETS = j.filed_tickets;
    if (fromFetch) {
      this.ARCHIVED_ROWS = (j && j.archived_rows) || {};
      this.RESENT = Object.keys(this.ARCHIVED_ROWS);
      this.JUST_ARCHIVED = [];
      this.RESTORE_NOTE = '';
    }
  }

  // Why this row cannot be archived, said before any click, or null. The filed
  // case carries link: true where the old page had an anchor to the history.
  archiveGuard(l: Load): {why: string; out: string; link?: boolean} | null {
    const t = String(l.ticket_number || '');
    if (t && !/^\d{6}$/.test(t))
      return {why: 'Not archivable',
              out: 'Archiving would hide real gallons \u2014 the number is fixed in the Tracker.'};
    const inv = parseTickets(this.invoiceText) || [];
    if (inv.indexOf(t) !== -1) {
      const id = this.invoiceId.trim();
      return l._paper
        ? {why: 'On the invoice \u2014 you entered it from the paper',
           out: 'Take the number off the invoice with the \u00d7 on its chip above.'}
        : {why: 'On invoice ' + (id || 'the one loaded') + ' \u2014 it is billed, so the paper decides',
           out: l._excluded ? 'Check the number on the paper.' : 'Un-tick it first.'};
    }
    const f = this.FILED_TICKETS[t];
    if (f)
      return {why: 'In the ' + monthLabel(String(f.period || '').slice(0, 7)) +
                   ' filing, recorded as filed on ' + (f.filed_at || '?') +
                   ' \u2014 a filed ticket stays filed',
              out: 'Open the filing history', link: true};
    if (!l._excluded)
      return {why: 'Ticked for this filing',
              out: 'Un-tick it first: the report\u2019s list changes only through its checkbox.'};
    return null;
  }

  // The body of POST /monthly/archive (submitArchive), or what is still missing.
  archiveBody(t: unknown, reason: string, text?: string, dup?: string):
      {err?: string; body?: Record<string, unknown>} {
    const tk = String(t);
    const st = {reason: reason, text: String(text || ''), dup: String(dup || '').replace(/\D/g, '')};
    const miss = archiveMissing(st);
    if (miss) return {err: miss};
    const l = this.LOADS.find(x => String(x.ticket_number || '') === tk);
    if (!l) return {err: 'no such row'};
    return {body: {ticket: tk, reason: st.reason,
      reason_text: st.text.trim() || null, duplicate_of: st.dup || null,
      invoice_tickets: parseTickets(this.invoiceText) || [],
      known_tickets: this.LOADS.map(x => String(x.ticket_number || '')),
      ticked: !l._excluded}};
  }

  // submitArchive, after the bot said yes.
  applyArchived(t: unknown, j: FetchResponse & {record?: unknown}): boolean {
    const tk = String(t);
    const l = this.LOADS.find(x => String(x.ticket_number || '') === tk);
    if (!l) return false;
    this.setArchiveState(j, false);
    this.LOADS = this.LOADS.filter(x => x !== l);
    this.ARCHIVED_ROWS[tk] = l;
    this.JUST_ARCHIVED.push({t: tk, name: clientNames(l)[0] || '', rec: j.record});
    this.refreshAll();
    return true;
  }

  // restoreArchived, after the bot said yes. Un-ticked unless the paper bills it.
  applyRestored(t: unknown, j: FetchResponse): void {
    const tk = String(t);
    this.setArchiveState(j, false);
    const row = this.ARCHIVED_ROWS[tk];
    delete this.ARCHIVED_ROWS[tk];
    this.JUST_ARCHIVED = this.JUST_ARCHIVED.filter(x => x.t !== tk);
    this.RESENT = this.RESENT.filter(x => x !== tk);
    if (row) {
      delete row._manual;
      row._restored = true;
      this.LOADS.push(row);
      this.applyInvoiceToLoads();
      this.RESTORE_NOTE = tk + ' is back in the list' + (row._excluded ? ', un-ticked.' : ', ticked by the invoice.');
    } else {
      this.RESTORE_NOTE = tk + ' is no longer archived. The system no longer sends it, so nothing comes ' +
                          'back to the list.';
    }
    this.refreshAll();
  }

  // loadArchiveState: the archive read on open meets a list already on the page.
  meetArchive(j: FetchResponse): void {
    this.setArchiveState(j, false);
    const before = this.LOADS.length;
    this.LOADS = this.LOADS.filter(l => {
      const t = String((l && l.ticket_number) || '');
      if (this.ARCHIVED[t]) { this.ARCHIVED_ROWS[t] = l; return false; }
      return true;
    });
    if (this.LOADS.length !== before) this.applyInvoiceToLoads();
    this.refreshAll();
  }

  // ---- The body the bot signs ----------------------------------------------

  payload(): PayloadResult {
    const ym = this.ym;
    if (!/^\d{4}-\d{2}$/.test(ym)) return {err: 'Pick a report month'};
    if (!this.LOADS.length) return {err: 'Load the month\'s tickets first (fetch button or file)'};
    const included = this.LOADS.filter(l => !l._excluded)
      .map(l => {
        const c = Object.assign({}, l);
        delete c._excluded; delete c._decal_src;
        delete c._manual; delete c._decal_feed;
        delete c._ord; delete c._ordBlock; delete c._decal_pinned;
        delete c._paper; delete c._offload_src; delete c._restored;
        delete c._hand_replaced;
        delete c._offload_pinned; delete c._offload_feed;
        delete c._offload_guess;
        if (Array.isArray(c.facilities))
          c.facilities = c.facilities.map(f => {
            const g = Object.assign({}, f);
            Object.keys(g).forEach(k => { if (k.charAt(0) === '_') delete g[k]; });
            return g;
          });
        return c;
      });
    if (!included.length) return {err: 'Every ticket is unchecked \u2014 nothing to file'};
    const body: PayloadBody = {
      year: +ym.slice(0, 4), month: +ym.slice(5, 7),
      invoice_id: this.invoiceId.trim() || null,
      invoice_tickets: parseTickets(this.invoiceText),
      loads: included };
    const excl = this.LOADS.map((l, i) => (l._excluded && !isHeld(l))
      ? String(l.ticket_number || ('<row ' + (i + 1) + ' without ticket>'))
      : null).filter(Boolean) as string[];
    if (excl.length) body.excluded_tickets = excl;
    body.candidate_pool = this.LOADS.map(l => {
      const e: {ticket_number: string; offload_date: string; out_of_county?: boolean} =
        {ticket_number: String(l.ticket_number || ''), offload_date: String(l.offload_date || '')};
      if (isOutOfCounty(l)) e.out_of_county = true;
      return e;
    });
    const md = this.manualDecalFindings();
    const ff = withoutReplacedDecalNotes(this.FETCHF, md).concat(md)
      .concat(this.paperLoadFindings()).concat(this.clientFindings())
      .concat(this.offloadInvoiceFindings()).concat(this.operatorOffloadFindings())
      .concat(this.handReplacedFindings());
    if (ff.length) body.fetch_findings = ff;
    return {body: body};
  }

  // Rows the bot would refuse: on the filing, no gallons. Held rows are not here.
  blockingLoads(): {l: Load; i: number}[] {
    const out: {l: Load; i: number}[] = [];
    this.LOADS.forEach((l, i) => {
      if (isHeld(l)) return;
      if (!l._excluded && resolvedGallons(l) == null) out.push({l: l, i: i});
    });
    return out;
  }

  // renderTiles and the list's filter bar, without the markup.
  counts() {
    const heldRows = this.LOADS.filter(l => isHeld(l));
    const inc = this.LOADS.filter(l => !l._excluded && !isHeld(l));
    const gal = inc.reduce((s, l) => s + (resolvedGallons(l) || 0), 0);
    const galDecal = inc.reduce((s, l) => s + (isOutOfCounty(l) ? 0 : (resolvedGallons(l) || 0)), 0);
    const by = this.combinedFlagsByTicket();
    const decidable = (l: Load) => {
      const fs = by[String(l.ticket_number || NO_TICKET_KEY)] || [];
      if (!fs.length) return false;
      return !(isHeld(l) && fs.every(f => {
        const t = ruleInfo(f.rule).tone;
        return t === 'hold' || t === 'policy';
      }));
    };
    return {
      loaded: this.LOADS.length,
      reported: inc.length,
      gallons: gal,
      gallonsDecal: galDecal,
      gallonsSizes: gal - galDecal,
      unresolved: inc.filter(l => resolvedGallons(l) == null).length,
      look: inc.filter(decidable).length,       // to decide, on the filing
      flagged: this.LOADS.filter(decidable).length,   // to decide, anywhere
      held: heldRows.length,
      heldClients: this.heldClients().length,
      off: this.LOADS.filter(l => l._excluded && !isHeld(l)).length,
      anyOn: inc.length > 0,
      setByHand: this.manualLoads().length,
      archived: Object.keys(this.ARCHIVED).length,
    };
  }

  // WHO to chase, each client once with its ticket count.
  heldClients(): [string, number][] {
    const seen = new Map<string, number>();
    this.LOADS.forEach(l => {
      if (!isHeld(l)) return;
      (l.sizes_missing_clients || []).forEach(nm => {
        const k = String(nm);
        seen.set(k, (seen.get(k) || 0) + 1);
      });
    });
    return Array.from(seen.entries()).sort((a, b) => a[0].localeCompare(b[0]));
  }

  // ---- NEW: what needs a person (read-only) --------------------------------
  // Everything the old page shows amber, counts as "to decide", or lists under
  // "Check these against the paper", as data. One difference from the old page:
  // it hides its local "not on the paper" lines once a check has answered the
  // same question; here they stay, and the check's copies of them are not repeated.
  decisions(): Decision[] {
    const out: Decision[] = [];
    const by = this.combinedFlagsByTicket();
    const stale = this.flagsAreStale();
    const onlyWaiting = (fs: Finding[]) => fs.length > 0 && fs.every(f => {
      const t = ruleInfo(f.rule).tone;
      return t === 'hold' || t === 'policy';
    });
    const base = (kind: DecisionKind, ticket: string | null, index: number | null,
                  rule: string | null, title: string, detail: string, counted: boolean): Decision => ({
      kind, ticket, index, rule, title: rule ? ruleInfo(rule).title : title,
      tone: rule ? ruleInfo(rule).tone : 'warn', detail, counted});

    // On the paper, absent from the data. Silent with no list to compare, and while typing.
    const only = (this.LOADS.length && this.INVOICE_SETTLED) ? this.invoiceOnlyTickets() : [];
    only.forEach(t => {
      out.push(Object.assign(base('number_no_ticket', t, null, 'invoice_ticket_missing_from_report', '',
        t + ' is on the invoice and the system has no ticket for it.', false), {
        invoiceDate: this.INV_DATES[t] || null, invoiceDecal: this.INV_DECALS[t] || null,
        typedDecal: this.PAPER_DECALS[t] || null, offload: this.formOffload(t, null) || null,
        handAdded: !!this.HAND_ADDED[t]}));
    });
    const archOn = (this.LOADS.length && this.INVOICE_SETTLED) ? this.invoiceArchivedTickets() : [];
    archOn.forEach(t => {
      out.push(Object.assign(base('archived_on_invoice', t, null, null, 'On this invoice, but archived',
        t + ' is billed, so the paper decides: restore it to file it, or take it off the invoice.', false), {
        record: this.ARCHIVED[t], row: this.ARCHIVED_ROWS[t] || null}));
    });
    this.inWindowNotBilled().forEach(l => {
      out.push(Object.assign(base('dumped_not_billed', String(l.ticket_number || '(no number)'), this.LOADS.indexOf(l),
        'ticket_in_window_not_billed', '', 'Dumped inside this invoice\u2019s dates but not on it.', false), {
        offload: l.offload_date || null, clients: clientNames(l)}));
    });

    // The rows, in reading order. These are what the old "N to decide" pill counts.
    const view = this.LOADS.map((l, i) => ({l, i}))
      .sort((a, b) => (a.l._ord == null ? a.i : a.l._ord) - (b.l._ord == null ? b.i : b.l._ord));
    view.forEach(({l, i}) => {
      const t = String(l.ticket_number || NO_TICKET_KEY);
      const fs = by[t] || [];
      const counted = fs.length > 0 && !(isHeld(l) && onlyWaiting(fs));
      const paperDecal = this.INV_DECALS[String(l.ticket_number || '')] || null;
      const paperDate = this.INV_DATES[String(l.ticket_number || '')] || null;
      fs.forEach(f => {
        const d = (kind: DecisionKind, extra: Record<string, unknown>) =>
          out.push(Object.assign(base(kind, t, i, f.rule, '', f.detail, counted), extra));
        switch (f.rule) {
          case DECAL_MISMATCH_RULE:
          case DECAL_VS_INVOICE_RULE:
            d('truck_differs', {rowDecal: l.decal || null, invoiceDecal: paperDecal,
              systemDecal: l._decal_feed === undefined ? null : l._decal_feed, pinned: !!l._decal_pinned,
              canUseInvoice: !!(l._decal_pinned && paperDecal &&
                String(paperDecal).toUpperCase() !== String(l.decal || '').toUpperCase())});
            break;
          case 'operator_set_decal':
            d('truck_set_by_hand', {rowDecal: l.decal || null, invoiceDecal: paperDecal,
              gallons: resolvedGallons(l)});
            break;
          case 'offload_vs_invoice':
            d('date_differs', {rowDate: l.offload_date || null, invoiceDate: paperDate,
              pickup: l.pickup_date || null, pinned: l._offload_pinned === true,
              canUseInvoice: !!(paperDate && !isOutOfCounty(l) && String(l.offload_date || '') !== paperDate),
              pickupAfterInvoiceDate: !!paperDate && pickupAfter(l.pickup_date, paperDate)});
            break;
          case 'out_of_county_gallons_held':
          case 'out_of_county_sizes_missing':
            d('waiting_on_size', {clients: l.sizes_missing_clients || [], facilities: l.facilities || [],
              disposal: l.disposal_facility || null});
            break;
          case 'manifest_number_shape':
            d('not_manifest_number', {number: l.ticket_number});
            break;
          case 'ticket_without_gallons':
            d('unresolved_gallons', {invoiceDecal: paperDecal,
              onInvoice: !!l.ticket_number && (parseTickets(this.invoiceText) || []).indexOf(String(l.ticket_number)) !== -1});
            break;
          case 'pickup_after_offload':
            d('pickup_after_offload', {pickup: l.pickup_date || null, offload: l.offload_date || null});
            break;
          case 'manual_load_from_paper':
            d('hand_row', {provenance: this.paperProvenance(l)});
            break;
          case 'client_typed':
            d('client_typed', {client: (l.facilities || []).find(c => c && c._src === 'typed' &&
              clientDetail(c.name, c.address) === f.detail) || null});
            break;
          case 'manual_load_replaced_by_feed':
            d('hand_replaced', {differences: l._hand_replaced || ''});
            break;
          case 'feed_rows_conflict':
            d('feed_conflict', {});
            break;
          default:
            d('row_finding', {});
        }
      });
    });

    // Findings about tickets not on the list.
    const loaded = this.LOADS.map(l => String(l.ticket_number || NO_TICKET_KEY));
    const skip = (f: Finding) => f.expected || RECEIPT_RULES.indexOf(f.rule) !== -1;
    this.FETCHF.forEach(f => {
      if (skip(f) || !f.row_key || loaded.indexOf(String(f.row_key)) !== -1) return;
      out.push(base('fetch_note', String(f.row_key), null, f.rule, '', f.detail, false));
    });
    if (!stale) this.PREVIEW_FINDINGS.forEach(f => {
      if (skip(f) || !f.row_key || loaded.indexOf(String(f.row_key)) !== -1) return;
      if (f.rule === 'invoice_ticket_missing_from_report' && only.indexOf(String(f.row_key)) !== -1) return;
      out.push(base('off_form', String(f.row_key), null, f.rule, '', f.detail, false));
    });

    // About the month: no ticket.
    const said: Record<string, boolean> = {};
    const monthly = this.FETCHF.concat(stale ? [] : this.PREVIEW_FINDINGS);
    monthly.forEach(f => {
      if (skip(f) || f.row_key) return;
      const k = f.rule + '|' + f.detail;
      if (said[k]) return;
      said[k] = true;
      out.push(base('month_note', null, null, f.rule, '', f.detail, false));
    });

    // Numbers the reader offered, not committed: added only by a person.
    this.candidates.near.forEach(c => out.push(Object.assign(
      base('reader_candidate', c.guess, null, null, 'Nearly a ticket number',
           'Read as ' + c.as_read + '. Check it on the paper, then add it.', false),
      {group: 'near', asRead: c.as_read})));
    this.candidates.outside.forEach(t => out.push(Object.assign(
      base('reader_candidate', t, null, null, 'Read in another column',
           'Found further along a row, not in the Ticket # column. Add it only if the paper has it as a ticket.', false),
      {group: 'outside'})));
    this.candidates.other.forEach(t => out.push(Object.assign(
      base('reader_candidate', t, null, null, 'Read, but not taken as a ticket',
           'A six-digit number outside the county\u2019s usual series.', false),
      {group: 'other'})));

    const s = this.reportShape();
    if (s) out.push(Object.assign(
      base('report_shape', null, null, null, 'Check the report month',
           s.out + ' of ' + s.total + ' tickets on this report were offloaded outside ' +
           monthLabel(this.ym) + '.', false), s));
    return out;
  }

  // ---- Approval: any change re-locks ---------------------------------------

  flagsAreStale(): boolean {
    if (this.previewedPayload === null) return true;
    const p = this.payload();
    return p.err ? true : JSON.stringify(p.body) !== this.previewedPayload;
  }

  lockApproval(): void { this.approved = false; this.approvalDisabled = true; }

  // A change locks. A later change back does NOT unlock: only a new check opens it.
  refreshGate(): void {
    const p = this.payload();
    const current = p.err ? null : JSON.stringify(p.body);
    if (this.previewedPayload === null || current === null || current !== this.previewedPayload)
      this.lockApproval();
  }

  // go('preview'), after the bot answered. sentBody is what was POSTed.
  setPreviewResult(sentBody: PayloadBody, findings: Finding[] | null | undefined, token: string | null): void {
    this.PREVIEW_FINDINGS = Array.isArray(findings) ? findings : [];
    this.previewToken = token;
    const b = Object.assign({}, sentBody);
    delete b.approved;
    this.previewedPayload = JSON.stringify(b);
    this.approvalDisabled = false;
  }

  setApproved(on: boolean): void { if (!this.approvalDisabled) this.approved = on; }

  // syncGenButton: approved, and nothing on the page the bot would refuse anyway.
  canGenerate(): boolean {
    if (this.approvalDisabled || !this.approved) return false;
    if (!this.LOADS.length || !this.LOADS.some(l => !l._excluded)) return false;
    return !this.blockingLoads().length;
  }

  // go('generate'): the body, with what proves THIS data was checked.
  generateBody(): PayloadResult {
    const p = this.payload();
    if (p.err || !p.body) return p;
    p.body.approved = this.approved;
    p.body.preview_token = this.previewToken;
    return p;
  }

  // After generate. id, tickets and list come from X-Filing-Id, X-Filing-Tickets, X-Filing-List.
  setGenerated(sentBody: PayloadBody, h: {id: string | null; tickets?: string | number | null; list?: string | null}): void {
    this.GENERATED = {id: h.id, ym: sentBody.year + '-' + String(sentBody.month).padStart(2, '0'),
                      invoice: sentBody.invoice_id, tickets: +(h.tickets || 0), list: filingList(h.list)};
  }

  // markFiled: the record is made off the saved row, against the list the person
  // was shown. filed_by_email and dry_run are the server function's to add.
  recordBody(): {err?: string; body?: {id: number; expect_tickets: string[]}} {
    const g = this.GENERATED;
    if (!g || !g.id)
      return {err: 'This page has no saved record of the report it generated. Generate it again, then record it.'};
    return {body: {id: +g.id, expect_tickets: g.list || []}};
  }

  // ---- The saved month (schema 2) ------------------------------------------

  savedFileBody(): SavedFile {
    const box = this.invoiceText;
    const out: SavedFile = {schema: SCHEMA_VERSION, loads: this.LOADS, fetch_findings: this.FETCHF};
    const listed = parseTickets(box) || [];
    const read = this.INVOICE_READ;
    const samePaper = read === null || listed.some(t => read.indexOf(t) !== -1);
    if (box.trim())
      out.invoice = {text: box, invoice_id: this.invoiceId,
                     source: samePaper ? this.INVOICE_SRC : null};
    return out;
  }

  // adoptSavedFile, without the re-read. When reread comes back non-null, POST
  // b64ToBytes(reread.source.b64) to the parse route, then call applySavedReread
  // with the answer, or rereadFailed if it could not run.
  adoptSavedFile(j: SavedFile | Load[]): {reread: SavedInvoice | null; differs: boolean; stale: boolean} {
    let stale = false, inv: SavedInvoice | null = null, differs = false;
    if (Array.isArray(j)) {
      this.restoreLoads(j); this.setFetchFindings([]);
      stale = true;
    } else if (j && Array.isArray(j.loads)) {
      const took = this.takeSavedInvoice(j.invoice);
      inv = took.inv; differs = !!took.differs;
      this.restoreLoads(j.loads);
      this.setFetchFindings(j.fetch_findings);
      stale = !(+(j.schema as number) >= SCHEMA_VERSION);
    } else {
      throw new Error('the file must contain a list of tickets, or {loads, fetch_findings}');
    }
    this.mergeDecals();
    this.mergeDates();
    this.FETCHF = this.FETCHF.filter(f => f.rule !== STALE_SAVE_RULE);
    if (stale)
      this.FETCHF = this.FETCHF.concat([{rule: STALE_SAVE_RULE, row_key: null,
        detail: 'this file was saved by an older build that did not keep ' +
                'what the system said about each truck, so a disagreement ' +
                'between the system and the invoice cannot be raised from ' +
                'it -- and that disagreement decides the gallons. Press ' +
                'Reload to pull the month from the system again, then drop ' +
                'the invoice.'}]);
    this.refreshAll();
    this.lastError = '';
    if (differs)
      this.invoiceStatus = {tone: 'warn', text: 'This month was saved with another invoice list. The invoice on the page ' +
        'stays. To use the saved one, empty the list in \u201cCorrect the ticket ' +
        'numbers by hand\u201d below, then load the month file again.'};
    const reread = (inv && inv.source && typeof inv.source.b64 === 'string') ? inv : null;
    return {reread, differs, stale};
  }

  takeSavedInvoice(inv?: SavedInvoice | null): {inv: SavedInvoice | null; differs?: boolean} {
    if (!inv || typeof inv.text !== 'string' || !inv.text.trim()) return {inv: null};
    const set = (t: string) => (parseTickets(t) || []).slice().sort().join('\n');
    if (this.invoiceText.trim())
      return {inv: null, differs: set(this.invoiceText) !== set(inv.text)};
    this.invoiceText = inv.text;
    this.invoiceId = String(inv.invoice_id || '');
    this.INVOICE_SETTLED = true;
    const s = inv.source;
    this.INVOICE_SRC = (s && typeof s.b64 === 'string') ? {name: String(s.name || 'the invoice'), b64: s.b64} : null;
    this.INVOICE_READ = null;
    return {inv: inv};
  }

  // rereadSavedInvoice, after the bot's parse of the saved bytes answered.
  applySavedReread(inv: SavedInvoice, p: InvoiceParse): boolean {
    const name = String((inv.source || {}).name || 'the invoice');
    if (this.invoiceText !== inv.text) return false;
    if (!this.applyInvoiceParse(p, name + ', saved with the month')) return false;
    this.invoiceText = inv.text;
    this.invoiceId = String(inv.invoice_id || '');
    const read = p.tickets || [];
    this.HAND_ADDED = {};
    (parseTickets(inv.text) || []).forEach(t => { if (read.indexOf(t) === -1) this.HAND_ADDED[t] = true; });
    this.INVOICE_READ = read.slice();
    this.applyInvoiceToLoads();
    this.refreshAll();
    const nt = (parseTickets(inv.text) || []).length;
    this.invoiceStatus = {tone: 'ok', text: name + ', from the saved month \u2014 read again: ' + nt +
                          ' ticket' + pl(nt) + ' on the invoice'};
    return true;
  }

  // The re-read could not run. The list and the pins stand.
  rereadFailed(inv: SavedInvoice): void {
    const name = String((inv.source || {}).name || 'the invoice');
    this.invoiceStatus = {tone: 'bad', text: 'Could not re-read ' + name + ' from the saved month.' +
      ' The list and your corrections stand; drop ' + name + ' again to check trucks and dates against it.'};
  }
}
