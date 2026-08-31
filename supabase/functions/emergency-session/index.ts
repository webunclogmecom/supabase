// ============================================================================
// emergency-session
//
// Hands the sentinel `Default` credential to a staff browser behind a passphrase, so people can
// keep working while Supabase Auth (GoTrue) is unreachable.
//
// Fred, 2026-08-31, during the outage: "We need to keep working, and no app with an Auth is
// working, so we gotta do a temporary fix ... make it so we work with a user called Default ...
// and just make all the apps skip the auth." Then: "take over any app from any session right now.
// We need to work without auth."
//
// Spec: docs/specs/2026-08-31-emergency-default-user-access.md
//
// 🛑 THIS DISPENSES A SUPABASE-SIGNED API KEY. IT DOES NOT MINT A JWT, AND THE HISTORY MATTERS.
// The first version signed its own HS256 token, which needs the project JWT secret. That secret is
// NOT reachable from here - measured three ways on 2026-08-31, each with a positive control:
//     GET /v1/projects/<ref>                      -> no jwt_secret field
//     GET .../config/auth, /secrets, /pgsodium    -> no jwt_secret field
//     current_setting('app.settings.jwt_secret')  -> empty (control: server_version = '17.4')
// So that design could never have been completed unattended. What replaced it is better:
// a **secret API key with a secret_jwt_template**, created through the Management API. Supabase
// signs it, so we never hold the signing secret at all.
//
// ✅ MEASURED, with controls, against live Prod during the outage:
//     current_role  authenticated      <- NOT service_role
//     bypassrls     false              <- RLS still applies in full
//     jwt_sub       00000000-0000-4000-8000-000000000001
//     jwt_email     default@unclogme.com
//     GET /rest/v1/clients, /rest/v1/visits        -> 200
//     CONTROL anon -> same RPC                     -> 42501
//     CONTROL anon -> /rest/v1/clients             -> 401   (anon grants UNCHANGED)
//
// 🛑 THE ONE PROPERTY THIS LOST, AND IT WAS THE SAFETY ARGUMENT OF THE ORIGINAL DESIGN:
// A MINTED JWT DIED IN <= 4 HOURS ON ITS OWN. AN API KEY DOES NOT EXPIRE.
// That is why emergency_access_until exists below and is checked on EVERY dispense. It is a
// weaker guarantee than an exp claim and it must be said plainly: the deadline stops the key
// being HANDED OUT, it does not kill copies already handed out. Only deleting the key does that.
// What the key gains in exchange is INSTANT REVOCATION, which a JWT cannot offer at all:
//     DELETE /v1/projects/<ref>/api-keys/01a288d9-6ea9-4b97-b37e-9c8250e70d3f
// kills every copy everywhere, immediately. That is the kill switch. Use it when auth is back.
//
// 🛑 WHY NOT JUST GRANT anon AND SKIP ALL THIS. Measured the same day:
//     has_table_privilege('anon', ...) on clients/visits/properties/derm_manifests/ops/client -> false
//     all 9 customer.* views                                                    -> 0 of 9
// The apps read authenticated-only objects, so "skip auth" without a credential means granting
// anon read across the client book - and the anon key ships in every published bundle, in two
// PUBLIC repos. It would put every client, address, contact email and compliance manifest on the
// open internet. This route touches ZERO grants, which is why the two anon controls above still
// return 401/42501 with the whole mode live.
//
// 🛑 THE Default SUB IS A SENTINEL UUID WITH NO ROW IN auth.users, DELIBERATELY.
// Creating a real user needs GoTrue, which is the thing that is down. Reusing a real person's uuid
// was the tempting shortcut and is REJECTED: it writes false per-person attribution into a
// compliance trail. Verified safe with a positive control: 0 RLS policies reference auth.users
// (control: 136 policies exist) and 0 functions in public/client/ops/derm/customer select from it.
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

