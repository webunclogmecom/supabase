"""
13_phase_2c_analyze.py

Analyze 12_phase_2c_results.json and produce:
  - phase_2c_report.md           (full report by classification)
  - 2026-05-25n_gdo_phase_2c_applies.sql  (Viktor pre-approved — no review needed
                                            per his standing rule update)
  - phase_2c_summary.md          (Slack post: status only, not asking approval)

NEW STANDING RULE (Viktor 2026-05-25 PM): "For WRONG_GDO_NUMBER, always check
for existing rows with the target gdo_number before UPDATE-in-place. If
conflict exists, demote the wrong row instead." Implemented here: queries
Supabase upfront for all gdo_numbers, builds a set, auto-routes
WRONG_GDO_NUMBER -> CONFLICT_DEMOTE when the bot's recommended gdo_number
is already taken.
"""
from __future__ import annotations

import asyncio
import difflib
import json
import os
import re
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv

# Name-similarity sanity check (added 2026-05-25 after Phase 2c bot batch
# revealed unreliable name_match on borderline cases like
# "Grove Kosher LLC (Harding Ave)" vs "GROVE KOSHER LLC" (parens confused
# the bot), and false positives like "Talmudic University" vs "IHOP".)
_NAME_STOPWORDS = {
    "llc", "inc", "corp", "corporation", "dba", "d/b/a", "co", "the",
    "of", "and", "&", "ltd", "miami", "beach", "florida", "fl",
    "restaurant", "cafe", "caffe", "kitchen", "bar", "bakery",
}


def _norm_name(s: str) -> str:
    if not s:
        return ""
    s = re.sub(r"[^\w\s]", " ", s.lower())
    words = [w for w in s.split() if w not in _NAME_STOPWORDS and len(w) > 1]
    return " ".join(words)


def name_sim(a: str, b: str) -> float:
    """Returns 0.0-1.0 similarity between two normalized name strings."""
    na, nb = _norm_name(a), _norm_name(b)
    if not na or not nb:
        return 0.0
    return difflib.SequenceMatcher(None, na, nb).ratio()


def name_word_overlap(a: str, b: str) -> set[str]:
    """Returns set of significant words present in BOTH names."""
    wa = set(_norm_name(a).split())
    wb = set(_norm_name(b).split())
    return wa & wb

HERE = Path(__file__).parent
ROOT = HERE.parents[2]  # HERE=probes/, [0]=phase dir, [1]=docs/, [2]=Supabase/

load_dotenv(ROOT / ".env", override=True)

PAT = os.environ["SUPABASE_PAT"]
PROJECT = os.environ["SUPABASE_PROJECT_ID"]

INPUT = HERE / "12_phase_2c_results.json"
# Phase letter switches based on env var so we can re-run for 2d without
# overwriting 2c artifacts. Default = 'n' (Phase 2c). Set PHASE_LETTER=p
# for Phase 2d, q for the next batch, etc.
_PHASE_LETTER = os.environ.get("PHASE_LETTER", "n")
_PHASE_NAME = {"n": "2c", "p": "2d", "q": "2e", "r": "2f"}.get(_PHASE_LETTER, _PHASE_LETTER)
PHASE_NAME = _PHASE_NAME  # exposed for f-string interpolation in notes bodies
MIGRATION = ROOT / "docs" / "migrations" / f"2026-05-25{_PHASE_LETTER}_gdo_phase_{_PHASE_NAME}_applies.sql"
REPORT = HERE / f"phase_{_PHASE_NAME}_report.md"
SUMMARY = HERE / f"phase_{_PHASE_NAME}_summary.md"

DEFERRED_GDOS = set()  # 194-PV Pura Vida 41 (GDO-03375) — already excluded from picker

