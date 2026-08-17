// ============================================================================
// save-client-fields — VERIFIED client name / client_code saga (2026-07-31)
// ============================================================================
// Fred: "we must have a way to edit a client key data, like client name, client
// code, type, zone, etc". Type + Zone are DB-owned (client.update_client_fields
// / client.update_client_zone, 2026-07-31_1035) and the app calls those RPCs
// directly. Name + code are JOBBER-MASTERED during the bridge, so they go
// through this saga, same spine as save-client-job: validate → mutate Jobber →
// RE-READ and verify → only then record our DB (fn_record_client_identity).
// The app AWAITS this function — that await is the loading state.
//
// ⚠ FACTS THIS FILE ENCODES (all measured; see
// docs/reference/jobber-client-code-convention.md):
// - Display convention: companyName = "<bare name> - <CODE>" for coded clients.
//   The DB stores the BARE name; the suffix exists only in Jobber.
// - Jobber RENDERS firstName+lastName when isCompany=false, companyName when
//   true. Writing only companyName leaves person-clients displaying the old
//   name (the 11-client gap the post-migration audit caught) — so for
//   isCompany=false this fn ALSO writes the person-name halves: last token
//   carries the " - CODE" suffix, the rest is firstName.
// - The code lives in the `Client Code` TEXT custom field (config GID below,
//   ALL_CLIENTS). webhook-jobber's parser (5549b03) derives client_code from
//   that field and strips the name suffix — which is exactly why the */5 poll
//   CONVERGES on this saga's values instead of reverting them.
// - ClientEditInput (clients use *Input; jobs use *Attributes — the canary-
//   caught trap). Mutations return HTTP 200 with userErrors.
// - Code REMOVAL is not supported (patch.client_code must be a real code).
//   Uncoded clients CAN be given their first code here.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";
// CustomFieldConfigurationText "Client Code", appliesTo ALL_CLIENTS.
// Account-stable; verified live during the 2026-07-31 fleet migration.
const CODE_CF_GID = "Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzgyNTkyNw==";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  // ADR 016: server-to-server writes carry no browser Origin; without this header
  // every audit row would land app_source='sql'.
  { global: { headers: { "x-app-source": "client-app" } } },
);

// ---- CORS (echo the requested headers — the save-calendar-visit lesson) ----
const ALLOW_FALLBACK = "authorization, x-client-info, apikey, content-type, x-supabase-api-version";
function corsPreflight(req: Request) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": req.headers.get("access-control-request-headers") ?? ALLOW_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
}
function hdrs() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": ALLOW_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
  };
}
function fail(code: string, message: string, extra: Record<string, unknown> = {}) {
  return new Response(JSON.stringify({ ok: false, code, message, ...extra }), { status: 200, headers: hdrs() });
}
function done(body: Record<string, unknown>) {
  return new Response(JSON.stringify({ ok: true, ...body }), { status: 200, headers: hdrs() });
}

