// viktor-visit-update: the ONLY way Viktor (the AI coworker in Slack) changes our data. It sets the truck on a
// COMPLETED visit when a person asks him, and the visit's Activity History shows who asked and why.
//
// Fred, 2026-10-12: "@Viktor add Moises to the visit" ... "if the visit isn't complete then don't ... let him make
// changes to the visits, and only visits, and when he does to have a way to know why he did it, like who was it who
// ordered him to do it. and for that to be saved in the Activity History of that visit."
//
// Every rule lives in public.viktor_set_visit_truck (migration 2026-10-13_0300): completed visits only, active trucks
// only, requester and reason required, attribution set inside the database so it cannot be left out, time on site
// measured right after. This function only checks Viktor's key and passes the request through; it never decides.
//
// AUTH: verify_jwt = false (Viktor has no Supabase login) + header `x-viktor-key` matched against the VIKTOR_API_KEY
// secret (comma-separated to allow a rotation overlap), the same shape as rpa-derm-queue's x-rpa-key.
// POST { visit_id: number, truck: "Moises", requested_by: "Diego", reason: "<the request as written>", dry_run?: bool }
// Reply: { ok, changed, message, ... } where `message` is a plain sentence Viktor posts back as it is.

const KEYS = (Deno.env.get("VIKTOR_API_KEY") ?? "").split(",").map((k) => k.trim()).filter(Boolean);
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function sameKey(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, message: "Use POST." }, 405);
  if (KEYS.length === 0) return json({ ok: false, message: "This door is not set up yet (no key configured)." }, 503);
  const presented = req.headers.get("x-viktor-key") ?? "";
  if (!KEYS.some((k) => sameKey(k, presented))) return json({ ok: false, message: "Wrong or missing key." }, 401);

  const b = await req.json().catch(() => null);
  const visitId = Number(b?.visit_id);
  if (!Number.isInteger(visitId) || visitId <= 0) return json({ ok: false, message: "I need the visit number (visit_id)." }, 400);
  for (const k of ["truck", "requested_by", "reason"]) {
    if (typeof b?.[k] !== "string" || !b[k].trim()) return json({ ok: false, message: `I need "${k}".` }, 400);
  }

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/viktor_set_visit_truck`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ p_visit_id: visitId, p_truck: b.truck, p_requested_by: b.requested_by,
                           p_reason: b.reason, p_dry_run: b.dry_run === true }),
  });
  if (!r.ok) {
    console.error(`viktor_set_visit_truck: HTTP ${r.status} ${(await r.text()).slice(0, 300)}`);
    return json({ ok: false, message: "The change could not be made because of a database error. Nothing was changed. Tell Fred." }, 500);
  }
  return json(await r.json());
});
