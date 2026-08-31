// ============================================================================
// emergency-session
//
// Mints a short-lived `authenticated` JWT for the sentinel `Default` identity so staff can keep
// working while Supabase Auth (GoTrue) is unreachable. The JWT is browser-safe (it is exactly the
// shape of a normal user token), which is the whole point of this version.
//
// Fred, 2026-08-31, during the outage: "make it so we work with a user called Default ... no auth it
// enters at once on the app, and everyone is the same user Default."
//
// Spec: docs/specs/2026-08-31-emergency-default-user-access.md
//
// 🛑 WHY THIS MINTS A JWT AND NOT AN API KEY. THE API-KEY VERSION WAS SHIPPED AND FAILED IN THE
// BROWSER. Supabase's gateway REJECTS `sb_secret_` keys from a browser outright:
//     {"message":"Forbidden use of secret API key in browser",
//      "hint":"Secret API keys can only be used in a protected environment ... Delete this secret
//              API key immediately!"}
// (Observed in Fred's console on calendar.unclogme.app, 2026-08-31.) A curl test passes because
// curl is not a browser, which is exactly why the API-key approach looked correct for six fix
// attempts and never worked. A publishable key is browser-safe but maps to `anon`, which holds no
// grants. The only browser-safe credential that resolves to `authenticated` is a JWT signed with
// the project's JWT secret — the same way the anon and service_role keys are themselves JWTs.
//
// 🛑 THE ONE THING ONLY FRED CAN SUPPLY: EMERGENCY_JWT_SECRET.
// It must be the project's JWT secret (Dashboard -> Settings -> API -> JWT Settings -> reveal).
// Measured three ways, each with a positive control, that it is NOT reachable programmatically:
// the Management API project endpoint, /config/auth, /secrets, /pgsodium, the vault, and
// current_setting('app.settings.jwt_secret') (control: server_version). So this cannot be finished
// unattended. Set it in the Dashboard (Edge Functions -> Secrets); it must never enter chat or a
// repo — both app repos are PUBLIC and this secret signs every session on the project.
//
// 🛑 THE `Default` SUB IS A SENTINEL UUID WITH NO ROW IN auth.users, DELIBERATELY.
// Verified safe with a positive control: 0 RLS policies reference auth.users (control: 136 policies
// exist) and 0 functions in public/client/ops/derm/customer select from it.
//
// ⚠ THE APP SENDS apikey=<anon key> AND Authorization=Bearer <this JWT>. Not apikey=JWT: the apikey
// header must be a project API key (the anon/publishable key), and the JWT rides in Authorization.
// See the app-side note in Building Apps/docs/2026-08-31-temporary-no-auth-mode.md.
//
// ⚠ CORS/OPTIONS IS ANSWERED BEFORE ANY GATE. A browser preflight carries no headers.
// ============================================================================

const ALLOWED_ORIGINS = [
  "https://hub.unclogme.app",
  "https://admin.unclogme.app",
  "https://clients.unclogme.app",
  "https://calendar.unclogme.app",
  "https://derm.unclogme.app",
  "https://stamp.unclogme.app",
];

const DEFAULT_SUB = "00000000-0000-4000-8000-000000000001";
const DEFAULT_EMAIL = "default@unclogme.com";
const MAX_TTL_SECONDS = 4 * 60 * 60; // hard cap; the mode is self-limiting because the token expires

