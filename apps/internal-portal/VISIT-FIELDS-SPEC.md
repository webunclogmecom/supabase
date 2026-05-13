# Visit fields spec — what to show, what to skip

Paste this whole document into your Claude Design chat as a follow-up
message. It tells the design model exactly what fields exist on a visit,
which are populated when, and what *not* to invent.

---

## The data shape (TypeScript)

```ts
type Visit = {
  // ── Always present ─────────────────────────────────────────────
  id:           number;          // internal numeric ID, e.g. 4001
  visit_date:   string;          // 'YYYY-MM-DD' — just the calendar date
  visit_status: 'scheduled' | 'completed' | 'cancelled';
  service_type: 'GT' | 'CL' | 'WD' | 'LS' | null;
  title:        string | null;   // e.g. "174-VIN Vincenzo's - Scheduled GT"
  source:       'jobber' | 'supabase_cron' | 'manual';

  // ── Embedded client info (always present if client_id is set) ──
  clients: {
    client_code: string | null;  // e.g. "174-VIN" (residential clients = null)
    name:        string | null;  // e.g. "Vincenzo's Pizzeria"
    status:      'ACTIVE' | 'RECURRING' | 'PAUSED' | 'INACTIVE';
  } | null;

  // ── Embedded property info (the service address) ───────────────
  properties: {
    address:           string;    // "1636 Meridian Avenue"
    city:              string;    // "Miami Beach"
    state:             string;    // "FL"
    zip:               string;    // "33139"
    access_hours_start: string | null;  // "09:00"  (24h, null = 24/7)
    access_hours_end:   string | null;  // "17:00"  (null = 24/7)
    access_days:       string[] | null;  // ['mon','tue','wed','thu','fri']
  } | null;

  // ── Set ONLY when visit_status='completed' ─────────────────────
  start_at:     string | null;   // ISO timestamp UTC — when truck arrived
  completed_at: string | null;   // ISO timestamp UTC — when done
  vehicles: {                    // the truck (NOT a person)
    name: 'Moises' | 'David' | 'Cloggy' | 'Goliath';
  } | null;

  // ── Set ONLY when an invoice has been generated ────────────────
  invoices: {
    id:             number;
    invoice_number: string;
    total:          number;       // dollars
    invoice_status: 'paid' | 'past_due' | 'awaiting_payment' | 'draft';
  } | null;
};
```

---

## What to render in the visit-detail panel

### For a SCHEDULED visit (the common case in upcoming view)

```
[service-type badge]  [status pill: "scheduled"]   #{id}

{clients.name}                         ← big, primary
{clients.client_code} · {service-name} ← muted secondary

WHEN
{visit_date — formatted long}          ← e.g. "Thursday, June 11, 2026"
Access window: {access_hours_start}–{access_hours_end} ← or "24/7" if null
Allowed days: {access_days joined}      ← only if not all 7 days

SERVICE ADDRESS
{properties.address}
{properties.city}, {properties.state} {properties.zip}
[Open in Maps ↗]                        ← deep-link to Google Maps

NOTES
{title}                                 ← the title field

SOURCE
{source}                                ← small muted tag
```

### For a COMPLETED visit (the same panel, more fields populated)

```
… everything above PLUS:

WHEN
{start_at — local time}  →  {completed_at — local time}
Duration: {completed_at - start_at}

TRUCK
{vehicles.name}                         ← "Moises" or "David" etc.
                                         (these are TRUCKS, not people!)

INVOICE
#{invoices.invoice_number}  ${invoices.total}  [{invoices.invoice_status}]
```

---

## What NOT to render (and why)

| Don't show | Why |
|---|---|
| Work order numbers / `WO-NNNNN` | We don't have that concept. Use `visits.id`. |
| Specific start time on **scheduled** visits | Scheduled visits have NO time of day — only the date. Show the property's *access window* instead (when the truck is allowed to arrive). |
| "Site Contact" with a person's name + phone | We track contacts at the **client** level, not per-visit. If you must show a contact, embed `client_contacts` (one row per client with role='primary'). |
| "Technician" with a person's name | We attribute the **truck** (Moises/David/Cloggy), never an individual technician. Driver-attribution at the person level was dropped in 2026-04-30. |
| "Dispatch Note" as if it's a per-visit field | No such field. The closest signal is `visits.title` (e.g. "Scheduled GT") or `service_configs.schedule_notes` (per-subscription, e.g. "Yan said only ring the bell"). |
| Made-up addresses, phone numbers, names | If you need placeholder data, see the realistic samples below. |

---

## Realistic mock data — use these instead of inventing names

```json
[
  {
    "id": 4001,
    "visit_date": "2026-06-11",
    "visit_status": "scheduled",
    "service_type": "GT",
    "title": "043-MIL Mila - Scheduled GT",
    "source": "supabase_cron",
    "clients":   { "client_code": "043-MIL", "name": "Mila", "status": "RECURRING" },
    "properties":{ "address": "1636 Meridian Avenue", "city": "Miami Beach", "state": "FL", "zip": "33139",
                   "access_hours_start": "10:00", "access_hours_end": "17:00", "access_days": null }
  },
  {
    "id": 4002,
    "visit_date": "2026-06-11",
    "visit_status": "scheduled",
    "service_type": "CL",
    "title": "057-BAY Bayshore Executive Plaza - Lyft station cleaning",
    "source": "supabase_cron",
    "clients":   { "client_code": "057-BAY", "name": "Bayshore Executive Plaza", "status": "ACTIVE" },
    "properties":{ "address": "1750 North Bayshore Drive", "city": "Miami", "state": "FL", "zip": "33132",
                   "access_hours_start": null, "access_hours_end": null, "access_days": null }
  },
  {
    "id": 1452,
    "visit_date": "2026-03-05",
    "visit_status": "completed",
    "service_type": "GT",
    "title": "174-VIN Vincenzo's Pizzeria - Scheduled GT",
    "source": "jobber",
    "clients":    { "client_code": "174-VIN", "name": "Vincenzo's Pizzeria", "status": "RECURRING" },
    "properties": { "address": "8888 Collins Avenue", "city": "Surfside", "state": "FL", "zip": "33154",
                    "access_hours_start": "00:00", "access_hours_end": "00:00", "access_days": null },
    "start_at":     "2026-03-05T03:30:00Z",
    "completed_at": "2026-03-05T05:15:00Z",
    "vehicles":     { "name": "Moises" },
    "invoices":     { "id": 1567, "invoice_number": "2267", "total": 399.00, "invoice_status": "paid" }
  }
]
```

---

## Service-type labels (already in the prompt, repeating here)

| Code | Full label |
|---|---|
| `GT` | Grease Trap |
| `CL` | Cleaning |
| `WD` | Water Discharge |
| `LS` | Lyft Station |

---

## One-line follow-up to Claude Design

After you paste this whole doc, add:

> "Refactor the visit-detail panel to use ONLY the fields in this spec. Drop work-order numbers, specific times for scheduled visits, site contacts, technician names, and dispatch notes — none of those exist in our schema. Use the realistic mock data above to repopulate the example state."
