// ============================================================================
// auth-recovery-watch  -  email Fred the moment Supabase Auth (GoTrue) comes back
// ============================================================================
// Fred, 2026-08-31, during the GoTrue outage that put all six staff apps into the
// temporary no-auth "Default" mode: "set up the automated email alert" so we know when
// it is safe to revert to normal auth.
//
// WHAT IT CHECKS (the same signals as scripts/probes/auth_recovery_check.js - see that
// file for the reasoning):
//   1. jwks.json returns a real { keys:[...] }  - what the apps' getClaims() fetches.
//   2. /auth/v1/health and /settings WITH the apikey (defeats the edge-rejection trap:
//      those routes 401 without an apikey BEFORE routing upstream, so a dead GoTrue
//      still looks "up" unless you send the key).
//   3. a functional login probe with BOGUS creds -> a 400 means GoTrue is actually
//      processing again; 503 means still down. No real credential, nothing created.
//   4. a data-plane control (/rest/v1) so a mixed reading is not trusted.
//
// EMAILS ONCE, ON THE down -> up TRANSITION. State lives in
// public.auth_recovery_state (singleton). While down it stays "down" silently; the
// first check that finds auth healthy again flips it to "recovered" and sends ONE email.
// If auth flaps (up, then down, then up) it re-arms and emails on each real recovery.
// A first run while still down just records "down" and sends nothing - so deploying this
// during the outage cannot produce a spurious "recovered" email.
//
// 🛑 THE MARK HAPPENS ONLY AFTER RESEND ACCEPTS (same rule as health-escalate). If the
//    email fails, the state is NOT advanced, so the next run retries. For a watchdog a
//    duplicate is cheap and a miss is the whole failure mode.
//
// AUTH: verify_jwt=true + an in-handler role gate (caller JWT must carry
// role=service_role). Invoked by pg_cron via public.fn_request_auth_recovery_watch(),
// which reads edge_invoke_service_key from vault. Never deploy --no-verify-jwt.
//
// Manual run:  POST {}                      with a service_role bearer
// Dry run:     POST {"dry_run": true}       - runs the checks, returns the verdict and
//                                             would-be email, sends nothing, writes nothing.
// ============================================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;
const RESEND_FROM = Deno.env.get("RESEND_FROM")!;
const TO = "fred@ayache.com";

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: { "Content-Type": "application/json" } });
}

function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

async function probe(fn: () => Promise<{ ok: boolean; status: number; detail?: string }>) {
  try { return await fn(); } catch (e) { return { ok: false, status: 0, detail: String(e).slice(0, 80) }; }
}

