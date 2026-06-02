// receipt_ocr_prompts.js — versioned prompts for the receipt-OCR skill.
// Each version is immutable once first used in a calibration batch — if you
// want to tune the prompt, ADD a new version and bump CURRENT_VERSION.

const v1 = `This is a disposal facility receipt photo from a grease-trap pumping operation. It will be ONE of these document types:

(A) BROWARD COUNTY SEPTAGE RECEIVING RECEIPT — has "Broward County" / "SEPTAGE RECEIVING FACILITY" header, fields like "Ticket Number", "Ticket Date", "EPD Decal", "Customer", "Waste Volume". The ticket number is typically 6 digits like "305031".

(B) MIAMI-DADE DERM disposal receipt — has Miami-Dade county or DERM markings, with a printed manifest number typically 6 digits like "824533" and a date field.

(C) Something else — a FOG eManifest form, a generic photo, or unreadable.

Extract THREE values and return ONLY a single-line JSON object with these keys (no markdown fences, no other text):

{"jurisdiction":"broward"|"dade"|"unknown", "number":"<digits or null>", "dump_date":"<YYYY-MM-DD or null>"}

- "jurisdiction": which county/jurisdiction issued this receipt
- "number": the ticket number (Broward) or manifest number (Miami-Dade) — JUST digits, no prefix, no separator
- "dump_date": the date the waste was dumped/received at the facility, normalized to YYYY-MM-DD. Often appears below the ticket number. If multiple dates appear, prefer the one labeled "Ticket Date" / "Date Waste Received" / similar.

If any value is unreadable or missing, use null. If the document is type (C), return all-null with jurisdiction "unknown".

Example responses:
{"jurisdiction":"broward","number":"305031","dump_date":"2026-05-14"}
{"jurisdiction":"dade","number":"824533","dump_date":"2026-05-15"}
{"jurisdiction":"unknown","number":null,"dump_date":null}`;

// v2 — 2026-05-19 — added based on v1 calibration failures:
//   - manifest 42 produced "2020-02-31" (Feb 31 doesn't exist, year wrong)
//   - manifest 35 stored 7-digit but typical is 6 (AT data quality issue)
//   - manifests 35, 43 had off-by-one digit reads
//   - manifest 33 returned partial data instead of full null
const v2 = `This is a disposal facility receipt photo from a grease-trap pumping operation. It will be ONE of these document types:

(A) BROWARD COUNTY SEPTAGE RECEIVING RECEIPT — has "Broward County" / "SEPTAGE RECEIVING FACILITY" header, fields like "Ticket Number", "Ticket Date", "EPD Decal", "Customer", "Waste Volume". The ticket number is typically 6 digits like "305031".

(B) MIAMI-DADE DERM disposal receipt — has Miami-Dade county or DERM markings, with a printed manifest number typically 6 digits like "824533" and a date field.

(C) Something else — a FOG eManifest form, a generic photo, or unreadable.

Extract THREE values and return ONLY a single-line JSON object with these keys (no markdown fences, no other text):

{"jurisdiction":"broward"|"dade"|"unknown", "number":"<digits or null>", "dump_date":"<YYYY-MM-DD or null>"}

CRITICAL RULES:
1. The number is ALMOST ALWAYS exactly 6 digits. If you can only see 5 or fewer digits clearly, return null — don't guess missing digits. If you see what appears to be 7+ digits, look again — you may be including a date or another field's digits. Read the digits one at a time and confirm count.
2. The dump_date MUST be a valid calendar date (Feb has at most 29 days, etc.). If your extraction would produce an invalid date like "2020-02-31", return null instead — that's a sign you've misread.
3. The year on these receipts is almost always 2024, 2025, or 2026 (this is a current operation). If you read "2020" or earlier, you've misread — return null for the date.
4. If the document is type (C), return all-null with jurisdiction "unknown" — don't try to extract partial data.
5. Read each digit and each date character TWICE before committing. Handwritten 4 vs 9, 1 vs 7, 3 vs 8 are common confusion pairs.

- "jurisdiction": which county/jurisdiction issued this receipt
- "number": the ticket number (Broward) or manifest number (Miami-Dade) — JUST digits, no prefix, no separator
- "dump_date": the date the waste was dumped/received at the facility, normalized to YYYY-MM-DD. Often appears below the ticket number. If multiple dates appear, prefer the one labeled "Ticket Date" / "Date Waste Received" / similar.

Example responses:
{"jurisdiction":"broward","number":"305031","dump_date":"2026-05-14"}
{"jurisdiction":"dade","number":"824533","dump_date":"2026-05-15"}
{"jurisdiction":"unknown","number":null,"dump_date":null}`;

module.exports = {
  CURRENT_VERSION: 'v2',
  v1,
  v2,
};
