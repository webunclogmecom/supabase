"""
Analyze 09_phase_2b_results.json and produce:
  - phase_2b_report.md  (human-readable summary, all 50 rows by classification)
  - 2026-05-25m_gdo_phase_2b_applies.sql  (draft migration for Viktor approval)
  - phase_2b_viktor_message.md  (Slack-ready summary to post)

Per Viktor 2026-05-25 PM rules:
  - CONFIRMED_MATCH    -> UPDATE max_frequency_days (only); keep 2026-12-31 expiration if bot returned a stale date
  - WRONG_CLIENT       -> DEMOTE status='INACTIVE', capture bot's issued_to/facility in notes
  - DIFFERENT_TENANT   -> DEMOTE status='INACTIVE', capture bot's findings
  - WRONG_GDO_NUMBER   -> Surface to Viktor for case-by-case approval (changes row identity)
  - AMBIGUOUS rows (Rustico/RUSTIKO, Pura Vida 41) -> defer
"""
from __future__ import annotations

import json
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parents[2]  # repo root (Supabase/): HERE=probes/, [0]=phase dir, [1]=docs/, [2]=Supabase/

RESULTS = json.loads((HERE / "09_phase_2b_results.json").read_text(encoding="utf-8"))
ROWS = RESULTS["results"]

# Ambiguous cases pulled by eyeball — surface to Viktor instead of auto-applying.
AMBIGUOUS_GDOS = {
    "GDO-08499",  # Rustico vs RUSTIKO (alt spelling? Or different business?)
    "GDO-03375",  # Pura Vida 41 -> bot returned name_match=true on "M&L FOOD MARKET" -- suspicious
}


def sql_escape(s: str) -> str:
    """Escape single quotes for SQL string literal."""
    if s is None:
        return ""
    return s.replace("'", "''")


def trunc(s: str, n: int = 50) -> str:
    if not s:
        return ""
    s = s.strip()
    return s if len(s) <= n else s[:n - 1] + "..."


# ----- Bucket rows -----
confirmed_safe = []
wrong_client_demote = []
different_tenant_demote = []
wrong_gdo_review = []
ambiguous = []

for r in ROWS:
    cls = r["classification"]
    if r["gdo_number"] in AMBIGUOUS_GDOS:
        ambiguous.append(r)
        continue
    if cls == "CONFIRMED_MATCH":
        confirmed_safe.append(r)
    elif cls == "WRONG_CLIENT":
        wrong_client_demote.append(r)
    elif cls == "DIFFERENT_TENANT":
        different_tenant_demote.append(r)
    elif cls == "WRONG_GDO_NUMBER":
        wrong_gdo_review.append(r)
    else:
        ambiguous.append(r)

# ----- Build the report markdown -----
report = []
report.append("# Phase 2b — 50-GDO Bot Batch Results\n")
report.append(f"Total: {len(ROWS)} rows · Generated from `09_phase_2b_results.json`\n")
report.append("## Counts\n")
report.append(f"- CONFIRMED_MATCH (safe UPDATE max_frequency_days): **{len(confirmed_safe)}**")
report.append(f"- WRONG_CLIENT (DEMOTE INACTIVE): **{len(wrong_client_demote)}**")
report.append(f"- DIFFERENT_TENANT (DEMOTE INACTIVE): **{len(different_tenant_demote)}**")
report.append(f"- WRONG_GDO_NUMBER (re-link to bot's gdo_number, NEEDS VIKTOR REVIEW): **{len(wrong_gdo_review)}**")
report.append(f"- AMBIGUOUS (defer, NEEDS VIKTOR REVIEW): **{len(ambiguous)}**\n")

def fmt_row(r):
    bot = r["bot"]
    return (
        f"| {r['id']} | {r['gdo_number']} | {r['client_code']} | "
        f"{trunc(r['client_name'], 28)} | {bot.get('frequency_days') or '?'} | "
        f"{bot.get('expiration_date') or '?'} | "
        f"{trunc(bot.get('facility_name') or '', 30)} | "
        f"{trunc(bot.get('issued_to') or '', 36)} |"
    )

table_hdr = ("| id | gdo_number | client_code | client_name | bot_freq | bot_exp | "
             "bot_facility | bot_issued_to |\n"
             "|---|---|---|---|---|---|---|---|")

