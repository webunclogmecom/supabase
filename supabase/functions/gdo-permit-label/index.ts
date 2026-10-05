// gdo-permit-label: sets gdos.location_label to the business the permit PDF is issued to.
//
// Fred, 2026-10-02/05: the permit card's name must be "what the actual PDF shows", from now on.
// Before this, the label came from a one-off DERM portal lookup that stored the county's facility
// name on record, which was sometimes a previous tenant (192-FRK showed "Cool Wild Company" while
// its permit says "NB2J INVESTMENTS, LLC DBA FRESKO").
//
// Reads each permit PDF ONCE per stored object (gdo id + storage eTag, in
// public.gdo_permit_label_reads). A replaced PDF has a new eTag, so it is read again; a staff edit
// of the label in the Client App stands until the PDF itself changes.
//
// AUTH: verify_jwt=true (pinned in config.toml) PLUS an in-handler service_role gate. Invoked by
// pg_cron via public.fn_request_gdo_permit_label_sweep().
// Body: { limit?: number, gdo_ids?: number[] (re-read these whatever the ledger says), dry_run?: boolean }

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MODEL = "claude-opus-5-5";
const TIME_BUDGET_MS = 90_000;
const MAX_PDF_BYTES = 10 * 1024 * 1024;

const PROMPT =
  "This is a Miami-Dade DERM grease (FOG) discharge permit. Report the business the permit is " +
  "issued to, exactly as printed: the text after \"Permit Issued To:\" or, on older permits, the " +
  "company line in the \"PERMITTEE:\" block (the company, never the person's name on the line above it). " +
  "Copy it character for character on one line, including LLC / DBA / punctuation. Reply with that " +
  "text only. If you cannot read it with certainty, reply with exactly: UNREADABLE";

const json = (p: unknown, status = 200) =>
  new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });

function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

function b64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });

async function readIssuedTo(pdf: Uint8Array): Promise<{ name: string | null; detail: string }> {
  // claude-opus-5-5: thinking cannot be disabled, so effort is the control; the default server-side
  // fallback answers a refusal on another model inside the same call.
  const msg: any = await anthropic.beta.messages.create({
    model: MODEL,
    max_tokens: 4000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low" },
    messages: [{
      role: "user",
      content: [
        { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64(pdf) } },
        { type: "text", text: PROMPT },
      ],
    }],
  } as any);
  if (msg.stop_reason === "refusal") return { name: null, detail: "refusal" };
  if (msg.stop_reason === "max_tokens") return { name: null, detail: "max_tokens" };
  const text = (msg.content ?? []).filter((c: any) => c?.type === "text").map((c: any) => c.text ?? "").join("\n").trim();
  const name = text.replace(/\s+/g, " ").trim();
  if (!name || name.toUpperCase() === "UNREADABLE" || /\n/.test(text) || name.length > 200) {
    return { name: null, detail: `unreadable: ${text.slice(0, 120)}` };
  }
  return { name, detail: `model ${msg.model}` };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);

  const body = await req.json().catch(() => ({}));
  const limit = Math.min(Math.max(Number(body.limit ?? 3) || 3, 1), 20);
  const gdoIds: number[] | null = Array.isArray(body.gdo_ids)
    ? body.gdo_ids.map(Number).filter(Number.isFinite)
    : null;
  const dryRun = body.dry_run === true;

  const db = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
    global: { headers: { "x-app-source": "gdo-permit-reader" } },
  });

  const { data: targets, error: tErr } = await db.rpc("fn_gdo_permit_label_targets", {
    p_limit: gdoIds ? gdoIds.length : limit,
    p_gdo_ids: gdoIds,
  });
  if (tErr) return json({ error: `targets: ${tErr.message}` }, 500);

  const started = Date.now();
  const results: unknown[] = [];
  type T = { gdo_id: number; storage_path: string; etag: string; current_label: string | null };
  for (const t of (targets ?? []) as T[]) {
    if (Date.now() - started > TIME_BUDGET_MS) { results.push({ gdo_id: t.gdo_id, outcome: "deferred" }); continue; }
    let outcome = "error", issued: string | null = null, detail = "";
    try {
      const { data: blob, error: dErr } = await db.storage.from("gdo-permits").download(t.storage_path);
      if (dErr || !blob) throw new Error(`download: ${dErr?.message ?? "no body"}`);
      const bytes = new Uint8Array(await blob.arrayBuffer());
      const isPdf = bytes.length > 4 && String.fromCharCode(...bytes.subarray(0, 4)) === "%PDF";
      if (!isPdf) { outcome = "not_pdf"; detail = "not a PDF (old scans are TIFF)"; }
      else if (bytes.length > MAX_PDF_BYTES) { outcome = "unreadable"; detail = `too large: ${bytes.length} bytes`; }
      else {
        const r = await readIssuedTo(bytes);
        issued = r.name; detail = r.detail;
        if (!issued) outcome = "unreadable";
        else if (issued === t.current_label) outcome = "same";
        else if (dryRun) outcome = "would_set";
        else {
          // Pinned to the path that was read: if the permit's PDF changed meanwhile, write nothing
          // and let the next sweep read the new one.
          const { data: upd, error: uErr } = await db.from("gdos").update({ location_label: issued })
            .eq("id", t.gdo_id).eq("permit_document_path", t.storage_path).select("id");
          if (uErr) throw new Error(`update: ${uErr.message}`);
          outcome = (upd ?? []).length === 1 ? "set" : "error";
          if (outcome === "error") detail = "permit_document_path changed during the read";
        }
      }
    } catch (e) {
      outcome = "error"; detail = String((e as Error)?.message ?? e).slice(0, 300);
    }
    if (!dryRun) {
      const { error: lErr } = await db.from("gdo_permit_label_reads").insert({
        gdo_id: t.gdo_id, storage_path: t.storage_path, etag: t.etag, outcome, issued_to: issued, detail,
      });
      if (lErr) detail += ` | ledger: ${lErr.message}`;
    }
    results.push({ gdo_id: t.gdo_id, outcome, issued_to: issued, previous: t.current_label, detail });
  }
  return json({ dry_run: dryRun, count: results.length, results });
});
