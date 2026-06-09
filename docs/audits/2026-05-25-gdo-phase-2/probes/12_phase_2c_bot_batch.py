"""
12_phase_2c_bot_batch.py

Phase 2c bot batch — 50 of the 77 remaining ACTIVE rows with
max_frequency_days IS NULL. Same classifier + bucket rules as 2b.

Excludes:
  - id=72 Pura Vida 41 (Viktor: keep deferred even if it comes up in 2c)

Output: docs/gdo-phase-2-2026-05-25/probes/12_phase_2c_results.json

Same classification rules as 2b:
  CONFIRMED_MATCH    -> bot_gdo == our_gdo AND name_match=True
  WRONG_CLIENT       -> bot_gdo == our_gdo AND name_match=False AND addr_ver
  WRONG_GDO_NUMBER   -> bot_gdo != our_gdo AND name_match (NEW STANDING RULE:
                        also check no conflict with existing gdo_number first;
                        if conflict -> reclass DEMOTE during analysis)
  DIFFERENT_TENANT   -> bot_gdo != our_gdo AND addr_ver AND not name_match
  NO_PERMIT          -> bot returned not-found
  UNCERTAIN          -> weak signal

Run: python docs/gdo-phase-2-2026-05-25/probes/12_phase_2c_bot_batch.py [--limit N]
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

HERE = Path(__file__).parent
REPO_ROOT = HERE.parents[2]  # HERE=probes/, [0]=phase dir, [1]=docs/, [2]=Supabase/
sys.path.insert(0, str(REPO_ROOT.parent / "Slack" / "DERM"))
from gdo_bot_prod.derm_lookup import lookup_gdo_permit  # noqa: E402

load_dotenv(REPO_ROOT / ".env", override=True)

PAT = os.environ["SUPABASE_PAT"]
PROJECT = os.environ["SUPABASE_PROJECT_ID"]
OUTPUT_PATH = HERE / "12_phase_2c_results.json"

# Pura Vida 41 stays deferred per Viktor 2026-05-25 PM
EXCLUDE_IDS = {72}

ZIP_RE = re.compile(r"\b(\d{5})\b")
HOUSE_RE = re.compile(r"^\s*(\d+)")


def extract_house_and_zip(address: str, fallback_zip: str = "") -> tuple[str, str]:
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
    if not bot_res.get("found"):
        return "NO_PERMIT"
    bot_gdo = (bot_res.get("gdo_number") or "").strip()
    name_match = bool(bot_res.get("name_match"))
    addr_ver = bool(bot_res.get("address_verified"))
    if bot_gdo == our_gdo and name_match:
        return "CONFIRMED_MATCH"
    if bot_gdo == our_gdo and not name_match and addr_ver:
        return "WRONG_CLIENT"
    if bot_gdo and bot_gdo != our_gdo and name_match:
        return "WRONG_GDO_NUMBER"
    if bot_gdo and bot_gdo != our_gdo and addr_ver and not name_match:
        return "DIFFERENT_TENANT"
    return "UNCERTAIN"


async def main() -> None:
    exclude_list = ",".join(str(i) for i in EXCLUDE_IDS)

    # Pull all 77 ACTIVE rows with NULL max_frequency_days, exclude defer ids,
    # take 50.
    print("--- Pulling Phase 2c pool (ACTIVE, max_freq NULL, ex Pura Vida 41) ---")
    pool = await sql_query(f"""
        SELECT g.id, g.gdo_number, g.location_label, g.max_frequency_days,
               g.permit_expiration::text AS permit_expiration,
               c.client_code, c.name AS client_name,
               p.address, p.zip
        FROM public.gdos g
        JOIN public.clients c ON c.id = g.client_id
        JOIN public.properties p ON p.id = g.property_id
        WHERE g.status = 'ACTIVE'
          AND g.max_frequency_days IS NULL
          AND g.id NOT IN ({exclude_list})
          AND p.address IS NOT NULL
        ORDER BY g.id;
    """)
    print(f"  {len(pool)} eligible rows")

    # Cap (default 50, --limit N for smoke tests)
    limit = 50
    for i, arg in enumerate(sys.argv):
        if arg == "--limit" and i + 1 < len(sys.argv):
            limit = int(sys.argv[i + 1])
    batch = pool[:limit]
    print(f"--- Batch size: {len(batch)} ---\n")

    results = []
    for i, row in enumerate(batch, 1):
        addr = row.get("address") or ""
        house, zip_code = extract_house_and_zip(addr, row.get("zip") or "")
        name = row.get("client_name") or ""
        code = row.get("client_code") or "?"
        our_gdo = row.get("gdo_number") or ""

        print(
            f"[{i}/{len(batch)}] id={row['id']:>3} {our_gdo:<11} {code:<10} "
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