for title, rows in [
    ("CONFIRMED_MATCH (safe UPDATE)", confirmed_safe),
    ("WRONG_CLIENT (DEMOTE)", wrong_client_demote),
    ("DIFFERENT_TENANT (DEMOTE)", different_tenant_demote),
    ("WRONG_GDO_NUMBER (NEEDS VIKTOR REVIEW)", wrong_gdo_review),
    ("AMBIGUOUS (NEEDS VIKTOR REVIEW)", ambiguous),
]:
    report.append(f"\n## {title} ({len(rows)})\n")
    if not rows:
        report.append("_(none)_")
        continue
    report.append(table_hdr)
    for r in rows:
        report.append(fmt_row(r))
    # Special call-outs
    if title.startswith("WRONG_GDO"):
        report.append("\n**Bot's proposed gdo_number for each:**")
        for r in rows:
            report.append(f"- id={r['id']} {r['client_code']} {r['client_name']}: "
                          f"our `{r['gdo_number']}` -> bot `{r['bot']['gdo_number']}` "
                          f"({trunc(r['bot'].get('issued_to') or r['bot'].get('facility_name') or '', 50)})")

(HERE / "phase_2b_report.md").write_text("\n".join(report), encoding="utf-8")
print("Wrote phase_2b_report.md")

# ----- Build the draft migration -----
sql_lines = []
sql_lines.append("-- 2026-05-25m_gdo_phase_2b_applies.sql (DRAFT — pending Viktor approval)")
sql_lines.append("--")
sql_lines.append("-- Phase 2b bot-batch applies. Generated from")
sql_lines.append("--   docs/gdo-phase-2-2026-05-25/probes/09_phase_2b_results.json")
sql_lines.append("-- by")
sql_lines.append("--   docs/gdo-phase-2-2026-05-25/probes/10_phase_2b_analyze.py")
sql_lines.append("--")
sql_lines.append("-- Scope (split per Viktor 2026-05-25 PM rules):")
sql_lines.append(f"--   {len(confirmed_safe)} CONFIRMED_MATCH UPDATEs (max_frequency_days only)")
sql_lines.append(f"--   {len(wrong_client_demote)} WRONG_CLIENT DEMOTEs to INACTIVE")
sql_lines.append(f"--   {len(different_tenant_demote)} DIFFERENT_TENANT DEMOTEs to INACTIVE")
sql_lines.append(f"--   {len(wrong_gdo_review)} WRONG_GDO_NUMBER cases — DEFERRED to Phase 2b-2 after Viktor decides")
sql_lines.append(f"--   {len(ambiguous)} AMBIGUOUS — DEFERRED")
sql_lines.append("--")
sql_lines.append("-- IDEMPOTENT (Rule 5): every WHERE filters on current state. Re-run is no-op.")
sql_lines.append("-- AUDIT (Rule 8): audit trigger on public.gdos auto-generates app_source='sql' rows.")
sql_lines.append("--")
sql_lines.append("BEGIN;")
sql_lines.append("")
sql_lines.append("-- ============================================================")
sql_lines.append(f"-- 1. {len(confirmed_safe)} CONFIRMED_MATCH UPDATEs (max_frequency_days only)")
sql_lines.append("-- ============================================================")
sql_lines.append("-- Trust bot's frequency_days. Don't overwrite permit_expiration:")
sql_lines.append("--   - Group A (was NULL): use 2026-12-31 (current annual cycle assumption)")
sql_lines.append("--   - Group B (already 2026-12-31 from 25l bulk): keep as-is")
sql_lines.append("-- The bot occasionally returns stale dates (e.g. 2023-12-31 for Marie Blachere);")
sql_lines.append("-- DERM annual renewal makes 2026-12-31 the truth right now.")
sql_lines.append("")
for r in confirmed_safe:
    bot = r["bot"]
    freq = bot.get("frequency_days")
    if freq is None:
        sql_lines.append(f"-- id={r['id']} {r['gdo_number']} ({r['client_code']}): "
                         f"bot returned NULL frequency_days, skipping (Viktor: bot rerun later)")
        continue
    # Build notes WITHOUT pre-escaping the inner pieces; we'll sql_escape once
    # at the embedding site. (Earlier bug: double-escape produced '''' instead of ''.)
    notes = (f"[2026-05-25 Phase 2b] CONFIRMED_MATCH via @GDO bot. "
             f"issued_to=\"{(bot.get('issued_to') or '').strip()}\", "
             f"facility_name=\"{(bot.get('facility_name') or '').strip()}\", "
             f"max_frequency_days={freq}.")
    # Set permit_expiration only if currently NULL (Group A); use 2026-12-31.
    exp_set = ", permit_expiration = '2026-12-31'" if r.get("permit_expiration") is None else ""
    exp_cond = " AND (permit_expiration IS NULL OR permit_expiration < '2026-12-31')" if r.get("permit_expiration") is None else ""
    sql_lines.append(f"UPDATE public.gdos SET max_frequency_days = {freq}{exp_set},")
    sql_lines.append(f"    notes = COALESCE(notes || E'\\n', '') || '{sql_escape(notes)}'")
    sql_lines.append(f"WHERE id = {r['id']} AND gdo_number = '{r['gdo_number']}'")
    sql_lines.append(f"  AND (max_frequency_days IS NULL OR max_frequency_days <> {freq}){exp_cond};")
    sql_lines.append("")