/** Constant-time compare so the passphrase cannot be recovered by timing the response. */
function timingSafeEqual(a: string, b: string): boolean {
  const ab = new TextEncoder().encode(a);
  const bb = new TextEncoder().encode(b);
  const len = Math.max(ab.length, bb.length);
  let diff = ab.length ^ bb.length;
  for (let i = 0; i < len; i++) diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  return diff === 0;
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
    // 🛑 FAIL CLOSED on an unparseable value. An emergency door whose deadline cannot be read is a
    // door with no deadline, which is the exact failure this whole mechanism exists to prevent.
    if (Number.isNaN(d.getTime())) return null;
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

  // ⚠ Preflight FIRST, before any validation. See the header note.
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status: number) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const expected = Deno.env.get("EMERGENCY_PASSPHRASE");
  const emergencyKey = Deno.env.get("EMERGENCY_DEFAULT_KEY");

  // 🛑 FAIL CLOSED AND SAY WHICH SECRET IS MISSING.
  if (!expected || !emergencyKey) {
    return json(
      {
        error: "not_configured",
        message: "Emergency access is not configured on this project.",
        missing: [!expected && "EMERGENCY_PASSPHRASE", !emergencyKey && "EMERGENCY_DEFAULT_KEY"]
          .filter(Boolean),
      },
      503,
    );
  }

  // 🛑 ORIGIN-GATED, PASSPHRASE-OPTIONAL. Fred, 2026-08-31: "no auth it enters at once on the app,
  // and everyone is the same user Default". A passphrase screen is still auth, so the app asks for
  // nothing and this dispenses to any of the six known app origins.
  //
  // ⚠ SAY WHAT THIS IS AND IS NOT. An Origin header is set by the browser but is TRIVIALLY SPOOFED
  // by anything that is not a browser. So this is NOT a security boundary and must never be
  // described as one. It is chosen over the alternative Fred asked for - baking the key into the
  // published bundle - because that alternative is strictly worse in ways that do not expire:
  //   - the bundle is served to the whole internet and is archived/crawled;
  //   - both app repos are PUBLIC, so a committed key is public permanently and irrevocably;
  //   - a key in a file survives every rollback, cache and mirror.
  // Fetching at runtime keeps the credential out of every file, lets the 4h window and the
  // Management-API delete actually retire it, and logs every single hand-out. Weak gate, real
  // containment. The containment is the point, not the gate.
  const originAllowed = !!origin && ALLOWED_ORIGINS.includes(origin);

  // ⚠ An empty or absent body is NORMAL now: the app sends no passphrase. Treat a parse failure as
  // "no body", never as an error, or the no-auth path 400s on its own success case.
  let body: { passphrase?: string; app?: string } = {};
  try {
    body = (await req.json()) ?? {};
  } catch {
    body = {};
  }

  const ip = req.headers.get("x-forwarded-for") ?? null;
  const ua = req.headers.get("user-agent") ?? null;
  const app = typeof body?.app === "string" ? body.app.slice(0, 40) : null;

  // 🛑 THE WINDOW IS CHECKED BEFORE THE PASSPHRASE IS EVEN COMPARED, so a closed mode cannot be
  // probed for a correct passphrase.
  const until = await windowEndsAt();
  if (!until) {
    await logGrant({
      expires_at: new Date().toISOString(),
      app,
      ip,
      user_agent: ua,
      outcome: "refused",
      refusal_reason: "window_closed",
    });
    return json(
      {
        error: "window_closed",
        message:
          "Emergency access is closed. Set public.app_config 'emergency_access_until' to a future timestamp to reopen it.",
      },
      403,
    );
  }

  const passphraseOk = typeof body?.passphrase === "string" &&
    timingSafeEqual(body.passphrase, expected);

  if (!originAllowed && !passphraseOk) {
    await logGrant({
      expires_at: until.toISOString(),
      app,
      ip,
      user_agent: ua,
      outcome: "refused",
      refusal_reason: origin ? `origin_not_allowed:${origin.slice(0, 60)}` : "no_origin",
    });
    return json({ error: "unauthorized" }, 401);
  }

  // ⚠ Record WHICH route dispensed it. When this is reviewed afterwards, "the app asked" and
  // "somebody typed the passphrase" are different events and the ledger must be able to tell them
  // apart. `app` is caller-supplied and therefore a hint, never evidence; `ip` and `origin` are not.
  await logGrant({
    expires_at: until.toISOString(),
    app: app ?? (originAllowed ? origin!.replace("https://", "") : null),
    ip,
    user_agent: ua,
    outcome: "granted",
    dispense_route: originAllowed ? "via_origin" : "via_passphrase",
  });

  return json(
    { key: emergencyKey, identity: DEFAULT_EMAIL, expires_at: until.toISOString() },
    200,
  );
});