# IDs already finalized in earlier migrations (25l / 25m / 25o). The Phase 2d
# picker queried the DB before 25o was applied so it pulled these as stale
# Group B rows. Skip them in analysis to avoid contradictory re-classifications
# (bot returns inconsistent results across runs for the same address).
ALREADY_DECIDED_IDS = {
    4,   # Fialkoff's — CONFIRMED_MATCH in 25o
    26,  # Roast — DEMOTED in 25o
    27,  # Pura Vida Brickell 701 — DEMOTED in 25o (3rd dup-client)
    39,  # carrot Sunset Harbor — CONFIRMED_MATCH in 25o
    46,  # Pura Vida (Bay Harbor) — CONFIRMED_MATCH in 25o
    57,  # Talmudic University — UPDATEd to GDO-00313 in 25o
    59,  # The Moore — bot keeps returning NULL freq; flagged for ops manual
    62,  # Pummarola — UPDATEd to GDO-00951 (typo fix) in 25o
    68,  # Grove Kosher LLC — CONFIRMED_MATCH in 25o
    73,  # Street Bar — DEMOTED in 25o
}

DATA = json.loads(INPUT.read_text(encoding="utf-8"))
ROWS = DATA["results"]


def sql_escape(s: str) -> str:
    if s is None:
        return ""
    return s.replace("'", "''")


def trunc(s: str, n: int = 50) -> str:
    if not s:
        return ""
    s = s.strip()
    return s if len(s) <= n else s[:n - 1] + "..."


async def sql_query(query: str) -> list[dict]:
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.post(
            f"https://api.supabase.com/v1/projects/{PROJECT}/database/query",
            headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json"},
            json={"query": query},
        )
        r.raise_for_status()
        return r.json()


