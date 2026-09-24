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

// Jobber validates a phone it is given and refuses a number it cannot text when the object has
// its SMS toggle on. Its own wording ("turn off the receives text messages toggle") is Jobber UI
// jargon that means nothing to someone standing in our app, and it arrives on a PROMOTE as well
// as on a hand edit, so translate it once here. Measured 2026-09-21 promoting a contact whose
// phone was 555-555-5555.
function explainJobberRefusal(raw: string, phone: string | null): string {
  if (/cannot receive text messages|valid mobile phone/i.test(raw)) {
    return `Jobber rejected the phone number${phone ? ` "${phone}"` : ""}: it will not accept a number that cannot receive texts while that contact has text messages switched on. ` +
      `Use a real mobile number, or switch texting off for it in Jobber. Nothing was changed - the email did not move either, because both go in one call.`;
  }
  return `Jobber refused the contact change: ${raw}. Nothing was written on our side.`;
}

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
    # 🛑 WHAT JOBBER WILL ACTUALLY PREFILL ON THE NEXT SEND, piggybacked onto the refresh the
    # client page already makes rather than a second round trip per page load. Measured on
    # 112-YA: the whole query costs 9 points, so this is free in practice.
    # These are Jobber's MEMORY of the address the office last sent to, and NOTHING we can write
    # through the API changes them - not the star, not isBillingContact. Only a real send does.
    # That is why the app can only show drift and never fix it. Both enum values verified against
    # the live EmailTypes enum (18 values) before shipping; a wrong one 400s the whole refresh
    # and would take the contacts list down on page open.
    invoiceDefault: defaultEmails(emailType: INVOICE_SENT)
    quoteDefault: defaultEmails(emailType: QUOTE_SENT)
    # Every address the client itself holds, so the Edit dialog can predict what an email edit does to
    # the prefill above. Measured 2026-09-24 on 112-YA: Jobber keeps remembering an address only while
    # it is still on the client or on one of its contacts, and falls back to the STAR when none is.
    emails { address primary }
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
  // ⚠ Read these from the SAME reply, never a second call. An empty array is a real answer
  // ("Jobber has no remembered address for this client yet"), not a failure.
  const asList = (v: unknown): string[] =>
    (Array.isArray(v) ? v : []).map((x) => String(x ?? "").trim().toLowerCase()).filter((x) => x.includes("@"));
  const jobberDefaults = {
    invoice: asList((r.data?.client as any)?.invoiceDefault),
    quote: asList((r.data?.client as any)?.quoteDefault),
  };
  if (!conn) return fail("not_found_jobber", "Jobber has no client at that id - the link is stale.");

  const nodes: any[] = Array.isArray(conn.nodes) ? conn.nodes : [];

  // Every address Jobber holds for this client, for the Edit dialog's invoice/quote prediction.
  // 🛑 EXACT SPELLINGS, NOT LOWERCASED, unlike jobber_defaults above. Measured 2026-09-24: all 426
  // remembered addresses fleet-wide match a held address byte for byte, and 64 clients hold their star
  // twice in two capitalisations ("Cogaaccounting@" starred + "cogaaccounting@"). Whether Jobber keeps a
  // remembered address alive through a copy that differs only in case is NOT measured (Jobber now
  // refuses such a copy), so the dialog may only claim survival on an exact match. Lowercasing here
  // would turn that unknown into a confident claim. Jobber's own order and DUPLICATES KEPT: when the
  // star is deleted Jobber stars the next one in this order (measured once, 112-YA). A contact's list
  // is capped at emails(first: 3).
  const raw = (v: unknown): string[] =>
    (Array.isArray(v) ? v : []).map((x) => String(x ?? "").trim()).filter((x) => x.includes("@"));
  const jcEmails = (Array.isArray((r.data?.client as any)?.emails) ? (r.data!.client as any).emails : [])
    .filter((e: any) => String(e?.address ?? "").includes("@"));
  const jobberEmails = {
    client: jcEmails.map((e: any) => String(e.address).trim()),
    star: jcEmails.find((e: any) => e?.primary === true)?.address?.trim() ?? null,
    contacts: Object.fromEntries(nodes.filter((n) => n?.id).map((n) => [String(n.id),
      raw((Array.isArray(n.emails?.nodes) ? n.emails.nodes : []).map((e: any) => e?.address))])),
    invoice: raw((r.data?.client as any)?.invoiceDefault),
    quote: raw((r.data?.client as any)?.quoteDefault),
  };
  const total = Number(conn.totalCount ?? nodes.length);
  const nowIso = new Date().toISOString();

  // 🛑 THIS PAYLOAD IS AN ARRAY, SO EVERY `?? null` BELOW IS LOAD-BEARING, NOT TIDINESS.
  // postgrest-js sends `?columns=<union of Object.keys over every element>`, and PostgREST NULLs
  // that column on any row whose object lacked the key. Because every field here is `?? null`,
  // no key is ever `undefined`, all elements carry an identical key set, and the union equals
  // each row's own keys. Change one to a bare `n.foo?.bar` and JSON.stringify drops it for the
  // rows where it is undefined while the union still lists it - that column then gets NULLed on
  // exactly those rows, silently. person_role / person_role_other are safe here only because
  // they are in no key at all. See Supabase/CLAUDE.md, "A PostgREST .upsert() WITH AN ARRAY
  // PAYLOAD" for the measurement.
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

    // 🛑 A SOFT-DELETED JOBBER CONTACT MUST NOT KEEP HOLDING THE CLIENT'S INVOICE SLOT.
    // client.jobber_contacts filters `deleted_at is null`, so the card disappears from the UI
    // while client_comm_one_invoice_per_client still counts the row: the client's only Invoice
    // slot stays taken forever, and save_contact_settings' 23505 names a person who is not on
    // screen. There is no way out through the app - it would take SQL. Freeing the slot here is
    // what keeps "removed in Jobber" from becoming a dead end.
    const retiredIds = (gone ?? []).map((g: { id: number }) => g.id).filter(Boolean);
    if (retiredIds.length) {
      const { error: prefErr } = await db.from("client_communication_prefs")
        .delete().eq("client_id", clientId).in("jobber_contact_id", retiredIds);
      // ⚠ Not fatal: the contacts ARE retired by this point, and failing the whole refresh over
      // the cleanup would leave the caller thinking nothing synced. Loud in the log instead.
      if (prefErr) console.error(`[save-client-contact] could not free comm prefs for retired contacts: ${prefErr.message}`);
    }
  }

  // Does this client actually receive DERM service reports? The Edit-contact dialog warns that
  // changing this contact's email moves the service-report recipient, and that sentence is only
  // TRUE for a client who gets one. 🛑 It is deliberately NOT the `service_report` communication
  // tick: trg_seed_client_communication seeds that on every client at contact birth (1,191 rows
  // over 397 clients, exactly three each, not one differing), so it carries no intent.
  // ⚠ On ANY error this stays FALSE. The warning asserts a fact, so "we could not check" must
  // never render as "the service report goes here" - the fallback is today's behaviour, no
  // warning at all. See Building Apps/Client App/docs/2026-09-23_derm-recipient-disclosure-decision.md
  let dermActive = false;
  {
    // 🛑 .schema("client") is load-bearing: the function is client.*, and a bare db.rpc() resolves
    // against `public`, errors, and (by the fail-false rule above) would silently never warn.
    const { data: da, error: daErr } = await db.schema("client")
      .rpc("fn_client_has_derm_activity", { p_client_id: clientId });
    if (daErr) console.error(`[save-client-contact] derm_active lookup failed for client ${clientId}: ${daErr.message}`);
    else dermActive = da === true;
  }

  return done({
    action: "refresh",
    client_id: clientId,
    contacts: rows.length,
    total_in_jobber: total,
    complete,
    // Jobber's remembered prefill addresses. Arrays, possibly empty: empty means Jobber has no
    // memory for this client yet, which is NOT the same as "nothing has been sent" - the API
    // cannot tell us who a message went to.
    jobber_defaults: jobberDefaults,
    // appended 2026-09-24; nothing above changed shape, so the published bundle is unaffected
    jobber_emails: jobberEmails,
    derm_active: dermActive,
    truncated: !complete,
    retired,
    note: complete ? undefined
      : `Jobber reports ${total} contacts and this read covers ${nodes.length}; removed contacts were NOT retired.`,
  });
}