sql_lines.append("-- ============================================================")
sql_lines.append(f"-- 2. {len(wrong_client_demote)} WRONG_CLIENT DEMOTEs to INACTIVE")
sql_lines.append("-- ============================================================")
sql_lines.append("-- DB had wrong client linked to a real GDO at the address;")
sql_lines.append("-- the actual permit holder is in bot.issued_to.")
sql_lines.append("")
for r in wrong_client_demote:
    bot = r["bot"]
    actual = (bot.get("issued_to") or bot.get("facility_name") or "(unknown)").strip()
    # No pre-escape; sql_escape happens once at embedding site.
    notes = (f"[2026-05-25 Phase 2b] DEMOTED. {r['gdo_number']} actually belongs to "
             f"\"{trunc(actual, 80)}\" per @GDO bot. {r['client_name']} "
             f"has no DERM permit at its address.")
    sql_lines.append(f"-- id={r['id']} {r['gdo_number']} ({r['client_code']} {trunc(r['client_name'], 30)})")
    sql_lines.append(f"UPDATE public.gdos SET status = 'INACTIVE',")
    sql_lines.append(f"    notes = COALESCE(notes || E'\\n', '') || '{sql_escape(notes)}'")
    sql_lines.append(f"WHERE id = {r['id']} AND gdo_number = '{r['gdo_number']}' AND status = 'ACTIVE';")
    sql_lines.append("")

sql_lines.append("-- ============================================================")
sql_lines.append(f"-- 3. {len(different_tenant_demote)} DIFFERENT_TENANT DEMOTEs to INACTIVE")
sql_lines.append("-- ============================================================")
sql_lines.append("-- Bot returned a different GDO at the address that doesn't match")
sql_lines.append("-- our client by name. Our row is wrong on both axes.")
sql_lines.append("")
for r in different_tenant_demote:
    bot = r["bot"]
    actual = (bot.get("issued_to") or bot.get("facility_name") or "(unknown)").strip()
    other_gdo = bot.get("gdo_number")
    notes = (f"[2026-05-25 Phase 2b] DEMOTED. {r['gdo_number']} does not appear at "
             f"this address per @GDO bot. Address belongs to {other_gdo} "
             f"\"{trunc(actual, 80)}\" — different tenant, different GDO. "
             f"{r['client_name']} has no DERM permit here.")
    sql_lines.append(f"-- id={r['id']} {r['gdo_number']} ({r['client_code']} {trunc(r['client_name'], 30)})")
    sql_lines.append(f"UPDATE public.gdos SET status = 'INACTIVE',")
    sql_lines.append(f"    notes = COALESCE(notes || E'\\n', '') || '{sql_escape(notes)}'")
    sql_lines.append(f"WHERE id = {r['id']} AND gdo_number = '{r['gdo_number']}' AND status = 'ACTIVE';")
    sql_lines.append("")

