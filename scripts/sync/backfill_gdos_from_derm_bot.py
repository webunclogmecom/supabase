"""
backfill_gdos_from_derm_bot.py

For each active Dade client with a GT service config but no GDO in our DB,
look up the permit via the Miami-Dade DERM bot (Slack/DERM/gdo_bot_prod).
When a confident match comes back, INSERT into public.gdos.

Trust order per Fred 2026-05-22:
  1. GDO Bot (Miami-Dade DERM website — source of truth)
  2. AT cross-reference (already imported in 2026-05-22 backfill)

This script only fills the GAP — clients with no GDO at all.

Per CLAUDE.md rules:
  - 3NF: gdos table shape unchanged.
  - Audit trigger fires on gdos INSERT.
  - Idempotent: skips clients that already gained a GDO between dry-run and execute.
  - Confidence-gated: only inserts when name_match=true OR address_verified=true
    AND gdo_number starts with "GDO-". Unconfident hits go to a manual-review list.

Run:
  python scripts/sync/backfill_gdos_from_derm_bot.py            # dry-run
  python scripts/sync/backfill_gdos_from_derm_bot.py --execute  # write
"""
from __future__ import annotations

import asyncio
import os
import re
import sys
from pathlib import Path

import httpx
from dotenv import load_dotenv

# Wire the bot module — it lives in ../../Slack/DERM/gdo_bot_prod
REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT.parent / "Slack" / "DERM"))
from gdo_bot_prod.derm_lookup import lookup_gdo_permit  # noqa: E402

load_dotenv(REPO_ROOT / ".env", override=True)

SUPABASE_URL = os.environ["SUPABASE_URL"]
KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
PAT = os.environ["SUPABASE_PAT"]
PROJECT = os.environ["SUPABASE_PROJECT_ID"]
EXECUTE = "--execute" in sys.argv

H = {"apikey": KEY, "Authorization": f"Bearer {KEY}", "Content-Type": "application/json"}

ZIP_RE = re.compile(r"\b(\d{5})\b")
HOUSE_RE = re.compile(r"^\s*(\d+)")  # leading digits = house number


def extract_house_and_zip(address: str) -> tuple[str, str]:
    if not address:
        return ("", "")
    house = ""
    m = HOUSE_RE.match(address)
    if m:
        house = m.group(1)
    zip_code = ""
    z = ZIP_RE.search(address)
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


async def rest_insert(table: str, row: dict, on_conflict: str | None = None) -> None:
    qs = f"?on_conflict={on_conflict}" if on_conflict else ""
    async with httpx.AsyncClient(timeout=30) as client:
        r = await client.post(
            f"{SUPABASE_URL}/rest/v1/{table}{qs}",
            headers={**H, "Prefer": "resolution=ignore-duplicates,return=minimal"},
            json=row,
        )
        if r.status_code >= 300:
            raise RuntimeError(f"REST {r.status_code}: {r.text[:200]}")


