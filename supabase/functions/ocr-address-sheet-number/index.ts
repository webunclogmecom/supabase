// ocr-address-sheet-number — reads the sheet number DERM prints in the top-right corner of a
// scanned FOG address sheet, so the Stamp auto-place can tell whether the paper the driver
// actually filled in is the sheet WE generated.
//
// WHY THIS EXISTS
//   The auto-place positions stamps from the slot order of the sheet we generated. On ticket 831710
//   the driver used a pre-printed pad sheet (1008) instead of our generated sheet (1079), so a
//   client's stamp landed on another client's row of a compliance document. The causality guard
//   (2026-08-04_1912) catches sheets generated AFTER the dump; this catches the rest.
//
// 🛑 WE MAY NOT MARK THE SHEET. Fred 2026-08-04: "The sheets cannot have a QR Code ... the sheets
//    should only be filled with data ... adding a QR code is not valid." It is a regulator-facing
//    form. This READS what DERM already prints. A QR/barcode was proposed and rejected — do not
//    revive it as a "simpler" alternative to this function.
//
// WRITES derm.address_sheet_scan_reads ONLY. Never derm.address_sheets, never address_row_map.
//   The gate that consumes it is DISAGREEMENT-ONLY: a read naming a different sheet blocks
//   placement, no read means no opinion. So this function is never on the critical path, and a
//   failed run degrades to "not yet read" rather than to a wrong stamp.
//
// AUTH: verify_jwt=true (pinned in config.toml) PLUS an in-handler role gate. The gateway only
//   proves the JWT is signed, and the anon key is a validly signed JWT — so the handler must also
//   assert role=service_role. Same pattern as redact-manifest-sheet / jobber-push-visit.
//
// Invoked by pg_cron via public.fn_request_sheet_number_ocr() (Vault-backed service_role bearer).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");

const MODEL = "claude-sonnet-5";
const TIME_BUDGET_MS = 20000;   // edge CPU cap: stop cleanly rather than be killed mid-batch
const DEFAULT_LIMIT = 3;

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json" } });
}

function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

// Same shape as redact-manifest-sheet: PostgREST with the derm schema profile. There is no
// arbitrary-SQL RPC in this project and there should not be one.
const dermHeaders = {
  "Content-Type": "application/json",
  "Content-Profile": "derm",
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
};

// Anchored to the number's fixed position, and told to refuse rather than guess. A guessed number
// here is worse than none: a wrong read blocks a legitimate placement, or clears a bad one.
const PROMPT =
  'This is a scanned Miami-Dade DERM "Fats, Oils and Grease (FOG) Single Load Liquid Waste ' +
  'Transporter eManifest" address sheet. In the TOP RIGHT corner there is a large pre-printed ' +
  "sheet number, for example 1008, 1059, 1071, or a multi-page form like 1072-1 or 1072-2. " +
  "Report EXACTLY that number as printed, including any -1 / -2 page suffix. " +
  "Do not report the ticket number, the DERM decal number, the GDO numbers, the gallons, or any " +
  "handwritten value. Reply with ONLY the number, nothing else. " +
  "If you cannot read it clearly, or you are not certain it is the top-right sheet number, " +
  "reply with exactly: UNREADABLE";

// ⚠ These scans are NOT all jpeg. The live target list includes .JPG, .jpeg and .webp, and Anthropic
// rejects a mislabelled media type outright — an early version hardcoded png-or-jpeg and would have
// failed every webp sheet with a confusing 400. Trust the server's Content-Type first, fall back to
// the extension, and only then default.
const ALLOWED = ["image/jpeg", "image/png", "image/gif", "image/webp"];
function mediaType(url: string, headerCt: string | null): string {
  const ct = (headerCt ?? "").split(";")[0].trim().toLowerCase();
  if (ALLOWED.includes(ct)) return ct;
  const ext = (url.split("?")[0].split(".").pop() ?? "").toLowerCase();
  if (ext === "png") return "image/png";
  if (ext === "gif") return "image/gif";
  if (ext === "webp") return "image/webp";
  return "image/jpeg";
}

