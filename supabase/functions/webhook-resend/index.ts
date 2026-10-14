// webhook-resend (2026-10-14): stores what Resend reports about every email we send (delivered, opened, bounced ...)
// in public.email_events, so the apps can show a Delivered / Opened chip and the health email can catch bounces.
// Plan: docs/superpowers/specs/2026-10-14-email-delivery-status-audit.md. Migration: 2026-10-14_*_email_delivery_events.sql.
//
// TWO DOORS, one function:
//   1. Resend's webhook (POST, Svix-signed). verify_jwt = false in config.toml because Resend cannot send a Supabase
//      token; the Svix signature (RESEND_WEBHOOK_SECRET, see svix.ts) IS the gate. Unsigned or badly signed: 401,
//      nothing written. Secret not set yet: 503, nothing written.
//   2. Backfill (POST {backfill: true}) with `Authorization: Bearer <service role key>`, matched EXACTLY against this
//      function's own SUPABASE_SERVICE_ROLE_KEY (no JWT parsing: with verify_jwt off a claim proves nothing).
//      For every logged send that has no event yet, asks Resend for the email's last_event and stores ONE
//      backfill_summary row. Resend keeps emails 30 days; an older one answers 404 and is stored as
//      basis 'assumed_before_reports' (Fred, 2026-10-14: "Mark them all as Delivered").
//
// RULES (do not regress):
// - Only our own mail: an event whose `from` address is not exactly @unclogme.com is answered 200 and dropped.
// - Append only. Rows are keyed (svix_id, recipient) and inserted with ignoreDuplicates, so a retried webhook writes
//   nothing new. Status is computed from ALL rows by public.v_email_delivery, never from the newest one (webhooks
//   arrive out of order and are retried for about 27 hours).
// - Never store the body of an email. `detail` keeps only the bounce / failure / suppression reason.
// - Answer fast: one insert, then 200.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { verifySvix } from "./svix.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("RESEND_WEBHOOK_SECRET") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";

const KEPT = new Set(["delivered", "opened", "bounced", "delivery_delayed", "complained", "failed", "suppressed"]);
const OUR_DOMAIN = "unclogme.com";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const sb = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
  global: { headers: { "x-app-source": "webhook-resend" } },
});

// "Unclogme <contact@unclogme.com>" -> "unclogme.com"
function fromDomain(from: unknown): string | null {
  if (typeof from !== "string") return null;
  const m = from.match(/<([^>]+)>/);
  const addr = (m ? m[1] : from).trim().toLowerCase();
  const at = addr.lastIndexOf("@");
  return at > 0 ? addr.slice(at + 1) : null;
}

type EventRow = {
  svix_id: string; resend_email_id: string; event_type: string; recipient: string;
  occurred_at: string; detail: Record<string, unknown> | null;
};

async function insertRows(rows: EventRow[]) {
  // Every row carries the same keys: an array upsert NULLs a key that some rows leave out.
  const { error } = await sb.from("email_events")
    .upsert(rows, { onConflict: "svix_id,recipient", ignoreDuplicates: true });
  if (error) throw new Error(error.message);
}