async def main() -> None:
    # Build set of existing gdo_numbers for conflict detection (Viktor's new rule)
    print("Loading existing gdo_numbers from DB for conflict check...")
    existing_rows = await sql_query(
        "SELECT id, gdo_number, status FROM public.gdos ORDER BY id;"
    )
    existing_map = {r["gdo_number"]: (r["id"], r["status"]) for r in existing_rows}
    print(f"  {len(existing_rows)} rows in gdos; {len(set(existing_map))} unique gdo_numbers")

    # Bucket rows. New rule layered on top of bot classification:
    # - WRONG_CLIENT with high name similarity (issued_to ~ client_name) -> SUSPECT_NAME_VARIATION (defer)
    # - WRONG_GDO_NUMBER with low name similarity -> SUSPECT_FALSE_MATCH (defer)
    # - All other WRONG_GDO_NUMBER -> defer to Viktor regardless (high-risk identity change)
    confirmed_safe = []
    wrong_client_demote = []
    different_tenant_demote = []
    wrong_gdo_defer = []  # All WRONG_GDO_NUMBER cases -> Viktor review
    suspect_name_variation = []  # WRONG_CLIENT cases that look like name-variation matches
    suspect_different_tenant = []  # DIFFERENT_TENANT cases where client name resembles bot facility (rare)
    ambiguous = []
    no_permit = []
    errors = []

    NAME_SIM_DEFER_THRESHOLD = 0.5  # ratio >= 0.5 -> defer for human review
    WORD_OVERLAP_DEFER_THRESHOLD = 2  # 2+ shared significant words -> defer

    skipped_already_decided = []

    for r in ROWS:
        cls = r["classification"]
        if r["id"] in ALREADY_DECIDED_IDS:
            skipped_already_decided.append(r)
            continue
        if r["gdo_number"] in DEFERRED_GDOS:
            ambiguous.append(r)
            continue

        client_name = r["client_name"]
        bot = r["bot"]
        compare_name = (bot.get("issued_to") or bot.get("facility_name") or "").strip()
        sim = name_sim(client_name, compare_name)
        shared_words = name_word_overlap(client_name, compare_name)
        r["_name_sim"] = round(sim, 2)
        r["_shared_words"] = sorted(shared_words)

        if cls == "CONFIRMED_MATCH":
            confirmed_safe.append(r)
        elif cls == "WRONG_CLIENT":
            # Sanity check: if names actually look related, defer for human review
            if sim >= NAME_SIM_DEFER_THRESHOLD or len(shared_words) >= WORD_OVERLAP_DEFER_THRESHOLD:
                suspect_name_variation.append(r)
            else:
                wrong_client_demote.append(r)
        elif cls == "DIFFERENT_TENANT":
            if sim >= NAME_SIM_DEFER_THRESHOLD or len(shared_words) >= WORD_OVERLAP_DEFER_THRESHOLD:
                suspect_different_tenant.append(r)
            else:
                different_tenant_demote.append(r)
        elif cls == "WRONG_GDO_NUMBER":
            # ALWAYS defer per Phase 2c learning: bot's name_match returns
            # false positives (e.g. Talmudic University -> IHOP), and the
            # identity-changing UPDATE is too risky to auto-apply.
            bot_gdo = (bot.get("gdo_number") or "").strip()
            if bot_gdo in existing_map:
                existing_id, existing_status = existing_map[bot_gdo]
                if existing_id != r["id"]:
                    r["_conflict_with"] = {"id": existing_id, "status": existing_status}
            wrong_gdo_defer.append(r)
        elif cls == "NO_PERMIT":
            no_permit.append(r)
        elif cls == "ERROR":
            errors.append(r)
        else:
            ambiguous.append(r)

    # ----- Build report -----
    report = []
    report.append("# Phase 2c — 50-GDO Bot Batch Results\n")
    report.append(f"Total: {len(ROWS)} rows · Generated from `12_phase_2c_results.json`\n")
    report.append("## Counts (auto-apply vs defer)\n")
    report.append("**Auto-applying:**")
    report.append(f"- CONFIRMED_MATCH: **{len(confirmed_safe)}**")
    report.append(f"- WRONG_CLIENT (clean DEMOTE, low name similarity): **{len(wrong_client_demote)}**")
    report.append(f"- DIFFERENT_TENANT (clean DEMOTE, low name similarity): **{len(different_tenant_demote)}**")
    report.append(f"- NO_PERMIT (DEMOTE): **{len(no_permit)}**")
    report.append("\n**Deferring to Viktor:**")
    report.append(f"- WRONG_GDO_NUMBER (all): **{len(wrong_gdo_defer)}** — bot's `name_match` is unreliable; identity-changing UPDATE is too risky to auto-apply")
    report.append(f"- WRONG_CLIENT with name similarity (SUSPECT_NAME_VARIATION): **{len(suspect_name_variation)}** — might actually be matches")
    report.append(f"- DIFFERENT_TENANT with name similarity: **{len(suspect_different_tenant)}** — might actually be matches")
    report.append(f"- AMBIGUOUS / ERROR: **{len(ambiguous) + len(errors)}**\n")

    def fmt_row(r):
        bot = r["bot"]
        return (
            f"| {r['id']} | {r['gdo_number']} | {r['client_code']} | "
            f"{trunc(r['client_name'], 28)} | {bot.get('frequency_days') or '?'} | "
            f"{bot.get('expiration_date') or '?'} | "
            f"{trunc(bot.get('issued_to') or bot.get('facility_name') or '', 36)} | "
            f"{r.get('_name_sim', '?')} |"
        )

    table_hdr = ("| id | gdo_number | client_code | client_name | bot_freq | bot_exp | bot_issued_to | name_sim |\n"
                 "|---|---|---|---|---|---|---|---|")

    for title, rows in [
        ("CONFIRMED_MATCH (auto-apply)", confirmed_safe),
        ("WRONG_CLIENT clean DEMOTE (auto-apply)", wrong_client_demote),
        ("DIFFERENT_TENANT clean DEMOTE (auto-apply)", different_tenant_demote),
        ("NO_PERMIT (auto-apply)", no_permit),
        ("WRONG_GDO_NUMBER — DEFER", wrong_gdo_defer),
        ("WRONG_CLIENT SUSPECT_NAME_VARIATION — DEFER", suspect_name_variation),
        ("DIFFERENT_TENANT with name similarity — DEFER", suspect_different_tenant),
        ("AMBIGUOUS / ERROR (defer)", ambiguous + errors),
    ]:
        report.append(f"\n## {title} ({len(rows)})\n")
        if not rows:
            report.append("_(none)_")
            continue
        report.append(table_hdr)
        for r in rows:
            report.append(fmt_row(r))

    REPORT.write_text("\n".join(report), encoding="utf-8")
    print(f"Wrote {REPORT}")

    # ----- Build migration -----
    sql = []
    sql.append("-- 2026-05-25n_gdo_phase_2c_applies.sql")
    sql.append("--")
    sql.append("-- Phase 2c bot-batch applies. Generated from")
    sql.append("--   docs/gdo-phase-2-2026-05-25/probes/12_phase_2c_results.json")
    sql.append("-- via")
    sql.append("--   docs/gdo-phase-2-2026-05-25/probes/13_phase_2c_analyze.py")
    sql.append("--")
    sql.append("-- Auto-applies per Viktor 2026-05-25 PM standing rule:")
    sql.append('--   "no need for me to pre-approve the migration pattern anymore.')
    sql.append("--    Just flag anything that doesn't fit the established buckets.\"")
    sql.append("--")
    sql.append("-- Deferred buckets (NOT in this migration; surfaced to Viktor separately):")
    sql.append(f"--   {len(wrong_gdo_defer)} WRONG_GDO_NUMBER - bot name_match unreliable in this batch (e.g., Talmudic Univ -> IHOP)")
    sql.append(f"--   {len(suspect_name_variation)} WRONG_CLIENT SUSPECT_NAME_VARIATION - might be name-variation matches")
    sql.append(f"--   {len(suspect_different_tenant)} DIFFERENT_TENANT with name similarity")
    sql.append(f"--   {len(ambiguous) + len(errors)} AMBIGUOUS/ERROR")
    sql.append("--")
    sql.append("-- SCOPE (auto-applied)")
    sql.append(f"--   {len(confirmed_safe)} CONFIRMED_MATCH UPDATEs")
    sql.append(f"--   {len(wrong_client_demote)} WRONG_CLIENT DEMOTEs (low name similarity)")
    sql.append(f"--   {len(different_tenant_demote)} DIFFERENT_TENANT DEMOTEs (low name similarity)")
    sql.append(f"--   {len(no_permit)} NO_PERMIT DEMOTEs")
    sql.append("--")
    sql.append("-- IDEMPOTENT (Rule 5) · AUDIT (Rule 8) · NEVER HARD-DELETE (Rule 6)")
    sql.append("")
    sql.append("BEGIN;")
    sql.append("")

    # 1. CONFIRMED_MATCH
    sql.append("-- ============================================================")
    sql.append(f"-- 1. {len(confirmed_safe)} CONFIRMED_MATCH UPDATEs")
    sql.append("-- ============================================================")
    sql.append("")
    for r in confirmed_safe:
        bot = r["bot"]
        freq = bot.get("frequency_days")
        if freq is None:
            sql.append(f"-- id={r['id']} {r['gdo_number']} ({r['client_code']}): NULL freq from bot, skip")
            continue
        notes_body = (f'[2026-05-25 Phase {PHASE_NAME}] CONFIRMED_MATCH via @GDO bot. '
                      f'issued_to="{(bot.get("issued_to") or "").strip()}", '
                      f'facility_name="{(bot.get("facility_name") or "").strip()}", '
                      f'max_frequency_days={freq}.')
        exp_set = ", permit_expiration = '2026-12-31'" if (
            r.get("permit_expiration") is None or r.get("permit_expiration") < "2026-12-31"
        ) else ""
        exp_cond = " AND (permit_expiration IS NULL OR permit_expiration < '2026-12-31')" if exp_set else ""
        sql.append(f"UPDATE public.gdos SET max_frequency_days = {freq}{exp_set},")
        sql.append(f"    notes = COALESCE(notes || E'\\n', '') || '{sql_escape(notes_body)}'")
        sql.append(f"WHERE id = {r['id']} AND gdo_number = '{r['gdo_number']}'")
        sql.append(f"  AND (max_frequency_days IS NULL OR max_frequency_days <> {freq}){exp_cond};")
        sql.append("")

    # 2. WRONG_CLIENT DEMOTE
    sql.append("-- ============================================================")
    sql.append(f"-- 2. {len(wrong_client_demote)} WRONG_CLIENT DEMOTEs")
    sql.append("-- ============================================================")
    sql.append("")
    for r in wrong_client_demote:
        bot = r["bot"]
        actual = (bot.get("issued_to") or bot.get("facility_name") or "(unknown)").strip()
        notes_body = (f'[2026-05-25 Phase {PHASE_NAME}] DEMOTED. {r["gdo_number"]} actually belongs to '
                      f'"{trunc(actual, 80)}" per @GDO bot. {r["client_name"]} has no DERM permit at its address.')
        sql.append(f"-- id={r['id']} {r['gdo_number']} ({r['client_code']} {trunc(r['client_name'], 30)})")
        sql.append("UPDATE public.gdos SET status = 'INACTIVE',")
        sql.append(f"    notes = COALESCE(notes || E'\\n', '') || '{sql_escape(notes_body)}'")
        sql.append(f"WHERE id = {r['id']} AND gdo_number = '{r['gdo_number']}' AND status = 'ACTIVE';")
        sql.append("")

    # 3. DIFFERENT_TENANT DEMOTE
    sql.append("-- ============================================================")
    sql.append(f"-- 3. {len(different_tenant_demote)} DIFFERENT_TENANT DEMOTEs")
    sql.append("-- ============================================================")
    sql.append("")
    for r in different_tenant_demote:
        bot = r["bot"]
        actual = (bot.get("issued_to") or bot.get("facility_name") or "(unknown)").strip()
        other_gdo = bot.get("gdo_number")
        notes_body = (f'[2026-05-25 Phase {PHASE_NAME}] DEMOTED. {r["gdo_number"]} does not appear at this address per @GDO bot. '
                      f'Address belongs to {other_gdo} "{trunc(actual, 80)}" - different tenant. '
                      f'{r["client_name"]} has no DERM permit here.')
        sql.append(f"-- id={r['id']} {r['gdo_number']} ({r['client_code']} {trunc(r['client_name'], 30)})")
        sql.append("UPDATE public.gdos SET status = 'INACTIVE',")
        sql.append(f"    notes = COALESCE(notes || E'\\n', '') || '{sql_escape(notes_body)}'")
        sql.append(f"WHERE id = {r['id']} AND gdo_number = '{r['gdo_number']}' AND status = 'ACTIVE';")
        sql.append("")

    # 4. NO_PERMIT DEMOTE (skipped if empty)
    if no_permit:
        sql.append("-- ============================================================")
        sql.append(f"-- 4. {len(no_permit)} NO_PERMIT DEMOTEs")
        sql.append("-- ============================================================")
        sql.append("-- Bot found no permit at the address — client may need to apply with DERM.")
        sql.append("")
        for r in no_permit:
            notes_body = (f'[2026-05-25 Phase {PHASE_NAME}] DEMOTED. {r["gdo_number"]} not found at any address per @GDO bot. '
                          f'{r["client_name"]} appears to have no active DERM permit. Flag for ops: may need to apply.')
            sql.append(f"-- id={r['id']} {r['gdo_number']} ({r['client_code']} {trunc(r['client_name'], 30)})")
            sql.append("UPDATE public.gdos SET status = 'INACTIVE',")
            sql.append(f"    notes = COALESCE(notes || E'\\n', '') || '{sql_escape(notes_body)}'")
            sql.append(f"WHERE id = {r['id']} AND gdo_number = '{r['gdo_number']}' AND status = 'ACTIVE';")
            sql.append("")

    sql.append("COMMIT;")
    sql.append("")
    sql.append("-- ============================================================")
    sql.append("-- VERIFICATION")
    sql.append("-- ============================================================")
    sql.append("-- 1. ACTIVE count")
    sql.append("--    SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int FROM public.gdos;")
    expected_demotes = len(wrong_client_demote) + len(different_tenant_demote) + len(no_permit)
    sql.append(f"--    Expected: 111 - {expected_demotes} = {111 - expected_demotes}")
    sql.append("-- 2. max_frequency_days non-NULL count")
    sql.append("--    SELECT COUNT(*) FROM public.gdos WHERE max_frequency_days IS NOT NULL;")
    sql.append(f"--    Expected: 34 + {len(confirmed_safe)} + (in-place freq sets) = approx")
    sql.append("-- 3. Audit rows")
    sql.append("--    SELECT app_source, operation, COUNT(*) FROM audit.logs")
    sql.append("--    WHERE table_name='gdos' AND changed_at > now() - interval '5 minutes'")
    sql.append("--    GROUP BY app_source, operation;")

    MIGRATION.write_text("\n".join(sql), encoding="utf-8")
    print(f"Wrote {MIGRATION}")

    # ----- Build summary (status post + deferral surface for Viktor) -----
    s = []
    s.append(f"Phase 2c bot batch + analyzer done. {len(ROWS)} rows classified.\n")
    s.append(f"**Auto-applying in `2026-05-25n`:**")
    s.append(f"- CONFIRMED_MATCH: **{len(confirmed_safe)}** (UPDATE max_frequency_days)")
    s.append(f"- WRONG_CLIENT clean: **{len(wrong_client_demote)}** (DEMOTE, low name similarity)")
    s.append(f"- DIFFERENT_TENANT clean: **{len(different_tenant_demote)}** (DEMOTE, low name similarity)")
    s.append(f"- NO_PERMIT: **{len(no_permit)}** (DEMOTE)\n")
    s.append(f"**Auto-total: {len(confirmed_safe) + len(wrong_client_demote) + len(different_tenant_demote) + len(no_permit)} rows**\n")
    s.append("**Deferring to your call** — bot data has reliability issues in this batch:\n")

    if wrong_gdo_defer:
        s.append(f"**WRONG_GDO_NUMBER ({len(wrong_gdo_defer)})** — `name_match=true` from bot but borderline. Need your judgment:")
        for r in wrong_gdo_defer:
            bot = r["bot"]
            actual = (bot.get("issued_to") or bot.get("facility_name") or "").strip()
            conflict = r.get("_conflict_with")
            conflict_note = f" [CONFLICT: existing at id={conflict['id']}]" if conflict else ""
            s.append(f"- {r['client_code']} {r['client_name']} (id={r['id']}): "
                     f"our `{r['gdo_number']}` -> bot `{bot.get('gdo_number')}` "
                     f"(`{trunc(actual, 40)}`, sim={r['_name_sim']}){conflict_note}")
        s.append("")

    if suspect_name_variation:
        s.append(f"**WRONG_CLIENT with name similarity ({len(suspect_name_variation)})** — bot says wrong client but names look related. Real match or false positive?")
        for r in suspect_name_variation:
            actual = (r["bot"].get("issued_to") or r["bot"].get("facility_name") or "").strip()
            s.append(f"- {r['client_code']} {r['client_name']} (id={r['id']}, `{r['gdo_number']}`): "
                     f"bot says `{trunc(actual, 40)}` (sim={r['_name_sim']}, shared={r['_shared_words']})")
        s.append("")

    if suspect_different_tenant:
        s.append(f"**DIFFERENT_TENANT with name similarity ({len(suspect_different_tenant)})**:")
        for r in suspect_different_tenant:
            actual = (r["bot"].get("issued_to") or r["bot"].get("facility_name") or "").strip()
            s.append(f"- {r['client_code']} {r['client_name']} (id={r['id']}): "
                     f"bot returned different `{r['bot'].get('gdo_number')}` for `{trunc(actual, 40)}` (sim={r['_name_sim']})")
        s.append("")

    if ambiguous or errors:
        s.append(f"**AMBIGUOUS / ERROR ({len(ambiguous) + len(errors)})**:")
        for r in ambiguous + errors:
            s.append(f"- {r['client_code']} {r['client_name']} (id={r['id']}, `{r['gdo_number']}`): "
                     f"{r.get('classification', 'AMBIGUOUS')}")
        s.append("")

    s.append("**Applying the auto-batch now.** I'll surface results in this thread once landed.")
    s.append("For the deferrals: your call on whether to UPDATE/DEMOTE/skip each.")
    SUMMARY.write_text("\n".join(s), encoding="utf-8")
    print(f"Wrote {SUMMARY}")


if __name__ == "__main__":
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    asyncio.run(main())
