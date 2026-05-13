# Data Spec — Upcoming Visits view

What Claude Code needs to know **after** the Claude Design handoff bundle
arrives. This file is the bridge between visual (Step 1-2) and full-stack
(Step 3) — keep it accurate.

---

## Source

**Supabase Prod project:** `wbasvhvvismukaqdnouk`
**REST base URL:** `https://wbasvhvvismukaqdnouk.supabase.co/rest/v1`
**Auth model in production:** Lovable user → Supabase JWT. RLS scopes the
SELECT to what the user is allowed to see.

For the prototype phase (before Lovable auth is wired), use the public
`anon` role with the existing RLS policies that allow read on `visits`,
`clients`, and `service_configs`.

---

## The query (PostgREST)

```http
GET /rest/v1/visits
  ?select=id,visit_date,visit_status,service_type,title,client_id,
          clients(client_code,name),
          properties(zone,address,city,state,zip,access_hours_start,access_hours_end)
  &visit_status=eq.scheduled
  &visit_date=gte.{today_iso_date}
  &order=visit_date.asc
  &limit=500

Headers:
  apikey: {SUPABASE_ANON_OR_JWT}
  Authorization: Bearer {SUPABASE_ANON_OR_JWT}
```

**Property embed note**: many visits have `property_id = NULL` even when the
client has a property. If you find the embed returns `properties: null` for
those, switch to a server-side view that COALESCEs the visit's `property_id`
with the client's `is_primary` property — `ops.v_visits_with_property` (we
have a helper view; if it's missing, ask Fred to add it). Quick client-side
fallback: if `visit.properties` is null, fire a second batched query for the
client's primary property and merge in. The zone shown on the visit row is
ALWAYS the property's zone, never the client's (clients don't have one).

`today_iso_date` is computed client-side as `YYYY-MM-DD` from the ET
calendar day (use `Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York' })`).
The cron writes visits in UTC but only the date matters here.

---

## Response shape

```ts
type Zone =
  | 'SOUTH' | 'DOWN' | 'MIAMI BEACH' | 'MID/EDG' | 'SF/BH'
  | 'AVE'   | 'NMB'  | 'BRO'         | 'PALM'    | 'WEST'
  | 'SUNNY';                            // legacy alias for AVE (3 rows; treat as AVE on read)

type Visit = {
  id:            number;          // primary key
  visit_date:    string;          // 'YYYY-MM-DD' (date, not timestamp)
  visit_status:  'scheduled' | 'completed' | 'cancelled';
  service_type:  'GT' | 'CL' | 'WD' | 'LS' | null;
  title:         string | null;   // e.g. "174-VIN Vincenzos - Scheduled GT"
  client_id:     number | null;
  clients: {
    client_code: string | null;   // e.g. "174-VIN"
    name:        string | null;   // e.g. "Vincenzo's Pizzeria"
  } | null;
  properties: {
    zone:                Zone | null;
    address:             string;
    city:                string;
    state:               string;
    zip:                 string;
    access_hours_start:  string | null;  // '09:00' (24h) or null = 24/7
    access_hours_end:    string | null;
  } | null;
};
```

### Zone palette (canonical, from `docs/research/unclogme-design-system.md`)

```ts
const ZONE_COLORS: Record<Zone, string> = {
  'SOUTH':       '#ef4444',  // red
  'DOWN':        '#3b82f6',  // blue
  'MIAMI BEACH': '#8b5cf6',  // purple
  'MID/EDG':     '#f59e0b',  // amber
  'SF/BH':       '#06b6d4',  // cyan
  'AVE':         '#f97316',  // orange
  'NMB':         '#eab308',  // yellow
  'BRO':         '#22c55e',  // green
  'PALM':        '#14b8a6',  // teal
  'WEST':        '#6366f1',  // indigo
  'SUNNY':       '#f97316',  // alias for AVE (3 legacy rows)
};

function zoneColor(zone: Zone | null | undefined): string {
  return zone ? ZONE_COLORS[zone] ?? '#9ca3af' : '#9ca3af';
}
```

---

## Grouping logic

The toggle in the UI controls how rows are bucketed:

### By day
```ts
key  = visit.visit_date
eyebrow = relativeDay(visit.visit_date)
            // 'Today' | 'Tomorrow' | 'In N days' | 'Nd ago' | ISO date
title = formatLong(visit.visit_date)
            // 'Wednesday, June 11, 2026'
```

### By client
```ts
key  = visit.clients?.client_code ?? visit.client_id.toString()
eyebrow = key                   // e.g. "174-VIN"
title = visit.clients?.name      // e.g. "Vincenzo's Pizzeria"
```

### By zone
```ts
key      = visit.properties?.zone ?? 'UNKNOWN'
eyebrow  = key                                       // e.g. "DOWN"
title    = `${key} · ${zoneAreaName(key)}`           // e.g. "DOWN · Brickell / Coral Gables"
accent   = zoneColor(visit.properties?.zone)         // hex for the section's accent line
```

Section header uses a 2px horizontal line in the zone color; the eyebrow
label is the zone color text. Group sort: by zone count descending (busiest
zone first), or alphabetical — pick whichever reads cleaner.

Sort visits within any group by `visit_date` ascending.

---

## Service-type labels (for the secondary text + badge)

```ts
const SERVICE_LABEL = {
  GT: 'Grease Trap',
  CL: 'Cleaning',
  WD: 'Water Discharge',
  LS: 'Lyft Station',
};
```

---

## Why "visits" and not a view?

There's a related view `ops.v_service_due` that computes "next due" per
`(client, service_type)`. **Don't use it here** — that view returns one
row per active subscription, not one row per scheduled visit. The list
we want is "rows already in `visits` with `visit_status='scheduled'` and
`visit_date >= today`," which is exactly what the cron generates.

---

## Refresh cadence

- **Cron writes:** daily at 04:30 ET (`.github/workflows/generate-recurring-visits.yml`)
- **Merge with Jobber:** when Diego creates a Jobber visit that matches a
  cron-generated one (same client + service + ±7d), `webhook-jobber.handleVisit`
  PROMOTES the row in place — `source` flips from `supabase_cron` to `jobber`.
- **UI consequence:** rows can swap `visit_status` from `scheduled` to
  `completed` between page loads. Live-subscribe via Supabase Realtime if you
  want it to update without refresh; otherwise a 60s poll is fine.

---

## RLS notes for Lovable auth

When wiring real auth (after the prototype phase):

1. The user's JWT is set on the Supabase client.
2. RLS policy on `visits` should already allow `SELECT` for any
   authenticated user with the `office_team` role (or however Yannick
   maps roles).
3. If the view ever needs to be **public** (no auth) for a kiosk-style
   ops dashboard, create a dedicated `app_upcoming_visits_public` view
   that strips PII and grant SELECT to `anon`.

---

## Known data quirks (so UI handles them gracefully)

- ~16 visits in 2026 have `service_type = NULL` — these are dump trips,
  one-off plumbing repairs, or inspections. **Hide them from this view**
  by filtering `service_type IN ('GT','CL','WD','LS')` in the query.
- Some clients have `client_code = NULL` (residentials). For those rows,
  fall back to `clients.name` in both the eyebrow and the row label.
- `title` can be null for cron-generated rows — fall back to
  `"{client_code or 'Client'} - Scheduled {service_type}"`.

---

## Acceptance criteria

The Step-3 wiring is done when:

- [ ] Hits Supabase Prod via the configured anon key (or Lovable JWT)
- [ ] Renders the 423 upcoming visits currently in Sbx
- [ ] Search filters by client name OR client_code OR title
- [ ] Service dropdown filters correctly
- [ ] Group-by toggle swaps between day and client views
- [ ] Skeleton state shows during fetch, empty state shows when filtered to zero
- [ ] Mobile layout (≤720px) collapses the right column below the middle
- [ ] Token-only theme toggle works (light/dark)
