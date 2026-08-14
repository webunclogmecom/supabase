// ============================================================================
// save-client-contact — VERIFIED primary-contact email/phone saga (2026-08-13)
// ============================================================================
// Fred: "We need to be able to edit the Contact section too, and that to be
// reflected on the DB + Jobber."
//
// Contact editing already existed DB-side (client.update_client_contact), but it
// HARD-REFUSES the client-level primary with 42501:
//     "…syncs from Jobber - edits here are overwritten within about five minutes."
// That refusal was correct and is NOT relaxed here. webhook-jobber.handleClient
// upserts client_contacts {name,email,phone} on every CLIENT_CREATE/UPDATE and the
// */5 poll replays ~400 synthetic CLIENT_UPDATEs a day, so a DB-only edit to the
// primary really is reverted within minutes. The migration header named the exit:
//     "the mechanism is the same verified saga the jobs feature uses
//      (push clientEdit, re-read, then write), NOT a relaxation of this guard."
// This function IS that mechanism. Jobber is written FIRST and verified, so the
// next poll CONVERGES on the new value instead of reverting it. That convergence
// is the entire point — nothing here suppresses or races the poll.
//
// ⚠ SCOPE IS THE PRIMARY'S EMAIL + PHONE, AND THAT IS MEASURED, NOT ARBITRARY:
//   - primary   366 emails, 0 comma-lists, longest 40 chars  -> clean 1:1 with Jobber
//   - accounting 156 emails, 6 comma-lists
//   - city        22 emails, 20 comma-lists  (e.g. "a@x.com, b@y.com, c@z.com")
//   Jobber models ONE address per email object. An accounting/city row is a
//   multi-address bag we invented; pushing it would either truncate to the first
//   address or create bogus contacts. Those two roles stay DB-only through
//   client.update_client_contact, which already works and needs no change.
//   🛑 Do NOT "finish the job" by pushing accounting/city without re-reading this.
//
// ⚠ THE NAME IS NOT EDITED HERE. For a client-level primary, client_contacts.name
//   mirrors the CLIENT's name ("Yan's Restaurant - 112-YA"), which is
//   save-client-fields' job (companyName + the person-name halves). Two writers on
//   one Jobber field is how you get a rollback fighting a rollback.
//
// ⚠ WE HOLD NO JOBBER EMAIL/PHONE IDs, SO THE RE-READ IS MANDATORY, NOT AN
//   OPTIMISATION. ClientEditInput has NO `emails:` array — it is
//   emailsToAdd/emailsToEdit/emailsToDelete, and EmailUpdateAttributes.id is
//   NON-NULL. Neither webhook-jobber nor sync-jobber-poll ever selected `id`
//   (both request `emails { address primary description }`), and
//   entity_source_links' CHECK whitelist has no 'contact'/'email'/'phone' entity
//   type, so there is nowhere to persist them without a migration. Hence: read the
//   client, take the id, then mutate.
//
// ⚠ PRIMARY SELECTION. 0 clients have two primary emails and 0 lack one, so
//   `primary === true` is a reliable selector for email. ONE client has phones
//   with none flagged primary, so the `?? phones[0]` fallback below is live code,
//   not defensive padding.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const GQL_VERSION = "2026-04-16";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  // ADR 016: server-to-server writes carry no browser Origin; without this the
  // audit row would land app_source='sql' instead of 'client-app'.
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