function corsHeaders(origin: string | null) {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlStr = (s: string) => b64url(new TextEncoder().encode(s));

async function mintJwt(secret: string, ttlSeconds: number) {
  const now = Math.floor(Date.now() / 1000);
  const exp = now + Math.min(ttlSeconds, MAX_TTL_SECONDS);
  const header = { alg: "HS256", typ: "JWT" };
  const payload = {
    aud: "authenticated",
    role: "authenticated",
    sub: DEFAULT_SUB,
    email: DEFAULT_EMAIL,
    app_mode: "emergency",
    iat: now,
    exp,
  };
  const signingInput = `${b64urlStr(JSON.stringify(header))}.${b64urlStr(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(signingInput)),
  );
  return { token: `${signingInput}.${b64url(sig)}`, exp };
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

/** The dispense window. Returns the deadline, or null when the mode is closed. */
async function windowEndsAt(): Promise<Date | null> {
  if (!SUPABASE_URL || !SERVICE_KEY) return null;
  try {
    const r = await fetch(
      `${SUPABASE_URL}/rest/v1/app_config?key=eq.emergency_access_until&select=value`,
      { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } },
    );
    if (!r.ok) return null;
    const rows = await r.json();
    const raw = rows?.[0]?.value;
    if (!raw || typeof raw !== "string") return null;
    const d = new Date(raw);
    if (Number.isNaN(d.getTime())) return null; // fail closed on an unparseable deadline
    return d > new Date() ? d : null;
  } catch {
    return null;
  }
}

async function logGrant(row: Record<string, unknown>) {
  if (!SUPABASE_URL || !SERVICE_KEY) return;
  try {
    await fetch(`${SUPABASE_URL}/rest/v1/emergency_session_grants`, {
      method: "POST",
      headers: {
        apikey: SERVICE_KEY,
        Authorization: `Bearer ${SERVICE_KEY}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify(row),
    });
  } catch (_e) {
    console.error("[emergency-session] ledger write failed");
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);

  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status: number) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const jwtSecret = Deno.env.get("EMERGENCY_JWT_SECRET");
  if (!jwtSecret) {
    return json(
      {
        error: "not_configured",
        message:
          "Emergency access is not configured. Set EMERGENCY_JWT_SECRET (the project JWT secret) as an edge secret.",
        missing: ["EMERGENCY_JWT_SECRET"],
      },
      503,
    );
  }

  const ip = req.headers.get("x-forwarded-for") ?? null;
  const ua = req.headers.get("user-agent") ?? null;
  let app: string | null = null;
  try {
    const body = (await req.json()) ?? {};
    if (typeof body?.app === "string") app = body.app.slice(0, 40);
  } catch { /* empty body is normal */ }

  // 🛑 ORIGIN-GATED, no passphrase (Fred: "enters at once"). An Origin is browser-set and trivially
  // spoofed, so this is containment (short-lived token, revocable window, full ledger), NOT a
  // security boundary. See the spec's risk table.
  if (!origin || !ALLOWED_ORIGINS.includes(origin)) {
    await logGrant({
      expires_at: new Date().toISOString(),
      app, ip, user_agent: ua,
      outcome: "refused",
      refusal_reason: origin ? `origin_not_allowed:${origin.slice(0, 60)}` : "no_origin",
    });
    return json({ error: "unauthorized" }, 401);
  }

  const until = await windowEndsAt();
  if (!until) {
    await logGrant({
      expires_at: new Date().toISOString(),
      app, ip, user_agent: ua,
      outcome: "refused",
      refusal_reason: "window_closed",
    });
    return json(
      { error: "window_closed", message: "Emergency access is closed. Set app_config 'emergency_access_until' to a future timestamp." },
      403,
    );
  }

  // exp is capped at 4h, but never let a token outlive the window either.
  const windowSeconds = Math.max(60, Math.floor((until.getTime() - Date.now()) / 1000));
  const { token, exp } = await mintJwt(jwtSecret, Math.min(MAX_TTL_SECONDS, windowSeconds));
  const expiresAt = new Date(exp * 1000).toISOString();

  await logGrant({
    expires_at: expiresAt,
    app: app ?? origin.replace("https://", ""),
    ip, user_agent: ua,
    outcome: "granted",
    dispense_route: "via_origin",
  });

  // `token` is a JWT for the Authorization header. `apikey` stays the app's anon key (browser-safe).
  return json({ token, identity: DEFAULT_EMAIL, expires_at: expiresAt }, 200);
});
