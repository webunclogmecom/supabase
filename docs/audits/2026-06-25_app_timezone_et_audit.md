# 2026-06-25 — App timezone (ET) display audit

**Question (Fred):** do all DB-consuming apps show times in **ET (America/New_York)**? DB may store UTC; apps must display ET.

**Method.** The failure mode to catch is an app formatting a `timestamptz` with the *browser's* local zone (bare `toLocaleString()`/`toLocaleTimeString()`/`toLocaleDateString()` with no `timeZone`), which renders the viewer's zone — and the audit Chrome's zone is **`Europe/Paris` (CEST, UTC+2)**, ~6 h off ET, so any leak is obvious. I checked, per app: (a) the DB views' time columns (raw `timestamptz` vs server-pre-formatted ET text), and (b) the app's own JS bundle for `America/New_York` / `timeZone:` usage vs **bare** browser-local date/time calls.

## Verdict — ✅ all apps display ET; no browser-zone leak found

| App | How times reach the user | Bundle grep | Verdict |
|---|---|---|---|
| **Field Portal** (fp.unclogme.app) | `customer.work_orders.visit_time` = `to_char(start_at AT TIME ZONE 'America/New_York', 'FMHH12:MI AM')` → **server-formatted ET text**; app does **0** client date formatting (renders text as-is) | NY 0, tz 0, **bare local 0** | ✅ ET |
| **DERM Tracker** (derm.unclogme.app) | `derm.*` views feed **date-only text** ("2026-03-05"); app does 0 client date formatting | NY 0, tz 0, **bare local 0** | ✅ dates (TZ-safe) |
| **Admin Review** (grease-buddy-dash) | Client-side formatting, **forces ET** | **NY 8, timeZone: 18, bare local 0** | ✅ ET |
| **Visit Calendar** (calendar.unclogme.app) | Gets raw UTC (`v_calendar_visit.start_at/end_at/completed_at`); bundle is TZ-aware (`America/New_York` + `timeZone:`); read view is **date-focused** (no time-of-day surfaced); the 3 bare `toLocaleString()` are number/`$` formatting (no bare *date/time* local calls) | NY 1, timeZone: present, **bare date/time local 0** | ✅ (see caveat) |

**Two safe patterns are in use, both correct:** server-side `AT TIME ZONE 'America/New_York'` → text in the view (FP, DERM), or client-side forced `America/New_York` (Admin Review, Calendar). No app uses bare browser-local date/time formatting.

## Caveats / follow-ups (not bugs today)
1. **Calendar editable drawer (pending Lovable work):** the new Start/End **time** fields read raw UTC `start_at`/`end_at` — they MUST display + edit in ET (force `America/New_York`). Folded into the drawer-edit Lovable prompt.
2. **DERM raw timestamps:** `derm.* created_at`/`updated_at` (UTC text) and `last_emailed_at`/`city_last_emailed_at` (raw `timestamptz`) are **not** ET-converted. They're internal today; if any is ever surfaced as a time, pre-format it to ET in the view (like `visit_time`) since DERM does no client-side conversion.
3. **Going forward:** keep to the two safe patterns; never add a bare `toLocaleString()`/`toLocaleTimeString()`/`toLocaleDateString()` on a `timestamptz` in app code — it renders the viewer's zone.
