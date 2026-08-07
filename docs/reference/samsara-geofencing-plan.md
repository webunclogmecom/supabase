# Client geolocation + geofencing: the plan

*Design agreed 2026-08-07 across three sessions (Supabase 2 driving, @Supabase on the DB half,
@Building Apps on the app half). Companion to
[`samsara-integration-state.md`](samsara-integration-state.md), which is the measured survey this
rests on. **Nothing here is built yet.***

## The ask

Fred: *"what i'd like for now it's the Geolocation + Geofencing to be a two-way pattern with the
Clients App + Samsara, but who knows what else later."*

Decisions he made during the brainstorm:

| Question | Answer |
|---|---|
| What is it for? | **Manage sites from the Client App**, two-way to Samsara, same pattern as the Jobber job editor |
| What does the office edit? | **Pin + radius + the site metadata** — the Client App becomes the single place a site is described |
| The 117 polygons we never ingested? | **Re-ingest the real vertices first, then protect them** |
| Map imagery? | **Satellite, but read-only for now** — see the shape, verify it, don't build drawing yet |

"who knows what else later" ⇒ do not build a geofence-only carrier.

---

## 🛑 The thing that outranks everything: the grain problem

Found by @Building Apps, verified independently.

```
(client, address) groups:  391 have TWO property rows  ·  73 have one
of those 391:              391 are exactly one billing + one service   -- 391/391, no exceptions
properties overall:        421 service / 434 billing
```

**84% of client-address groups are a service/billing pair.** So "the office manages a site" is
ambiguous *before the first pixel is drawn*. If the office edits the pin on the **billing** row, the
**service** row is untouched — and the service row is what visits and GPS attribution hang off. The
result is a saved geofence that changes nothing operationally, reported with a success toast.

**⇒ A geofence belongs to the SERVICE property. A billing row is never a push target.**

⚠ **And the obvious discriminator does not work.** The link `source_id` has two namespaces (224 bare
numeric, 58 `addr_`-prefixed) and it is tempting to read the prefix as the role. Measured:

```
addr_ prefixed   58 -> 41 billing, 17 SERVICE
bare numeric    224 -> 33 BILLING, 191 service
```

**Wrong for 50 of 282 links**, and wrong in the dangerous direction for the 33 bare ids pointing at
billing rows. **The discriminator is `properties.is_billing`. The prefix records which script wrote
the row, not what the row means.**

**⇒ Resolve in the DB, not the app**, so Field Portal and Calendar cannot drift from whatever the
Client App decides.

---

## Phase 0 — Resolve the grain (DB, no behaviour change)

A single canonical answer to "which property row IS this site", exposed as one object every consumer
shares. Keyed on `is_billing`, never on the link id format. Handles the states that actually exist:

- a group with one property (73 groups) — that row is the site
- a group with a service/billing pair (391) — the service row is the site
- 🛑 **a real client whose `client_code` is NULL** — **318 properties, 37% of the table.**

> ⚠ **CORRECTION (2026-08-07).** An earlier version of this line said *"a site with no client at
> all"* and cited 2 properties. **That was false, and it was my error propagated from a bad query.**
> Measured across all 855: `client_id IS NULL` = **0**, dangling FK = **0**, real client with a NULL
> `client_code` = **318**. The two I named do have clients — prop 185 → client 262 "Richard Mahfood"
> (ACTIVE), prop 301 → client 155 "NOT USE bayshore plaza" (INACTIVE).
>
> The NULL came from `array_agg(distinct c.client_code)` over a LEFT JOIN, read as "the join failed".
> **A NULL in an aggregated joined column means that column is null, not that there was no match.**
> Check `c.id IS NULL` for join failure. (Caught by @Supabase, who wrote the original query and
> corrected it.)
>
> The distinction is load-bearing: anything that resolves, groups, logs or **displays** by
> `client_code` degrades for **37% of properties**, and a resolver treating a null code as "unlinked"
> would reject valid rows. This is a display and grouping problem, not a data-integrity one.

Nothing else changes in this phase. It is the foundation the other three stand on.

## Phase 1 — Canonicalise the link namespace (DB)

1. Migrate the 58 `addr_`-prefixed `source_id`s to bare numeric.
2. Add a CHECK that rejects the prefixed form, so the third namespace can never appear.
3. Uniqueness must be on the **normalised** id — @Building Apps ran a raw `group by source_id` first
   and got **zero collisions**, because the two formats mint different strings for the same object.
   A constraint on the raw value passes today and keeps admitting collisions forever.
