# GDO bot: dashboard manual entries reach the Tracker (for Jon, 2026-10-26)

> **SUPERSEDED 2026-10-27** by `docs/superpowers/plans/2026-10-27-gdo-bot-manual-entry-upstream.md` (reviewed). Kept
> as the record of the first draft. Do not build from it: it uses `INSERT OR REPLACE`, sends `dump_date`, offers a
> dashboard line D3 declines, and its message to Jon predates 8889-8892 and Part A (B9 rewrites it).

Two parts: the task brief, written the way the bot repo writes them (`docs/TASK_*.md`; it goes in as
`docs/TASK_MANUAL_ENTRY_UPSTREAM.md`), and the message telling Jon. **Neither is sent or pushed.** Bot-repo pushes are
deploys and wait until the September LWT report is filed (`Supabase/docs/reference/gdo-report-bot.md` section 9).
Our side is live: `rpa-derm-result` v40, section 10 of that reference.

---

## Part 1: the brief (`docs/TASK_MANUAL_ENTRY_UPSTREAM.md`)

```markdown
# Task brief: manual entries are recorded upstream as manual filings (Fred, 2026-10-26)

A report typed on the dashboard ("Add a report by hand") and filed on the county portal must show in the Tracker as
a manual filing. This IMPLEMENTS R7 in docs/REQUIREMENTS_TRACKER_SSO.md: the Tracker side now exists
(rpa-derm-result accepts `manual_entry`, live 2026-10-26). Work under CLAUDE.md's loop: write -> audit ->
mutation-verify -> one commit_msg.txt thread.

First case: manual entry #1 by yan, permit 14965, manifest 808783, date 2025-11-16, run
882d2b19-aa06-4db8-9d43-136d1451bebb. The portal accepted it at 12:00 ET; every POST got 400
unknown_field_manual_entry. Fred recorded it upstream by hand from /evidence-export, so the cached seed now gets
200 deduped and clears itself.

## What is true today (read in the code at 7681388)

- The design says a manual entry never posts (R7, HANDOFF, DOMAIN_RULES, reporter.py comments at 336-341 and
  383-390). The guard lives only in `_post_and_cache` (reporter.py:392-395). Two paths skip it, so every SUCCESS of
  a manual entry DOES post: the F1 seed (reporter.py:963, `db.cache_failed_result` directly, flushed later by
  `_flush_pending_results`, reporter.py:447) and the final POST after the email (reporter.py:1060).
- The body carries nothing that says which filing it is: `visit_id` / `manifest_id` null (server.py
  `_manual_payload` leaves them out on purpose), no permit, manifest or date (`build_result_payload` never copies
  them), no `gdo_id`.
- The retry resends the SEED, written before the email wait, so it has no image: `pending_api_results` is
  `INSERT OR IGNORE` on run_id (db.py:428) and the final payload is never cached (reporter.py:1062-1063 only logs).

## What changes

1. **build_result_payload puts the typed values inside `manual_entry`** (top-level contract unchanged):
   `gdo_number` (the one permit; validate_manual_entry already refuses commas), `ticket_number`, `service_date` as
   ISO YYYY-MM-DD (convert through parse_portal_date; upstream also reads MM/DD/YYYY, send ISO), `dump_date`
   (optional), plus the existing `created_by` and `why`. Upstream refuses any other key inside `manual_entry`
   (400 `unknown_field_manual_entry.<key>`), and refuses `manual_entry` together with a `visit_id`, `manifest_id`
   or `gdo_id`.
2. **For a MANUAL entry only, a failed final POST replaces the seed with the final payload.** This deliberately
   departs from PLAN_INLINE_EVIDENCE step 5a ("INSERT OR IGNORE keeps the seed"), so say so in the commit. That rule
   is right for a QUEUE item: its seed carries no image by ruling B, and once the result lands the late-evidence
   drain attaches the email through `/rpa-derm-evidence` under (visit_id, run_id). A manual entry has no visit_id,
   and `db.get_unposted_email_evidence` requires one, so its email is never drained (silently); the final payload is
   the only copy that will ever carry it, and upstream refuses a manual entry with no image. So: in the else branch
   at reporter.py:1062, when the item is `_manual`, cache the final payload with a replace for that call only (e.g.
   `cache_failed_result(..., replace=True)` -> `INSERT OR REPLACE`). The default stays IGNORE, queue items are
   unchanged, and the re-assert path (reporter.py:641-655) must never overwrite an original seed.
3. **Manual entries post on purpose now, SUCCESS only.** Keep the `_post_and_cache` guard for every other manual
   result (dry run, validation, errors stay local: upstream answers them 200 recorded:false anyway, but nothing is
   gained by sending them). Rewrite the comments that say a manual entry never posts.
4. **Read the answer.** Upstream returns:
   - 201 `{recorded:true, manual_entry:true, visit_id, gdo_id, run_id:"manual-bot-<run_id>", filed_by}`;
   - 200 `{recorded:true, deduped:true, ...}` on a retry;
   - 200 `{recorded:false, reason, announced:true}` when it cannot match ONE visit (no permit/manifest/date, no
     matching visit, several visits on that manifest, no image) or the permit is already filed. Upstream has
     already posted it to #apps-notifications for a person; do NOT retry it;
   - 500 `*_retry` when something on its side failed; retry as today.
   Optional, operator-facing: when `recorded:false`, the manual entry's row on the dashboard says "Filed on the
   county; not recorded in the Tracker: <reason>" instead of plain "Filed" (_finish_manual_item reads only the
   local ledger today).

## Tests (behaviour, mutation-verified)

- build_result_payload on a `_manual` item carries the four values in `manual_entry`, ISO date; a queue item is
  unchanged (no `manual_entry` key at all).
- For a manual item, a failed final POST leaves the FINAL payload (with `screenshot`) in pending_api_results; for a
  queue item the seed is still kept (IGNORE); the re-assert path still cannot overwrite a seed (revert `replace`,
  or drop the `_manual` condition, and a test fails).
- A manual non-SUCCESS result never reaches api_client.post_result.
- Assert behaviour, not source text (WORKING_AGREEMENTS): drive the code, never `"foo" in src`.
- Full suite green in the runtime image plus node (RUNBOOK section 1: `docker build --target runtime`, then
  `Dockerfile.test`, exit 0), not only the venv. Then the auditor subagent on the diff, verify-then-apply.

## Docs in the same change

- REQUIREMENTS_TRACKER_SSO.md R7: DELIVERED 2026-10-26 on the Tracker side, with the shipped shape above (its text
  "never POST to rpa-derm-queue results" was already untrue: the seed and the final POST skipped the guard).
- DOMAIN_RULES.md, GDO filings: the new decision with who and when (Fred, 2026-10-26: a dashboard entry filed on the
  county portal is a manual filing and is recorded upstream as one).
- PROJECT_GDO_BOT.md (the invariant "its result is never POSTed upstream ... `_post_and_cache` refuses at the one
  door all its call sites pass through" was false: two call sites skip that door), HANDOFF.md section 4 and line 113,
  TASK_UI_ACKS_AND_MANUAL_GDO.md (a dated note under "Delivered", never an edit of the record),
  PLAN_INLINE_EVIDENCE.md step 5a (the manual-item exception), API_CONTRACT.md (the `manual_entry` body and its
  three answers), the server.py `_manual_payload` docstring, reporter.py comments at 336-341 and 383-390.
- A "Delivered" section at the end of this brief, naming what was deliberately NOT done.
- The push is a deploy (HANDOFF section 2): only after the September LWT report is filed, between hourly runs, and
  check the startup lines and `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=120` afterwards (RUNBOOK section 4, DEPLOYMENT).
```

