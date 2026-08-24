// ============================================================================
// health-escalate — email Fred when a health problem is NEW or has festered
// ============================================================================
// Fred, 2026-08-24: "3 days, email only." / "for now just send an email to
// fred@ayache.com" / "you can use the resend.com".
//
// WHY EMAIL AND NOT THE SLACK DIGEST IT REPLACES. The digest posts only when
// something CHANGES, which leaves a hole: a problem that appears once and then sits
// produces exactly ONE message and then silence for ever. rpa-derm-health was
// unchanged for 11 straight runs while a Miami-Dade report stayed unfiled. "It has
// been broken for N days" is the trigger that was missing.
//
// ⚠ AND "just store it in the DB" was already the situation. The verdicts have been
//   in public.sync_log all along and nobody read them for days. A record nothing
//   pushes is a record nothing reads.
//
// WHAT IT SENDS (public.fn_health_alert_scan decides; this only delivers):
//   NEW      an item we have never emailed about
//   STALE    open >= 3 days, unacknowledged, and due again (weekly, not daily)
//   RESOLVED rides along in a mail that is already going out; never triggers one
//
// 🛑 THE MARK HAPPENS ONLY AFTER RESEND ACCEPTS. fn_health_alert_scan() records what
//    it SAW but not that anything was alerted; fn_health_alert_mark_sent() is called
//    only on a 2xx from Resend. So a failed send REPEATS tomorrow instead of
//    vanishing. For a watchdog a duplicate is cheap and a miss is the whole failure
//    mode. Do not "optimise" this into a single call.
//
// AUTH: verify_jwt=true + an in-handler role gate — the caller's JWT must carry
// role=service_role. Invoked by pg_cron via fn_request_health_escalation(), which
// reads edge_invoke_service_key from vault. Never deploy --no-verify-jwt.
//
// Manual run:  POST {} with a service_role bearer
// Dry run:     POST {"dry_run": true} — returns the payload and the rendered body,
//              sends nothing, marks nothing.
// ============================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const RESEND_FROM = Deno.env.get("RESEND_FROM")!;
const TO = "fred@ayache.com";
const STALE_DAYS = 3;
const RENOTIFY_DAYS = 7;

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const payload = JSON.parse(atob(tok.split(".")[1] ?? ""));
    return payload?.role ?? null;
  } catch {
    return null;
  }
}

async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]!));

// One line per item. The per-item payload differs by check, so pull out whatever
// identifying text that check actually carries rather than assuming a shape.
function itemLine(row: Record<string, any>): string {
  const it = row.item ?? {};
  const bits: string[] = [];
  // Skip anything that just repeats item_key — for rpa-derm-health the key IS the
  // kind, and "retry_loop_visits — retry_loop_visits" reads like a bug.
  const add = (v: unknown) => {
    const s = String(v ?? "").trim();
    if (s && s !== String(row.item_key) && !bits.includes(s)) bits.push(s);
  };
  add(it.client); add(it.client_code); add(it.issue); add(it.reason);
  add(it.kind); add(it.blocker);
  const n = Number(it.clients_blocked);
  if (n > 0) bits.push(`${n} client${n === 1 ? "" : "s"}`);
  const detail = bits.length ? ` — ${bits.join(", ")}` : "";
  const age = row.open_days === 0 ? "today" : `${row.open_days}d`;
  return `${esc(row.check_name)} · ${esc(row.item_key)}${esc(detail)} (open ${age})`;
}

// The remedy the check already computed. Carrying it matters: blackout-health's
// static advice used to say "run a measurement pass", which for ticket-833049 is the
// one action that re-opens a cross-client leak.
function whatToDo(row: Record<string, any>): string | null {
  const w = row.item?.what_to_do;
  return w ? String(w) : null;
}

