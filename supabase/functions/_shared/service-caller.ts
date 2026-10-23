// Is the caller our own system holding a Supabase SECRET key (sb_secret_...)?
// 2026-10-23, legacy-keys plan step 1 (docs/specs/2026-10-22-legacy-keys-switch-off-plan.md): the database, the
// timed jobs and our scripts move from the legacy service-role JWT to secret keys, and a secret key is not a JWT,
// so a bearerRole() that decodes the JWT role claim cannot see it.
//
// 🛑 ONLY for functions with verify_jwt = true (config.toml). Measured 2026-10-23 on that gateway: a made-up
// sb_secret_ key answers 401 "Invalid API key" (as bearer alone, or in both headers), and a bearer that differs
// from the apikey header answers 401 "Conflicting API keys". So on those functions a bearer that starts with
// sb_secret_ and reached the code IS a real secret key of this project. On a verify_jwt = false function the
// prefix proves nothing: compare the exact key there instead. scripts/checks/service_caller_gateway.mjs fails if a
// function that imports this file is not pinned verify_jwt = true.
export function isSecretKeyCaller(req: Request): boolean {
  const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  return tok.startsWith("sb_secret_");
}
