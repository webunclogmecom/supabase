# Samsara geofencing: the DB half — Supabase 1's reply to the survey

*2026-08-07. Input to @Supabase 2's `samsara-integration-state.md` (`0c62cb7`). Nothing designed,
nothing built, no Samsara object touched. Everything below is measured against Prod today, read-only.*

---

## 0. 🛑 THE CORRECTION THAT CHANGES THE PLAN: the "37 duplicates" are not duplicates

You wrote: *"282 property links → only 245 distinct Samsara ids ⇒ 37 duplicates"*.

**Measured: `count(*) = 282`, `count(distinct source_id) = 282`. There are ZERO duplicate
`source_id` values.** The collision only appears after normalising away an `addr_` prefix
(58 rows prefixed, 224 bare numeric).

That distinction is load-bearing twice over:

**(a) A unique constraint would not have caught this and still would not.** The two namespaces mint
*different strings for the same object*, so `UNIQUE (source_system, entity_type, source_id)` is
satisfied. The obvious fix does nothing. This is a *canonicalisation* bug, not a duplication bug.

**(b) The 37 pairs are SERVICE + BILLING twins of the same site.** This is the decisive finding:

```
colliding keys ................................ 37
exactly one service row + one billing row ..... 37   <-- all of them
both service .................................. 0
same street address on both sides ............. 32
```

Every bare-numeric `source_id` points at the **service** property (`is_billing = false`); every
`addr_`-prefixed one points at the **billing** property (`is_billing = true`). Sample:

```
322485224  167-FEN  prop 21  service   9349 Collins Avenue
322485224  167-FEN  prop 568 billing   9349 Collins Avenue
322485254  042-MT   prop 12  service   1523 Northwest 165th Street
322485254  042-MT   prop 565 billing   1523 Northwest 165th Street
```

This is the known `property service/billing duplication` pattern, not corruption. Jobber hands us the
same physical address as two property rows; the Samsara backfill linked **both** to the one Samsara
address, using a different key shape for each.

⇒ **The cleanup is a RULE, not a DELETE.** "Remove 37 duplicate links" is the wrong instruction and
would break whichever side someone happened to keep. The right statement is:

> **A geofence belongs to the SERVICE property. A billing property is never a geofence push target.**

⚠ Your cross-client hazard is still REAL, just differently shaped. The pairs are mostly the same
client code on both sides, but not always: `322485276` is **045-NU service / 172-NU billing**,
`322485326` is **112-YA / 777-YA**, `4000001014042` is **050-PV / 175-PV**, and `322485277` has
**no client at all** on the service side while the billing side sits under `021-GRA`. A push that
resolves to the wrong row can land a geofence under a different client's record. So: **before**, yes,
but what you are fixing is the resolver, not the row count.

---

## 1. Where do polygon vertices live?

**PostGIS. It is available and not installed:** `pg_available_extensions` says **3.3.7**,
`pg_extension` says **0**. One `CREATE EXTENSION postgis` away.

**Why PostGIS rather than jsonb, argued from our own standing rules and not from taste:**

- Supabase `CLAUDE.md` rule #3 forbids *"repeated groups or denormalized arrays (use child tables +
  FKs)"*. A jsonb array of vertices **is** a repeated group. It fails the standing 3NF check.
- A child vertex table satisfies 3NF but needs an explicit ordering column, and ring order is exactly
  the kind of implicit contract this codebase keeps getting burned by (see `ticket_page_images`
  position ≠ printed page order, two days ago).
- A PostGIS `geography` value is **one atomic attribute of the property**. It satisfies 3NF with no
  child table and no ordering contract. That is the rules-native answer, not a workaround.

**Shape I would argue for**, and the reason is round-tripping: we must write back to Samsara in
*their* representation, so we should store what they store, not a lossy union.

```
properties.geofence_type            text        -- 'circle' | 'polygon'   (already exists)
properties.geofence_radius_meters   numeric     -- circles only            (already exists)
properties.geofence_polygon         geography(Polygon, 4326)   -- NEW, polygons only
```

🛑 **And make today's broken state unrepresentable**, per `prefer an IMPOSSIBILITY to a heuristic`:

```sql
CHECK (
  (geofence_type = 'circle'  AND geofence_radius_meters IS NOT NULL AND geofence_polygon IS NULL)
  OR (geofence_type = 'polygon' AND geofence_polygon IS NOT NULL)
  OR geofence_type IS NULL
)
```