// ---- Jobber WRITE token (jobber_write row + refresh; NOT the read app) ------
async function getJobberToken(): Promise<string> {
  const { data, error } = await db.from("webhook_tokens")
    .select("access_token,refresh_token,client_id,client_secret,expires_at")
    .eq("source_system", "jobber_write").single();
  if (error || !data) throw new Error("no jobber_write token row");
  if (new Date(data.expires_at).getTime() > Date.now() + 120_000) return data.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(data.refresh_token)}` +
    `&client_id=${encodeURIComponent(data.client_id)}&client_secret=${encodeURIComponent(data.client_secret)}`;
  const r = await fetch("https://api.getjobber.com/api/oauth/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
  if (!r.ok) throw new Error(`token refresh failed ${r.status}`);
  const t = await r.json();
  const exp = JSON.parse(atob(t.access_token.split(".")[1])).exp * 1000;
  await db.from("webhook_tokens").update({
    access_token: t.access_token, refresh_token: t.refresh_token || data.refresh_token,
    expires_at: new Date(exp).toISOString(), updated_at: new Date().toISOString(),
  }).eq("source_system", "jobber_write");
  return t.access_token;
}

type GqlResult = { ok: true; data: any } | { ok: false; kind: "busy" | "unreachable" | "no_answer" | "rejected"; detail: string };
async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<GqlResult> {
  let r: Response;
  try {
    r = await fetch("https://api.getjobber.com/api/graphql", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION },
      body: JSON.stringify({ query, variables }),
    });
  } catch (e) {
    return { ok: false, kind: "unreachable", detail: e instanceof Error ? e.message : String(e) };
  }
  let j: any = {};
  try { j = await r.json(); } catch { j = {}; }
  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) => e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled) {
    if (_retry < 5) {
      await new Promise((res) => setTimeout(res, 400 * Math.pow(2, _retry)));
      return gql(token, query, variables, _retry + 1);
    }
    return { ok: false, kind: "busy", detail: "throttled after 5 retries" };
  }
  if (r.status >= 500) return { ok: false, kind: "no_answer", detail: `HTTP ${r.status}` };
  if (Array.isArray(j.errors) && j.errors.length) {
    return { ok: false, kind: "rejected", detail: j.errors.map((e: any) => e.message).join("; ").slice(0, 300) };
  }
  return { ok: true, data: j.data };
}

function ue(payload: any): string | null {
  const errs = payload?.userErrors;
  if (Array.isArray(errs) && errs.length) {
    return errs.map((e: any) => e.message).join("; ").slice(0, 300);
  }
  return null;
}

// ---- Jobber queries/mutations ----------------------------------------------
const CLIENT_FIELDS = `id name firstName lastName companyName isCompany
  customFields { __typename ... on CustomFieldText { label valueText } }`;
const Q_CLIENT = `query($id: EncodedId!) { client(id: $id) { ${CLIENT_FIELDS} } }`;
const M_EDIT = `mutation($id: EncodedId!, $input: ClientEditInput!) {
  clientEdit(clientId: $id, input: $input) { client { ${CLIENT_FIELDS} } userErrors { message path } } }`;

const cfCode = (c: any): string | null => {
  const v = (c?.customFields ?? [])
    .find((f: any) => String(f?.label ?? "").trim().toLowerCase() === "client code")?.valueText;
  return v == null || String(v).trim() === "" ? null : String(v).trim();
};
const norm = (s: unknown) => String(s ?? "").replace(/\s+/g, " ").trim();
const squash = (s: unknown) => String(s ?? "").replace(/\s+/g, "").toUpperCase();
// The convention's code shape. Anywhere in a NAME it is a violation (prefix,
// suffix or parenthetical); as a CODE it must match exactly, anchored.
const CODE_ANYWHERE = /[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+/;
const CODE_EXACT = /^[0-9]{2,3}-[A-Z0-9&]+$/;

// isCompany=false split: Jobber renders firstName+" "+lastName. The last token
// carries the " - CODE" suffix so the rendered name ends with the convention;
// the rest is firstName. Single-token names put the whole name in firstName and
// the bare suffix in lastName.
function personHalves(bareName: string, code: string | null): { firstName: string; lastName: string } {
  const tokens = bareName.split(/\s+/);
  if (tokens.length > 1) {
    const last = tokens[tokens.length - 1];
    return {
      firstName: tokens.slice(0, -1).join(" "),
      lastName: code ? `${last} - ${code}` : last,
    };
  }
  return { firstName: bareName, lastName: code ? `- ${code}` : "" };
}

// ============================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPreflight(req) });
  if (req.method !== "POST") return fail("method", "POST only");

  // AUTH — in-handler, NOT gateway verify_jwt (ES256 session tokens; the gateway
  // rejects them with UNAUTHORIZED_ASYMMETRIC_JWT — measured 2026-07-30, see
  // config.toml). auth.getUser round-trips to GoTrue: signature + expiry checked.
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return fail("forbidden", "Staff account required.");
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const email = String(userData?.user?.email ?? "").toLowerCase();
  if (userErr || !userData?.user?.id ||
      (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return fail("forbidden", "Staff account required.");
  }

  let body: any;
  try { body = await req.json(); } catch { return fail("bad_request", "Invalid JSON body."); }
  const clientId = Number(body.client_id);
  if (!Number.isInteger(clientId) || clientId <= 0) return fail("bad_request", "client_id is required.");
  const patch = body.patch ?? {};
  const keys = Object.keys(patch);
  if (keys.length === 0 || keys.some((k) => !["name", "client_code"].includes(k))) {
    return fail("bad_request", "patch may contain only: name, client_code. Type and Zone use their RPCs.");
  }

  // ---- validate the patch ---------------------------------------------------
  let newName: string | null = null;
  if ("name" in patch) {
    newName = norm(patch.name);
    if (!newName) return fail("bad_request", "Client name cannot be empty.");
    if (newName.length > 120) return fail("bad_request", "Client name is too long (120 max).");
  }
  let newCode: string | null = null;
  if ("client_code" in patch) {
    newCode = String(patch.client_code ?? "").trim().toUpperCase();
    if (!newCode) return fail("bad_request", "Removing a client code is not supported.");
    if (!CODE_EXACT.test(newCode)) return fail("bad_request", "Client code must look like NNN-XX (digits, dash, letters/digits).");
  }

  // ---- load our side --------------------------------------------------------
  const { data: dbClient } = await db.from("clients")
    .select("id, name, client_code, status").eq("id", clientId).maybeSingle();
  if (!dbClient) return fail("not_found", `Client ${clientId} does not exist.`);
  const { data: link } = await db.from("entity_source_links").select("source_id")
    .eq("entity_type", "client").eq("source_system", "jobber").eq("entity_id", clientId).maybeSingle();
  if (!link?.source_id) {
    return fail("not_linked",
      "This client has no live Jobber link, so identity edits cannot be verified against Jobber. Fix the link first.");
  }
  const gid = link.source_id;

  const targetName = newName ?? norm(dbClient.name);
  const targetCode = newCode ?? (dbClient.client_code ? String(dbClient.client_code).trim().toUpperCase() : null);
  if (!targetName) return fail("bad_request", "Client has no name and none was provided.");
  // The EFFECTIVE name must be bare — checked here (not only on patch.name) so a
  // legacy code-shaped DB name cannot ride a code-only patch into Jobber and then
  // 22023 in the recorder AFTER the mutate (review finding).
  if (CODE_ANYWHERE.test(targetName)) {
    return fail("bad_request",
      "The client name must not contain a client code — the code is stored separately and Jobber gets it as the ' - CODE' suffix automatically. Fix the name in the same edit.");
  }

  // no-op guard: nothing actually changes
  if (targetName === norm(dbClient.name) && (targetCode ?? null) === (dbClient.client_code ?? null)) {
    return done({ noop: true, client: dbClient });
  }

  // code uniqueness on any code CHANGE (all rows, INACTIVE included — the
  // 239-COM lesson). The recorder re-checks with the same change-only scope.
  if (targetCode && targetCode !== (dbClient.client_code ?? null)) {
    const { data: clash, error: clashErr } = await db.from("clients").select("id, name, status")
      .eq("client_code", targetCode).neq("id", clientId).limit(1);
    // Destructured and checked: a discarded error returns data null, the emptiness test reads as
    // "no clash", and the guard fails OPEN in front of a Jobber rename.
    if (clashErr) {
      return fail("db_error", `Could not check whether ${targetCode} is free, so nothing was changed.`,
        { detail: clashErr.message });
    }
    if (clash && clash.length) {
      return fail("code_taken",
        `Client code ${targetCode} already belongs to "${clash[0].name}" (${clash[0].status}).`,
        { field: "client_code" });
    }

    // 🛑 AND THE NUMBER, WHICH IS THE ACTUAL IDENTITY. THIS IS THE HOLE 168 CAME THROUGH.
    // Fred, 2026-08-17: *"I changed 609 Lenox LLC client code to 168 which was supposed to be for
    // 168-AVA, that shouldn't be able to happen."* The check above compares the whole string, so
    // `168-609` was not equal to `168-AVA` and sailed straight past it — and the DB's
    // `clients_active_client_code_uniq` is unique on the string too, so nothing else caught it
    // either. The edit reached Jobber, which is why the repair needed clearing on BOTH sides.
    // Now mirrored by `clients_active_client_number_uniq` (2026-08-17_2355); this check exists to
    // produce a sentence naming the owner instead of a raw 23505.
    const numPart = targetCode.split("-")[0];
    if (/^\d{3}$/.test(numPart) && numPart !== "000") {
      const { data: numClash, error: numErr } = await db.from("clients")
        .select("id, name, status, client_code")
        .like("client_code", `${numPart}-%`).neq("id", clientId).neq("status", "INACTIVE");
      if (numErr) {
        return fail("db_error", `Could not check whether number ${numPart} is free, so nothing was changed.`,
          { detail: numErr.message });
      }
      if (numClash && numClash.length) {
        return fail("code_taken",
          `Number ${numPart} is already used by ${numClash.map((c) => `${c.client_code} (${c.name})`).join(", ")}. ` +
          `The client code scheme treats the NUMBER as the identity, so two clients cannot share one outside the 000 dump band.`,
          { field: "client_code",
            holders: numClash.map((c) => ({ id: c.id, name: c.name, status: c.status, client_code: c.client_code })) });
      }
    }
  }

  // ---- Jobber: read-before-write, mutate, verify ---------------------------
  let token: string;
  try { token = await getJobberToken(); } catch (e) {
    return fail("jobber_auth", `Could not authenticate to Jobber: ${e instanceof Error ? e.message : e}`);
  }

  const pre = await gql(token, Q_CLIENT, { id: gid });
  if (!pre.ok) return fail("jobber_" + pre.kind, `Jobber read failed: ${pre.detail}`);
  const before = pre.data?.client;
  if (!before) return fail("jobber_gone", "Jobber no longer has this client (deleted upstream?). No changes made.");

  // ⚠ DB-vs-Jobber code disagreement (review finding): the poll's heal
  // deliberately skips duplicate-holder cases, so Jobber can carry a code our
  // DB does not (145-NON class). A name-only edit would then strip Jobber's
  // ' - CODE' suffix, or silently re-assert a stale DB code over Jobber's.
  // Refuse unless the human states the code EXPLICITLY in this edit.
  const beforeCf = cfCode(before);
  const beforeSuffix = (norm(before.companyName).match(/-\s*([0-9]{2,3}-[A-Za-z0-9&]+)\s*$/) || [])[1] ?? null;
  if (!newCode) {
    if (!targetCode && (beforeCf || beforeSuffix)) {
      return fail("code_mismatch",
        `Jobber carries client code ${beforeCf ?? beforeSuffix} but our DB has none for this client. State the code explicitly in this edit so both sides agree.`);
    }
    if (targetCode && beforeCf && squash(beforeCf) !== squash(targetCode)) {
      return fail("code_mismatch",
        `Our DB says ${targetCode} but Jobber's Client Code field says ${beforeCf}. Re-save with the code stated explicitly to settle which is right.`);
    }
  }

  const targetCompany = targetCode ? `${targetName} - ${targetCode}` : targetName;
  const input: Record<string, unknown> = { companyName: targetCompany };
  const wroteHalves = before.isCompany === false;
  if (wroteHalves) {
    const halves = personHalves(targetName, targetCode);
    input.firstName = halves.firstName;
    input.lastName = halves.lastName;
  }
  const wroteCf = !!(targetCode && squash(targetCode) !== squash(beforeCf ?? ""));
  if (wroteCf) {
    input.customFields = [{ customFieldConfigurationId: CODE_CF_GID, valueText: targetCode }];
  }

  // Revert to the BEFORE snapshot, verified. Only touches fields the forward
  // mutation wrote; restores the CF (or clears a first-code write); confirms
  // with a re-read. Returns true ONLY when the confirming read matches.
  async function revertJobber(): Promise<boolean> {
    const revert: Record<string, unknown> = { companyName: before.companyName ?? "" };
    if (wroteHalves) {
      revert.firstName = before.firstName ?? "";
      revert.lastName = before.lastName ?? "";
    }
    if (wroteCf) {
      revert.customFields = [{ customFieldConfigurationId: CODE_CF_GID, valueText: beforeCf ?? "" }];
    }
    const res = await gql(token, M_EDIT, { id: gid, input: revert });
    if (!res.ok || ue(res.data?.clientEdit)) return false;
    const chk = await gql(token, Q_CLIENT, { id: gid });
    const b = chk.ok ? chk.data?.client : null;
    return !!b &&
      norm(b.companyName) === norm(before.companyName ?? "") &&
      squash(cfCode(b) ?? "") === squash(beforeCf ?? "");
  }

  const mut = await gql(token, M_EDIT, { id: gid, input });
  if (!mut.ok) return fail("jobber_" + mut.kind, `Jobber rejected the edit: ${mut.detail}`);
  const uerr = ue(mut.data?.clientEdit);
  if (uerr) return fail("jobber_rejected", `Jobber rejected the edit: ${uerr}`);

  // RE-READ and verify — never trust the mutation echo alone. The read is
  // idempotent, so transient 5xx/unreachable get retried before we conclude
  // anything (a single blip must not trigger a revert of a good edit).
  let post = await gql(token, Q_CLIENT, { id: gid });
  for (let i = 0; i < 2 && (!post.ok || !post.data?.client); i++) {
    await new Promise((r) => setTimeout(r, 700 * (i + 1)));
    post = await gql(token, Q_CLIENT, { id: gid });
  }
  const after = post.ok ? post.data?.client : null;
  const rendered = norm(after?.name);
  const companyOk = norm(after?.companyName) === norm(targetCompany);
  const renderedOk = targetCode
    ? (squash(rendered).endsWith(squash(`- ${targetCode}`)) &&
       squash(rendered).split(squash(targetCode)).length - 1 === 1)
    : rendered.length > 0;
  const cfOk = targetCode ? squash(cfCode(after)) === squash(targetCode) : squash(cfCode(after) ?? "") === squash(beforeCf ?? "");

  if (!after || !companyOk || !renderedOk || !cfOk) {
    const reverted = await revertJobber();
    return fail("verify_failed",
      reverted
        ? "Jobber accepted the edit but the re-read did not match; the change was rolled back in Jobber (confirmed) and nothing was written on our side."
        : "Jobber accepted the edit but the re-read did not match, and the rollback could NOT be confirmed — Jobber's state is unknown; open the client in Jobber to check. Nothing was written on our side.",
      { expected: { companyName: targetCompany, code: targetCode }, got: { companyName: after?.companyName, name: after?.name, code: cfCode(after) } });
  }

  // ---- record our side (atomic, audited) -----------------------------------
  // One retry for transient failures; the recorder is idempotent.
  let rec: any = null, recErr: any = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    const r = await db.rpc("fn_record_client_identity", {
      p_client_id: clientId, p_name: targetName, p_client_code: targetCode,
    });
    rec = r.data; recErr = r.error;
    if (!recErr) break;
    await new Promise((res) => setTimeout(res, 600));
  }
  if (recErr) {
    // ⚠ Never leave the two sides split (review finding): the poll converges
    // NAMES from Jobber but a changed CODE is heal-only-if-null — it would
    // diverge forever. Revert Jobber so failure means "nothing changed".
    const reverted = await revertJobber();
    return fail("db_record_failed",
      reverted
        ? `Recording locally failed (${recErr.message}); the Jobber change was rolled back — nothing changed on either side. Try again.`
        : `Recording locally failed (${recErr.message}) AND the Jobber rollback could not be confirmed — Jobber may carry the new values while our DB does not. Open the client in Jobber to check, then re-save.`);
  }

  return done({
    client: rec,
    jobber: { companyName: after.companyName, name: after.name, code: cfCode(after), isCompany: after.isCompany },
  });
});