async function handleWebhook(req: Request, raw: string): Promise<Response> {
  if (!WEBHOOK_SECRET) return json({ error: "not_configured" }, 503);
  const v = await verifySvix(
    WEBHOOK_SECRET, req.headers.get("svix-id"), req.headers.get("svix-timestamp"),
    req.headers.get("svix-signature"), raw, Math.floor(Date.now() / 1000),
  );
  if (!v.ok) return json({ error: "unauthorized", reason: v.reason }, 401);

  let evt: { type?: string; created_at?: string; data?: Record<string, unknown> };
  try { evt = JSON.parse(raw); } catch { return json({ error: "bad_json" }, 400); }
  const type = String(evt.type ?? "").replace(/^email\./, "");
  const data = evt.data ?? {};
  if (!KEPT.has(type)) return json({ ok: true, ignored: "event_type" });
  if (fromDomain(data.from) !== OUR_DOMAIN) return json({ ok: true, ignored: "not_our_domain" });
  const emailId = typeof data.email_id === "string" ? data.email_id : "";
  if (!emailId) return json({ ok: true, ignored: "no_email_id" });

  const to = (Array.isArray(data.to) ? data.to : [data.to])
    .filter((x): x is string => typeof x === "string" && x.includes("@"))
    .map((x) => x.trim().toLowerCase());
  const detail: Record<string, unknown> = {};
  for (const k of ["bounce", "failed", "suppressed"]) if (data[k] != null) detail[k] = data[k];
  const svixId = req.headers.get("svix-id")!;
  const occurred = typeof evt.created_at === "string" ? evt.created_at : new Date().toISOString();
  const rows: EventRow[] = (to.length ? to : [""]).map((recipient) => ({
    svix_id: svixId, resend_email_id: emailId, event_type: type, recipient,
    occurred_at: occurred, detail: Object.keys(detail).length ? detail : null,
  }));
  try {
    await insertRows(rows);
  } catch (e) {
    // 500 makes Resend retry; the row key makes the retry harmless.
    console.error(`[webhook-resend] insert failed: ${(e as Error).message}`);
    return json({ error: "insert_failed" }, 500);
  }
  return json({ ok: true, stored: rows.length });
}

async function handleBackfill(body: { limit?: unknown; include_test?: unknown }): Promise<Response> {
  if (!RESEND_API_KEY) return json({ error: "no_resend_key" }, 503);
  const limit = Math.min(Math.max(Number(body.limit) || 100, 1), 500);
  let q = sb.from("v_email_delivery")
    .select("resend_email_id, sent_at, is_test")
    .eq("event_count", 0).eq("summary_only", false)
    .lt("sent_at", new Date(Date.now() - 60 * 60 * 1000).toISOString())
    .order("sent_at", { ascending: true }).limit(limit);
  if (body.include_test !== true) q = q.eq("is_test", false);
  const { data: todo, error } = await q;
  if (error) return json({ error: "list_failed", detail: error.message }, 500);

  const out = { asked: 0, resend_answered: 0, assumed: 0, skipped: [] as { id: string; status: number }[] };
  for (const s of (todo ?? []) as { resend_email_id: string; sent_at: string }[]) {
    out.asked++;
    let status = 0;
    let lastEvent: string | null = null;
    try {
      const r = await fetch(`https://api.resend.com/emails/${encodeURIComponent(s.resend_email_id)}`, {
        headers: { Authorization: `Bearer ${RESEND_API_KEY}` }, signal: AbortSignal.timeout(15000),
      });
      status = r.status;
      if (r.ok) lastEvent = ((await r.json()) as { last_event?: string }).last_event ?? null;
      else await r.body?.cancel();
    } catch { status = -1; }

    let basis: string | null = null;
    if (status === 200) { basis = "resend_last_event"; out.resend_answered++; }
    else if (status === 404) { basis = "assumed_before_reports"; out.assumed++; }
    if (!basis) { out.skipped.push({ id: s.resend_email_id, status }); }
    else {
      try {
        await insertRows([{
          svix_id: `backfill:${s.resend_email_id}`, resend_email_id: s.resend_email_id, event_type: "backfill_summary",
          recipient: "", occurred_at: s.sent_at, detail: { basis, last_event: lastEvent },
        }]);
      } catch (e) { out.skipped.push({ id: s.resend_email_id, status: -2 }); console.error(`[webhook-resend] backfill insert: ${(e as Error).message}`); }
    }
    await new Promise((r) => setTimeout(r, 250)); // about 4 a second, under Resend's 10
  }
  return json({ ok: true, ...out });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const raw = await req.text();
  if ((req.headers.get("Authorization") ?? "") === `Bearer ${SERVICE_KEY}`) {
    let body: { backfill?: unknown };
    try { body = JSON.parse(raw || "{}"); } catch { return json({ error: "bad_json" }, 400); }
    if (body.backfill === true) return await handleBackfill(body as Record<string, unknown>);
    return json({ error: "unknown_service_call" }, 400);
  }
  return await handleWebhook(req, raw);
});