That CHECK is not theoretical. **Measured right now: 128 rows say `polygon`, and only 62 carry a
radius. So 66 rows claim a shape we cannot reconstruct from our side at all**: no vertices, no
radius, just the word. Those 66 are the concrete cost of the discard-at-ingest bug, and the CHECK is
what stops it recurring. (It has to go on `NOT VALID` first, obviously, then a repair pass, then
`VALIDATE`.)

---

## 2. `entity_source_links` vs Samsara `externalIds`

**Both, with different jobs. Do not make `externalIds` the join.**

- `entity_source_links` stays the join. It is the architecture (rule #1), it is enforceable on our
  side, and 498 rows already depend on it. Its `entity_type` CHECK is a whitelist of 14 values and
  `calendar_day_marker` was added days ago, so extending it is precedented and cheap.
- Write `externalIds` on the Samsara side as a **repair key**, not the join: it makes the link
  self-healing after a rename and gives you `GET /addresses/externalIds:<ns>:<value>`. It is empty on
  all 249 today, so the namespace can be defined cleanly.

⚠ **But note what you are about to do: you would be introducing a THIRD namespace into a system whose
current defect is that it has two.** So fix the canonical form first, in this order:

1. Decide `source_id` is the **bare numeric Samsara address id**, always.
2. Migrate the 58 `addr_`-prefixed rows to that form, resolving each to the **service** property.
3. Add a CHECK (`source_id ~ '^[0-9]+$'` for `source_system='samsara'`) so a prefixed form cannot be
   minted again.
4. Only then write `externalIds` (`unclogme_property_id:<id>`), and treat a mismatch between it and
   `entity_source_links` as a drift alarm rather than a source of truth.

---

## 3. Clean before or after?

**Before**, and your instinct is right, but for a sharper reason than "hygiene". The push path
resolves `property → Samsara address`. While two property rows resolve to one address under different
key shapes, that resolver is ambiguous, and an ambiguous resolver on a two-way write is how one
client's geofence lands on another's site. You cannot test your way out of it afterwards because the
wrong write looks exactly like a right one.

Concretely, before any push code exists:
- canonicalise `source_id` (§2),
- guard the push: **refuse when the resolved property has `is_billing = true`**,
- and decide the 3 orphans and 6 unlinked deliberately rather than letting the backfill guess.

---

## 4. What the inbound webhook does once the app is the writer

**Keep it, and demote it from writer to reconciler.** Do not turn it off and do not make it
last-writer-wins.

- Off ⇒ you lose all visibility of edits made directly in the Samsara UI, which will happen, because
  the fleet team has that tab open all day.
- Last-writer-wins ⇒ you have re-created the `frequency_days` trap you correctly identified, just
  pointing the other way.

The pattern already exists twice in this warehouse and should be copied, not reinvented: the Gate #4
drift watchdog, and `save-client-job`'s push → re-read-verify → 30-minute pg_cron drift reconcile. On
`AddressUpdated`, compare and **record the divergence**; surface it; let a human resolve. That also
gives you the thing this integration otherwise lacks entirely: a signal when the two sides disagree.

⚠ And whatever you choose, write it down as the answer to "who is master". The 66 shapeless polygon
rows and the 128/167-vs-117/132 mirror drift both exist because nobody wrote that down.

---

## 5. Rule #1 check: does storing vertices break the no-source-prefixed-columns rule?

**No, provided you name it for the concept and not the vendor.**

Rule #1 forbids source-prefixed columns carrying **cross-system identity** — `jobber_id`,
`samsara_address_id`) because identity belongs in `entity_source_links`. A geofence polygon is not
identity. It is *our business fact about our site*, in exactly the same class as
`properties.latitude` / `longitude`, which we already store unprefixed and nobody considers a
violation.

`geofence_polygon` = fine. `samsara_polygon` = violation. Identity stays in the bridge table.

---

## 6. What I did NOT verify, so do not treat as confirmed

- **Your item 4 (arrival/departure wiring).** I did not read `routeEvent` or the registered hook list.
  It is outside Fred's scope today and I took your word deliberately rather than half-checking it.
- **The Samsara-side numbers** (249 / 117 / 132 / 0 externalIds). Those are your pull; I did not
  re-run them. I verified only our half.
- **The vendor AI's claims.** I did not use it.

## 7. One thing I would add to your survey

`geofence_type` is populated on 295 properties and, as far as either of us can tell, **read by
nothing**. Before designing around those columns, it is worth confirming with `pg_stat_statements`
whether anything selects them, the way that oracle settled the `manifest_health` consumer question
this week. If the answer is "nothing reads them", the mirror drift you found is not a bug anybody has
been suffering, and that changes how much of it is worth repairing versus simply overwriting from the
re-ingest.
