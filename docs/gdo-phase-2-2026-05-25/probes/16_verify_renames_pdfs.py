"""
Triple-check post-hoc: download + read PDFs for the 8 in-place gdo_number
renames (Phase 2b/2c/2d) and verify the actual permit holder matches what
we recorded in the migrations.

The 8 renames are spread across 2 results JSONs:
  09_phase_2b_results.json  : 5 from Phase 2b (Hubble, La Granja S, Moore, PV Bakery, PV Flamingo)
  12_phase_2c_results.json  : 3 from Phase 2d (was overwritten from 2c) — Pummarola, Talmudic, Ironside

For each rename, pull the bot's pdf_url for the NEW gdo_number, download,
and verify the PDF text contains our client name (or our expected
issued_to). Output a verification table.
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
ROOT = HERE.parents[2]
load_dotenv(ROOT / ".env", override=True)

# The 8 in-place rename targets — paired with our expected key tokens
# (the issued_to substring we expected to find in the PDF).
RENAMES = [
    # id, client_code, client_name, old, new, expected_token
    (133, "208-HUB", "Hubble Bubble Lounge",     "GDO-08370", "GDO-16086", "HUBBLE BUBBLE"),
    (125, "036-LG",  "La Granja South Miami",    "GDO-12484", "GDO-11708", "LA GRANJA"),
    (59,  "148-MOR", "The Moore",                "GDO-11226", "GDO-14769", "MOORE"),
    (7,   "170-PV",  "Pura Vida Bakery",         "GDO-11433", "GDO-14681", "PURA VIDA"),
    (44,  "155-PV",  "Pura Vida Flamingo",       "GDO-12838", "GDO-10891", "PURA VIDA"),
    (62,  "132-PUM", "Pummarola",                "GDO-000951","GDO-00951", "PUMMAROLA"),
    (57,  "060-TU",  "Talmudic University",      "GDO-13076", "GDO-00313", "TALMUDIC"),
    (99,  "171-CAF", "Ironside Cafe",            "GDO-10248", "GDO-10249", "IRONSIDE"),
]

PDF_DIR = Path(os.environ.get("TEMP", os.environ.get("TMP", "/tmp"))) / "gdo-rename-verify"
PDF_DIR.mkdir(exist_ok=True)


def load_results():
    """Build a map of (gdo_number -> {pdf_url, issued_to, facility_name}) from both JSONs."""
    by_id = {}  # row id -> bot result row
    by_new_gdo = {}  # bot's returned gdo_number -> bot dict
    for fn in ("09_phase_2b_results.json", "12_phase_2c_results.json"):
        path = HERE / fn
        if not path.exists():
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        for r in data["results"]:
            by_id[r["id"]] = r
            bot_gdo = (r.get("bot", {}).get("gdo_number") or "").strip()
            if bot_gdo:
                by_new_gdo[bot_gdo] = r["bot"]
    return by_id, by_new_gdo


async def download(url: str, dest: Path) -> bool:
    if dest.exists() and dest.stat().st_size > 0:
        return True
    async with httpx.AsyncClient(timeout=60, follow_redirects=True) as client:
        try:
            r = await client.get(url)
            r.raise_for_status()
            dest.write_bytes(r.content)
            return True
        except Exception as e:
            print(f"     ERROR downloading: {str(e)[:120]}")
            return False


def extract_text_pdf(path: Path) -> str:
    """Lightweight PDF text extraction. Falls back to raw-byte search if pypdf isn't available."""
    try:
        from pypdf import PdfReader  # type: ignore
        reader = PdfReader(str(path))
        return "\n".join((p.extract_text() or "") for p in reader.pages)
    except ImportError:
        # Fall back to raw bytes string-extraction (good enough for case-insensitive substring search)
        return path.read_bytes().decode("latin-1", errors="ignore")
    except Exception as e:
        return f"(extraction failed: {e})"


