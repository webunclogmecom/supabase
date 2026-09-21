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

// Jobber READS a description back capitalised ("Main", "Other", "Mobile") but the INPUT
// enums are upper case. Re-adding an object we deleted with the value we read would be
// rejected, so normalise, and fall back rather than send something the enum has never
// heard of. Introspected 2026-09-21 at version 2026-04-16.
const EMAIL_DESCRIPTIONS = ["MAIN", "WORK", "PERSONAL", "OTHER"];
const PHONE_DESCRIPTIONS = ["MAIN", "WORK", "MOBILE", "HOME", "FAX", "OTHER"];
const enumDesc = (raw: unknown, allowed: string[]) => {
  const v = String(raw ?? "").trim().toUpperCase();
  return allowed.includes(v) ? v : "MAIN";
};

// pick the object Jobber treats as the primary; see the header note on the fallback
const pickPrimary = <T extends { primary?: boolean }>(arr: T[] | null | undefined): T | null => {
  const a = Array.isArray(arr) ? arr : [];
  return a.find((x) => x?.primary === true) ?? a[0] ?? null;
};

// ============================================================================
// ============================================================================
// action:"refresh" - mirror Jobber's REAL contacts into public.client_jobber_contacts.
//
// WHAT THESE ARE. A Jobber Client carries `contacts: ContactModelConnection`, people with their
// own firstName/lastName/role/title/emails/phones/properties. They are NOT the rows in
// public.client_contacts: that table holds the client-record mirror webhook-jobber synthesises,
// plus the accounting/city rows we invented. Nothing here had ever read Jobber's contacts, so
// 112-YA's ContactModel/135562 ("Mr. Yannick ayache", role QUOTE/INVOICE) was invisible in the
// app while sitting in Jobber the whole time.
//
// READ-THROUGH, called when a client page opens. NOT on the poll:
// - adding contacts(first:5) to webhook-jobber's client query takes it from 26 requested points
//   to 166, and first:25 to 1094, against a 10,000 bucket restoring at 500/s, on a path replayed
//   ~400x/day for data only a human looks at. Wrong trade.
// - and keeping it out is what makes the poll STRUCTURALLY unable to touch this table: it cannot
//   revert, duplicate or orphan a row it never selects.
//
// EVERY CONNECTION IS BOUNDED. Measured 2026-09-21: the same shape with the nested connections
// unbounded costs 81,119 and is THROTTLED outright. Bounded it costs 22 actual / 755 requested.
const CONTACT_PAGE = 25;
const Q_CONTACTS = `query($id: EncodedId!) {
  client(id: $id) {
    id
    contacts(first: ${CONTACT_PAGE}) {
      totalCount
      nodes {
        id firstName lastName name role title isBillingContact
        emails(first: 3) { nodes { address primary } }
        phones(first: 3) { nodes { number primary } }
        properties(first: 5) { nodes { id } }
      }
    }
  }
}`;

// Jobber returns each contact's own emails/phones as CONNECTIONS (unlike Client.emails, which is
// a plain list), so these take .nodes. Prefer the primary, fall back to the first.
const pickNode = (conn: any): any => {
  const a = Array.isArray(conn?.nodes) ? conn.nodes : [];
  return a.find((x: any) => x?.primary === true) ?? a[0] ?? null;
};