async function gql(token: string, query: string, variables: Record<string, unknown>, _retry = 0): Promise<GqlResult> {
  let r: Response;
  try {
    r = await fetch("https://api.getjobber.com/api/graphql", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${token}`,
        "Content-Type": "application/json",
        "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION,
      },
      body: JSON.stringify({ query, variables }),
    });
  } catch (e) {
    return { ok: false, kind: "unreachable", detail: e instanceof Error ? e.message : String(e) };
  }
  // 🛑 JOBBER SHEDS LOAD WITH AN HTML "WAITING ROOM" PAGE AT HTTP 200 (measured 2026-08-13).
  // Not 429, not 5xx, no `errors` array - a text/html body with a 200. The inherited helper did
  // `try { j = await r.json() } catch { j = {} }`, so that body became {}, sailed past both the
  // status check and the errors check, and returned ok:true with data UNDEFINED. Every caller
  // then read `data?.client` as null and reported its own not-found message: this function said
  // "Jobber has no client at that id - the link is stale", which sends someone to repair a link
  // that is perfectly healthy. An outage was being reported as data corruption.
  // Content-type is the only honest discriminator here, because the status code lies.
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    return { ok: false, kind: "busy",
      detail: `Jobber returned ${ctype || "an unknown content type"} at HTTP ${r.status} (its waiting room), not GraphQL` };
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
  if (Array.isArray(errs) && errs.length) return errs.map((e: any) => e.message).join("; ").slice(0, 300);
  return null;
}

// ---- Jobber query/mutation --------------------------------------------------
const CONTACT_FIELDS = `id
  emails { id address description primary }
  phones { id number description primary }`;
const Q_CLIENT = `query($id: EncodedId!) { client(id: $id) { ${CONTACT_FIELDS} } }`;
const M_EDIT = `mutation($id: EncodedId!, $input: ClientEditInput!) {
  clientEdit(clientId: $id, input: $input) { client { ${CONTACT_FIELDS} } userErrors { message path } } }`;

const norm = (s: unknown) => String(s ?? "").replace(/\s+/g, " ").trim();
// Jobber normalises phone formatting, so compare on digits only or a cosmetic
// difference reads as a failed verify and triggers a pointless rollback.
const digits = (s: unknown) => String(s ?? "").replace(/\D/g, "");
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// pick the object Jobber treats as the primary; see the header note on the fallback
const pickPrimary = <T extends { primary?: boolean }>(arr: T[] | null | undefined): T | null => {
  const a = Array.isArray(arr) ? arr : [];
  return a.find((x) => x?.primary === true) ?? a[0] ?? null;
};

// ============================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsPreflight(req) });
  if (req.method !== "POST") return fail("method", "POST only");

  // AUTH — in-handler, NOT gateway verify_jwt (ES256 session tokens; the gateway
  // rejects them with UNAUTHORIZED_ASYMMETRIC_JWT). Same gate as save-client-fields.
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return fail("forbidden", "Staff account required.");
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const actor = String(userData?.user?.email ?? "").toLowerCase();
  if (userErr || !userData?.user?.id ||
      (!actor.endsWith("@ayache.com") && !actor.endsWith("@unclogme.com"))) {
    return fail("forbidden", "Staff account required.");
  }

  let body: any;
  try { body = await req.json(); } catch { return fail("bad_request", "Invalid JSON body."); }
  const contactId = Number(body.contact_id);
  if (!Number.isInteger(contactId) || contactId <= 0) return fail("bad_request", "contact_id is required.");
  const patch = body.patch ?? {};
  const keys = Object.keys(patch);
  if (keys.length === 0 || keys.some((k) => !["email", "phone"].includes(k))) {
    return fail("bad_request",
      "patch may contain only: email, phone. The contact's name follows the client name (Edit client); " +
      "accounting and city contacts are saved by client.update_client_contact.");
  }

  // ---- load our side --------------------------------------------------------
  const { data: row, error: rowErr } = await db.from("client_contacts")
    .select("id, client_id, property_id, contact_role, name, email, phone").eq("id", contactId).maybeSingle();
  if (rowErr) return fail("db_error", `Could not read the contact: ${rowErr.message}`);
  if (!row) return fail("not_found", `Contact ${contactId} does not exist.`);

  // This function exists ONLY for the class the RPC refuses. Anything else must go
  // through client.update_client_contact, which already works and does not need Jobber.
  const isClientPrimary = row.property_id === null && row.contact_role === "primary";
  if (!isClientPrimary) {
    return fail("not_primary",
      `This is the ${row.contact_role} contact, which is ours and is saved directly — it does not go to Jobber. ` +
      `Use the normal contact save.`);
  }

  const wantEmail = "email" in patch ? norm(patch.email) : null;
  const wantPhone = "phone" in patch ? norm(patch.phone) : null;
  if (wantEmail !== null && wantEmail !== "" && !EMAIL_RE.test(wantEmail)) {
    return fail("bad_request", `That does not look like an email address: ${wantEmail}`, { field: "email" });
  }
  if (wantPhone !== null && wantPhone !== "" && digits(wantPhone).length < 7) {
    return fail("bad_request", "That phone number looks too short.", { field: "phone" });
  }

  const { data: link } = await db.from("entity_source_links").select("source_id")
    .eq("entity_type", "client").eq("source_system", "jobber").eq("entity_id", row.client_id).maybeSingle();
  if (!link?.source_id) {
    return fail("not_linked",
      "This client has no live Jobber link, so a contact edit cannot be verified against Jobber. Fix the link first.");
  }
  const gid = link.source_id as string;

  let token: string;
  try { token = await getJobberToken(); }
  catch (e) { return fail("jobber_unavailable", `Could not reach Jobber: ${e instanceof Error ? e.message : String(e)}`); }

  // ---- READ Jobber: we need the email/phone GIDs, which we do not store -------
  const before = await gql(token, Q_CLIENT, { id: gid });
  if (!before.ok) return fail("jobber_unavailable", `Could not read the client from Jobber (${before.kind}): ${before.detail}`);
  const jc = before.data?.client;
  if (!jc) return fail("not_found_jobber", "Jobber has no client at that id — the link is stale.");

  const curEmail = pickPrimary<any>(jc.emails);
  const curPhone = pickPrimary<any>(jc.phones);

  // 🛑 DRIFT GUARD — refuse rather than clobber an address the user was never shown.
  // We edit Jobber's PRIMARY object by id. If our stored value disagrees with what that
  // object currently holds, then either the poll has not caught up or someone edited
  // Jobber directly, and writing would silently overwrite a DIFFERENT address than the
  // one on screen. Same posture as save-client-job's stale_view preflight.
  //
  // ⚠ This is not hypothetical. 112-YA carries yannick@ayache.com TWICE (primary
  // "Other" + non-primary "Main") alongside serena@unclogme.com, and 134 of 439 clients
  // (30.5%) hold more than one email. Picking the wrong one of three is a live risk, and
  // an equality check against what we displayed is the only thing standing in front of it.
  const drifted: string[] = [];
  if (wantEmail !== null && norm(row.email) !== "" &&
      norm(curEmail?.address).toLowerCase() !== norm(row.email).toLowerCase()) {
    drifted.push(`email (we show "${row.email}", Jobber's primary is "${curEmail?.address ?? "none"}")`);
  }
  if (wantPhone !== null && digits(row.phone) !== "" &&
      digits(curPhone?.number) !== digits(row.phone)) {
    drifted.push(`phone (we show "${row.phone}", Jobber's primary is "${curPhone?.number ?? "none"}")`);
  }
  if (drifted.length) {
    return fail("stale_view",
      `Jobber has changed since this page loaded, so saving could overwrite the wrong entry: ${drifted.join("; ")}. ` +
      `Refresh to pull Jobber's current value, then re-apply your edit.`,
      { drifted });
  }

  // ---- build the add/edit/delete triples -------------------------------------
  const input: Record<string, unknown> = {};
  if (wantEmail !== null) {
    if (wantEmail === "") {
      if (curEmail) input.emailsToDelete = [curEmail.id];
    } else if (curEmail) {
      // description deliberately omitted so Jobber KEEPS whatever it has
      // (Main/Work/Personal/Other are all in live use across the fleet).
      input.emailsToEdit = [{ id: curEmail.id, address: wantEmail, primary: true }];
    } else {
      input.emailsToAdd = [{ address: wantEmail, description: "MAIN", primary: true }];
    }
  }
  if (wantPhone !== null) {
    if (wantPhone === "") {
      if (curPhone) input.phonesToDelete = [curPhone.id];
    } else if (curPhone) {
      input.phonesToEdit = [{ id: curPhone.id, number: wantPhone, primary: true }];
    } else {
      input.phonesToAdd = [{ number: wantPhone, description: "MAIN", primary: true }];
    }
  }
  if (Object.keys(input).length === 0) {
    return done({ code: "no_changes", message: "Nothing to change.", contact_id: contactId });
  }

  // ---- MUTATE ----------------------------------------------------------------
  const mut = await gql(token, M_EDIT, { id: gid, input });
  if (!mut.ok) {
    return fail(mut.kind === "rejected" ? "jobber_rejected" : "jobber_unavailable",
      `Jobber did not accept the contact change (${mut.kind}): ${mut.detail}. Nothing was written on our side.`);
  }
  const uerr = ue(mut.data?.clientEdit);
  if (uerr) return fail("jobber_rejected", `Jobber refused the contact change: ${uerr}. Nothing was written on our side.`);

  // ---- RE-READ and VERIFY — never trust the mutation echo ---------------------
  const after = await gql(token, Q_CLIENT, { id: gid });
  const ac = after.ok ? after.data?.client : null;
  const gotEmail = pickPrimary<any>(ac?.emails);
  const gotPhone = pickPrimary<any>(ac?.phones);

  const emailOk = wantEmail === null ? true
    : wantEmail === "" ? !gotEmail
    : norm(gotEmail?.address).toLowerCase() === wantEmail.toLowerCase();
  const phoneOk = wantPhone === null ? true
    : wantPhone === "" ? !gotPhone
    : digits(gotPhone?.number) === digits(wantPhone);

  if (!after.ok || !emailOk || !phoneOk) {
    // roll Jobber back to exactly what we read before the mutation
    const undo: Record<string, unknown> = {};
    if (wantEmail !== null && curEmail) undo.emailsToEdit = [{ id: curEmail.id, address: curEmail.address, primary: curEmail.primary === true }];
    if (wantPhone !== null && curPhone) undo.phonesToEdit = [{ id: curPhone.id, number: curPhone.number, primary: curPhone.primary === true }];
    let undone = false;
    if (Object.keys(undo).length) {
      const rb = await gql(token, M_EDIT, { id: gid, input: undo });
      undone = rb.ok && !ue(rb.data?.clientEdit);
    }
    return fail("verify_failed",
      undone
        ? "Jobber accepted the change but the re-read did not match; it was rolled back in Jobber (confirmed) and nothing was written on our side."
        : "Jobber accepted the change but the re-read did not match, and the rollback could NOT be confirmed — Jobber's state is unknown. Open the client in Jobber to check. Nothing was written on our side.",
      { rolled_back: undone });
  }

  // ---- only NOW our DB. Same columns the poll writes, so it CONVERGES ---------
  const dbPatch: Record<string, unknown> = {};
  if (wantEmail !== null) dbPatch.email = wantEmail === "" ? null : wantEmail;
  if (wantPhone !== null) dbPatch.phone = wantPhone === "" ? null : wantPhone;
  const { error: upErr } = await db.from("client_contacts").update(dbPatch).eq("id", contactId);
  if (upErr) {
    return fail("record_failed",
      `Jobber was updated and verified, but recording it here failed (${upErr.message}). ` +
      `The next Jobber poll will bring the new value in on its own — no action needed unless it persists.`);
  }

  return done({
    contact_id: contactId,
    client_id: row.client_id,
    email: wantEmail === null ? row.email : (wantEmail === "" ? null : wantEmail),
    phone: wantPhone === null ? row.phone : (wantPhone === "" ? null : wantPhone),
    pushed_to_jobber: true,
    actor,
  });
});