// ============================================================================
// action:"edit_jobber_contact" - edit one of Jobber's REAL contact people.
//
// This is the path that finally makes Fred's ask true: first name, last name, role, email and
// phone all round-trip, because a ContactModel genuinely has all of them. It is NOT the client
// record: that is the mirror row and its email/phone go through the original path below.
//
// PROVEN BEFORE IT WAS BUILT (2026-09-21, live on 112-YA ContactModel/135562, rolled back):
// clientEdit(contactsToEdit:[{id, emailsToEdit:[{id,address}], phonesToEdit:[{id,number}]}])
// returns userErrors [] and the write LANDS, edited IN PLACE - the Email keeps its id, no new
// object is minted. Introspection only proved the field exists; Jobber's docs never define
// ContactModel at all, so the run was the only way to know.
const Q_ONE_CONTACT = `query($id: EncodedId!) {
  client(id: $id) {
    id
    contacts(first: ${CONTACT_PAGE}) {
      totalCount
      nodes {
        id firstName lastName name role title isBillingContact
        emails(first: 3) { nodes { id address description primary } }
        phones(first: 3) { nodes { id number description primary } }
        properties(first: 5) { nodes { id } }
      }
    }
  }
}`;

const PERSON_FIELDS = ["first_name", "last_name", "role", "email", "phone"];

