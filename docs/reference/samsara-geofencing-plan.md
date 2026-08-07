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
- **a site with no client at all** — 2 of the 8 cross-client pairs have a null client on the service
  side, one literally named *"NOT USE bayshore plaza"*. This is a real state, not an error.

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

**This is the cheapest moment this will ever be.** The geofence columns are read by exactly two
pass-through views (`client.properties`, `ops.properties`) and **nothing computes with them** — the
app bundle does not reference `geofence_type` or `radius_meters` at all. The drift has cost nobody
anything yet, so it can be overwritten rather than reconciled.

⚠ **Rule #1 is not breached.** A polygon is our business fact about our site, the same class as
`properties.latitude`, which we already store unprefixed. `geofence_polygon` yes, `samsara_polygon` no.

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
- The UI must render **"this Samsara address is shared with another client"** and **"this site has no
  client"** as real states, not errors.

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
- **Three sessions produced three different wrong things**, each caught by another: my "37 duplicate
  links" (canonicalisation, not corruption), @Supabase's namespace-based resolver (wrong 50 times),
  and the entity_type filter that hid the three-way link. None of these were bad measurements — every
  number was right. The errors were all in the sentence wrapped around the number.
