// The recorded act sequences. Made-up tickets and clients only. Every act here is
// driven through the old page and through monthly-rules.ts by run-golden.mjs.

const fac = (name, address, extra) => Object.assign({name, address}, extra || {});
export const HARBOR = fac('Harbor Grill', '100 Harbor Ln, Miami, FL 33101');
export const BAYSIDE = fac('Bayside Cafe', '200 Bay Ave, Miami, FL 33102', {county: 'Miami-Dade', in_dade: true});
export const CORAL = fac('Coral Bistro', '300 Coral Rd, Miami, FL 33103');
export const SUNSET = fac('Sunset Taqueria', '400 Sunset Dr, Miami, FL 33104');
export const MARINA = fac('Marina Deli', '500 Marina Way, Miami, FL 33105');
export const DOCK = fac('Dockside Diner', '600 Dock St, Hollywood, FL 33020', {county: 'Broward', in_dade: false});
export const PIER = fac('Pier Oyster Bar', '700 Pier Pl, Miami, FL 33107');

export const row = (t, offload, f, extra) => Object.assign({ticket_number: t, pickup_date: '2026-09-06', offload_date: offload,
  gallons: null, decal: null, facilities: [Object.assign({}, f)], trucks: ['Truck A'], disposal_facility: 'South District WWTP'}, extra || {});
export const ooc = (t, offload, f, gallons, extra) => row(t, offload, f, Object.assign({out_of_county: true, gallons,
  disposal_facility: 'Water and Wastewater Services', gallons_sources: gallons == null ? [] : ['size_on_file'],
  sizes_missing_clients: gallons == null ? [f.name] : undefined}, extra || {}));

export const FEED = () => [
  row('900001', '2026-09-10', HARBOR),
  row('900002', '2026-09-11', BAYSIDE),
  row('900003', '2026-09-03', CORAL),
  row('900004', '2026-09-11', SUNSET),
  row('900005', '2026-09-10', MARINA, {pickup_date: '2026-09-07'}),
];
export const P1 = () => ({tickets: ['900001', '900002', '900004', '900005', '900100', '900101'], invoice_id: 'SP00099001',
  decals: {'900001': 'C1184', '900002': 'C0976', '900004': 'C0976', '900100': 'C1184'},
  service_dates: {'900001': '2026-09-07', '900002': '2026-09-11', '900004': '2026-09-11', '900005': '2026-09-08',
                  '900100': '2026-09-11', '900101': '2026-09-12'}});
export const P2 = () => Object.assign(P1(), {invoice_id: 'SP00099002',
  service_dates: Object.assign(P1().service_dates, {'900001': '2026-09-08', '900101': '2026-09-13'})});

const PICKED_TYPED = [fac('Harbor Grill', '100 Harbor Ln, Miami, FL 33101', {_src: 'picked'}),
                      fac('Nuevo Sitio', '9 B St, Miami, FL 33125', {_src: 'typed'})];

const open = (loads, more) => ({act: 'fetch', unreported: true, loads: loads || FEED(), fetch_findings: [], ...(more || {})});
const reload = (loads, more) => ({act: 'fetch', unreported: true, loads: loads || FEED(), fetch_findings: [], ...(more || {})});
const drop = (parse, name) => ({act: 'drop', parse, name: name || 'SP00099001.pdf'});
const tick = (ticket, on) => ({act: 'tick', ticket, on});
const decal = (ticket, d) => ({act: 'decal', ticket, decal: d});
const useDecal = ticket => ({act: 'useInvoiceDecal', ticket});
const useDate = ticket => ({act: 'useInvoiceDate', ticket});
const undoDate = ticket => ({act: 'undoInvoiceDate', ticket});
const addPaper = (num, offload, d, opts) => ({act: 'addPaper', num, offload, decal: d, opts});
const preview = (findings, token) => ({act: 'preview', findings: findings || [], token: token || 'tok-1'});
const saveFresh = () => ({act: 'saveAndFresh'});
const adopt = (parse, more) => ({act: 'adopt', parse, ...(more || {})});
const pf = (fn, ...args) => ({act: 'pf', fn, args});

