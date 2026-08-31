#!/usr/bin/env node
/**
 * auth_recovery_check.js  -  "Is Supabase Auth back to normal yet?"
 *
 * Run this whenever you want to know if it is safe to revert the temporary no-auth
 * "Default" mode and go back to normal login. It answers ONE question with a clear
 * verdict, and it only READS - it creates nothing, logs nobody in, mutates nothing.
 *
 *   node scripts/probes/auth_recovery_check.js
 *
 * WHY THESE SPECIFIC CHECKS (not arbitrary):
 *
 *  1. jwks.json  -  THE ONE THAT MATTERS MOST. The staff apps verify a session with
 *     supabase.auth.getClaims(), which fetches /auth/v1/.well-known/jwks.json. If that is
 *     not a valid JWKS, the auth gate breaks and login is dead - which IS the outage. So a
 *     real recovery MUST show this returning 200 with a { keys: [...] } body. It needs no
 *     apikey, so it is also the one honest probe the edge-rejection trap cannot fool.
 *
 *  2. health + settings WITH the apikey  -  the edge-rejection trap (cost real time on
 *     2026-08-31): /auth/v1/* returns 401 WITHOUT an apikey *before routing upstream*, so a
 *     dead GoTrue still answers 401 and looks "up". We ALWAYS send the apikey; healthy = 200,
 *     dead = 503.
 *
 *  3. a FUNCTIONAL login probe with BOGUS creds  -  200 on a health endpoint means the
 *     gateway answered, not that GoTrue can mint tokens. We POST a token grant with a fake
 *     email + fake password; if GoTrue is truly alive it REJECTS them with 400 (that 400 is
 *     the SUCCESS signal - the auth logic ran). 503 means still down. No real credential is
 *     ever used and nothing is created.
 *
 *  4. positive control  -  the DATA PLANE (/rest/v1) must be healthy throughout. If it is
 *     suddenly failing too, the instrument is measuring something else and the verdict is
 *     untrusted.
 *
 * VERDICT:  RECOVERED (all green, safe to revert) | STILL_DOWN | UNCERTAIN (control failed).
 */

const fs = require("fs");
const path = require("path");

const REF = "wbasvhvvismukaqdnouk";
const BASE = "https://" + REF + ".supabase.co";
const MGMT = "https://api.supabase.com";

