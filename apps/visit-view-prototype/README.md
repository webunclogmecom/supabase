# Visit View — Prototype

A dependency-free, single-page prototype of the **upcoming-visits view** Yannick
will rebuild in Lovable. Built to give the Lovable handoff three concrete
things:

1. **Design tokens** (`tokens.css`) — the visual contract.
2. **Layout primitives** (`styles.css`) — composition rules.
3. **Data shape + queries** (`app.js`) — exactly what to fetch from Supabase.

Edit one of those three; the rest stays the same.

## Running locally

It's static HTML — no build step.

```bash
cd apps/visit-view-prototype
python3 -m http.server 8000      # or `npx serve .`
# open http://localhost:8000
```

By default it renders **mock data** (~12 visits across the next 2 weeks) so
the design works without credentials.

## Pointing at real Supabase data

Drop a script tag before `<script src="app.js">` in `index.html`:

```html
<script>
  window.SUPABASE_URL  = 'https://wbasvhvvismukaqdnouk.supabase.co';
  window.SUPABASE_ANON = 'eyJhbGc...'; // public anon key, gated by RLS
</script>
```

`app.js` switches off MOCK and hits `/rest/v1/visits?...` with PostgREST
resource embedding to inline client info.

The query (see `fetchVisits()`):

```
GET /rest/v1/visits
  ?select=id,visit_date,visit_status,service_type,title,client_id,
          clients(client_code,name)
  &visit_status=eq.scheduled
  &visit_date=gte.{today}
  &order=visit_date.asc
  &limit=500
```

## Files

| File | Purpose |
|---|---|
| `tokens.css` | All visual constants — colors, spacing, typography, radii, shadows. Includes a dark-mode override hook. |
| `styles.css` | Layout + components, referencing tokens. No hard-coded values. |
| `index.html` | The view. Includes filters (search, service-type, group-by-day vs by-client) and a skeleton-loading state. |
| `app.js` | Fetch + render + grouping. Self-contained, no framework. |

## Design decisions

- **Tokens over hard-coded values** — Yannick (or a designer) can shift the
  palette by editing one file. Same pattern Anthropic uses in their own
  documentation site.
- **Service-type color accents** (GT amber, CL blue, WD purple, LS green) —
  fast visual triage in a long list. Yan asked for this in our 2026-04
  whiteboard.
- **By-day or by-client** grouping toggle — ops needs both views (driver
  routes group by day, account managers group by client).
- **No framework** — Lovable will rebuild this. We're giving it a complete
  visual + data spec, not a build to fork.

## What's intentionally out of scope

- Auth UI (Lovable owns auth flow)
- Edit-visit interactions (read-only prototype)
- Mobile route planning (separate app)
- Backend writes (Supabase cron owns visit generation)

## Next steps (for the production build in Lovable)

1. Pull the schema view `clients_due_service` instead of raw `visits` — it
   already computes `next_visit` per (client, service) via the Option D
   anchor chain, so the view stays current without re-querying.
2. Wire Yannick's auth so RLS scopes the query to the user's permissions.
3. Add the "snooze / reschedule" action (writes to `visits.visit_date`).
4. Add per-client drill-down: click client → see full visit history.
