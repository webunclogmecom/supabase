// gdo-permit-scan: read a Miami-Dade DERM GDO permit from its PICTURE with Claude, for a PDF with no readable text.
// Moved VERBATIM from gdo-lookup/index.ts on 2026-11-24 (its pick E1, Trello #242) so parse-gdo-permit can use the same
// reader (Trello #227, Fred: "do we use the Anthropic scan for it like we do for the Monthly report?" -> "yes").
// Text PDFs are read by gdo-permit-read.ts; this is only for what that reader cannot read.
// ⚠ Every answer is a suggestion for a person to check against the PDF: the frequency drives compliance, and a
// scan's penalty text ("sixty (60) days in jail") sits on the same page. scanFields keeps 1..365 days only.
// Models and keys: docs/reference/anthropic-api-usage.md.

import Anthropic from "npm:@anthropic-ai/sdk";

const MODEL = "claude-opus-5-5";
const ISO = /^\d{4}-\d{2}-\d{2}$/;
const digitsOf = (n: string) => String(Number(String(n).replace(/\D/g, "")));
const six = (n: string) => "GDO-" + digitsOf(n).padStart(6, "0");

function b64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

const SCAN_PROMPT =
  "This file comes from Miami-Dade County's public list of grease (GDO) operating permits. It may be a scanned " +
  "picture. Read ONLY these facts from the permit itself: the permit number (e.g. GDO-014655), the business it is " +
  "issued to exactly as printed after \"Permit Issued To:\" or in the PERMITTEE block (the company, never a person's " +
  "name), the facility location (street address, unit, city, ZIP), the dates the permit is valid from and through " +
  "(as YYYY-MM-DD), and how often the grease trap must be cleaned at a minimum, in days. Leave out everything else: " +
  "never return a contact person, a mailing address, a password or a PIN. Use null for a fact you cannot read with " +
  "certainty. Set is_permit to false if this is not a GDO operating permit.";

const SCAN_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["is_permit", "permit_number", "issued_to", "facility_location", "valid_from", "valid_through", "cleaning_every_days"],
  properties: {
    is_permit: { type: "boolean" },
    permit_number: { anyOf: [{ type: "string" }, { type: "null" }] },
    issued_to: { anyOf: [{ type: "string" }, { type: "null" }] },
    facility_location: { anyOf: [{ type: "string" }, { type: "null" }] },
    valid_from: { anyOf: [{ type: "string", format: "date" }, { type: "null" }] },
    valid_through: { anyOf: [{ type: "string", format: "date" }, { type: "null" }] },
    cleaning_every_days: { anyOf: [{ type: "integer" }, { type: "null" }] },
  },
};

let anthropic: Anthropic | null = null;

/** Pick E1: a permit the county only has as a scan, read from its picture. */
export async function readScan(pdf: Uint8Array) {
  anthropic ??= new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  // claude-opus-5-5: thinking cannot be turned off, effort is the control; the default server-side fallback answers a
  // refusal on another model inside the same call (as gdo-permit-label).
  // deno-lint-ignore no-explicit-any
  const msg: any = await anthropic.beta.messages.create({
    model: MODEL,
    max_tokens: 4000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low", format: { type: "json_schema", schema: SCAN_SCHEMA } },
    messages: [{
      role: "user",
      content: [
        { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64(pdf) } },
        { type: "text", text: SCAN_PROMPT },
      ],
    }],
  // deno-lint-ignore no-explicit-any
  } as any);
  if (msg.stop_reason === "refusal" || msg.stop_reason === "max_tokens") return { ok: false as const, why: msg.stop_reason };
  // deno-lint-ignore no-explicit-any
  const text = (msg.content ?? []).filter((c: any) => c?.type === "text").map((c: any) => c.text ?? "").join("");
  try {
    return { ok: true as const, out: JSON.parse(text) as Record<string, unknown>, model: String(msg.model ?? MODEL) };
  } catch {
    return { ok: false as const, why: "not_json" };
  }
}

/** The facts a scan read gave, each checked; null where the answer did not pass. */
// deno-lint-ignore no-explicit-any
export function scanFields(o: Record<string, any>) {
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim().slice(0, 200) : null);
  const num = str(o.permit_number);
  const days = typeof o.cleaning_every_days === "number" && o.cleaning_every_days > 0 && o.cleaning_every_days <= 365
    ? Math.round(o.cleaning_every_days) : null;
  const fields = {
    // 2026-11-24 (#227): only the digits right after "GDO", at most 6. Claude returns the permit years too
    // ("GDO-14769 2024-2025"), and six(num) of the whole answer gave "GDO-1476920242025" on 3 of 3 real scans.
    gdo_number: num && /GDO[-\s]*(\d{1,6})(?!\d)/i.test(num) ? six(num.match(/GDO[-\s]*(\d{1,6})(?!\d)/i)![1]) : null,
    issued_to: str(o.issued_to),
    facility_location: str(o.facility_location),
    permit_effective: ISO.test(String(o.valid_from)) ? String(o.valid_from) : null,
    permit_expiration: ISO.test(String(o.valid_through)) ? String(o.valid_through) : null,
    max_frequency_days: days,
    capacity_gpm: null,
  };
  return fields;
}