function classify(raw: string): { sheet_no: string | null; confidence: string } {
  const t = (raw ?? "").trim();
  if (/^UNREADABLE$/i.test(t)) return { sheet_no: null, confidence: "unreadable" };
  const m = t.match(/^(\d{3,5})(?:\s*-\s*(\d))?$/);
  if (!m) return { sheet_no: null, confidence: "unreadable" };
  return { sheet_no: m[1] + (m[2] ? "-" + m[2] : ""), confidence: "high" };
}

async function askVision(bytes: Uint8Array, mediaType: string): Promise<string> {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": ANTHROPIC_API_KEY!, "anthropic-version": "2023-06-01", "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL, max_tokens: 32,
      messages: [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: mediaType, data: btoa(bin) } },
        { type: "text", text: PROMPT },
      ] }],
    }),
  });
  if (!r.ok) throw new Error(`anthropic ${r.status}: ${(await r.text()).slice(0, 200)}`);
  const j = await r.json();
  return (j?.content?.[0]?.text ?? "").trim();
}

Deno.serve(async (req) => {
  if (bearerRole(req) !== "service_role") return json({ error: "service_role required" }, 403);
  if (!ANTHROPIC_API_KEY) return json({ error: "ANTHROPIC_API_KEY not configured" }, 500);

  const started = Date.now();
  let limit = DEFAULT_LIMIT;
  try { limit = Math.max(1, Math.min(10, Number((await req.json())?.limit) || DEFAULT_LIMIT)); } catch { /* no body */ }

  // Targets come from derm.fn_sheet_number_ocr_targets — the selection logic (and the two traps it
  // encodes) lives in SQL where it can be tested in a transaction, not in this handler.
  const tr = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_sheet_number_ocr_targets`, {
    method: "POST", headers: dermHeaders, body: JSON.stringify({ p_limit: limit }),
  });
  if (!tr.ok) return json({ error: "targets rpc failed", status: tr.status, detail: (await tr.text()).slice(0, 300) }, 500);
  const rows: { dump_folder: string; ticket: string; page: number; image_url: string }[] = await tr.json();

  const out: any[] = [];
  for (const r of rows) {
    if (Date.now() - started > TIME_BUDGET_MS) { out.push({ stopped: "time budget" }); break; }
    let raw = "", cls = { sheet_no: null as string | null, confidence: "unreadable" };
    try {
      const img = await fetch(r.image_url);
      if (!img.ok) throw new Error(`image ${img.status}`);
      const bytes = new Uint8Array(await img.arrayBuffer());
      raw = await askVision(bytes, mediaType(r.image_url, img.headers.get("content-type")));
      cls = classify(raw);
    } catch (e) {
      out.push({ dump_folder: r.dump_folder, page: r.page, error: String(e).slice(0, 160) });
      continue;   // leave it unread; the gate treats "no read" as no opinion, never as a pass
    }

    const w = await fetch(`${SUPABASE_URL}/rest/v1/address_sheet_scan_reads?on_conflict=dump_folder,page`, {
      method: "POST",
      headers: { ...dermHeaders, Prefer: "resolution=merge-duplicates" },
      body: JSON.stringify({
        dump_folder: r.dump_folder, page: r.page,
        sheet_no_read: cls.sheet_no, raw_read: raw, confidence: cls.confidence,
        model: MODEL, image_url: r.image_url, read_at: new Date().toISOString(),
      }),
    });
    if (!w.ok) {
      out.push({ dump_folder: r.dump_folder, page: r.page, error: `write ${w.status}: ${(await w.text()).slice(0, 120)}` });
      continue;
    }
    out.push({ dump_folder: r.dump_folder, page: r.page, sheet_no_read: cls.sheet_no, confidence: cls.confidence });
  }

  return json({ candidates: rows.length, processed: out.length, results: out, ms: Date.now() - started });
});