function readEnv() {
  const txt = fs.readFileSync(path.join(__dirname, "..", "..", ".env"), "utf8");
  const out = {};
  for (const line of txt.split(/\r?\n/)) {
    const i = line.indexOf("=");
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

async function getAnonKey(pat) {
  // The anon key is public (it ships in every bundle); fetch it so the script is
  // self-contained and never hardcodes a key that could rotate.
  const r = await fetch(MGMT + "/v1/projects/" + REF + "/api-keys?reveal=true", {
    headers: { Authorization: "Bearer " + pat },
  });
  const keys = await r.json();
  const anon = Array.isArray(keys) && keys.find((k) => k.name === "anon" || k.id === "anon");
  if (!anon || !anon.api_key) throw new Error("could not resolve the anon key via the Management API");
  return anon.api_key;
}

async function timed(fn) {
  const t0 = Date.now();
  try {
    const v = await fn();
    return Object.assign({ ms: Date.now() - t0 }, v);
  } catch (e) {
    return { ok: false, status: 0, detail: String(e).slice(0, 80), ms: Date.now() - t0 };
  }
}

async function main() {
  const env = readEnv();
  if (!env.SUPABASE_PAT) throw new Error("SUPABASE_PAT missing from Supabase/.env");
  const anon = await getAnonKey(env.SUPABASE_PAT);

  const nowET = new Date().toLocaleString("en-US", { timeZone: "America/New_York" });
  console.log("\n  Supabase Auth recovery check  -  " + nowET + " ET\n  " + "-".repeat(58));

  const jwks = await timed(async () => {
    const r = await fetch(BASE + "/auth/v1/.well-known/jwks.json", { signal: AbortSignal.timeout(12000) });
    let body = null;
    try { body = await r.json(); } catch (e) { /* not json */ }
    const valid = !!(body && Array.isArray(body.keys) && body.keys.length > 0);
    return { ok: r.status === 200 && valid, status: r.status, detail: valid ? body.keys.length + " keys" : "no keys[] in body" };
  });

  const health = await timed(async () => {
    const r = await fetch(BASE + "/auth/v1/health", { headers: { apikey: anon }, signal: AbortSignal.timeout(12000) });
    return { ok: r.status === 200, status: r.status, detail: "" };
  });

  const settings = await timed(async () => {
    const r = await fetch(BASE + "/auth/v1/settings", { headers: { apikey: anon }, signal: AbortSignal.timeout(12000) });
    return { ok: r.status === 200, status: r.status, detail: "" };
  });

  const login = await timed(async () => {
    const r = await fetch(BASE + "/auth/v1/token?grant_type=password", {
      method: "POST",
      headers: { apikey: anon, "Content-Type": "application/json" },
      body: JSON.stringify({ email: "recovery-probe-noreply@ayache.com", password: "not-a-real-password-000" }),
      signal: AbortSignal.timeout(12000),
    });
    return { ok: r.status === 400, status: r.status, detail: r.status === 400 ? "rejected bogus creds (GoTrue alive)" : "" };
  });

  const control = await timed(async () => {
    const r = await fetch(BASE + "/rest/v1/clients?select=id&limit=1", {
      headers: { apikey: anon, Authorization: "Bearer " + anon },
      signal: AbortSignal.timeout(12000),
    });
    return { ok: r.status === 401 || r.status === 200, status: r.status, detail: "data plane reachable" };
  });

  const rows = [
    ["jwks.json (apps' getClaims needs this)", jwks],
    ["/auth/v1/health   (apikey sent)", health],
    ["/auth/v1/settings (apikey sent)", settings],
    ["login probe (bogus creds -> expect 400)", login],
    ["control: data plane /rest/v1", control],
  ];
  for (const [label, r] of rows) {
    console.log("  " + (r.ok ? "PASS" : "FAIL") + "  " + label.padEnd(42) + " " + String(r.status).padStart(3) + "  " + r.ms + "ms  " + (r.detail || ""));
  }

  const authGreen = jwks.ok && health.ok && settings.ok && login.ok;
  const controlGreen = control.ok;

  console.log("  " + "-".repeat(58));
  let verdict;
  if (authGreen && controlGreen) verdict = "RECOVERED";
  else if (!controlGreen) verdict = "UNCERTAIN";
  else verdict = "STILL_DOWN";
  console.log("  VERDICT: " + verdict + "\n");

  if (verdict === "RECOVERED") {
    console.log("  Supabase Auth looks fully back. Recommended revert order:\n");
    console.log("     1. Prove it by hand FIRST: open an app in a fresh/incognito window,");
    console.log("        click \"Exit emergency mode\", and sign in normally. It should work.");
    console.log("     2. Close the emergency window (apps fall back to login on their own):");
    console.log("        update public.app_config set value='2000-01-01' where key='emergency_access_until';");
    console.log("     3. Republish each of the 6 apps without the emergency branch (or leave them -");
    console.log("        with the window closed the token fetch 4xx's and they use normal login).");
    console.log("     4. Drop the probe helper: drop function if exists public.emergency_whoami();");
    console.log("     There is no API key to revoke - the minted JWTs just expire.\n");
  } else if (verdict === "STILL_DOWN") {
    console.log("  Auth is NOT back. Keep emergency mode on. Re-run this later.\n");
    console.log("     If the emergency window is near expiry and staff still need in, extend it:");
    console.log("       update public.app_config set value=(now()+interval '4 hours')::text");
    console.log("        where key='emergency_access_until';\n");
  } else {
    console.log("  Mixed signals - the data-plane control did not pass, so this reading is not");
    console.log("     trustworthy. Do NOT revert. Investigate the FAIL rows above.\n");
  }

  process.exit(verdict === "RECOVERED" ? 0 : 1);
}

main().catch((e) => { console.error("probe error:", e.message); process.exit(2); });