---

## Part 2: the message to Jon

In Spanish: the bot repo's rule is "talk to Jon in Spanish" (`docs/PROJECT_INSTRUCTIONS.md`). Since the 2026-10-08
handoff the bot is ours and Jon is out of the loop unless there is a separate agreement (HANDOFF section 10), so
this message only lets him know; it asks nothing of him.

> Hola Jon, un aviso sobre el bot de GDO, nada urgente y no necesitamos nada de ti.
>
> El 26 de octubre Yan usó "Add a report by hand" en el dashboard para Marie Blachere (permiso 14965, manifiesto
> 808783, 16/11/2025). El condado lo aceptó. Después el bot envió el resultado a nuestra API, aunque R7 dice que una
> entrada manual nunca se envía: la copia previa (F1) y el POST final después del correo no pasan por el guard de
> `_post_and_cache`. Nuestra API lo rechazó (`unknown_field_manual_entry`) y el bot reintentó cada hora.
>
> Decidimos tratar esas entradas como presentaciones manuales: nuestra API ahora acepta `manual_entry` y la registra
> igual que una presentación manual del DERM App. Así que R7 queda entregado de nuestro lado. En el bot vamos a hacer
> nosotros dos cambios, siguiendo tus reglas (brief en `docs/TASK_MANUAL_ENTRY_UPSTREAM.md`, tests verificados por
> mutación, auditor, `commit_msg.txt`):
> 1. mandar el permiso, el número de manifiesto y la fecha de servicio (y la de descarga si hay) dentro de
>    `manual_entry`, porque hoy el cuerpo no dice a qué visita corresponde;
> 2. solo para una entrada manual, si falla el POST final, guardar el payload final (con el correo del condado) en
>    lugar de la copia previa: el drain de evidencia tardía necesita un visit_id, así que nunca adjuntaría ese correo.
>    Los items de la cola siguen igual.
>
> La entrada de Yan ya está registrada de nuestro lado. El push espera a que se presente el reporte LWT de septiembre.
>
> ¡Gracias!
