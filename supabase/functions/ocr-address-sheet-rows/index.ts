// ocr-address-sheet-rows — reads the ORDERED Section B roster off a scanned DERM address sheet, so
// the Stamp auto-place can MEASURE which printed row belongs to which client instead of inferring it.
//
// WHY THIS EXISTS
//   The auto-place decides "slot N is client X" from client-SET arithmetic: this sheet's client set
//   equals this ticket's, therefore the Nth slot is the Nth client. That inference is the only thing
//   between us and a stamp on another client's row — which, through the FP blackout, would show one
//   client another client's line on a regulator-facing document.
//   But the sheet already prints the answer. Every Section B row reads, verbatim:
//       GDO-08940 | Facility Name | 091-SB Street Bar
//   So we can read it and check. Fred (2026-08-06): "keep the certainty really high so we minimize
//   the stamping landing on another clients row."
//
// 🛑 WE MAY NOT MARK THE SHEET. Fred 2026-08-04: no QR, no barcode, no watermark — it is a
//    regulator-facing form and may only be FILLED, never annotated. This READS what DERM prints.
//    A QR code was proposed and explicitly rejected; do not revive it as a "simpler" option.
//
// 🛑 THE CODE IS THE SIGNAL, NOT THE NAME. Sheet 1081 page 2 carries BOTH
//    "061-TCE The carrot express 71st Collins" AND "062-TCE The carrot express Aventura Mall".
//    A facility-name match would cheerfully confuse them — which is the exact mis-place this guards.
//    We ask for, store and compare the CLIENT CODE.
//
// WRITES derm.address_sheet_row_reads ONLY. Never address_sheets, never address_row_map. Nothing is
// placed or completed here. The consuming gate (derm.fn_row_read_confirms) treats a missing or
// low-confidence read as NO OPINION, so a failed run degrades to "not yet read", never to a stamp.
//
// AUTH: verify_jwt=true (config.toml) PLUS an in-handler role gate — the anon key is a validly
// signed JWT, so the gateway check alone is half a gate.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");

const MODEL = "claude-sonnet-5";
const TIME_BUDGET_MS = 40000;
const MAX_PAGES = 6;

function json(p: unknown, status = 200): Response {
  return new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });
}
function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}
const dermHeaders = {
  "Content-Type": "application/json",
  "Content-Profile": "derm",
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
};

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

// Anchored to Section B and told to refuse per-row rather than guess. A guessed code here is the
// worst possible output: it would AUTHORISE a placement onto the wrong client's row, which is the
// precise harm this function exists to prevent. "unsure" must always beat "probably".
const PROMPT = [
  'This is a scanned Miami-Dade DERM "Fats, Oils and Grease (FOG) Single Load Liquid Waste',
  'Transporter eManifest" address sheet.',
  '',
  'Look ONLY at section "B: Origination of Waste" - the stack of facility rows in the left half.',
  'Each row prints a facility line that usually begins with a client code such as "091-SB",',
  '"110-CLA", "062-TCE" or "214-MYK" - digits, a hyphen, then 2-5 letters - followed by the',
  'facility name, e.g. "091-SB Street Bar".',
  '',
  'Report EVERY row position in Section B from top to bottom, including blank ones, as JSON:',
  '{"rows":[{"row":1,"code":"091-SB","name":"Street Bar","sure":true}, ...]}',
  '',
  'Rules, in order of importance:',
  '1. "row" is the 1-based position counting from the TOP of section B. Never renumber to skip blanks.',
  '2. If a row is empty/unused, use {"row":N,"code":null,"name":null,"sure":false}.',
  '3. If you cannot read a code with confidence, set "code" to null and "sure" to false.',
  '   NEVER guess a code and never infer it from the facility name. An unsure answer is useful;',
  '   a confident wrong answer is harmful.',
  '4. Set "sure" true only when the printed code is plainly legible.',
  '5. Copy the code EXACTLY as printed, including its digits and letters. Do not normalise or correct it.',
  '6. Ignore the handwritten values, the GDO numbers, gallons, dates, signatures and sections A/C/D/E/F.',
  '',
  'Reply with ONLY the JSON object.',
].join("\n");

// Returns the raw text AND the stop reason. The stop reason is not diagnostic garnish: a truncated
// reply produces unparseable JSON, which produces ZERO rows, which is indistinguishable from "the
// page had no readable codes" unless we surface it. That silent-zero is the failure this whole
// function exists to avoid committing elsewhere, so it must not be reproduced here.
async function askVision(bytes: Uint8Array, mt: string): Promise<{ text: string; stop: string }> {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": ANTHROPIC_API_KEY!, "anthropic-version": "2023-06-01", "Content-Type": "application/json" },
    body: JSON.stringify({
      model: MODEL, max_tokens: 4000,
      messages: [{ role: "user", content: [
        { type: "image", source: { type: "base64", media_type: mt, data: btoa(bin) } },
        { type: "text", text: PROMPT },
      ] }],
    }),
  });
  if (!r.ok) throw new Error(`anthropic ${r.status}: ${(await r.text()).slice(0, 200)}`);
  const j = await r.json();
  // 🛑 NEVER READ content[0].text. The content array can lead with a non-text block (e.g. thinking),
  // and then content[0].text is undefined -> "" -> zero rows on a perfectly legible page. Measured
  // 2026-08-06: this produced a SILENT false zero on 3 of 5 pages, and it was nondeterministic, so it
  // looked like flaky OCR rather than a parsing bug. Select text blocks by TYPE, always.
  const text = (j?.content ?? []).filter((c: any) => c?.type === "text")
                                 .map((c: any) => c?.text ?? "").join("\n").trim();
  return { text, stop: j?.stop_reason ?? "?" };
}

