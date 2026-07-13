# Line-Item Propagation (082-TFC + systemic) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the GDO line item Diego added in Jobber (job #99900714 / 082-TFC) reflect on all future visits + the customer work order, and fix the underlying class so every SA/SC completion carries frozen visit services.

**Architecture:** Three coordinated DB-side changes, lowest-blast-radius first: (A) reconcile job 1472's job-scoped `line_items` to Jobber truth so the Calendar inherits the corrected set; (B1) add a job-scoped fallback to `customer.work_orders.services` so completed visits with no visit-scoped rows still show services; (B2) an `AFTER UPDATE` trigger that freezes the effective line set onto a visit at completion (SA = snapshot the job template; SC = keep the visit's own lines). No writes go through `edit_calendar_visit` (avoids Jobber push-back). Direct `line_items`/view/trigger writes only.

**Tech Stack:** Postgres (Supabase Prod `wbasvhvvismukaqdnouk`) via Management API; Node sync script `reconcile_jobs.js`; Jobber GraphQL (read scope). No app/Lovable changes.

**Spec:** [`../reference/line-item-lifecycle-and-jobber-edit-ripple.md`](../reference/line-item-lifecycle-and-jobber-edit-ripple.md)

**Two refinements discovered during planning (supersede the spec's §5; Task D reconciles the spec):**
1. **No inline DERM re-derivation in B2.** `fn_visit_requires_derm` already unions **job** scope, so DERM is already correct for these visits without visit-scoped rows; the nightly `derm-required-rederive` pg_cron is the monotonic backstop. Calling `set_visit_derm_required` inside a `visits` trigger would issue a nested `visits` UPDATE (cascade risk). So B2 is a **pure `line_items` snapshot insert** — no `visits` write, no cascade.
2. **No retroactive backfill of the 22 old blanks.** B1's fallback already shows their services (display), and stamping the *current* job template onto an *old* visit would fabricate a wrong "snapshot" (e.g. 6215 predates the GDO add). So: B1 covers old blanks' display; B2 captures **true** snapshots for future completions only.

---

## Ground truth (verified live 2026-07-13)

- Client 082-TFC = `clients.id=31` (RECURRING/SA). SA job = `jobs.id=1472`, `job_number='99900714'`, gid `gid://Jobber/Job/148742630`, `frequency_days=30`, `job_status='requires_invoicing'`.
- **Jobber** job 1472 line items (read scope, L1): `01 - …Pumping…` $300, **`27 - GDO Online Reporting` $35 (Diego's add, non-pumping)**, `25 - Credit card fee (3.53%)` **$11.83**. Total **$346.83**.
- **DB** job 1472 job-scoped `line_items` are STALE: only 2 rows (`72964` 01-Pumping $300, `72963` 25-CC fee **$10.59**) — no GDO, old fee. (Root cause: jobs poll uses a `createdAt` cursor; the 6h `reconcile_jobs.js` closes it but hasn't re-pulled since Diego's edit.)
- 6 future scheduled 082-TFC visits (all `source='supabase_cron'`, `job_id=1472`, `line_items_rev=0`, 0 visit-scoped lines): `6216` 2026-08-08, `6217` 2026-09-07, `6218` 2026-10-07, `6219` 2026-11-06, `6220` 2026-12-06, `6910` 2027-01-05.
- 22 completed DB-mastered visits are blank (0 visit-scoped lines); **20 have an SA job template**, 2 are SC/no-template (visit `5680` 112-YA, and 214-MYK grey-water still counts as templated). 082-TFC's `6215` (`public_id='5iDsX4YLbM'`) is one of the blanks.
- Functions: `public.set_visit_derm_required(p_visit_id bigint)`, `public.fn_visit_requires_derm(p_visit_id bigint)`.
- `line_items` columns: `id, job_id, quote_id, name, description, quantity, unit_price, total_price, taxable, invoice_id, visit_id` (+timestamps). Job scope = `job_id` set, `visit_id/invoice_id/quote_id` NULL. Only trigger = `trg_line_items_updated_at` (timestamp). `line_items` is audit-opt-out (ADR-010).
- `customer.work_orders.services` **already** strips the `NN - ` prefix and filters `credit[ ]?card|fee|discount|surcharge|convenience|gratuity`. The **live** view also LEFT JOINs `derm.redacted_manifest_docs rd` (→ `derm_manifest_url = rd.url`) and `derm.receipt_doc_class rc` (→ gated `wwtp_receipt_url`) — the other session's FP-Blackout work. **B1 must preserve these.**

**DB access:** Node `fetch`/`https` POST to `https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query`, `Authorization: Bearer <SUPABASE_PAT from Supabase/.env>`, body `{query, read_only:<bool>}`. On Windows write results to a file + `JSON.parse` (stdout corrupts). Never print the PAT (repo is PUBLIC).

---

## Task 0: Claim + backups (pre-flight)

**Files:**
- Modify: `../../WORKING-NOW.md` (workspace root — the claim board)
- Create: `../../backups/2026-07-13_job1472_lineitems_before.json`
- Create: `../../backups/2026-07-13_work_orders_view_before.sql`

- [ ] **Step 1: Re-read `WORKING-NOW.md`** and confirm the other session (Supabase 2) is NOT on Calendar-side / `public.visits` / `public.line_items` / job 1472 / `customer.work_orders`. If it is, STOP and ask Fred to sequence.

- [ ] **Step 2: Append a claim line** to `WORKING-NOW.md` under "🟢 Active now":

```
- [Supabase] · 2026-07-13 · **🟠 IN PROGRESS — line-item propagation (082-TFC #99900714 + systemic).** touching: `public.line_items` (job 1472 job-scoped rows), `customer.work_orders` (CREATE OR REPLACE — grafting a services fallback onto the LIVE def, preserving @Supabase 2's `rd.url`/`receipt_doc_class` blackout joins), NEW trigger `trg_zz_freeze_line_items_on_complete` on `public.visits` + fn `fn_freeze_visit_line_items`, `scripts/sync/reconcile_jobs.js` (+`--only` flag). NOT touching visit_status/lifecycle, NOT via edit_calendar_visit, NO Jobber push. @Supabase 2: I only ADD a services COALESCE arm to work_orders — your derm_manifest_url/wwtp joins are preserved verbatim.
```

- [ ] **Step 3: Back up** job 1472's current job-scoped rows and the live view def.

Run (writes both backup files):
```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
node -e "const https=require('https'),fs=require('fs');const env=fs.readFileSync('.env','utf8');const g=k=>{const m=env.match(new RegExp('^'+k+'=(.*)$','m'));return m?m[1].trim().replace(/^[\"']|[\"']$/g,''):'';};const PAT=g('SUPABASE_PAT');function pg(q){return new Promise((res,rej)=>{const b=JSON.stringify({query:q,read_only:true});const r=https.request({hostname:'api.supabase.com',path:'/v1/projects/wbasvhvvismukaqdnouk/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}},x=>{let d='';x.on('data',c=>d+=c);x.on('end',()=>res(JSON.parse(d)))});r.on('error',rej);r.write(b);r.end()})}(async()=>{const li=await pg('SELECT * FROM line_items WHERE job_id=1472 AND visit_id IS NULL ORDER BY id');fs.writeFileSync('../backups/2026-07-13_job1472_lineitems_before.json',JSON.stringify(li,null,2));const def=await pg(\"SELECT pg_get_viewdef('customer.work_orders'::regclass,true) AS def\");fs.writeFileSync('../backups/2026-07-13_work_orders_view_before.sql','-- live customer.work_orders BEFORE B1 (rollback = CREATE OR REPLACE VIEW customer.work_orders AS <this>)\n'+def[0].def);console.log('backups written');})();"
```
Expected: `backups written`; both files exist.

- [ ] **Step 4: Commit** the claim (docs/backups are safe to commit; do NOT `git add -A` — the tree has other-session strays).

```bash
git add ../WORKING-NOW.md ../backups/2026-07-13_job1472_lineitems_before.json ../backups/2026-07-13_work_orders_view_before.sql
git commit -m "Claim line-item propagation work + back up job 1472 lines and work_orders view"
git pull --rebase origin main && git push origin main
```
*(Note: `WORKING-NOW.md` + `backups/` are OUTSIDE the Supabase repo root — they live in the workspace root, which is a SEPARATE/no git or the Building Apps repo. If `git add ../WORKING-NOW.md` fails "outside repository", edit + leave it uncommitted (it is a live scratch board, not version-controlled in this repo). Commit only the two `backups/` files if they are inside the repo; otherwise skip the commit — backups are local safety copies.)*

---

## Task A: Reconcile job 1472 to Jobber truth (Calendar shows $346.83)

**Files:**
- Modify: `scripts/sync/reconcile_jobs.js` (add optional `--only=<job_number>` filter; backward-compatible)

- [ ] **Step 1: Add the `--only` flag.** After the `EXECUTE` line (~L19) insert:

```js
const ONLY = (process.argv.find(a => a.startsWith('--only=')) || '').split('=')[1] || null; // reconcile a single job_number
```

Change the job SELECT `WHERE` (the `WHERE j.job_status <> 'archived' ORDER BY j.id` line ~L29) to:

```js
    WHERE j.job_status <> 'archived' ${ONLY ? `AND j.job_number = '${sq(ONLY)}'` : ''} ORDER BY j.id`);
```

And the log line (~L30):

```js
  console.log(`${EXECUTE ? 'EXECUTE' : 'DRY'} — ${jobs.length} non-archived jobs${ONLY ? ` (only #${ONLY})` : ''}`);
```

- [ ] **Step 2: Dry-run for job 1472** to confirm it resolves + sees 3 Jobber lines.

Run:
```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/sync/reconcile_jobs.js --only=99900714
```
Expected: `DRY — 1 non-archived jobs (only #99900714)` and `DONE — {"...","liSynced":1,...}` (liSynced counts the SA job with lines). No DB change yet.

- [ ] **Step 3: Execute** the reconcile for job 1472 only.

Run:
```bash
node scripts/sync/reconcile_jobs.js --only=99900714 --execute
```
Expected: `EXECUTE — 1 non-archived jobs (only #99900714)`, `DONE — {...,"liSynced":1,...}`, errors:0.

- [ ] **Step 4: Verify** job-scoped rows = Jobber truth and the 6 future visits inherit $346.83.

Run (read-only query; write result to file, then read):
```sql
SELECT 'job_lines' k, json_agg(json_build_object('name',name,'total',total_price) ORDER BY id)::text v
  FROM line_items WHERE job_id=1472 AND visit_id IS NULL
UNION ALL
SELECT 'future_visit_inherited_totals',
  json_agg(json_build_object('id',v.id,'date',v.visit_date,'total',
    (SELECT sum(total_price) FROM line_items li WHERE li.job_id=v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL)) ORDER BY v.visit_date)::text
  FROM visits v WHERE v.client_id=31 AND v.visit_status='scheduled' AND v.deleted_at IS NULL AND v.visit_date>=current_date;
```
Expected: `job_lines` = 3 items incl. `27 - GDO Online Reporting` $35 and `25 - Credit card fee (3.53%)` **$11.83**; `future_visit_inherited_totals` = **346.83** for all 6 visits. (Optional cross-check: `ops.v_calendar_visit` amount for those visits = 346.83.)

- [ ] **Step 5: Commit** the script change.

```bash
git add scripts/sync/reconcile_jobs.js
git commit -m "reconcile_jobs: add --only=<job_number> for targeted single-job reconcile"
git pull --rebase origin main && git push origin main
```

---

## Task B1: Job-scoped services fallback in `customer.work_orders`

**Files:**
- Create: `docs/migrations/2026-07-13_work_orders_services_job_fallback.sql`

- [ ] **Step 1: Verify the current (broken) state** — 6215's work order shows no services.

Run:
```sql
SELECT id, services FROM customer.work_orders WHERE id = '5iDsX4YLbM';
```
Expected (BEFORE): `services = {}` (empty) — the blank we're fixing.

- [ ] **Step 2: Write the migration** grafting a job-scoped fallback onto the LIVE view (from `backups/2026-07-13_work_orders_view_before.sql`). Change ONLY the `services` column expression; keep every other column and both blackout LEFT JOINs verbatim.

Create `docs/migrations/2026-07-13_work_orders_services_job_fallback.sql`:

```sql
-- 2026-07-13 — customer.work_orders.services: add job-scoped fallback (line-item propagation B1)
--
-- WHY: scheduled/DB-mastered completed visits carry no visit-scoped line_items; they inherit the
-- SA job's template. The work order read only visit-scoped rows, so those visits showed no services
-- (blank). Add a COALESCE 2nd arm reading the job-scoped template (job_id=v.job_id, visit_id NULL)
-- with the SAME prefix-strip + fee filter. Visits with their own lines are unaffected (1st arm wins).
-- Grafted onto the LIVE view (preserves the FP-Blackout rd.url / receipt_doc_class joins).
-- Backup of prior view: backups/2026-07-13_work_orders_view_before.sql (rollback = re-apply it).
-- Audit: view only, no table/trigger change. Apply via Management API (read_only:false).

CREATE OR REPLACE VIEW customer.work_orders AS
 SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE WHEN v.start_at IS NOT NULL THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text) ELSE NULL::text END AS visit_time,
    COALESCE(( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) FROM visit_assignments va JOIN employees e ON e.id = va.employee_id WHERE va.visit_id = v.id),
             ( SELECT string_agg(e2.full_name, ', '::text ORDER BY e2.full_name) FROM visit_team vt JOIN employees e2 ON e2.id = vt.employee_id WHERE vt.visit_id = v.id)) AS driver,
    veh.name AS truck,
    veh.decal_number AS decal,
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0), NULLIF(( SELECT prim.grease_trap_manhole_count FROM properties prim WHERE prim.client_id = v.client_id AND prim.is_primary = true LIMIT 1), 0)) AS manholes,
    v.manhole_breakdown,
    v.ticket_number,
    v.trap_condition_notes AS trap_condition,
    row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date)::integer AS visit_num,
    ( SELECT CASE WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer END FROM service_configs sc WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type LIMIT 1) AS visit_total,
    v.title AS notes,
    dm.white_manifest_number AS derm_manifest_number,
    rd.url AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
        CASE WHEN rc.class = 'receipt'::text THEN dm.derm_manifest_url ELSE NULL::text END AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE WHEN dm.white_manifest_number IS NOT NULL THEN 'dade'::text WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text ELSE NULL::text END AS manifest_jurisdiction,
    dm.id AS manifest_id,
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count FROM properties prim WHERE prim.client_id = v.client_id AND prim.is_primary = true LIMIT 1), 0)) AS sample_ports,
    ( SELECT df.name FROM disposal_facilities df WHERE df.id = dm.disposal_facility_id) AS disposal_facility,
    COALESCE(
      ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id)
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text
            AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text),
      ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id)
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL
            AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text
            AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text),
      ARRAY[]::text[]) AS services
   FROM visits v
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN properties prop ON prop.id = v.property_id
     LEFT JOIN LATERAL ( SELECT dm_inner.id, dm_inner.client_id, dm_inner.service_date, dm_inner.dump_ticket_date, dm_inner.white_manifest_number, dm_inner.yellow_ticket_number, dm_inner.sent_to_client, dm_inner.sent_to_city, dm_inner.created_at, dm_inner.updated_at, dm_inner.wwtp_receipt_number, dm_inner.wwtp_receipt_document_path, dm_inner.wwtp_ticket_number, dm_inner.disposal_facility_id, dm_inner.derm_manifest_url, dm_inner.derm_address_url, dm_inner.fog_manifest_url, dm_inner.gdo_id
           FROM derm_manifests dm_inner JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
          WHERE mv.visit_id = v.id AND dm_inner.deleted_at IS NULL
          ORDER BY dm_inner.service_date DESC NULLS LAST LIMIT 1) dm ON true
     LEFT JOIN derm.redacted_manifest_docs rd ON rd.manifest_id = dm.id AND rd.client_id = v.client_id
     LEFT JOIN derm.receipt_doc_class rc ON rc.url = dm.derm_manifest_url
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true AND v.deleted_at IS NULL;
```

**IMPORTANT:** before applying, diff this against `backups/2026-07-13_work_orders_view_before.sql` — the ONLY intended difference is the `services` expression (added 2nd COALESCE arm). If the live def has drifted further (other-session change), re-graft onto the newest def.

- [ ] **Step 3: Apply** the migration via the Management API (`read_only:false`) and confirm no error.

- [ ] **Step 4: Verify** the fallback works and blackout joins are intact.

Run:
```sql
SELECT id, services, derm_manifest_url, wwtp_receipt_url FROM customer.work_orders WHERE id='5iDsX4YLbM';
```
Expected (AFTER): `services = {"Service Agreement - Pumping - Grease Trap & Tank Cleaning","GDO Online Reporting"}` (card fee hidden, prefix stripped); `derm_manifest_url`/`wwtp_receipt_url` unchanged from before (blackout preserved). Also spot-check a visit that has its OWN visit-scoped lines still shows those (1st arm), e.g. a `source='jobber'` completed visit.

- [ ] **Step 5: Commit** the migration.

```bash
git add docs/migrations/2026-07-13_work_orders_services_job_fallback.sql
git commit -m "work_orders: add job-scoped services fallback for inheriting visits"
git pull --rebase origin main && git push origin main
```

---

## Task B2: Freeze-on-completion trigger (all clients; SA snapshot / SC keep own)

**Files:**
- Create: `docs/migrations/2026-07-13_freeze_visit_line_items_on_completion.sql`

- [ ] **Step 1: Write the failing test** — with NO trigger yet, completing a DB-mastered SA visit adds no line items. (Run in a self-rolling-back DO block so nothing persists; the RAISE aborts the txn, so visit 6216 stays scheduled.)

Run (via Management API `read_only:false`):
```sql
DO $$
DECLARE before_cnt int; after_cnt int;
BEGIN
  SELECT count(*) INTO before_cnt FROM public.line_items WHERE visit_id = 6216;
  UPDATE public.visits SET visit_status = 'completed' WHERE id = 6216;   -- would fire the trigger once it exists
  SELECT count(*) INTO after_cnt FROM public.line_items WHERE visit_id = 6216;
  RAISE EXCEPTION 'TEST before=% after=% (txn rolled back)', before_cnt, after_cnt;
END $$;
```
Expected (BEFORE trigger): error `TEST before=0 after=0 (txn rolled back)` — no snapshot, and the RAISE rolled back the completion (verify `SELECT visit_status FROM visits WHERE id=6216` = `scheduled`).

- [ ] **Step 2: Write the migration** (function + trigger).

Create `docs/migrations/2026-07-13_freeze_visit_line_items_on_completion.sql`:

```sql
-- 2026-07-13 — freeze visit line items on completion (line-item propagation B2)
--
-- WHY: for DB-mastered completions (source supabase_cron/visit-calendar), handleVisit early-returns
-- before its line_items block, so completed SA visits get no visit-scoped line_items and the customer
-- work order goes blank (and this becomes the norm as Jobber sunsets). This trigger freezes the
-- visit's effective services at completion: if the visit already has its own visit-scoped lines
-- (SC / manual Calendar visits) it keeps them; if it has none but its job carries a template (SA jobs),
-- it snapshots the job's job-scoped lines onto the visit. Pure INSERT into line_items (no visits write,
-- no line_items_rev bump) -> no Jobber push, no trigger cascade. DERM is NOT re-derived here:
-- fn_visit_requires_derm already unions job scope and the nightly derm-required-rederive cron backstops.
-- Audit: line_items stays audit-opt-out (ADR-010); trigger adds no human-editable field. Jobber-mastered
-- (source='jobber') visits are excluded (handleVisit already materializes their real visit lines).

CREATE OR REPLACE FUNCTION public.fn_freeze_visit_line_items()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.job_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.line_items li WHERE li.visit_id = NEW.id)
     AND EXISTS (SELECT 1 FROM public.line_items li
                  WHERE li.job_id = NEW.job_id AND li.visit_id IS NULL
                    AND li.invoice_id IS NULL AND li.quote_id IS NULL)
  THEN
    INSERT INTO public.line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
    SELECT NEW.id, li.name, li.description, li.quantity, li.unit_price, li.total_price, li.taxable
    FROM public.line_items li
    WHERE li.job_id = NEW.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL;
  END IF;
  RETURN NULL;  -- AFTER trigger
END;
$$;

DROP TRIGGER IF EXISTS trg_zz_freeze_line_items_on_complete ON public.visits;
CREATE TRIGGER trg_zz_freeze_line_items_on_complete
  AFTER UPDATE OF visit_status ON public.visits
  FOR EACH ROW
  WHEN (NEW.visit_status = 'completed'
        AND OLD.visit_status IS DISTINCT FROM 'completed'
        AND NEW.source IN ('supabase_cron','visit-calendar'))
  EXECUTE FUNCTION public.fn_freeze_visit_line_items();
```

- [ ] **Step 3: Apply** the migration via Management API (`read_only:false`); confirm no error.

- [ ] **Step 4: Run the same test to verify it now passes** (snapshot appears, still rolled back).

Run the identical DO block from Step 1.
Expected (AFTER trigger): error `TEST before=0 after=3 (txn rolled back)` (3 = the reconciled job-1472 template rows). Confirm `SELECT visit_status, (SELECT count(*) FROM line_items WHERE visit_id=6216) FROM visits WHERE id=6216` = `scheduled, 0` (rollback left 6216 untouched — no real completion, no snapshot persisted).

- [ ] **Step 5: Verify the "keep own lines" branch** — a visit that already has visit-scoped lines is NOT duplicated. Use an SC/Calendar visit that has its own lines (e.g. `7090`), simulate a re-complete in a rolled-back txn:

```sql
DO $$
DECLARE before_cnt int; after_cnt int;
BEGIN
  SELECT count(*) INTO before_cnt FROM public.line_items WHERE visit_id = 7090;
  UPDATE public.visits SET visit_status = 'scheduled' WHERE id = 7090;   -- flip off
  UPDATE public.visits SET visit_status = 'completed' WHERE id = 7090;   -- and back on -> trigger fires
  SELECT count(*) INTO after_cnt FROM public.line_items WHERE visit_id = 7090;
  RAISE EXCEPTION 'KEEPOWN before=% after=% (rolled back)', before_cnt, after_cnt;
END $$;
```
Expected: `KEEPOWN before=2 after=2 (rolled back)` — no duplication (the NOT EXISTS guard skipped the snapshot).

- [ ] **Step 6: Commit** the migration.

```bash
git add docs/migrations/2026-07-13_freeze_visit_line_items_on_completion.sql
git commit -m "Freeze visit line items on completion (SA snapshot / SC keep own)"
git pull --rebase origin main && git push origin main
```

---

## Task C: Confirm fee filter (no change) — verification only

- [ ] **Step 1:** Confirm the customer work order excludes the card fee and strips the prefix (already true; asserted by Task B1 Step 4 — `services` contains no `Credit card fee` and no `NN - ` prefixes). No code change. If any fee leaks, revisit the regex in the B1 migration.

---

## Task D: Docs — fix stale integration.md + reconcile the spec

**Files:**
- Modify: `docs/integration.md` (JOB_CREATE/JOB_UPDATE handler row)
- Modify: `docs/reference/line-item-lifecycle-and-jobber-edit-ripple.md` (mark shipped + the 2 refinements)
- Modify: `CLAUDE.md` (add a doc-map link)

- [ ] **Step 1:** In `docs/integration.md`, find the `JOB_CREATE`/`JOB_UPDATE` webhook row/section (grep `JOB_UPDATE`). Add that `handleJob` also syncs **job-scoped `line_items` (SA jobs) + the Frequency custom field**, and that `reconcile_jobs.js` (every 6h) is the catch-up for edited jobs (the `createdAt`-cursor poll can't re-select them).

- [ ] **Step 2:** In the reference doc §5, mark Part A/B1/B2/C **SHIPPED (2026-07-13)** and fold in the two planning refinements: B2 does **not** re-derive DERM inline (job-scope + nightly cron cover it); **no retroactive backfill** (B1 fallback covers old blanks, B2 snapshots forward only). Update §8 code refs with the new migration filenames.

- [ ] **Step 3:** In `CLAUDE.md` documentation map, add a row linking `docs/reference/line-item-lifecycle-and-jobber-edit-ripple.md` ("line-item lifecycle + Jobber-edit ripple").

- [ ] **Step 4: Commit** docs.

```bash
git add docs/integration.md docs/reference/line-item-lifecycle-and-jobber-edit-ripple.md CLAUDE.md
git commit -m "Docs: line-item sync in integration.md + mark propagation design shipped"
git pull --rebase origin main && git push origin main
```

*(App-side doc-in-both-places: the customer work order lives in the Field Portal / ops-portal, not the Visit Calendar. Add a one-line note to the ops-portal FP changelog if/when that repo is touched — not required for this DB-only change.)*

---

## Task E: Final audit + release the claim

- [ ] **Step 1: End-to-end re-verify** (single read-only query, result to file):
  - job 1472 job-scoped lines = 3 ($346.83);
  - all 6 future 082-TFC visits inherit $346.83 in `ops.v_calendar_visit`;
  - `customer.work_orders` for `5iDsX4YLbM` shows `{…Pumping…, GDO Online Reporting}`, fee hidden, blackout URLs intact;
  - trigger `trg_zz_freeze_line_items_on_complete` exists (`SELECT tgname FROM pg_trigger WHERE tgname='trg_zz_freeze_line_items_on_complete'`);
  - no new open push flags for the 6 future visits (`visit_sync_flags` / `ops.v_calendar_push_health` = 0 for client 31) — proves no accidental Jobber push.

- [ ] **Step 2: Run the Supabase:zero-runs skill** (audit-after-fixes rule) or a targeted pipeline audit; confirm no regressions.

- [ ] **Step 3: Update `WORKING-NOW.md`** — move the claim to "Recently done" with the shipped commit hashes + a one-line summary. Confirm no other-session collision occurred.

---

## Self-review (spec coverage)

- Spec §5 Part A → **Task A** ✅ · Part B1 → **Task B1** ✅ · Part B2 (SA+SC, all clients) → **Task B2** ✅ (SC "keep own" verified Step 5) · Part C (fees) → **Task C** ✅ · Part D guardrails: direct writes only (A/B2 no `edit_calendar_visit`), WORKING-NOW claim (Task 0/E), verify+rollback (backups Task 0, rollback notes in each migration) ✅ · Docs (integration.md + reference + link) → **Task D** ✅.
- Deviations from spec, documented above + reconciled in Task D: no inline DERM re-derive; no retroactive backfill. Both are strict improvements (lower cascade risk / no fabricated historical snapshots).
- Rollback: Task A = re-sync is idempotent to Jobber truth (backup captured prior rows). B1 = re-apply `backups/2026-07-13_work_orders_view_before.sql`. B2 = `DROP TRIGGER trg_zz_freeze_line_items_on_complete ON public.visits; DROP FUNCTION public.fn_freeze_visit_line_items();`.
- Types/names consistent: `fn_freeze_visit_line_items` / `trg_zz_freeze_line_items_on_complete` used identically in the migration + rollback + Task E.
```