async function handleRefresh(clientId: number) {
  if (!Number.isInteger(clientId) || clientId <= 0) {
    return fail("bad_request", "client_id is required for action:'refresh'.");
  }
  const { data: link, error: linkErr } = await db.from("entity_source_links").select("source_id")
    .eq("entity_type", "client").eq("source_system", "jobber").eq("entity_id", clientId).maybeSingle();
  if (linkErr) return fail("db_error", `Could not read the Jobber link: ${linkErr.message}`);
  if (!link?.source_id) {
    return fail("not_linked", "This client has no live Jobber link, so its Jobber contacts cannot be read.");
  }

  let token: string;
  try { token = await getJobberToken(); }
  catch (e) { return fail("jobber_unavailable", `Could not get a Jobber token: ${String(e)}`); }

  const r = await gql(token, Q_CONTACTS, { id: link.source_id });
  if (!r.ok) {
    return fail("jobber_unavailable",
      `Could not read this client's contacts from Jobber (${r.kind}): ${r.detail}. Nothing was changed.`);
  }
  const conn = r.data?.client?.contacts;
  if (!conn) return fail("not_found_jobber", "Jobber has no client at that id - the link is stale.");

  const nodes: any[] = Array.isArray(conn.nodes) ? conn.nodes : [];
  const total = Number(conn.totalCount ?? nodes.length);
  const nowIso = new Date().toISOString();

  const rows = nodes.filter((n) => n?.id).map((n) => {
    const em = pickNode(n.emails), ph = pickNode(n.phones);
    return {
      client_id: clientId,
      jobber_contact_id: String(n.id),
      first_name: n.firstName ?? null,
      last_name: n.lastName ?? null,
      name: n.name ?? null,
      jobber_role: n.role ?? null,
      title: n.title ?? null,
      is_billing_contact: n.isBillingContact ?? null,
      email: em?.address ?? null,
      phone: ph?.number ?? null,
      property_gids: (Array.isArray(n.properties?.nodes) ? n.properties.nodes : [])
        .map((p: any) => p?.id).filter(Boolean),
      // 🛑 CLEARING deleted_at IS MANDATORY, not tidiness. Without it a contact that is removed in
      // Jobber and then added back stays soft-deleted here forever - the re-add-writer failure
      // this estate has already paid for once.
      deleted_at: null,
      synced_at: nowIso,
      updated_at: nowIso,
    };
  });

  if (rows.length) {
    const { error: upErr } = await db.from("client_jobber_contacts")
      .upsert(rows, { onConflict: "jobber_contact_id" });
    if (upErr) return fail("db_error", `Could not save this client's Jobber contacts: ${upErr.message}`);
  }

  // 🛑 THE REMOVAL PASS RUNS ONLY WHEN THE READ WAS COMPLETE. If Jobber reports more contacts than
  // we asked for, or returned fewer nodes than it counted, we do NOT know who is missing versus
  // merely unread - and retiring on a truncated read would soft-delete live people. Skip it and
  // SAY SO in the response rather than letting a partial read look like a full one.
  const complete = total <= CONTACT_PAGE && nodes.length === total;
  let retired = 0;
  if (complete) {
    const keep = rows.map((x) => x.jobber_contact_id);
    let qy = db.from("client_jobber_contacts")
      .update({ deleted_at: nowIso, synced_at: nowIso })
      .eq("client_id", clientId).is("deleted_at", null);
    // PostgREST rejects an empty in.() list, and "Jobber has none" is a real, common state
    // (432 of 490 clients), so that case retires everything we still hold for the client.
    if (keep.length) qy = qy.not("jobber_contact_id", "in", `(${keep.map((k) => `"${k}"`).join(",")})`);
    const { data: gone, error: delErr } = await qy.select("id");
    if (delErr) return fail("db_error", `Could not retire removed contacts: ${delErr.message}`);
    retired = gone?.length ?? 0;
  }

  return done({
    action: "refresh",
    client_id: clientId,
    contacts: rows.length,
    total_in_jobber: total,
    complete,
    truncated: !complete,
    retired,
    note: complete ? undefined
      : `Jobber reports ${total} contacts and this read covers ${nodes.length}; removed contacts were NOT retired.`,
  });
}

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

  // action:"refresh" takes a client_id, not a contact_id, so it routes BEFORE the contact checks.
  if (String(body?.action ?? "").trim().toLowerCase() === "refresh") {
    return await handleRefresh(Number(body.client_id));
  }

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
  // 🛑 AN EMPTY STORED VALUE IS DRIFT TOO. The `norm(row.email) !== ""` conjunct that used
  // to sit here SKIPPED the guard exactly when we had nothing stored — so a save on a
  // NULL-valued contact took the `curEmail` branch and OVERWROTE a Jobber address the user
  // was never shown, which is the one outcome this guard exists to prevent. Both-empty is
  // still not drift, because norm(undefined) === norm(null) === "".
  const drifted: string[] = [];
  if (wantEmail !== null &&
      norm(curEmail?.address).toLowerCase() !== norm(row.email).toLowerCase()) {
    drifted.push(`email (we show "${row.email ?? ""}", Jobber's primary is "${curEmail?.address ?? "none"}")`);
  }
  if (wantPhone !== null && digits(curPhone?.number) !== digits(row.phone)) {
    drifted.push(`phone (we show "${row.phone ?? ""}", Jobber's primary is "${curPhone?.number ?? "none"}")`);
  }
  if (drifted.length) {
    return fail("stale_view",
      `Jobber has changed since this page loaded, so saving could overwrite the wrong entry: ${drifted.join("; ")}. ` +
      `Refresh to pull Jobber's current value, then re-apply your edit.`,
      { drifted });
  }

  // ---- build the add/edit/delete triples -------------------------------------
  // ⚠ Remember WHICH of the three we chose. The undo below has to mirror the action: an
  // ADD cannot be undone by an edit, and a DELETE cannot be undone by an edit on an id
  // Jobber has already destroyed. Guessing "it was probably an edit" is what made two of
  // the three branches report a false "Jobber's state is unknown".
  type Act = "none" | "add" | "edit" | "delete";
  let emailAct: Act = "none";
  let phoneAct: Act = "none";

  const input: Record<string, unknown> = {};
  if (wantEmail !== null) {
    if (wantEmail === "") {
      if (curEmail) { input.emailsToDelete = [curEmail.id]; emailAct = "delete"; }
    } else if (curEmail) {
      // description deliberately omitted so Jobber KEEPS whatever it has
      // (Main/Work/Personal/Other are all in live use across the fleet).
      input.emailsToEdit = [{ id: curEmail.id, address: wantEmail, primary: true }];
      emailAct = "edit";
    } else {
      input.emailsToAdd = [{ address: wantEmail, description: "MAIN", primary: true }];
      emailAct = "add";
    }
  }
  if (wantPhone !== null) {
    if (wantPhone === "") {
      if (curPhone) { input.phonesToDelete = [curPhone.id]; phoneAct = "delete"; }
    } else if (curPhone) {
      input.phonesToEdit = [{ id: curPhone.id, number: wantPhone, primary: true }];
      phoneAct = "edit";
    } else {
      input.phonesToAdd = [{ number: wantPhone, description: "MAIN", primary: true }];
      phoneAct = "add";
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
  const emailList: any[] = Array.isArray(ac?.emails) ? ac.emails : [];
  const phoneList: any[] = Array.isArray(ac?.phones) ? ac.phones : [];
  const gotEmail = pickPrimary<any>(emailList);
  const gotPhone = pickPrimary<any>(phoneList);

  // 🛑 A CLEAR IS VERIFIED BY THE ID BEING ABSENT, NOT BY pickPrimary RETURNING NOTHING.
  // pickPrimary falls back to `?? a[0]`, which is right for SELECTING and wrong for
  // VERIFYING: on the 134 of 439 clients that hold more than one email, the survivor comes
  // back, `!gotEmail` is false, and a clear that actually succeeded is rolled back and
  // reported as verify_failed. 112-YA is in exactly that shape.
  const emailOk = wantEmail === null ? true
    : wantEmail === "" ? (!curEmail || !emailList.some((e) => e?.id === curEmail.id))
    : norm(gotEmail?.address).toLowerCase() === wantEmail.toLowerCase();
  const phoneOk = wantPhone === null ? true
    : wantPhone === "" ? (!curPhone || !phoneList.some((p) => p?.id === curPhone.id))
    : digits(gotPhone?.number) === digits(wantPhone);

  if (!after.ok || !emailOk || !phoneOk) {
    // roll Jobber back to exactly what we read before the mutation
    // 🛑 THE UNDO MIRRORS THE ACTION. Undoing an ADD means DELETING the object we just
    // created — and its id exists only in the re-read, never in `before`. Undoing a DELETE
    // means RE-ADDING the captured values, because emailsToEdit on the id we destroyed is a
    // guaranteed no-op that still reports success. The old code emitted an edit for all
    // three, so an ADD produced an EMPTY undo object and a DELETE addressed a dead GID:
    // both then said "the rollback could NOT be confirmed" when a real rollback existed.
    const undo: Record<string, unknown> = {};
    if (emailAct === "edit" && curEmail) {
      undo.emailsToEdit = [{ id: curEmail.id, address: curEmail.address, primary: curEmail.primary === true }];
    } else if (emailAct === "add") {
      const born = emailList.find((e) => norm(e?.address).toLowerCase() === String(wantEmail).toLowerCase());
      if (born?.id) undo.emailsToDelete = [born.id];
    } else if (emailAct === "delete" && curEmail) {
      undo.emailsToAdd = [{ address: curEmail.address, description: enumDesc(curEmail.description, EMAIL_DESCRIPTIONS), primary: curEmail.primary === true }];
    }
    if (phoneAct === "edit" && curPhone) {
      undo.phonesToEdit = [{ id: curPhone.id, number: curPhone.number, primary: curPhone.primary === true }];
    } else if (phoneAct === "add") {
      const born = phoneList.find((p) => digits(p?.number) === digits(wantPhone));
      if (born?.id) undo.phonesToDelete = [born.id];
    } else if (phoneAct === "delete" && curPhone) {
      undo.phonesToAdd = [{ number: curPhone.number, description: enumDesc(curPhone.description, PHONE_DESCRIPTIONS), primary: curPhone.primary === true }];
    }
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