sql_lines.append("COMMIT;")
sql_lines.append("")
sql_lines.append("-- ============================================================")
sql_lines.append("-- VERIFICATION (run after apply)")
sql_lines.append("-- ============================================================")
sql_lines.append("-- 1. CONFIRMED_MATCH UPDATEs landed")
sql_lines.append("--    SELECT gdo_number, max_frequency_days, permit_expiration::text")
sql_lines.append("--    FROM gdos WHERE gdo_number IN (...)")
sql_lines.append("-- 2. DEMOTE counts")
sql_lines.append("--    SELECT COUNT(*) FILTER (WHERE status='INACTIVE') FROM gdos")
sql_lines.append(f"--    -- Expected: 4 + {len(wrong_client_demote) + len(different_tenant_demote)} = "
                 f"{4 + len(wrong_client_demote) + len(different_tenant_demote)} INACTIVE total")
sql_lines.append("")

migration_path = ROOT / "docs" / "migrations" / "2026-05-25m_gdo_phase_2b_applies.sql"
migration_path.write_text("\n".join(sql_lines), encoding="utf-8")
print(f"Wrote {migration_path}")

# ----- Build Viktor Slack message -----
v = []
v.append("Phase 2b bot batch done. 50 GDOs through @GDO bot, results classified.\n")
v.append("**Distribution:**")
v.append(f"- CONFIRMED_MATCH: {len(confirmed_safe)} (safe `max_frequency_days` UPDATEs)")
v.append(f"- WRONG_CLIENT: {len(wrong_client_demote)} (DEMOTE — real GDO, wrong client linked)")
v.append(f"- DIFFERENT_TENANT: {len(different_tenant_demote)} (DEMOTE — no permit for our client at address)")
v.append(f"- WRONG_GDO_NUMBER: {len(wrong_gdo_review)} (**NEEDS DECISION** — bot has correct gdo_number, want me to re-link?)")
v.append(f"- AMBIGUOUS: {len(ambiguous)} (deferred, need your eye)\n")
v.append("**Critical bot quirk learned:** the bot's `facility_name` field grabs an "
         "unrelated permit at the same address — it's misleading. The reliable field is "
         "`issued_to` (e.g. \"NB2J INVESTMENTS, LLC DBA FRESKO\"). My classifier now keys "
         "off `issued_to` + `name_match`, which validates correctly.\n")
v.append("**Asks (in priority order):**\n")
v.append("1. **Approve draft migration `2026-05-25m`** which ships the 23 CONFIRMED_MATCH UPDATEs + "
         f"{len(wrong_client_demote) + len(different_tenant_demote)} demotes. Path: "
         "`docs/migrations/2026-05-25m_gdo_phase_2b_applies.sql`. "
         f"After ship: ACTIVE 131 -> {131 - len(wrong_client_demote) - len(different_tenant_demote)}, "
         f"max_frequency_days non-NULL 6 -> {6 + len(confirmed_safe)}.\n")
v.append(f"2. **WRONG_GDO_NUMBER ({len(wrong_gdo_review)} rows)** — bot's "
         "`issued_to` confirms our CLIENT but says we have the wrong gdo_number. Options:")
v.append("   - (a) UPDATE `gdo_number` in place (keeps row id + audit chain; simple)")
v.append("   - (b) DEMOTE the wrong row + INSERT a new row with bot's gdo_number (cleaner history)")
v.append("   - (c) DEMOTE the wrong row, no insert (let ops verify before re-adding)")
v.append("   List:")
for r in wrong_gdo_review:
    actual = (r['bot'].get('issued_to') or r['bot'].get('facility_name') or '(no name)').strip()
    v.append(f"   - {r['client_code']} {r['client_name']} (id={r['id']}): "
             f"our `{r['gdo_number']}` -> bot `{r['bot']['gdo_number']}` "
             f"(`{trunc(actual, 50)}`)")
v.append("")
v.append(f"3. **AMBIGUOUS ({len(ambiguous)} rows)** — defer with reasoning:")
for r in ambiguous:
    v.append(f"   - {r['client_code']} {r['client_name']} (id={r['id']}, "
             f"`{r['gdo_number']}`): bot returned `{r['bot'].get('issued_to') or r['bot'].get('facility_name')}` — "
             "edge case, want your judgment.")
v.append("")
v.append("4. Anything you want me to spot-check from the 23 CONFIRMED_MATCH before I apply?\n")

(HERE / "phase_2b_viktor_message.md").write_text("\n".join(v), encoding="utf-8")
print("Wrote phase_2b_viktor_message.md")
print("\nDone. Review the .md files before sending the Slack message.")