function render(p: any): { subject: string; html: string; text: string } {
  const nNew = p.new.length, nStale = p.stale.length, nRes = p.resolved.length;
  const subject = nStale > 0
    ? `UnclogMe health: ${nStale} unresolved ${nStale === 1 ? "issue" : "issues"}${nNew ? `, ${nNew} new` : ""}`
    : `UnclogMe health: ${nNew} new ${nNew === 1 ? "issue" : "issues"}`;

  const L: string[] = [];
  const T: string[] = [];
  const sec = (title: string, rows: any[]) => {
    if (!rows.length) return;
    L.push(`<h3 style="margin:18px 0 6px;font:600 15px system-ui">${esc(title)}</h3><ul style="margin:0;padding-left:18px">`);
    T.push(`\n${title}`);
    for (const r of rows) {
      const w = whatToDo(r);
      L.push(`<li style="margin:4px 0;font:14px system-ui">${itemLine(r)}` +
        (w ? `<div style="color:#555;font:13px system-ui;margin:2px 0 0">${esc(w)}</div>` : "") +
        `<div style="color:#888;font:12px system-ui;margin:2px 0 0">silence 30d: <code>select fn_health_ack('${esc(r.check_name)}','${esc(r.item_key)}',30,'why');</code></div></li>`);
      T.push(`  ${itemLine(r).replace(/&amp;/g, "&")}${w ? `\n     ${w}` : ""}`);
    }
    L.push(`</ul>`);
  };

  sec(`New`, p.new);
  sec(`Still open after ${p.stale_days}+ days`, p.stale);
  if (nRes) {
    L.push(`<h3 style="margin:18px 0 6px;font:600 15px system-ui">Resolved</h3><ul style="margin:0;padding-left:18px">`);
    T.push(`\nResolved`);
    for (const r of p.resolved) {
      L.push(`<li style="margin:4px 0;font:14px system-ui">${esc(r.check_name)} · ${esc(r.item_key)}</li>`);
      T.push(`  ${r.check_name} · ${r.item_key}`);
    }
    L.push(`</ul>`);
  }

  L.push(`<p style="color:#888;font:12px system-ui;margin:20px 0 0">` +
    `You get this only when something is new or has been open ${p.stale_days}+ days. ` +
    `Silence means nothing changed and nothing has festered. Full state: <code>select * from ops.v_health_status;</code>` +
    `</p>`);
  T.push(`\nYou get this only when something is new or has been open ${p.stale_days}+ days.`);

  return { subject, html: L.join(""), text: T.join("\n") };
}

Deno.serve(async (req) => {
  if (bearerRole(req) !== "service_role") return json({ error: "service_role required" }, 403);

  let body: { dry_run?: boolean } = {};
  try { body = await req.json(); } catch { /* defaults */ }

  const p = await rpc("fn_health_alert_scan", {
    p_stale_days: STALE_DAYS,
    p_renotify_days: RENOTIFY_DAYS,
  });

  if (!p?.should_send) {
    console.log(`[health] nothing new and nothing stale — not sending (this is the contract)`);
    return json({ ok: true, sent: false, reason: "nothing new or stale", resolved: p?.resolved?.length ?? 0 });
  }

  const mail = render(p);
  if (body.dry_run) {
    console.log(`[health] DRY RUN — ${mail.subject}`);
    return json({ ok: true, sent: false, dry_run: true, subject: mail.subject, text: mail.text, payload: p });
  }

  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: RESEND_FROM, to: [TO], subject: mail.subject, html: mail.html, text: mail.text }),
  });
  const er = await r.json().catch(() => ({}));
  if (!r.ok) {
    // Deliberately do NOT mark. The same items re-alert on the next run.
    console.error(`[health] resend failed ${r.status}:`, JSON.stringify(er).slice(0, 300));
    return json({ ok: false, sent: false, error: "resend_failed", detail: er }, 502);
  }

  // Only now is it safe to say we told somebody.
  const alerted = [...p.new, ...p.stale].map((x: any) => ({ check_name: x.check_name, item_key: x.item_key }));
  const marked = await rpc("fn_health_alert_mark_sent", { p_items: alerted });

  console.log(`[health] sent "${mail.subject}" to ${TO} (resend id ${(er as any)?.id}), marked ${marked}`);
  return json({ ok: true, sent: true, subject: mail.subject, marked, email_id: (er as any)?.id ?? null });
});
