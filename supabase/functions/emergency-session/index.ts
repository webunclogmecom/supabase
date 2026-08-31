// ============================================================================
// emergency-session
//
// Mints a short-lived `authenticated` JWT for the sentinel `Default` identity so staff can keep
// working while Supabase Auth (GoTrue) is unreachable.
//
// Fred, 2026-08-31, during the outage: "We need to keep working, and no app with an Auth is
// working, so we gotta do a temporary fix ... make it so we work with a user called Default ...
// and just make all the apps skip the auth."
//
// Spec: docs/specs/2026-08-31-emergency-default-user-access.md
//
// 🛑 WHY THIS CAN WORK AT ALL, AND IT IS THE ONE MEASUREMENT THE DESIGN RESTS ON.
// Measured live at 12:5x ET while every /auth/v1/* route was returning 503:
//     service_role -> /rest/v1/clients?limit=1   HTTP 200
//     anon         -> same                        HTTP 401
//     both project keys                           {"alg":"HS256"}
// PostgREST validates an HS256 JWT **locally, against the project JWT secret**. It never calls
// GoTrue. So a token minted here is accepted by the database DURING the auth outage, and none of
// this needs a single new grant to `anon`.
//
// 🛑 WHY NOT JUST GRANT anon AND SKIP ALL THIS. Measured the same day:
//     has_table_privilege('anon', ...) on clients/visits/properties/derm_manifests/ops/client -> false
//     all 9 customer.* views                                                    -> 0 of 9
// The apps read `authenticated`-only objects, so "skip auth" without minting means granting `anon`
// read across the client book - and the anon key ships in every published bundle, in two PUBLIC
// repos. It would put every client, address, contact email and compliance manifest on the open
// internet.
// ⚠ AND A GRANT CANNOT BE TIME-BOXED. Grants live until a human removes them. This estate has the
// receipt: client_email_live_sends was set false "for testing" and was still false three days
// later because nothing expires it. Every credential minted here dies in <= 4 hours on its own.
// That expiry, not anyone's diligence, is what makes this defensible.
//
// 🛑 THE `Default` SUB IS A SENTINEL UUID WITH NO ROW IN auth.users, DELIBERATELY.
// Creating a real user needs GoTrue, which is down. Reusing a real person's uuid was the tempting
// shortcut and is REJECTED: it writes false per-person attribution into a compliance trail.
// ✅ Verified safe before shipping, with a positive control: 0 RLS policies reference auth.users
// (control: 136 policies exist) and 0 functions in public/client/ops/derm/customer select from it.
// Re-run that check before reusing this pattern.
//
// ⚠ CORS/OPTIONS IS ANSWERED BEFORE ANY GATE. A browser preflight carries no headers; gating
// before it turns every in-app call into an opaque CORS failure. Same lesson as send-derm-email.
// ============================================================================

const ALLOWED_ORIGINS = [
  "https://hub.unclogme.app",
  "https://admin.unclogme.app",
  "https://clients.unclogme.app",
  "https://calendar.unclogme.app",
  "https://derm.unclogme.app",
  "https://stamp.unclogme.app",
];

// 🛑 HARD CAP. Do not raise it. This is the mechanism that makes the mode self-limiting.
const MAX_TTL_SECONDS = 4 * 60 * 60;

// The `Default` identity. Fixed so every emergency action is attributable to the same sentinel.
// ⚠ MUST BE A SYNTACTICALLY VALID UUID. auth.uid() is uuid-typed, so a clever-looking string that
// spells a word is not an option: any non-hex character or wrong group length makes the cast fail
// and every write dies with 22P02. All-zero prefix + ...0001 keeps it obviously synthetic.
const DEFAULT_SUB = "00000000-0000-4000-8000-000000000001";
const DEFAULT_EMAIL = "default@unclogme.com";

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

/** Constant-time compare so the passphrase cannot be recovered by timing the response. */
function timingSafeEqual(a: string, b: string): boolean {
  const ab = new TextEncoder().encode(a);
  const bb = new TextEncoder().encode(b);
  // Compare a fixed number of bytes regardless of length, then fold length in.
  const len = Math.max(ab.length, bb.length);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < len; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
}

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

async function logGrant(row: Record<string, unknown>) {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return;
  try {
    await fetch(`${url}/rest/v1/emergency_session_grants`, {
      method: "POST",
      headers: {
        apikey: key,
        Authorization: `Bearer ${key}`,
        "Content-Type": "application/json",
        Prefer: "return=minimal",
      },
      body: JSON.stringify(row),
    });
  } catch (_e) {
    // Never let the ledger write break the grant path; the console line is the fallback record.
    console.error("[emergency-session] ledger write failed");
  }
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);

  // ⚠ Preflight FIRST, before any validation. See the header note.
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status: number) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const expected = Deno.env.get("EMERGENCY_PASSPHRASE");
  const jwtSecret = Deno.env.get("EMERGENCY_JWT_SECRET");

  // 🛑 FAIL CLOSED AND SAY WHICH SECRET IS MISSING. A half-configured emergency door that mints
  // unsigned or wrongly-signed tokens is worse than a closed one: PostgREST would reject them and
  // the apps would show an auth failure that looks exactly like the outage we are working around.
  if (!expected || !jwtSecret) {
    return json(
      {
        error: "not_configured",
        message: "Emergency access is not configured on this project.",
        missing: [!expected && "EMERGENCY_PASSPHRASE", !jwtSecret && "EMERGENCY_JWT_SECRET"].filter(
          Boolean,
        ),
      },
      503,
    );
  }

  let body: { passphrase?: string; app?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  const ip = req.headers.get("x-forwarded-for") ?? null;
  const ua = req.headers.get("user-agent") ?? null;
  const app = typeof body?.app === "string" ? body.app.slice(0, 40) : null;

  if (typeof body?.passphrase !== "string" || !timingSafeEqual(body.passphrase, expected)) {
    await logGrant({
      expires_at: new Date().toISOString(),
      app,
      ip,
      user_agent: ua,
      outcome: "refused",
      refusal_reason: "bad_passphrase",
    });
    return json({ error: "unauthorized" }, 401);
  }

  const { token, exp } = await mintJwt(jwtSecret, MAX_TTL_SECONDS);
  const expiresAt = new Date(exp * 1000).toISOString();

  await logGrant({
    expires_at: expiresAt,
    app,
    ip,
    user_agent: ua,
    outcome: "granted",
  });

  return json({ token, expires_at: expiresAt, identity: DEFAULT_EMAIL }, 200);
});