def extract_text_tif(path: Path) -> str:
    """TIF (.tif) is an image. Can't extract text without OCR. Mark as needs-manual."""
    return "(TIF image — manual visual verification required)"


async def main() -> None:
    by_id, by_new_gdo = load_results()
    print(f"Loaded bot results: {len(by_id)} rows total, {len(by_new_gdo)} unique returned gdo_numbers\n")
    print(f"{'id':>4} {'client_code':<10} {'client_name':<28} {'new_gdo':<11} {'expected':<14} {'pdf_format':<5} {'match':<6} pdf_url")
    print("-" * 160)

    all_findings = []
    for (row_id, code, name, old, new, expected_token) in RENAMES:
        # Look up bot result for this row
        bot_for_row = by_id.get(row_id, {}).get("bot", {})
        bot_for_gdo = by_new_gdo.get(new, {})
        # Prefer the row's bot (matches the rename context); fall back to the by_gdo entry.
        bot = bot_for_row if bot_for_row.get("gdo_number") == new else bot_for_gdo
        pdf_url = (bot.get("pdf_url") or "").strip()
        if not pdf_url:
            print(f"{row_id:>4} {code:<10} {name[:28]:<28} {new:<11} {expected_token:<14} {'?':<5} {'NO-URL':<6} (no pdf_url in JSON)")
            all_findings.append({"id": row_id, "result": "NO_URL"})
            continue

        ext = ".pdf" if pdf_url.lower().endswith(".pdf") else ".tif"
        dest = PDF_DIR / f"{new}{ext}"
        ok = await download(pdf_url, dest)
        if not ok:
            print(f"{row_id:>4} {code:<10} {name[:28]:<28} {new:<11} {expected_token:<14} {ext[1:]:<5} {'DL-FAIL':<6} {pdf_url}")
            all_findings.append({"id": row_id, "result": "DL_FAIL"})
            continue

        if ext == ".pdf":
            text = extract_text_pdf(dest)
        else:
            text = extract_text_tif(dest)

        text_upper = text.upper() if text else ""
        match = expected_token.upper() in text_upper
        # Also try issued_to from bot for a second confirmation
        issued = (bot.get("issued_to") or "").upper()
        issued_token_present = any(w in text_upper for w in issued.split() if len(w) > 3) if issued else None

        result_marker = "OK" if match else ("MANUAL" if ext == ".tif" else "MISS")
        print(f"{row_id:>4} {code:<10} {name[:28]:<28} {new:<11} {expected_token:<14} {ext[1:]:<5} {result_marker:<6} {dest.name}")
        all_findings.append({
            "id": row_id, "client_name": name, "new_gdo": new,
            "expected_token": expected_token,
            "format": ext,
            "found_expected_token": match,
            "bot_issued_to": bot.get("issued_to"),
            "issued_to_tokens_present": issued_token_present,
            "pdf_path": str(dest),
            "result": result_marker,
        })

    print("\n=== Summary ===")
    for f in all_findings:
        if f["result"] == "OK":
            print(f"  ✓ id={f['id']} {f['client_name']:<28} new={f['new_gdo']}  PDF contains '{f['expected_token']}'")
        elif f["result"] == "MANUAL":
            print(f"  ? id={f['id']} {f['client_name']:<28} new={f['new_gdo']}  TIF image — open manually: {f['pdf_path']}")
        elif f["result"] == "MISS":
            print(f"  ✗ id={f['id']} {f['client_name']:<28} new={f['new_gdo']}  expected '{f['expected_token']}' NOT in PDF text. bot.issued_to={f['bot_issued_to']!r}")
        else:
            print(f"  - id={f['id']}  {f['result']}")

    out = HERE / "phase_2_pdf_verification.json"
    out.write_text(json.dumps(all_findings, indent=2))
    print(f"\nFull findings: {out}")


if __name__ == "__main__":
    os.environ.setdefault("PYTHONIOENCODING", "utf-8")
    asyncio.run(main())