async def main() -> None:
    print(f"Mode: {'EXECUTE' if EXECUTE else 'DRY-RUN'}\n")

    # 1) Pull the gap list (deduped, no food trucks/residences)
    rows = await sql_query("""
        SELECT DISTINCT ON (c.id)
          c.id, c.client_code, c.name,
          p.id AS property_id, p.address, p.city, p.zip
        FROM clients c
        JOIN properties p ON p.client_id = c.id AND p.is_primary = true
        JOIN service_configs sc ON sc.client_id = c.id
        WHERE c.status IN ('ACTIVE','RECURRING')
          AND p.county = 'Dade'
          AND sc.service_type = 'GT'
          AND NOT EXISTS (SELECT 1 FROM gdos g WHERE g.client_id = c.id)
          AND c.name !~* '(truck|food truck|residence)'
        ORDER BY c.id, p.id;
    """)
    print(f"{len(rows)} Dade GT clients needing GDO lookup\n")

    found_confident = []
    found_unconfident = []
    not_found = []
    errors = []

    for i, row in enumerate(rows, 1):
        addr = row.get("address") or ""
        house, zip_code = extract_house_and_zip(addr)
        if not zip_code:
            zip_code = (row.get("zip") or "")[:5]
        name = row.get("name") or ""
        code = row.get("client_code") or "?"
        print(f"[{i}/{len(rows)}] {code} {name[:40]:<40} | house={house or '?':<6} zip={zip_code or '?':<5}")
        try:
            res = await lookup_gdo_permit(
                house_number=house,
                zip_code=zip_code,
                facility_name=name,
            )
        except Exception as e:
            print(f"          ERROR: {str(e)[:100]}")
            errors.append({"client": code, "name": name, "error": str(e)[:200]})
            continue

        if not res.get("found"):
            print("          → not found")
            not_found.append({"client": code, "name": name, "address": addr})
            continue

        gdo = res.get("gdo_number") or ""
        # Tighter rule (2026-05-22): require BOTH signals. Same address often
        # hosts multiple tenants — address_verified alone routinely surfaces
        # the wrong neighbor's GDO. Name-match alone surfaces same-named
        # chains at different addresses. Both together is the safe bar.
        confident = bool(res.get("name_match") and res.get("address_verified"))
        gdo_ok = bool(re.match(r"^GDO-\d{3,6}$", gdo))

        if confident and gdo_ok:
            print(f"          ✓ {gdo} ({res.get('facility_name') or res.get('issued_to')})")
            found_confident.append({
                "client_id": row["id"],
                "client_code": code,
                "property_id": row["property_id"],
                "gdo_number": gdo,
                "facility_name": res.get("facility_name"),
                "issued_to": res.get("issued_to"),
                "expiration_date": res.get("expiration_date"),
                "frequency_days": res.get("frequency_days"),
                "pdf_url": res.get("pdf_url"),
            })
        else:
            cand_count = len(res.get("candidates") or [])
            print(f"          ? {gdo or '(none)'} unconfident — {cand_count} candidates")
            found_unconfident.append({
                "client": code, "name": name,
                "top": {"gdo": gdo, "facility": res.get("facility_name")},
                "candidates": res.get("candidates"),
            })

    print(f"\n=== Summary ===")
    print(f"  confident matches:   {len(found_confident)}")
    print(f"  unconfident matches: {len(found_unconfident)}")
    print(f"  not found:           {len(not_found)}")
    print(f"  errors:              {len(errors)}")

    if not EXECUTE:
        print("\n[DRY-RUN] No writes. Re-run with --execute to insert confident matches.")
        if found_unconfident:
            print(f"\nUnconfident matches (review manually):")
            for u in found_unconfident:
                print(f"  {u['client']} {u['name']}")
                print(f"    top: {u['top']}")
                if u.get('candidates'):
                    for c in u['candidates'][:3]:
                        print(f"      cand: {c.get('gdo_number')} | {c.get('facility_name')}")
        return

    # Insert confident matches
    print(f"\nInserting {len(found_confident)} confident GDOs...")
    written = 0
    for c in found_confident:
        try:
            await rest_insert(
                "gdos",
                {
                    "client_id": c["client_id"],
                    "property_id": c["property_id"],
                    "gdo_number": c["gdo_number"],
                    "location_label": c.get("facility_name"),
                    "permit_expiration": c.get("expiration_date"),
                    "permit_document_path": c.get("pdf_url"),
                    "status": "ACTIVE",
                    "notes": f"Source: DERM Bot scrape {('matched ' + c['client_code']) if c.get('client_code') else ''}",
                },
                on_conflict="client_id,gdo_number",
            )
            written += 1
        except Exception as e:
            print(f"  insert fail ({c['client_code']}):", str(e)[:120])
    print(f"\n  Inserted {written} GDOs")

    # Final coverage check
    final = await sql_query("SELECT COUNT(*) AS total, COUNT(gdo_number) AS with_gdo FROM derm.visits;")
    print(f"  derm.visits GDO chip coverage: {final}")


if __name__ == "__main__":
    asyncio.run(main())