4. **Adjudicate the 8 cross-client pairs by hand** (Fred/Yannick). Three are unrelated businesses
   sharing one Samsara address:
   ```
   016-FIA Fialkoff's      + 273-YMB Yes Market Miami Beach
   251-AS  Andrew Saka     + 125-EI  Esther Isaacov
   187-HAI Shalom Haifa    + 137-BB  Bagel Boss Aventura
   ```
   The other five are same-business variants (Nu Real Food / Coral Gables, Pura Vida Brickell / 701,
   Yan's 112 / 777) or have a null-code client.

⚠ **Do NOT blanket-dedupe the 29 same-client pairs.** They are the service/billing model, not
corruption; deleting either side removes a link the service row needs.

⚠ **An audit here must filter `entity_type`.** 205 normalised ids carry **both** a client link and a
property link, because the address webhook links both from one Samsara object. An unfiltered count is
measuring something else. (Mine filtered and missed the shape; @Building Apps' did not filter and
found it. Both were needed.)

## Phase 2 — Re-ingest the real shapes (DB + script)

The reason this must come first: **117 of 249 Samsara addresses are polygons and we hold none of
their vertices.** We discard them at ingest (`backfill_geo_from_samsara.js:94` and
`webhook-samsara/index.ts`) and keep only the word "polygon" plus a centroid. Verified live —
`091-SB Street Bar` returns 4 vertices at full precision.

1. **Enable PostGIS** — available **3.3.7**, `installed_version` NULL, one `CREATE EXTENSION` away.
   Chosen over jsonb (rule #3 forbids the denormalised array, so it fails the standing 3NF check) and
   over a child vertex table (needs an ordering column, and implicit ordering contracts already cost
   us the `ticket_page_images` page-order bug). A `geography` value is one atomic attribute.
2. Add `geofence_polygon geography(Polygon,4326)`, keep the circle columns for round-tripping, and a
   **CHECK making `type='polygon'` without a shape unrepresentable**. That is not theoretical:
   **128 rows say polygon and only 62 carry a radius, so 66 geofences cannot be reconstructed from
   our side at all.**
3. Backfill all 249 from `GET /addresses`, which also corrects the mirror drift — we say
   **128 polygon / 167 circle**, Samsara says **117 / 132**.
4. **Fix the two ingest paths that discard polygons**, or the next webhook silently undoes the
   backfill.

**This is the cheapest moment this will ever be** — but *"nothing computes with them"* was too strong
and is corrected here. Nothing **derives** from the geofence columns, and the app bundle does not
reference `geofence_type` or `radius_meters` at all. But `pg_stat_statements` (control: 262 of 4,932
statements mention `properties`) shows they **are read**:

```
UPDATE properties SET address, geofence_radius_meters ...              317 calls
UPDATE properties SET address, geofence_type ...                       109 calls
SELECT id, address, city, state, zip, geofence_radius_meters,
       latitude, longitude FROM properties
       WHERE client_id = $1 AND is_primary = $2                         41 calls, 2 rows/call
```

That 41-call query is parameterised on `client_id` + `is_primary` — an app or script shape, not an
ad-hoc survey. **Identify that caller BEFORE the re-ingest, not after**: if something displays
`geofence_radius_meters`, silently overwriting the 66 shapeless rows changes what a user sees. It is
the only `is_primary`-filtered geofence read in the list, so it is cheap to find. (Raised by
@Supabase running the stronger oracle after I settled for the catalogue version.)

⚠ **Rule #1 is not breached.** A polygon is our business fact about our site, the same class as
`properties.latitude`, which we already store unprefixed. `geofence_polygon` yes, `samsara_polygon` no.

## 🛑 The population the editor actually faces — and the open scope question

Sliced by `is_billing` × link state, which neither the survey nor my first plan did (@Building Apps):

```
SERVICE properties   421 total ->  208 linked (49.4%)  ·  213 NOT LINKED
BILLING properties   434 total ->   74 linked          ·  360 not linked (never push targets)

clients with >=1 unlinked SERVICE site:  209  (of 439 clients holding any property)
```

**Roughly half of clients hit "this site is not in Samsara" on their first visit to the feature.**
That is not a tail case, and v1 must not be designed against the other 49% and discover it later.

Of the 208 linked service rows: **102 circle · 95 polygon · 11 neither**. Polygons are **46% of
linked service sites** — half the work, not an edge case.

Two of my figures move under this slice:

- The **66 radius-less polygons** are **44 service + 22 billing**. Billing rows are never push
  targets, so the sites the office genuinely cannot see a shape for before the re-ingest is **44**.
- The "nothing to show at all" case (linked, no type, no radius) is **20**.

### ✅ DECIDED: v1 is edit **AND** create (Fred, 2026-08-07)

The office can create a Samsara address for a site that has none. That is a genuine write of a **new
object** into Samsara and needs its own verify-then-store, exactly like the edit path.

Two constraints on it, both measured:

**1. A duplicate check is mandatory.** **6 unlinked Samsara addresses already exist.** A create path
without an "is this already there?" check grows that number instead of shrinking it. Check by
coordinates and by name before creating, and offer to LINK rather than create when a candidate is found.

**2. 🛑 THE NAMING CONVENTION CANNOT BE APPLIED TO 55% OF THE SITES WE WOULD CREATE.**

193 of 249 existing Samsara addresses follow `NNN-XXX ClientName`, so there is a convention to
honour. But of the 213 unlinked service sites:

```
 95  client HAS a client_code   -> can be named conformingly
118  client_code is NULL        -> CANNOT be named conformingly
     by status: ACTIVE 182 (118 of them codeless) · RECURRING 30 (0 codeless) · PAUSED 1
     all 213 DO have lat/lng, so there is a coordinate to create from
```

Every RECURRING client already has a code. **All 118 codeless sites belong to ACTIVE clients.**

This is the `client_code`-is-NULL correction from Phase 0 arriving with teeth. Creating those 118
with a fallback name would **grow the 56 non-conforming names** — the precise problem the migration
exists to fix — and break every future join done by name.

**Recommendation: creating a Samsara address REQUIRES a `client_code`.** If the client has none, the
editor says so and refuses, surfacing a real data gap instead of papering over it. Per `CLAUDE.md`,
assigning a client code is a business decision (Yannick's SA-build list, or Fred), not something the
app should invent.

⚠ **This needs Fred's confirmation**, because the alternative — inventing a naming fallback — is a
product decision with a long tail, not an engineering one.

## Phase 3 — The editor (app + edge fn)

An **"Edit site" modal** on the existing property card — not a new tab. That card is already where a
site is described (access hours, access notes, lock box, manholes), and the job editor already solved
push → re-read-verify → store. Reusing it means one failure model, not two.

**Satellite imagery, read-only shapes, pin + radius editable** (Fred's choice). The office can see and
verify the 117 re-ingested shapes without us building a drawing tool yet.

Load-bearing rules:

- 🛑 **A polygon site's save must never carry a radius.** One careless round-trip flattens 117 real
  shapes into circles. **Enforced server-side in the resolver**, not only by disabling a control —
  the UI is not the last line. (@Building Apps: this is the single most damaging thing the feature
  could do, and it is the `frequency_days` trap wearing a different hat.)
- **Disable the radius control on a polygon site, do not hide it**, with the reason visible
  ("custom shape from Samsara"). Hiding it invites someone to re-add it later.
- 🛑 **A live Samsara read is a PRECONDITION of opening the editor**, not a recovery action. Our
  mirror has been frozen since **2026-07-23**; stored values are not evidence. Stamp "as of HH:MM".
  If the read fails, **open read-only** with "cannot reach Samsara". Editing from a 15-day-old pin is
  how you overwrite a correction someone made in Samsara last week. This is stricter than the job
  editor's `stale_view`, deliberately: a 30-minute lag is a lag, 15 days is an absence of evidence.
- **Define the ceiling for shapes we cannot represent.** Samsara allows polygons to 2048 vertices. If
  a shape exceeds what we can round-trip, **degrade to read-only — never simplify**.
- The UI must render **"this Samsara address is shared with another client"** and **"this client has
  no client_code"** (318 properties) as real states, not errors.
- 🛑 **BLOCK THE SAVE on a polygon site whose vertices are not yet re-ingested** (44 service sites).
  A pin-only editor over a site whose real shape we do not hold is exactly how 44 polygons become
  circles, and it would look like a successful save. **Two independent guards** — this block *and*
  the server-side no-radius rule — because the payload rule is one `if` away from being wrong.
  (@Building Apps.) The editor is otherwise **not gated on the backfill**: gating trades a small
  honest gap for a feature nobody can use.

**Four states the editor must handle**, of which only one is degraded:

| state | count | what the office sees |
|---|---|---|
| circle, linked | 102 | full editor — pin + radius |
| polygon with vertices (post re-ingest) | 95 | shape read-only, radius control **disabled** with the reason shown |
| polygon, vertices not re-ingested | 44 | pin only, "a custom shape exists in Samsara and is not loaded yet", **save blocked** |
| not linked to Samsara | 213 | "not in Samsara" — behaviour depends on the open scope question above |

**Map library:** Mapbox for satellite (mature polygon rendering). A JS SDK key is public by nature;
the control is **HTTP-referrer restriction on the vendor side, not secrecy**. There is **no CSP on the
app today** (no header, no meta tag), so CSP is not a constraint — but check before assuming it stays
that way.

## Phase 4 — Demote the inbound webhook to a reconciler

Keep it. Turning it off loses visibility of Samsara-UI edits; last-writer-wins recreates the
`frequency_days` trap pointing the other way. Copy the shape that exists twice already (the Gate #4
drift watchdog, and `save-client-job`'s 30-minute reconcile): **record divergence, surface it, let a
human resolve.**

---

## Explicitly NOT in this plan

**Arrival / departure detection.** Fred scoped this to geolocation + geofencing management. It is also
blocked by a defect worth recording here so nobody assumes it is a config toggle:

> The hooks registered at Samsara include `["AlertIncident","AlertObjectEvent"]`. `routeEvent`
> (`webhook-samsara/index.ts:437-440`) handles only `AlertTriggered` / `GeofenceEntry` /
> `GeofenceExit`, and **those two strings appear nowhere in `supabase/functions/`**. Every alert falls
> to `default:`, logs `status='skipped'`, returns 200. `integration.md:212` instructs registering
> `GeofenceEntry`/`GeofenceExit`, which **Samsara does not expose as subscribable types**.

That is why `is_gps_confirmed` / `actual_arrival_at` / `actual_departure_at` are **0/0/0 across 2,426
visits**.

⚠ **One question neither the DB nor the vendor AI can answer:** whether any alert rule exists in the
Samsara dashboard. "No rules configured" and "rules fire and are dropped" both produce zero rows. It
is a click in Settings → Alerts, and it decides whether this is a five-line router fix or a
configuration job.

---

## Method notes worth keeping

- **The vendor AI sees only Samsara's half.** Its org numbers were exact (249 / 193 / 0 externalIds /
  0 tags, all matched an independent API pull), but it told us there was *"no structured join back to
  your DB"* — we hold 498 links — and guessed no webhooks were wired when five are registered and
  delivering. Useful on their data model, unreliable on ours.
- **@Building Apps' first bundle scan walked 3 chunks and its `latitude` control did not fire.** It
  would have produced a confident "no map library". Seed a bundle scan from a real route and make a
  control fire before believing a zero.
- **`is_billing` is now load-bearing for a PUSH**, which is heavier duty than it has carried before.
  It has **no NOT NULL constraint** — it happens to be non-null on all 855 rows, which is luck rather
  than a guarantee. A future NULL insert leaves the resolver with no service row, and the editor then
  either blocks everything or silently falls back. **Add the constraint in the same migration as the
  normalised uniqueness**, so the UI can treat "exactly one service row" as an invariant rather than
  a hope. (@Building Apps.)
- **Four sessions-worth of wrong conclusions, every one caught by another, and NOT ONE was a bad
  number:**
  - mine: "37 duplicate links" — canonicalisation, not corruption
  - mine: "a site with no client at all" — 0 such rows; it is 318 with a null `client_code`
  - @Supabase's: a namespace-based resolver — wrong 50 of 282, and already wrong inside the 16-row
    sample it was generalised from
  - @Supabase's: "nothing computes with them" — nothing *derives*, but they are read 400+ times
  - the `entity_type` filter that hid the three-way link — my query filtered and missed the shape,
    theirs did not filter and found it
  **The errors were all in the sentence wrapped around the number.** Instrument the inference.