// The month as a person works it (hand row guessed before the paper, then the acts).
const WORK = [
  open(),
  addPaper('900101', '2026-09-05', 'C1184', {pickup: '2026-09-04'}),
  drop(P1()),
  addPaper('900100', '2026-09-11', 'C1184', {pickup: '2026-09-09', clients: PICKED_TYPED}),
  tick('900101', false),
  useDate('900001'),
  decal('900002', 'C1184'),
  decal('900003', 'C0976'),
  decal('900004', 'C1184'),
  useDecal('900004'),
  useDate('900005'),
  undoDate('900005'),
];

export const SEQUENCES = [
  {name: 'plain invoice drop', ym: '2026-09', steps: [
    open(), drop(P1()), preview(), {act: 'approve', on: true}]},

  {name: 'number on the invoice with no ticket, added from the paper', ym: '2026-09', steps: [
    open(), drop(P1()),
    pf('pfQuery', '900100', 'harbor'), pf('pfPick', '900100', 0),
    pf('pfTypeOpen', '900100'), pf('pfTyped', '900100', 'Nuevo Sitio', ''), pf('pfTyped', '900100', 'Nuevo Sitio', '9 B St, Miami, FL 33125'),
    pf('pfPickup', '900100', '2026-09-09'),
    {act: 'addFromForm', ticket: '900100'},
    // No read date for this one: the form has nothing to prefill, so it is refused.
    {act: 'finished', text: 'SP-KEEP\n900001\n900222'},
    {act: 'addFromForm', ticket: '900222'},
    pf('pfOffload', '900222', '2026-09-10'),
    {act: 'setPaperDecal', ticket: '900222', value: 'C0976'},
    {act: 'addFromForm', ticket: '900222'},
    preview([{rule: 'manual_load_from_paper', row_key: '900222', detail: 'server words', expected: false}])]},

  {name: 'truck correction after the paper priced it', ym: '2026-09', steps: [
    open(), drop(P1()), decal('900002', 'C1184'), preview(), drop(P2(), 'b.pdf'),
    decal('900002', 'C0976'), decal('900002', 'C1184'), useDecal('900002'), decal('900002', 'bogus'), decal('900002', '')]},

  {name: 'truck guess before the paper', ym: '2026-09', steps: [
    open(), decal('900001', 'C0976'), decal('900003', 'C0976'), drop(P1()), reload(), drop(P1())]},

  {name: 'date correction and "use the invoice\'s date"', ym: '2026-09', steps: [
    open(), drop(P1()), useDate('900001'), undoDate('900001'), useDate('900001'), drop(P2(), 'b.pdf'),
    undoDate('900001'), useDate('900001'), undoDate('900001'), useDate('900003'),
    drop(Object.assign(P1(), {service_dates: {'900005': '2026-09-01'}}), 'c.pdf'), useDate('900005')]},

  {name: 'un-tick and re-tick', ym: '2026-09', steps: [
    open(), drop(P1()), tick('900001', false), tick('900003', true), {act: 'finished'}, tick('900001', true),
    tick('900001', false), {act: 'match'}, tick('900004', false), reload()]},

  {name: 'reload after work', ym: '2026-09', steps: [
    ...WORK, reload(), drop(P2(), 'b.pdf'), reload(), tick('900100', false), reload()]},

  {name: 'saved-file round trip', ym: '2026-09', steps: [
    ...WORK, saveFresh(), adopt(P1()), drop(P2(), 'b.pdf'), saveFresh(), adopt(P2()), reload()]},

  {name: 'out of county with and without a size', ym: '2026-09', steps: [
    open([row('900001', '2026-09-10', HARBOR), ooc('900201', '2026-09-08', DOCK, 65), ooc('900202', '2026-09-09', PIER, null),
          ooc('900203', '2026-09-09', DOCK, null, {sizes_missing_clients: []})],
         {fetch_findings: [{rule: 'out_of_county_ticket_on_report', row_key: '900201', detail: 'on it', expected: true},
                           {rule: 'out_of_county_sizes_missing', row_key: '900202', detail: 'Pier Oyster Bar has no size', expected: false},
                           {rule: 'out_of_county_total_mismatch', row_key: '900203', detail: 'two answers', expected: false}]}),
    drop(P1()), tick('900201', false), decal('900201', 'C1184'), useDate('900201'),
    reload([row('900001', '2026-09-10', HARBOR), ooc('900201', '2026-09-08', DOCK, 65), ooc('900202', '2026-09-09', PIER, 200)]),
    saveFresh(), adopt(P1()), tick('900202', false),
    reload([row('900001', '2026-09-10', HARBOR), ooc('900201', '2026-09-08', DOCK, null), ooc('900202', '2026-09-09', PIER, null)]),
    reload([row('900201', '2026-09-08', DOCK)])]},

  {name: 'archived ticket', ym: '2026-09', steps: [
    open(), drop(P1()),
    {act: 'archive', ticket: '900001', reason: 'test_data'},  // billed: refused before a click
    tick('900003', true), {act: 'archive', ticket: '900003', reason: 'test_data'},  // ticked: refused
    tick('900003', false), {act: 'archive', ticket: '900003', reason: 'duplicate', dup: 'x9000a'}, // no number
    {act: 'archive', ticket: '900003', reason: 'other', text: 'Not a real pickup of ours'},
    reload(), {act: 'finished', text: '900001\n900003'}, {act: 'restore', ticket: '900003'},
    {act: 'archive', ticket: '900004', reason: 'not_ours'}, {act: 'restore', ticket: '900004'},
    {act: 'archive', ticket: '900005', reason: 'duplicate', dup: '900001'}, saveFresh(), {act: 'loadArchive'}, adopt(P1())]},

  {name: 'empty invoice with typed numbers', ym: '2026-09', steps: [
    open(), {act: 'typing', text: '9000'}, {act: 'typing', text: '900001'}, {act: 'typing', text: '900001\n900002, 900002;900999'},
    {act: 'finished'}, {act: 'addNumber', raw: '123'}, {act: 'addNumber', raw: '900300', decal: 'C0976'},
    {act: 'addNumber', raw: '900001', decal: 'C1184'}, {act: 'setInvoiceId', value: ' SP00099777 '},
    addPaper('900999', '2026-09-12', '', {clients: [fac('Marina Deli', '500 Marina Way, Miami, FL 33105', {_src: 'picked'})]}),
    {act: 'removeNumber', num: '900999'}, {act: 'removeNumber', num: '900300'}, saveFresh(), adopt(null)]},

  {name: 'the system and the paper name different trucks', ym: '2026-09', steps: [
    open(FEED().map(l => l.ticket_number === '900001' ? Object.assign(l, {decal: 'C0976'}) : l)), drop(P1()), reload(FEED().map(l => l.ticket_number === '900001' ? Object.assign(l, {decal: 'C0976'}) : l)),
    decal('900001', 'C0976'), decal('900001', 'C1184'), drop({tickets: ['900002'], invoice_id: 'SP00099003'}, 'c.pdf'), saveFresh(), adopt(null)]},

  {name: 'edit a hand row', ym: '2026-09', steps: [
    open(), addPaper('900100', '2026-09-05', '', {}), drop(P1()), {act: 'openEdit', ticket: '900100'},
    pf('pfQuery', '900100', 'bay'), pf('pfPick', '900100', 0), pf('pfTyped', '900100', 'Nuevo Sitio', '9 B St'), pf('pfRemove', '900100', 0),
    pf('pfPickup', '900100', '2026-09-20'), pf('pfUseInvoiceDate', '900100'), {act: 'saveEdit'},
    {act: 'openEdit', ticket: '900100'}, pf('pfOffload', '900100', 'bad'), {act: 'saveEdit'}, {act: 'cancelEdit'},
    {act: 'openEdit', ticket: '900100'}, pf('pfOffload', '900100', '2026-09-30'), {act: 'saveEdit'},
    useDate('900100'), undoDate('900100'), {act: 'removeNumber', num: '900100'}, reload()]},

  {name: 'any change re-locks', ym: '2026-09', steps: [
    open([row('900001', '2026-09-10', HARBOR), row('900002', '2026-09-11', BAYSIDE)]), drop(P1()), preview([], 'tok-a'), {act: 'approve', on: true},
    tick('900001', false), {act: 'approve', on: true}, tick('900001', true), {act: 'approve', on: true},
    preview([], 'tok-b'), {act: 'approve', on: true}, {act: 'setInvoiceId', value: 'SP00099005'}, preview([], 'tok-c'),
    {act: 'approve', on: true}, {act: 'setMonth', ym: '2026-10'}, {act: 'setMonth', ym: 'nope'}, preview([], 'tok-d'), {act: 'approve', on: true},
    {act: 'generate', id: '41', tickets: '2', list: ['900001', '900002']}, {act: 'record', said: {dry_run: true, what: 'x'}},
    {act: 'record', said: {dry_run: false, state: 'already'}}, {act: 'record', said: {dry_run: false, state: 'recorded', what: 'x'}},
    {act: 'record', ok: false, raw: {detail: 'no', refused_by: 'tracker'}}]},

  {name: 'gallons missing panel', ym: '2026-09', steps: [
    open([row('900001', '2026-09-10', HARBOR), row('900005', '2026-09-10', MARINA), row('900003', '2026-09-03', CORAL)]),
    drop(P1()), {act: 'blockerDecal', ticket: '900005', value: 'C0976'}, preview(), {act: 'blockerDecal', ticket: '900005', value: ''},
    {act: 'blockerLeaveOff', ticket: '900005'}, {act: 'finished'}, tick('900003', true), {act: 'blockerLeaveOff', ticket: '900003'}, reload([row('900005', '2026-09-10', MARINA)])]},

  {name: 'a hand row the system now sends', ym: '2026-09', steps: [
    ...WORK, reload(FEED().concat([row('900100', '2026-09-11', HARBOR, {pickup_date: '2026-09-10', decal: 'C0976'})])), saveFresh(), adopt(P1()),
    tick('900100', false), reload(FEED().concat([row('900100', '2026-09-11', HARBOR, {pickup_date: '2026-09-10'})]))]},
  {name: 'a hand row the system sends as typed', ym: '2026-09', steps: [
    ...WORK, reload(FEED().concat([row('900100', '2026-09-11', HARBOR, {pickup_date: '2026-09-09', facilities: [fac('Harbor Grill', 'x'), fac('Nuevo Sitio', 'y')]})]))]},

  {name: 'saved files of every age', ym: '2026-09', steps: [
    ...WORK, {act: 'saveAndFresh', transform: 'noInvoice'}, adopt(null), reload(),
    {act: 'saveAndFresh', transform: 'schema1'}, adopt(null),
    {act: 'saveAndFresh', transform: 'bareList'}, adopt(null), drop(P1()),
    {act: 'saveAndFresh'}, adopt(P1(), {parseOk: false}), {act: 'saveAndFresh'}, adopt(P1()),
    {act: 'saveAndFresh', keepBox: '900001\n900002'}, adopt(P1()),
    {act: 'saveAndFresh', keepBox: 'SAME'}, adopt(P1()),
    {act: 'saveAndFresh', transform: 'noSource'}, adopt(null),
    {act: 'finished', text: '700001\n700002'}, {act: 'saveAndFresh'}, adopt(null)]},

  {name: 'report month shape', ym: '2026-08', steps: [
    open(), {act: 'finished', text: '900001\n900002\n900003'}, {act: 'setMonth', ym: '2026-09'}, tick('900003', false),
    {act: 'setMonth', ym: '2026-07'}, drop(P1()), {act: 'setMonth', ym: '2026-09'}]},

  {name: 'what the reader could not commit to', ym: '2026-09', steps: [
    open(), {act: 'drop', parse: {tickets: [], invoice_id: 'SP0', near_tickets: [{guess: '900001', as_read: '9OO001'}], other_sixdigit: ['444111'], outside_column: ['900720']}, name: 'scan.jpg'},
    {act: 'accept', num: '900001'}, {act: 'accept', num: '900720'},
    {act: 'drop', parse: Object.assign(P1(), {source: 'ocr', decals_inferred: ['900002'], near_tickets: [{guess: '900003', as_read: '9OO003'}],
       other_sixdigit: ['444111'], outside_column: ['900720'], parse_warnings: ['page 3 unread'], total_mismatch: 'Total 4,000.00 vs rows 3,600.00',
       decal_conflicts: [{detail: 'price and truck disagree', row_key: '900002'}, {detail: 'unreadable row', row_key: null}]}), name: 'scan2.jpg'},
    {act: 'accept', num: '900003'}, reload(), {act: 'drop', parse: {tickets: ['900001']}, name: 'noid.pdf'}]},

  {name: 'odd rows', ym: '2026-09', steps: [
    open([row('', '2026-09-10', HARBOR), row('9-24-26', '2026-09-24', DOCK, {feed_conflicts: ['the data system flagged a conflict on client X']}),
          row('900001', null, HARBOR, {facilities: []}), row('900002', '09/11/2026', {name: '', address: 'Only a street'}, {pickup_date: null}),
          row('', '2026-09-12', CORAL)],
         {fetch_findings: [{rule: 'client_without_address', row_key: '900001', detail: 'no address', expected: false},
                           {rule: 'data_quality_unchecked', row_key: null, detail: 'month note', expected: false},
                           {rule: 'out_of_county_other_month', row_key: '999999', detail: 'not on the list', expected: false},
                           {rule: 'operator_excluded_ticket', row_key: '900002', detail: 'a receipt', expected: false}]}),
    {act: 'tickAt', i: 0, on: true}, {act: 'decalAt', i: 0, decal: 'C1184'}, {act: 'tickAt', i: 4, on: true}, {act: 'tickAt', i: 1, on: true},
    drop(P1()), {act: 'archive', ticket: '9-24-26', reason: 'test_data'}, saveFresh(), adopt(P1())]},

  {name: 'a clean pull carries nothing', ym: '2026-09', steps: [
    ...WORK, {act: 'fetch', unreported: false, loads: FEED(), fetch_findings: []}, drop(P1()),
    {act: 'fetch', unreported: false, loads: [], fetch_findings: []}, reload()]},

  {name: 'a truck kept for a number with no row yet', ym: '2026-09', steps: [
    open(), {act: 'addNumber', raw: '900100', decal: 'C0976'}, reload(FEED().concat([row('900100', '2026-09-11', PIER)])), // guess, rides on
    {act: 'fetch', unreported: false, loads: FEED(), fetch_findings: []}, drop(P1()), {act: 'addNumber', raw: '900100', decal: 'C0976'},
    reload(FEED().concat([row('900100', '2026-09-11', PIER)])),                                                  // against the price: pinned
    {act: 'fetch', unreported: false, loads: FEED(), fetch_findings: []}, {act: 'addNumber', raw: '900100', decal: 'C0976'}, drop(P2(), 'b.pdf'),
    addPaper('900100', '2026-09-11', 'C0976', {}), {act: 'setNumberDecal', num: '900100', decal: 'C1184'}, {act: 'setNumberDecal', num: '900777', decal: 'bad'}]},

  {name: 'findings from the last check', ym: '2026-09', steps: [
    open(), drop(P1()),
    preview([{rule: 'ticket_not_on_invoice', row_key: '900003', detail: 'next package', expected: false},
             {rule: 'invoice_ticket_missing_from_report', row_key: '900100', detail: 'billed, not on it', expected: false},
             {rule: 'offload_vs_invoice', row_key: '900001', detail: 'server voice', expected: false},
             {rule: 'operator_excluded_ticket', row_key: '900003', detail: 'a receipt', expected: false},
             {rule: 'out_of_month', row_key: '900002', detail: 'expected one', expected: true},
             {rule: 'membership_unverified', row_key: null, detail: 'month', expected: false}]),
    tick('900003', true), preview([]), tick('900003', false)]},
];
