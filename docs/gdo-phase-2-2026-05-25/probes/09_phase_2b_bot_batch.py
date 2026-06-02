"""
09_phase_2b_bot_batch.py

Phase 2b: lookup permit info from the DERM bot for 50 existing GDOs and
classify each result as CONFIRMED_MATCH / WRONG_GDO_NUMBER / NO_PERMIT /
UNCERTAIN.

Difference vs. backfill_gdos_from_derm_bot.py: that script INSERTS net-new
GDOs. This script VERIFIES existing rows already in public.gdos and outputs
a structured JSON report for migration generation. No DB writes.

Output: docs/gdo-phase-2-2026-05-25/probes/09_phase_2b_results.json

Per Fred's domain rule + Viktor 2026-05-25 PM:
  - CONFIRMED_MATCH (name AND address verified, bot's gdo_number == ours)
      → UPDATE max_frequency_days + permit_expiration in migration 2026-05-25m
  - WRONG_GDO_NUMBER (bot returns a different GDO than ours at this address)
      → DEMOTE our row, capture correct GDO in notes, flag for re-link
  - NO_PERMIT (bot says no permit at address)
      → DEMOTE our row, flag for ops (client may need to apply)
  - UNCERTAIN (name XOR address, or multiple candidates with no clear winner)
      → Send to Viktor for review

Run: python docs/gdo-phase-2-2026-05-25/probes/09_phase_2b_bot_batch.py
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT.parent / "Slack" / "DERM"))
from gdo_bot_prod.derm_lookup import lookup_gdo_permit  # noqa: E402

load_dotenv(REPO_ROOT / ".env", override=True)

PAT = os.environ["SUPABASE_PAT"]
PROJECT = os.environ["SUPABASE_PROJECT_ID"]

OUTPUT_PATH = Path(__file__).parent / "09_phase_2b_results.json"

PHASE_2A_GDO_NUMBERS = {
    "GDO-10877", "GDO-15062", "GDO-16389",
    "GDO-01179", "GDO-15328", "GDO-00376",
    "GDO-14336", "GDO-01759", "GDO-10822", "GDO-11532",
}

ZIP_RE = re.compile(r"\b(\d{5})\b")
HOUSE_RE = re.compile(r"^\s*(\d+)")


def extract_house_and_zip(address: str, fallback_zip: str = "") -> tuple[str, str]:
    """Extract house # and zip.

    Prefer the DB's `zip` column (`fallback_zip`) over regex-on-address.
    Regex risks: the 5-digit ZIP_RE will match the house number when the
    address has no explicit ZIP (e.g. "19062 Northeast 29th Avenue, Miami"
    matched "19062" as the zip).
    """
    if not address:
        return ("", fallback_zip[:5] if fallback_zip else "")
    house = ""
    m = HOUSE_RE.match(address)
    if m:
        house = m.group(1)
    zip_code = ""
    if fallback_zip and re.match(r"^\d{5}", fallback_zip):
        zip_code = fallback_zip[:5]
    else:
        # Try to extract a 5-digit zip from the trailing portion of the
        # address (skip the leading house number).
        trailing = address[len(house):] if house else address
        z = ZIP_RE.search(trailing)
        if z:
            zip_code = z.group(1)
    return (house, zip_code)


async def sql_query(query: str) -> list[dict]:
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.post(
            f"https://api.supabase.com/v1/projects/{PROJECT}/database/query",
            headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json"},
            json={"query": query},
        )
        r.raise_for_status()
        return r.json()


def classify(our_gdo: str, bot_res: dict) -> str:
    """Classify a bot response against our DB row.

    The Phase 2a learning: bot-returned `address_verified=True` alone is
    NOT a confirmation — the address can host multiple tenants, and the
    bot may return a different tenant's GDO. The same applies when the
    GDO number matches ours: if `name_match=False`, the GDO at that
    address belongs to a DIFFERENT facility than our client, and we have
    a wrong client<->GDO link in the DB.
    """
    if not bot_res.get("found"):
        return "NO_PERMIT"
    bot_gdo = (bot_res.get("gdo_number") or "").strip()
    name_match = bool(bot_res.get("name_match"))
    addr_ver = bool(bot_res.get("address_verified"))
    # Strongest signal: same GDO number AND name match.
    if bot_gdo == our_gdo and name_match:
        return "CONFIRMED_MATCH"
    # Bot finds our exact GDO at the address but under a DIFFERENT facility
    # name. The GDO belongs to that other facility — our client is wrongly
    # linked. (This is the same failure mode as Phase 2a's 4 demotes.)
    if bot_gdo == our_gdo and not name_match and addr_ver:
        return "WRONG_CLIENT"
    # Bot finds a DIFFERENT GDO at the address that DOES name-match our
    # client. Our gdo_number is wrong — but the client has a real permit.
    if bot_gdo and bot_gdo != our_gdo and name_match:
        return "WRONG_GDO_NUMBER"
    # Bot finds a different GDO at the address that doesn't match our
    # client by name either.
    if bot_gdo and bot_gdo != our_gdo and addr_ver and not name_match:
        return "DIFFERENT_TENANT"
    # Bot returned something but it's weak signal.
    return "UNCERTAIN"


async def main() -> None:
    exclude_list = ",".join(f"'{n}'" for n in PHASE_2A_GDO_NUMBERS)

    # Group A: 15 ACTIVE rows with permit_expiration IS NULL
    print("--- Pulling Group A (NULL expiration) ---")
    group_a = await sql_query(f"""
        SELECT g.id, g.gdo_number, g.location_label, g.max_frequency_days,
               g.permit_expiration::text AS permit_expiration,
               c.client_code, c.name AS client_name,
               p.address, p.zip
        FROM public.gdos g
        JOIN public.clients c ON c.id = g.client_id
        JOIN public.properties p ON p.id = g.property_id
        WHERE g.status = 'ACTIVE'
          AND g.permit_expiration IS NULL
          AND g.gdo_number NOT IN ({exclude_list})
        ORDER BY g.gdo_number;
    """)
    print(f"  {len(group_a)} rows")

    # Group B: random 32 ACTIVE with max_frequency_days NULL and expiration set
    print("--- Pulling Group B (random max_freq NULL) ---")
    group_b = await sql_query(f"""
        SELECT g.id, g.gdo_number, g.location_label, g.max_frequency_days,
               g.permit_expiration::text AS permit_expiration,
               c.client_code, c.name AS client_name,
               p.address, p.zip
        FROM public.gdos g
        JOIN public.clients c ON c.id = g.client_id
        JOIN public.properties p ON p.id = g.property_id
        WHERE g.status = 'ACTIVE'
          AND g.max_frequency_days IS NULL
          AND g.permit_expiration IS NOT NULL
          AND g.gdo_number NOT IN ({exclude_list})
          AND p.address IS NOT NULL
        ORDER BY random()
        LIMIT 35;
    """)
    print(f"  {len(group_b)} rows")

    # Dedup by id (Group C was redundant with Group A)
    seen = set()
    merged: list[dict] = []
    for r in group_a + group_b:
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        merged.append(r)
    print(f"--- After dedup: {len(merged)} unique rows ---")

    # Cap at 50 for the batch (or --limit N for smoke tests)
    limit = 50
    for i, arg in enumerate(sys.argv):
        if arg == "--limit" and i + 1 < len(sys.argv):
            limit = int(sys.argv[i + 1])
    merged = merged[:limit]
    print(f"--- Capped to {len(merged)} for this batch ---\n")

    results = []
    for i, row in enumerate(merged, 1):
        addr = row.get("address") or ""
        house, zip_code = extract_house_and_zip(addr, row.get("zip") or "")
        name = row.get("client_name") or ""
        code = row.get("client_code") or "?"
        our_gdo = row.get("gdo_number") or ""

        print(
            f"[{i}/{len(merged)}] id={row['id']:>3} {our_gdo:<11} {code:<10} "
            f"{name[:40]:<40} | house={house or '?':<6} zip={zip_code or '?':<5}",
            flush=True,
        )
        try:
            res = await lookup_gdo_permit(
                house_number=house,
                zip_code=zip_code,
                facility_name=name,
            )
        except Exception as e:
            print(f"     ERROR: {str(e)[:140]}")
            results.append({
                **{k: row[k] for k in ("id", "gdo_number", "location_label",
                                       "max_frequency_days", "permit_expiration",
                                       "client_code", "client_name", "address", "zip")},
                "classification": "ERROR",
                "error": str(e)[:300],
            })
            continue

        cls = classify(our_gdo, res)
        bot_gdo = res.get("gdo_number") or ""
        facility = res.get("facility_name") or res.get("issued_to") or ""
        print(
            f"     -> {cls:<18} bot_gdo={bot_gdo or '(none)':<12} "
            f"freq={res.get('frequency_days') or '?'} "
            f"exp={res.get('expiration_date') or '?':<10} "
            f"facility={facility[:40]}"
        )

        results.append({
            **{k: row[k] for k in ("id", "gdo_number", "location_label",
                                   "max_frequency_days", "permit_expiration",
                                   "client_code", "client_name", "address", "zip")},
            "classification": cls,
            "bot": {
                "found": res.get("found"),
                "gdo_number": bot_gdo,
                "name_match": res.get("name_match"),
                "address_verified": res.get("address_verified"),
                "facility_name": res.get("facility_name"),
                "issued_to": res.get("issued_to"),
                "expiration_date": res.get("expiration_date"),
                "frequency_days": res.get("frequency_days"),
                "pdf_url": res.get("pdf_url"),
                "candidates": res.get("candidates"),
            },
        })

    # Summary
    summary = {"total": len(results)}
    for r in results:
        summary[r["classification"]] = summary.get(r["classification"], 0) + 1

    print("\n=== Summary ===")
    for k, v in sorted(summary.items()):
        print(f"  {k}: {v}")

    OUTPUT_PATH.write_text(json.dumps({"summary": summary, "results": results}, indent=2))
    print(f"\nWrote {OUTPUT_PATH}")


if __name__ == "__main__":
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    asyncio.run(main())
