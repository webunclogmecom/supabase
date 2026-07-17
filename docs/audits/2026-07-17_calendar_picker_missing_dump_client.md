# Calendar "New Visit" client picker: 000-DH missing (Diego blocked) + full audit

**2026-07-17.** Diego: *"estoy tratando de crear un dump para hoy en el Calendar App y no me sale
el cliente 000-DH, solo el cliente 000-DP."* (Can't create today's dump; 000-DH Homestead Dump does
not appear in the New Visit client search; only 000-DP DUMP Pompano does.)

## Root cause
The Calendar "New Visit" client picker reads **`ops.client_service_options`**, which is **job-driven**:
it lists a client only if it has a **non-archived job** whose title is `ILIKE 'Service Agreement%'`
**or** exactly `'service call'`, and not `[OLD]`. It never looks at the client name.

- **000-DP shows:** its live job (Jobber #148825624 / 99900908) is titled **"Service Call"**.
- **000-DH hidden:** its only live job (Jobber #149257415 / 99900969, `action_required`) had a
  **NULL title**, matching neither pattern. All its other dump jobs are archived `[OLD]`. So even
  though "Homestead **Dump**" contains "dump", the picker filtered it out upstream on the job title.

Both dumps are meant to be "Service Call" jobs (the "dumps are Service Calls" model, commit `8ca2273`).
000-DH's just never got its title set.

## Fix applied (Fred approved: unblock 000-DH now, Jobber + DB, "just 000-DH for now")
Set the job title to **"Service Call"** on 000-DH's job in BOTH places:
1. **DB** `public.jobs` id 1720 (`sql-000DH-dump-title`) — instant, so 000-DH appears in the picker
   immediately. (Only trigger on `jobs` is `updated_at`; no outbound push.)
2. **Jobber** job `gid://Jobber/Job/149257415` via `jobEdit(input:{title:"Service Call"})` — durable,
   so the next job-sync webhook keeps "Service Call" instead of reverting the DB title to NULL
   (the job is Jobber-mastered).

Verified: `ops.client_service_options` now lists 000-DH as SC "Service Call" (alongside 000-DP); DB and
Jobber titles both "Service Call".

⚠ Process note (my error, corrected): I first ran `jobEdit` on the WRONG GID (148825624 = 000-DP),
which was a **no-op** (000-DP was already "Service Call", no damage), because I mis-ordered the two
entity_source_links rows. Re-verified the GID→client mapping from `entity_source_links` and re-applied
to the correct job (149257415 = 000-DH). Lesson: decode the GID and confirm client_code before a
Jobber write, never trust row order.

## Full audit — 5 more clients are also invisible in the Calendar picker (DEFERRED per Fred)
`ops.client_service_options` has 428 rows / 249 clients. Missing ACTIVE/RECURRING coded clients:

- **4 real, recently-added clients with NO non-archived job at all** (so unschedulable): **235-LOU**
  (Skinny Louie West Palm Beach), **246-LOUI** (Skinny Louie Little Havana), **247-EC** (Excelsior
  Condo), **247-LOU** (Skinny Louie Coral Gables). Different root cause than 000-DH: onboarded as
  clients but never given a Jobber SA/SC job. Needs Yan/Fred to decide recurring vs on-demand + create
  the Jobber jobs.
- **777-YA** (Yan's Restaurant) — test client, correctly excluded (SA-gen exclusion list). Not a gap.

## Structural footgun (DEFERRED per Fred)
A client silently disappears from Calendar scheduling the moment its only live job has a NULL/odd
title, with no signal anywhere. That is exactly how Diego got stuck with no clue why. A future
hardening (surface ACTIVE clients whose only live job is unschedulable as a "needs a job" state,
rather than dropping them) would prevent the next occurrence; it is a `client_service_options` view
change plus a Calendar app change. Fred chose "just 000-DH for now" — left as a documented follow-up.