// A code must look like a code. Anything else is treated as unreadable rather than stored, because a
// malformed value that later "matches nothing" is indistinguishable from a genuine mismatch.
const CODE_RE = /^\d{1,4}-[A-Z0-9]{1,6}$/i;

// Whole-document JSON.parse is the WRONG shape here: one truncated or malformed tail throws away
// every correctly-read row and returns [], i.e. a confident zero on a legible page. So parse the
// document if we can, and otherwise recover row objects INDIVIDUALLY — a damaged reply should cost
// us the damaged row, not the page.
function parseRows(raw: string): { row: number; code: string | null; name: string | null; sure: boolean }[] {
  let list: any[] | null = null;
  const m = raw.match(/\{[\s\S]*\}/);
  if (m) { try { const p = JSON.parse(m[0]); if (Array.isArray(p?.rows)) list = p.rows; } catch { /* fall through */ } }
  if (!list) {
    list = [];
    for (const obj of raw.match(/\{[^{}]*"row"[^{}]*\}/g) ?? []) {
      try { list.push(JSON.parse(obj)); } catch { /* skip just this row */ }
    }
  }
  return list.map((r: any) => {
    const code = typeof r?.code === "string" && CODE_RE.test(r.code.trim()) ? r.code.trim().toUpperCase() : null;
    return {
      row: Number(r?.row) || 0,
      code,
      name: typeof r?.name === "string" ? r.name.trim().slice(0, 200) : null,
      // a code we could not parse can never be "sure", regardless of what the model claimed
      sure: code !== null && r?.sure === true,
    };
  }).filter((r: any) => r.row > 0);
}

Deno.serve(async (req) => {
  if (bearerRole(req) !== "service_role") return json({ error: "service_role required" }, 403);
  if (!ANTHROPIC_API_KEY) return json({ error: "ANTHROPIC_API_KEY not configured" }, 500);

  let body: { ticket?: string };
  try { body = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const ticket = String(body?.ticket ?? "").trim();
  if (!/^\d{4,8}$/.test(ticket)) return json({ error: "need { ticket: '<digits>' }" }, 400);

  // Same resolver the sheet-number pass uses. address_row_map.image_url is STALE (page-2 rows point
  // at address_1, some are the literal 'pending'), so it must not be used to find page images.
  const ir = await fetch(`${SUPABASE_URL}/rest/v1/rpc/ticket_page_images`, {
    method: "POST", headers: dermHeaders, body: JSON.stringify({ p_wm: ticket }),
  });
  if (!ir.ok) return json({ error: "page image rpc failed", detail: (await ir.text()).slice(0, 300) }, 500);
  const urls: string[] = (await ir.json()) ?? [];
  if (!urls.length) return json({ ok: false, error: `no page images for ${ticket}` });

  const started = Date.now();
  const out: any[] = [];

  for (let i = 0; i < Math.min(urls.length, MAX_PAGES); i++) {
    if (Date.now() - started > TIME_BUDGET_MS) { out.push({ stopped: "time budget" }); break; }
    const page = i + 1;
    let rows: ReturnType<typeof parseRows> = [];
    let vis: { text: string; stop: string };
    try {
      const img = await fetch(urls[i]);
      if (!img.ok) throw new Error(`image ${img.status}`);
      const bytes = new Uint8Array(await img.arrayBuffer());
      vis = await askVision(bytes, mediaType(urls[i], img.headers.get("content-type")));
      rows = parseRows(vis.text);
    } catch (e) {
      out.push({ page, error: String(e).slice(0, 160) });
      continue;   // unread page = no opinion; never a pass
    }

    // A zero here must never be silent. `stop` distinguishes "the model ran out of tokens" from
    // "the model genuinely saw nothing", and raw_head shows what it actually said. Without these
    // two fields a truncated reply and a blank page are the same observation.
    const diag = { stop: vis.stop, raw_len: vis.text.length,
                   raw_head: rows.length === 0 ? vis.text.slice(0, 300) : undefined };

    const payload = rows.map((r) => ({
      dump_folder: `ticket-${ticket}`,
      page,
      row_index: r.row,
      client_code_read: r.code,
      facility_name_read: r.name,
      confidence: r.sure ? "high" : "low",
      read_at: new Date().toISOString(),
    }));

    if (payload.length) {
      const w = await fetch(
        `${SUPABASE_URL}/rest/v1/address_sheet_row_reads?on_conflict=dump_folder,page,row_index`,
        { method: "POST",
          headers: { ...dermHeaders, Prefer: "resolution=merge-duplicates,return=minimal" },
          body: JSON.stringify(payload) },
      );
      if (!w.ok) {
        out.push({ page, ...diag, error: `write failed ${w.status}: ${(await w.text()).slice(0, 200)}` });
        continue;
      }
    }
    out.push({ page, ...diag, rows_read: payload.length,
               high_confidence: payload.filter((p) => p.confidence === "high").length, rows });
  }

  return json({ ok: true, ticket, pages: urls.length, results: out });
});