async function handleEditJobberContact(body: any) {
  const rowId = Number(body.jobber_contact_row_id);
  if (!Number.isInteger(rowId) || rowId <= 0) {
    return fail("bad_request", "jobber_contact_row_id is required for action:'edit_jobber_contact'.");
  }
  const patch = body.patch ?? {};
  const keys = Object.keys(patch);
  if (keys.length === 0 || keys.some((k) => !PERSON_FIELDS.includes(k))) {
    return fail("bad_request", `patch may contain only: ${PERSON_FIELDS.join(", ")}.`);
  }

  const { data: row, error: rowErr } = await db.from("client_jobber_contacts")
    .select("id, client_id, jobber_contact_id, first_name, last_name, jobber_role, email, phone, deleted_at")
    .eq("id", rowId).maybeSingle();
  if (rowErr) return fail("db_error", `Could not read the contact: ${rowErr.message}`);
  if (!row) return fail("not_found", `Jobber contact row ${rowId} does not exist.`);
  if (row.deleted_at) return fail("gone", "That contact no longer exists in Jobber. Refresh the page.");

  const wantFirst = "first_name" in patch ? norm(patch.first_name) : null;
  const wantLast  = "last_name"  in patch ? norm(patch.last_name)  : null;
  const wantRole  = "role"       in patch ? norm(patch.role)       : null;
  const wantEmail = "email"      in patch ? norm(patch.email)      : null;
  const wantPhone = "phone"      in patch ? norm(patch.phone)      : null;
  if (wantEmail !== null && wantEmail !== "" && !EMAIL_RE.test(wantEmail)) {
    return fail("bad_request", `That does not look like an email address: ${wantEmail}`, { field: "email" });
  }
  if (wantPhone !== null && wantPhone !== "" && digits(wantPhone).length < 7) {
    return fail("bad_request", "That phone number looks too short.", { field: "phone" });
  }
  if (wantFirst !== null && wantFirst === "" && wantLast !== null && wantLast === "") {
    return fail("bad_request", "A contact needs a first or last name.");
  }

  const { data: link } = await db.from("entity_source_links").select("source_id")
    .eq("entity_type", "client").eq("source_system", "jobber").eq("entity_id", row.client_id).maybeSingle();
  if (!link?.source_id) return fail("not_linked", "This client has no live Jobber link.");

  let token: string;
  try { token = await getJobberToken(); }
  catch (e) { return fail("jobber_unavailable", `Could not get a Jobber token: ${String(e)}`); }

  // ---- READ Jobber first: we need the Email/Phone object ids, which we do not store ----------
  const before = await gql(token, Q_ONE_CONTACT, { id: link.source_id });
  if (!before.ok) {
    return fail("jobber_unavailable", `Could not read the contact from Jobber (${before.kind}): ${before.detail}. Nothing was changed.`);
  }
  const findIn = (r: any) => (r?.data?.client?.contacts?.nodes ?? [])
    .find((n: any) => String(n?.id) === String(row.jobber_contact_id));
  const jc = findIn(before);
  if (!jc) {
    return fail("gone", "Jobber no longer has that contact. Refresh the page; it will disappear from the list.");
  }
  const curEmail = pickNode(jc.emails);
  const curPhone = pickNode(jc.phones);

  // 🛑 DRIFT GUARD, same posture as the client-record path: refuse rather than overwrite a value
  // the user was never shown. An EMPTY stored value counts as drift when Jobber holds one - that
  // exact conjunct is what made the client-record guard skippable and had to be removed there.
  const drifted: string[] = [];
  const cmp = (label: string, ours: unknown, theirs: unknown) => {
    if (norm(ours).toLowerCase() !== norm(theirs).toLowerCase()) {
      drifted.push(`${label} (we show "${norm(ours)}", Jobber has "${norm(theirs) || "none"}")`);
    }
  };
  if (wantFirst !== null) cmp("first name", row.first_name, jc.firstName);
  if (wantLast  !== null) cmp("last name",  row.last_name,  jc.lastName);
  if (wantRole  !== null) cmp("role",       row.jobber_role, jc.role);
  if (wantEmail !== null) cmp("email",      row.email,      curEmail?.address);
  if (wantPhone !== null && digits(row.phone) !== digits(curPhone?.number)) {
    drifted.push(`phone (we show "${row.phone ?? ""}", Jobber has "${curPhone?.number ?? "none"}")`);
  }
  if (drifted.length) {
    return fail("stale_view",
      `Jobber has changed since this page loaded, so saving could overwrite the wrong value: ${drifted.join("; ")}. ` +
      `Refresh to pull Jobber's current values, then re-apply your edit.`, { drifted });
  }

  // ---- build the nested contactsToEdit --------------------------------------------------------
  const attrs: Record<string, unknown> = { id: row.jobber_contact_id };
  if (wantFirst !== null) attrs.firstName = wantFirst;
  if (wantLast  !== null) attrs.lastName  = wantLast;
  if (wantRole  !== null) attrs.role      = wantRole;
  let emailAct: "none" | "add" | "edit" | "delete" = "none";
  let phoneAct: "none" | "add" | "edit" | "delete" = "none";
  if (wantEmail !== null) {
    if (wantEmail === "") { if (curEmail) { attrs.emailsToDelete = [curEmail.id]; emailAct = "delete"; } }
    else if (curEmail)    { attrs.emailsToEdit = [{ id: curEmail.id, address: wantEmail }]; emailAct = "edit"; }
    else                  { attrs.emailsToAdd  = [{ address: wantEmail, description: "MAIN", primary: true }]; emailAct = "add"; }
  }
  if (wantPhone !== null) {
    if (wantPhone === "") { if (curPhone) { attrs.phonesToDelete = [curPhone.id]; phoneAct = "delete"; } }
    else if (curPhone)    { attrs.phonesToEdit = [{ id: curPhone.id, number: wantPhone }]; phoneAct = "edit"; }
    else                  { attrs.phonesToAdd  = [{ number: wantPhone, description: "MAIN", primary: true }]; phoneAct = "add"; }
  }
  if (Object.keys(attrs).length === 1) {
    return done({ code: "no_changes", message: "Nothing to change.", jobber_contact_row_id: rowId });
  }

  const mut = await gql(token, M_EDIT, { id: link.source_id, input: { contactsToEdit: [attrs] } });
  if (!mut.ok) {
    return fail(mut.kind === "rejected" ? "jobber_rejected" : "jobber_unavailable",
      `Jobber did not accept the contact change (${mut.kind}): ${mut.detail}. Nothing was written on our side.`);
  }
  const uerr = ue(mut.data?.clientEdit);
  if (uerr) return fail("jobber_rejected", explainJobberRefusal(uerr, wantPhone));

  // ---- RE-READ and VERIFY, never the mutation echo --------------------------------------------
  const after = await gql(token, Q_ONE_CONTACT, { id: link.source_id });
  const ja = after.ok ? findIn(after) : null;
  const gotEmails: any[] = Array.isArray(ja?.emails?.nodes) ? ja.emails.nodes : [];
  const gotPhones: any[] = Array.isArray(ja?.phones?.nodes) ? ja.phones.nodes : [];
  const gotEmail = pickNode(ja?.emails), gotPhone = pickNode(ja?.phones);

  const ok =
    (wantFirst === null || norm(ja?.firstName) === wantFirst) &&
    (wantLast  === null || norm(ja?.lastName)  === wantLast) &&
    (wantRole  === null || norm(ja?.role)      === wantRole) &&
    (wantEmail === null || (wantEmail === ""
        ? (!curEmail || !gotEmails.some((e) => e?.id === curEmail.id))
        : norm(gotEmail?.address).toLowerCase() === wantEmail.toLowerCase())) &&
    (wantPhone === null || (wantPhone === ""
        ? (!curPhone || !gotPhones.some((p) => p?.id === curPhone.id))
        : digits(gotPhone?.number) === digits(wantPhone)));

  if (!after.ok || !ja || !ok) {
    // undo mirrors the action, for the same reason as the client-record path
    const undo: Record<string, unknown> = { id: row.jobber_contact_id };
    if (wantFirst !== null) undo.firstName = norm(jc.firstName);
    if (wantLast  !== null) undo.lastName  = norm(jc.lastName);
    if (wantRole  !== null) undo.role      = norm(jc.role);
    if (emailAct === "edit" && curEmail) undo.emailsToEdit = [{ id: curEmail.id, address: curEmail.address }];
    else if (emailAct === "add") {
      const born = gotEmails.find((e) => norm(e?.address).toLowerCase() === String(wantEmail).toLowerCase());
      if (born?.id) undo.emailsToDelete = [born.id];
    } else if (emailAct === "delete" && curEmail) {
      undo.emailsToAdd = [{ address: curEmail.address, description: enumDesc(curEmail.description, EMAIL_DESCRIPTIONS), primary: curEmail.primary === true }];
    }
    if (phoneAct === "edit" && curPhone) undo.phonesToEdit = [{ id: curPhone.id, number: curPhone.number }];
    else if (phoneAct === "add") {
      const born = gotPhones.find((p) => digits(p?.number) === digits(wantPhone));
      if (born?.id) undo.phonesToDelete = [born.id];
    } else if (phoneAct === "delete" && curPhone) {
      undo.phonesToAdd = [{ number: curPhone.number, description: enumDesc(curPhone.description, PHONE_DESCRIPTIONS), primary: curPhone.primary === true }];
    }
    let undone = false;
    if (Object.keys(undo).length > 1) {
      const rb = await gql(token, M_EDIT, { id: link.source_id, input: { contactsToEdit: [undo] } });
      undone = rb.ok && !ue(rb.data?.clientEdit);
    }
    return fail("verify_failed",
      undone
        ? "Jobber accepted the change but the re-read did not match; it was rolled back in Jobber (confirmed) and nothing was written on our side."
        : "Jobber accepted the change but the re-read did not match, and the rollback could NOT be confirmed - Jobber's state is unknown. Open the client in Jobber to check. Nothing was written on our side.",
      { rolled_back: undone });
  }

  // ---- only now, our side ---------------------------------------------------------------------
  const nowIso = new Date().toISOString();
  const { error: wErr } = await db.from("client_jobber_contacts").update({
    first_name: ja.firstName ?? null,
    last_name: ja.lastName ?? null,
    name: ja.name ?? null,
    jobber_role: ja.role ?? null,
    title: ja.title ?? null,
    is_billing_contact: ja.isBillingContact ?? null,
    email: gotEmail?.address ?? null,
    phone: gotPhone?.number ?? null,
    synced_at: nowIso,
    updated_at: nowIso,
  }).eq("id", rowId);
  if (wErr) {
    return fail("db_error_after_jobber",
      `The change is saved in Jobber but could not be written here: ${wErr.message}. Refresh the page to pull it back.`);
  }
  return done({ action: "edit_jobber_contact", jobber_contact_row_id: rowId, jobber: "updated" });
}

