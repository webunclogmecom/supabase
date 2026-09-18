# Draft for Fred to post in the Slack thread (#C0B15CHQ1D4, 2026-09-18)

Jonathan, the endpoint now returns gallons for the Broward-disposed tickets. Live since today on
`rpa-derm-monthly`, both `month=` and `unreported=1`:

**Rows.** On any ticket with `offload_in_dade: false`, every row carries `gallons` (integer, the client's
grease trap capacity from our DB, per Yan's "gallons per client") plus a new `gallons_source`
(`grease_trap_size` or `service_config_size`). White tickets keep `gallons: null` exactly as before, so
your invoice/decal path for Dade is untouched.

**Ticket head, new:** `dade_pickup_gallons: { total, rows, rows_missing, complete }` on every yellow
ticket (`null` on white). `total` is the sum over the rows with `pickup_in_dade: true`, `rows_missing`
is how many of those have no size on record, `complete` is `rows > 0 && rows_missing == 0`.

**What I need on your side, because of how `_flatten_ticket` reads gallons today:**
1. Stop returning `None` for `offload_in_dade: false`.
2. For those tickets take `dade_pickup_gallons.total` (or sum the `pickup_in_dade` rows yourself);
   the values differ per client, so the "exactly one distinct value" rule would report a conflict on
   most of them.
3. If `complete` is `false`, treat the ticket as unresolved. Please do not let it fall through to the
   decal constant (`C1184 -> 3800`, `C0976 -> 2000`): that is a Dade load figure and would be wrong on a
   Broward dump.
4. A row can still be `null` for now: it means we hold no trap size for that property yet. We are
   filling them in on our side (August: 7 rows across 4 tickets). Today only 310607 is complete for
   August; 310590 also has the Cloggy no-decal problem you already know.

**Two facts so the numbers do not surprise you:** the value is a trap capacity, not a measured volume
(the Broward receipt's "Waste Volume" is the whole load and is not in our DB), and the Dade "3,800 /
2,000" you file are the receipt's own "approximately" figures per decal, so neither side is a
measurement.

Your period question from the thread (offload month vs the invoice window) is still open; `month=`
selects by offload date, `unreported=1` gives you all 12 Broward tickets back to June. Tell me which
you want for the 20th. Full field reference: `postman/README.md` §4c.