async function runChecks() {
  const T = 12000;
  const jwks = await probe(async () => {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/.well-known/jwks.json`, { signal: AbortSignal.timeout(T) });
    let body: any = null; try { body = await r.json(); } catch { /* not json */ }
    const valid = !!(body && Array.isArray(body.keys) && body.keys.length > 0);
    return { ok: r.status === 200 && valid, status: r.status, detail: valid ? `${body.keys.length} keys` : "no keys[]" };
  });
  const health = await probe(async () => {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/health`, { headers: { apikey: ANON_KEY }, signal: AbortSignal.timeout(T) });
    return { ok: r.status === 200, status: r.status };
  });
  const settings = await probe(async () => {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/settings`, { headers: { apikey: ANON_KEY }, signal: AbortSignal.timeout(T) });
    return { ok: r.status === 200, status: r.status };
  });
  const login = await probe(async () => {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
      method: "POST",
      headers: { apikey: ANON_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ email: "recovery-probe-noreply@ayache.com", password: "not-a-real-password-000" }),
      signal: AbortSignal.timeout(T),
    });
    return { ok: r.status === 400, status: r.status, detail: r.status === 400 ? "rejected bogus creds" : "" };
  });
  const control = await probe(async () => {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/clients?select=id&limit=1`, {
      headers: { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}` }, signal: AbortSignal.timeout(T),
    });
    return { ok: r.status === 401 || r.status === 200, status: r.status };
  });

  const authGreen = jwks.ok && health.ok && settings.ok && login.ok;
  const isUp = authGreen && control.ok; // recovered only when auth is green AND the control trusts the reading
  return { isUp, authGreen, controlGreen: control.ok, detail: { jwks, health, settings, login, control } };
}

async function sendEmail(detail: unknown) {
  const nowET = new Date().toLocaleString("en-US", { timeZone: "America/New_York" });
  const subject = "Supabase Auth is BACK - revert the no-auth Default mode";
  const text =
    `Supabase Auth (GoTrue) is responding normally again as of ${nowET} ET.\n\n` +
    `The six staff apps are still in the temporary no-auth "Default" mode. To go back to normal login:\n\n` +
    `1. Prove it by hand: open an app in an incognito window, click "Exit emergency mode", and sign in.\n` +
    `2. Close the emergency window (apps fall back to login on their own):\n` +
    `     update public.app_config set value='2000-01-01' where key='emergency_access_until';\n` +
    `3. Republish each of the six apps without the emergency branch when convenient.\n` +
    `4. drop function if exists public.emergency_whoami();\n\n` +
    `The minted JWTs just expire; there is no API key to revoke.\n\n` +
    `Detail: ${JSON.stringify(detail)}`;
  const html =
    `<p><b>Supabase Auth (GoTrue) is responding normally again</b> as of ${nowET} ET.</p>` +
    `<p>The six staff apps are still in the temporary no-auth &ldquo;Default&rdquo; mode. To go back to normal login:</p>` +
    `<ol><li><b>Prove it by hand:</b> open an app in an incognito window, click &ldquo;Exit emergency mode&rdquo;, and sign in.</li>` +
    `<li>Close the emergency window (apps fall back to login on their own):<br>` +
    `<code>update public.app_config set value='2000-01-01' where key='emergency_access_until';</code></li>` +
    `<li>Republish each of the six apps without the emergency branch when convenient.</li>` +
    `<li><code>drop function if exists public.emergency_whoami();</code></li></ol>` +
    `<p>The minted JWTs just expire; there is no API key to revoke.</p>`;
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: RESEND_FROM, to: [TO], subject, html, text }),
  });
  return r.ok;
}

async function db(path: string, init: RequestInit) {
  return fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "forbidden" }, 403);

  let dryRun = false;
  let testEmail = false;
  try { const b = (await req.json()) ?? {}; dryRun = b?.dry_run === true; testEmail = b?.test_email === true; } catch { /* empty body */ }

  // {"test_email": true} - confirm the Resend plumbing works without waiting for a real
  // recovery. Sends ONE clearly-marked test to Fred, touches no state, runs no checks.
  if (testEmail) {
    const nowET = new Date().toLocaleString("en-US", { timeZone: "America/New_York" });
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: RESEND_FROM, to: [TO],
        subject: "[TEST] auth-recovery-watch email plumbing works",
        text: `This is a test from the auth-recovery-watch alert (${nowET} ET). If you got this, the recovery email will reach you when Supabase Auth comes back. No action needed.`,
        html: `<p>This is a <b>test</b> from the auth-recovery-watch alert (${nowET} ET). If you got this, the recovery email will reach you when Supabase Auth comes back. No action needed.</p>`,
      }),
    });
    return json({ test_email: true, resend_ok: r.ok, resend_status: r.status });
  }

  const checks = await runChecks();

  if (dryRun) {
    return json({ dry_run: true, isUp: checks.isUp, authGreen: checks.authGreen, controlGreen: checks.controlGreen, detail: checks.detail });
  }

  // read the singleton state row
  const priorRes = await db("auth_recovery_state?id=eq.1&select=status", { method: "GET" });
  const priorRows = priorRes.ok ? await priorRes.json() : [];
  const priorStatus = priorRows?.[0]?.status ?? "unknown";

  const nowIso = new Date().toISOString();
  const detailJson = checks.detail;

  if (checks.isUp) {
    // Email ONLY on a real down -> up transition (not on unknown -> up), so a first run
    // that happens to catch auth healthy never spams. Since auth is currently down, the
    // first run records "down" and the true recovery is a down -> up.
    if (priorStatus === "down") {
      const sent = await sendEmail(detailJson);
      if (!sent) {
        // 🛑 do NOT advance state on a failed send; next run retries.
        return json({ status: "recovered_but_email_failed", note: "state left as down; will retry next run", detail: detailJson }, 502);
      }
      await db("auth_recovery_state?id=eq.1", {
        method: "PATCH",
        body: JSON.stringify({ status: "recovered", last_checked_at: nowIso, recovered_at: nowIso, alerted_at: nowIso, detail: detailJson }),
      });
      return json({ status: "recovered", emailed: true, detail: detailJson });
    }
    // already recovered (or unknown->up): record without emailing
    await db("auth_recovery_state?id=eq.1", {
      method: "PATCH",
      body: JSON.stringify({ status: "recovered", last_checked_at: nowIso, recovered_at: priorStatus === "recovered" ? undefined : nowIso, detail: detailJson }),
    });
    return json({ status: "recovered", emailed: false, note: `no transition (prior=${priorStatus})`, detail: detailJson });
  }

  // still down (or uncertain) -> re-arm so the next real recovery emails
  await db("auth_recovery_state?id=eq.1", {
    method: "PATCH",
    body: JSON.stringify({ status: "down", last_checked_at: nowIso, recovered_at: null, alerted_at: null, detail: detailJson }),
  });
  return json({ status: checks.controlGreen ? "still_down" : "uncertain", emailed: false, detail: detailJson });
});