// ============================================================================
// THE CLIENT-RECORD WRITE PATH, extracted so PROMOTE reuses it instead of becoming a
// SECOND writer of the Jobber client's primary email and phone.
//
// 🛑 Exactly one piece of code may change those two values. Two writers means two drift
// guards, two verifies and two rollbacks, and eventually a rollback fighting a rollback.
// Promote decides WHO, then hands the same {email, phone} to this.
async function editClientRecord(opts: {
  token: string; gid: string; row: any; contactId: number;
  wantEmail: string | null; wantPhone: string | null; actor: string; via?: string;
}) {
  const { token, gid, row, contactId, wantEmail, wantPhone, actor, via } = opts;
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
  type Act = "none" | "add" | "edit" | "delete" | "star";
  let emailAct: Act = "none";
  let phoneAct: Act = "none";

  // An object this client ALREADY holds carrying the value we want. If one exists we star it
  // rather than overwriting a different object's value. See the "star" branches below.
  const emailTwin = wantEmail
    ? (Array.isArray(jc.emails) ? jc.emails : [])
        .find((e: any) => e?.id && norm(e.address).toLowerCase() === wantEmail.toLowerCase()) ?? null
    : null;
  const phoneTwin = wantPhone
    ? (Array.isArray(jc.phones) ? jc.phones : [])
        .find((p: any) => p?.id && digits(p.number) === digits(wantPhone)) ?? null
    : null;

  const input: Record<string, unknown> = {};
  if (wantEmail !== null) {
    if (wantEmail === "") {
      if (curEmail) { input.emailsToDelete = [curEmail.id]; emailAct = "delete"; }
    } else if (emailTwin && emailTwin.id !== curEmail?.id) {
      // 🛑 THIS CLIENT ALREADY HOLDS THIS ADDRESS ON ANOTHER Email OBJECT: STAR THAT ONE.
      // The `emailsToEdit {id: curEmail.id, address: wantEmail}` branch below rewrites the
      // CURRENTLY-STARRED object's address in place, which DESTROYS the address it held.
      // That is correct for an EDIT (this contact's address really is changing) and wrong
      // for a PROMOTE, where we are making a DIFFERENT contact's existing address primary
      // and the old one must survive. Both callers share this writer (:943 promote,
      // :1041 edit), which is why the defect was invisible: the drift guard above compares
      // our stored value against Jobber's primary, and on a promote those AGREE - the
      // clobber comes from writing the NEW address onto the OLD object, not from staleness.
      // Measured on 112-YA 2026-09-23 before writing this: `emailsToEdit [{id, primary:true}]`
      // with NO address is accepted, moves the star, auto-demotes the previous one, leaves
      // exactly one star, and every address survives.
      input.emailsToEdit = [{ id: emailTwin.id, primary: true }];
      emailAct = "star";
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
    } else if (phoneTwin && phoneTwin.id !== curPhone?.id) {
      // Same defect, same fix, on the phone side - promote copies the phone too.
      input.phonesToEdit = [{ id: phoneTwin.id, primary: true }];
      phoneAct = "star";
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
  if (uerr) return fail("jobber_rejected", explainJobberRefusal(uerr, wantPhone));

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
    } else if (emailAct === "star" && curEmail) {
      // Undoing a STAR is re-starring the object that held it. No address moved, so there is
      // nothing else to restore, and Jobber auto-demotes the one we starred (measured 112-YA).
      undo.emailsToEdit = [{ id: curEmail.id, primary: true }];
    }
    if (phoneAct === "star" && curPhone) {
      undo.phonesToEdit = [{ id: curPhone.id, primary: true }];
    } else if (phoneAct === "edit" && curPhone) {
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
    via,
    email: wantEmail === null ? row.email : (wantEmail === "" ? null : wantEmail),
    phone: wantPhone === null ? row.phone : (wantPhone === "" ? null : wantPhone),
    pushed_to_jobber: true,
    actor,
  });
}
// ============================================================================
// action:"promote" - make a person's details the client's own contact details.
//
// 🛑 JOBBER HAS NO PRIMARY-CONTACT FLAG. A 751-type schema sweep, with a positive control that
// DID return Email.primary and ClientPhoneNumber.primary, found `primary` only on email and
// phone objects; isBillingContact is a different boolean. So "primary contact" is OUR concept
// and there is nothing in Jobber to set. Fred's decision (2026-09-21) is the only version Jobber
// can express: promoting COPIES that person's email and phone onto the Jobber CLIENT's own
// primary Email and ClientPhoneNumber. It is a copy, not a move - the person keeps their own.
//
// MEASURED, so the implementation can be simple: setting primary:true on a second email
// AUTO-DEMOTES the first, in the same call, atomically. There is no two-primary window to guard
// and no explicit demote to issue. (⚠ `description` does NOT move with it: "Main" stayed on the
// demoted address. We deliberately leave descriptions alone.)
//
// AND IT GOES THROUGH editClientRecord, not its own write. One writer for those two values.
async function handlePromote(body: any, actor: string) {
  const preview = body?.preview === true;
  const clientId = Number(body.client_id);
  if (!Number.isInteger(clientId) || clientId <= 0) return fail("bad_request", "client_id is required.");

  // Handing the badge BACK to the client record needs no Jobber write at all: the client's own
  // email and phone are already whatever they are. Only the pointer moves. (It does NOT restore an
  // address a previous promote overwrote - that is a separate edit, and pretending otherwise would
  // be the kind of false success this function exists to avoid.)
  if (body?.to_client_record === true) {
    if (preview) {
      return done({ action: "promote", preview: true, client_id: clientId, to_client_record: true,
        person: { label: "the client record", email: null, phone: null, source: "client_record" },
        refusal: null,
        note: "The badge moves back to the client record. Nothing is written to Jobber, and the client's email and phone stay exactly as they are." });
    }
    const { error } = await db.from("clients").update({ primary_contact_ref: null }).eq("id", clientId);
    if (error) return fail("db_error", `Could not move the primary back: ${error.message}`);
    return done({ action: "promote", client_id: clientId, to_client_record: true, primary_contact_ref: null });
  }

  const jRowId = body.jobber_contact_row_id != null ? Number(body.jobber_contact_row_id) : null;
  const oRowId = body.contact_id != null ? Number(body.contact_id) : null;
  if ((jRowId == null) === (oRowId == null)) {
    return fail("bad_request", "Pass exactly one of jobber_contact_row_id or contact_id.");
  }

  // ---- who is being promoted -------------------------------------------------------------
  let person: { label: string; email: string | null; phone: string | null; source: string };
  if (jRowId != null) {
    const { data: p, error } = await db.from("client_jobber_contacts")
      .select("id, client_id, name, first_name, last_name, email, phone, deleted_at")
      .eq("id", jRowId).maybeSingle();
    if (error) return fail("db_error", `Could not read the contact: ${error.message}`);
    if (!p || p.deleted_at) return fail("not_found", "That contact no longer exists. Refresh the page.");
    if (Number(p.client_id) !== clientId) return fail("bad_request", "That contact belongs to a different client.");
    person = {
      label: norm(p.name) || norm(`${p.first_name ?? ""} ${p.last_name ?? ""}`) || "this contact",
      email: p.email, phone: p.phone, source: "jobber",
    };
  } else {
    const { data: p, error } = await db.from("client_contacts")
      .select("id, client_id, name, first_name, last_name, contact_role, property_id, email, phone")
      .eq("id", oRowId).maybeSingle();
    if (error) return fail("db_error", `Could not read the contact: ${error.message}`);
    if (!p) return fail("not_found", "That contact does not exist.");
    if (Number(p.client_id) !== clientId) return fail("bad_request", "That contact belongs to a different client.");
    if (p.property_id === null && p.contact_role === "primary") {
      return fail("already_primary", "That row IS the client record. There is nothing to promote.");
    }
    person = {
      label: norm(p.name) || norm(`${p.first_name ?? ""} ${p.last_name ?? ""}`) || `the ${p.contact_role} contact`,
      email: p.email, phone: p.phone, source: "ours",
    };
  }

  // ---- refusals, IN THE FUNCTION so the UI is not the only guard ---------------------------
  // 🛑 A COMMA-BEARING ADDRESS IS REFUSED. 20 of our 22 `city` rows hold several addresses in
  // one string. Jobber stores whatever string it is given, the verify would compare equal and
  // PASS, and the client's email of record would silently become "a@x, b@y, c@z" - which then
  // reaches five ops.* views and every DERM send. Splitting it is a human decision.
  const emailHasComma = (person.email ?? "").includes(",");
  const hasSomething = norm(person.email) !== "" || norm(person.phone) !== "";

  // ---- the mirror row (the client record) --------------------------------------------------
  const { data: mirror } = await db.from("client_contacts")
    .select("id, client_id, property_id, contact_role, name, email, phone")
    .eq("client_id", clientId).is("property_id", null).eq("contact_role", "primary").maybeSingle();

  // ---- what the DERM recipient is now, and would be after ----------------------------------
  // Both lines come from client.fn_derm_recipient, the SAME function send-derm-email uses, so
  // the dialog cannot claim one thing while the sender does another.
  // 🛑 THE SET, NOT THE SINGLE ADDRESS (2026-09-22). Several people can now hold the service
  // report, so the dialog has to be able to say so.
  const { data: dermNow } = await db.schema("client").rpc("fn_derm_recipients", { p_client_id: clientId });
  const { data: dermAfter } = await db.schema("client").rpc("fn_derm_recipients", {
    p_client_id: clientId,
    p_override_primary_email: norm(person.email) === "" ? null : person.email,
  });
  const mails = (v: unknown): string[] =>
    ((v ?? []) as Array<{ email?: string | null }>)
      .map((r) => String(r?.email ?? "").trim()).filter((e) => e.includes("@"));
  const nowAll = mails(dermNow);
  const afterAll = mails(dermAfter);
  // 🛑 `now` / `after` STAY STRINGS. The published app reads them, and changing a shape the live
  // bundle already renders is the deploy-order mistake this estate keeps paying for: server first
  // only ever works when it ACCEPTS more, never when it RETURNS something different. The arrays
  // are ADDED alongside, so the dialog can move to them whenever it ships.
  const nowEmail = nowAll[0] ?? null;
  const afterEmail = afterAll[0] ?? null;

  const refusal =
    emailHasComma ? { code: "multi_address",
        message: `${person.label} holds several addresses in one field ("${person.email}"), and a client can only have one email in Jobber. Split it into separate contacts first.` }
    : !hasSomething ? { code: "nothing_to_copy",
        message: `${person.label} has no email and no phone, so there is nothing to copy onto the client record.` }
    : !mirror ? { code: "no_client_record",
        message: "This client has no contact details in Jobber yet, so there is nothing to promote onto. Add an email or phone with Edit client first." }
    : null;

  if (preview) {
    return done({
      action: "promote", preview: true, client_id: clientId,
      person: { label: person.label, email: person.email, phone: person.phone, source: person.source },
      client_record: mirror ? { contact_id: mirror.id, email: mirror.email, phone: mirror.phone } : null,
      after: {
        email: norm(person.email) === "" ? (mirror?.email ?? null) : person.email,
        phone: norm(person.phone) === "" ? (mirror?.phone ?? null) : person.phone,
      },
      derm: {
        now: nowEmail, after: afterEmail, moves: nowEmail !== afterEmail,
        // appended 2026-09-22; `now`/`after` above are kept for the published bundle
        now_all: nowAll, after_all: afterAll,
        moves_all: JSON.stringify(nowAll) !== JSON.stringify(afterAll),
      },
      // 🛑 a missing value is OMITTED, never cleared. Promote must not empty the client's phone
      // just because the person it promotes has none.
      keeps: {
        email: norm(person.email) === "",
        phone: norm(person.phone) === "",
      },
      refusal,
    });
  }

  if (refusal) return fail(refusal.code, refusal.message);

  const wantEmail = norm(person.email) === "" ? null : norm(person.email);
  const wantPhone = norm(person.phone) === "" ? null : norm(person.phone);
  if (wantEmail !== null && !EMAIL_RE.test(wantEmail)) {
    return fail("bad_request", `${person.label}'s email does not look valid: ${wantEmail}`);
  }

  const { data: link } = await db.from("entity_source_links").select("source_id")
    .eq("entity_type", "client").eq("source_system", "jobber").eq("entity_id", clientId).maybeSingle();
  if (!link?.source_id) return fail("not_linked", "This client has no live Jobber link.");

  let token: string;
  try { token = await getJobberToken(); }
  catch (e) { return fail("jobber_unavailable", `Could not reach Jobber: ${e instanceof Error ? e.message : String(e)}`); }

  // ONE writer. Same drift guard, same verify, same rollback as a hand edit of the client record.
  const res = await editClientRecord({
    token, gid: link.source_id as string, row: mirror, contactId: Number(mirror!.id),
    wantEmail, wantPhone, actor, via: `promote:${person.source}`,
  });

  // 🛑 THE BADGE MOVES ONLY AFTER JOBBER IS VERIFIED. editClientRecord returns a 200 for refusals
  // too, so read body.ok - the same rule the UI has to follow. If Jobber refused or the rollback
  // ran, the pointer must NOT move, or the app would show a primary whose details never landed.
  const out = await res.clone().json().catch(() => null);
  if (out?.ok !== true) return res;

  // clients.primary_contact_ref is the marker BECAUSE contact_role cannot be: that row is the
  // poll's ON CONFLICT target, so moving contact_role mints a second primary within ~20 seconds.
  const ref = person.source === "jobber" ? `jobber:${jRowId}` : `ours:${oRowId}`;
  const { error: pErr } = await db.from("clients").update({ primary_contact_ref: ref }).eq("id", clientId);
  if (pErr) {
    return fail("record_failed",
      `Jobber was updated and verified, but marking ${person.label} as the primary here failed ` +
      `(${pErr.message}). The details did move in Jobber; refresh and set the primary again.`);
  }
  return done({ ...out, primary_contact_ref: ref, promoted: person.label });
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
  if (String(body?.action ?? "").trim().toLowerCase() === "edit_jobber_contact") {
    return await handleEditJobberContact(body);
  }
  if (String(body?.action ?? "").trim().toLowerCase() === "promote") {
    return await handlePromote(body, actor);
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

  return await editClientRecord({ token, gid, row, contactId, wantEmail, wantPhone, actor });
});
