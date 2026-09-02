// ============================================================================
// jobber-push-custom-field — the OUTBOUND half of the property custom-field sync
// ----------------------------------------------------------------------------
// Fred, 2026-09-02: "we need a two way ... when edit at our app it reflects on jobber."
//
// Drains sync.outbound_queue. Each row is an INTENT recorded by
// sync.fn_enqueue_outbound_custom_field inside the staff member's own transaction; this function
// turns intent into a Jobber write and then, only after verifying it, into a shadow re-baseline.
//
// Invoked by pg_cron with an Authorization: Bearer <service_role_key> header. Deployed WITH
// verify_jwt=true (pinned in supabase/config.toml). Same rule as jobber-push-visit: the handler
// only DECODES the bearer to check role=service_role, so the gateway MUST verify the signature.
// Do NOT deploy this one with --no-verify-jwt.
//
// ============================================================================
// THE ORDER IS THE ENTIRE SAFETY ARGUMENT: PUSH -> READ BACK -> THEN RECORD THE SHADOW
// ============================================================================
// Push without re-baselining the shadow and the row FREEZES on the next poll: fn_shadow_decision
// sees the source move AND our side move in the same comparison, which is CONFLICT by definition.
//
// Record the shadow BEFORE a push that then fails and it is WORSE than a freeze: the shadow claims
// Jobber holds the new value while Jobber still holds the old one, so the next poll reads the true
// old value as a fresh Jobber edit and ADOPTS it over the staff member's number. Silent data loss
// in the exact column this function exists to propagate.
//
// The crash window is therefore benign BY CONSTRUCTION rather than by luck. If this function dies
// between the Jobber write and the shadow write, the queue row is still 'pending'. The retry
// re-reads Jobber, finds it already equal to the desired value, takes the "already equal" branch
// and only re-baselines. Idempotent, and it converges. That is why the row is NOT marked done
// until after the shadow write, and why attempts are counted rather than the row being claimed.
//
// ============================================================================
// WHAT IT REFUSES, AND WHY EACH REFUSAL EXISTS
// ============================================================================
//  * conflict_at set        a human owns that row; pushing would bury the question
//  * live Jobber != shadow  the SOURCE moved since we last looked. Our side moving is not licence
//                           to overwrite theirs. Left for the inbound sync / a human.
//  * a CLEAR                desired_value is JSON null. NOT pushed. See the note inside processRow.
//  * unlinked / deleted /   no Property GID to write to.
//    billing property
//
// A Jobber NUMERIC custom field reports empty as 0, so "Jobber has 0" and "nobody ever filled it
// in" are the same byte. Comparisons below normalise 0 and null together for the numeric field.
//
// jsonb identity matters: 3061111 must round-trip as a jsonb NUMBER and 3061112 as a jsonb STRING.
// fn_shadow_decision compares with IS DISTINCT FROM, so recording "403" instead of 403 would make
// every later poll see a change that never happened, on all 477 grease-trap rows.
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GQL_VERSION = "2026-04-16";
const MAX_ATTEMPTS = 5;
const BATCH = 25;
const db = createClient(SUPABASE_URL, SERVICE_KEY);

type Field = {
  label: string;
  column: string;
  fragment: string;
  read: (n: any) => any;
  input: (v: any) => Record<string, unknown>;
  isNumeric: boolean;
};

const FIELDS: Record<string, Field> = {
  "gid://Jobber/CustomFieldConfigurationNumeric/3061111": {
    label: "Grease Trap size",
    column: "grease_trap_size_gallons",
    fragment: "... on CustomFieldNumeric { label valueNumeric }",
    read: (n) => (n && n.valueNumeric != null ? Number(n.valueNumeric) : null),
    input: (v) => ({ valueNumeric: Number(v) }),
    isNumeric: true,
  },
  "gid://Jobber/CustomFieldConfigurationText/3061112": {
    label: "Lock Box/Key",
    column: "lock_box_key",
    fragment: "... on CustomFieldText { label valueText }",
    read: (n) => (n && n.valueText != null && n.valueText !== "" ? String(n.valueText) : null),
    input: (v) => ({ valueText: String(v) }),
    isNumeric: false,
  },
};

async function getJobberToken(): Promise<string> {
  const { data, error } = await db.from("webhook_tokens")
    .select("access_token,refresh_token,client_id,client_secret,expires_at")
    .eq("source_system", "jobber_write").single();
  if (error || !data) throw new Error("no jobber_write token row");
  if (new Date(data.expires_at).getTime() > Date.now() + 120_000) return data.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(data.refresh_token)}` +
    `&client_id=${encodeURIComponent(data.client_id)}&client_secret=${encodeURIComponent(data.client_secret)}`;
  const r = await fetch("https://api.getjobber.com/api/oauth/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body,
  });
  if (!r.ok) throw new Error(`token refresh failed ${r.status}: ${(await r.text()).slice(0, 150)}`);
  const t = await r.json();
  const exp = JSON.parse(atob(t.access_token.split(".")[1])).exp * 1000;
  await db.from("webhook_tokens").update({
    access_token: t.access_token, refresh_token: t.refresh_token || data.refresh_token,
    expires_at: new Date(exp).toISOString(), updated_at: new Date().toISOString(),
  }).eq("source_system", "jobber_write");
  return t.access_token;
}

async function gql(token: string, query: string, variables?: unknown, _retry = 0): Promise<any> {
  const r = await fetch("https://api.getjobber.com/api/graphql", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`, "Content-Type": "application/json",
      "X-JOBBER-GRAPHQL-VERSION": GQL_VERSION,
    },
    body: JSON.stringify({ query, variables }),
  });
  // Jobber sheds load with an HTML waiting room at HTTP 200: the status code lies, the
  // content-type does not. Reading that as "the field is empty" is how a sync silently
  // decides a populated field was cleared.
  const ctype = r.headers.get("content-type") || "";
  if (!ctype.includes("json")) {
    throw new Error(`Jobber returned ${ctype} at HTTP ${r.status} (waiting room?)`);
  }
  const j = await r.json().catch(() => ({}));
  const throttled = r.status === 429 ||
    (Array.isArray(j.errors) && j.errors.some((e: any) =>
      e?.extensions?.code === "THROTTLED" || /throttl/i.test(e?.message || "")));
  if (throttled && _retry < 5) {
    const waitMs = Math.min(30_000, 1_000 * Math.pow(2, _retry)) + _retry * 250;
    console.log(`[push-cf] throttled — backoff ${waitMs}ms (retry ${_retry + 1}/5)`);
    await new Promise((s) => setTimeout(s, waitMs));
    return gql(token, query, variables, _retry + 1);
  }
  // A well-formed reply with no `data` key is a throttle or an outage, never an answer.
  if (j.errors) throw new Error(`GraphQL: ${JSON.stringify(j.errors).slice(0, 300)}`);
  if (!("data" in j)) throw new Error(`Jobber replied with no data key: ${JSON.stringify(j).slice(0, 200)}`);
  return j.data;
}

const norm = (f: Field, v: any) => (f.isNumeric && (v === 0 || v === null || v === undefined) ? 0 : v);
const same = (f: Field, a: any, b: any) =>
  f.isNumeric ? Number(norm(f, a)) === Number(norm(f, b)) : String(a ?? "") === String(b ?? "");

// All four DB touches below go through public.* SECURITY DEFINER wrappers instead of addressing
// the sync schema directly. PostgREST does not expose that schema, so the direct form failed at
// runtime with `Invalid schema: sync` even though service_role holds the grant on it.
// A PRIVILEGE CHECK IS NOT A REACHABILITY CHECK. Wrappers: 2026-09-02_1500.
async function finish(id: number, status: string, err: string | null, attempts: number) {
  const { error } = await db.rpc("fn_outbound_queue_finish", {
    p_id: id, p_status: status, p_error: err, p_attempts: attempts,
  });
  if (error) console.error(`[push-cf] finish(${id}) failed: ${error.message}`);
}

async function processRow(token: string, row: any): Promise<string> {
  const f = FIELDS[row.field_key];
  if (!f) { await finish(row.id, "skipped", `unknown field_key ${row.field_key}`, row.attempts); return "skipped"; }

  // ---- CLEARS ARE NOT PUSHED, DELIBERATELY -------------------------------------------------
  // desired_value JSON null means a staff member emptied the field. Blanking a Jobber field from
  // an unattended process is the single most damaging write this path can make, and the INBOUND
  // half already refuses the mirror case: fn_sync_property_custom_field returns
  // 'REFUSED:would clear' because the handler never passes p_allow_clear. Refusing in both
  // directions keeps the two halves symmetric.
  // The cost is real and is NOT hidden: the row lands as 'skipped' with this reason and shows up
  // in sync.v_outbound_queue_health, so a clear that needs to reach Jobber is visible rather than
  // silently dropped. Whether an app-side clear should blank Jobber is a business decision.
  if (row.desired_value === null) {
    await finish(row.id, "skipped", "clear not pushed: emptying a Jobber field is not automated", row.attempts);
    return "skipped";
  }

  const { data: prop } = await db.from("properties")
    .select("id,deleted_at,is_billing," + f.column).eq("id", row.entity_id).maybeSingle();
  if (!prop || prop.deleted_at || prop.is_billing) {
    await finish(row.id, "skipped", "property missing, soft-deleted or a billing row", row.attempts);
    return "skipped";
  }

  const { data: link } = await db.from("entity_source_links")
    .select("source_id").eq("entity_type", "property").eq("source_system", "jobber")
    .eq("entity_id", row.entity_id).maybeSingle();
  if (!link?.source_id) {
    await finish(row.id, "skipped", "property has no Jobber link", row.attempts);
    return "skipped";
  }

  const { data: shRows, error: shReadErr } = await db.rpc("fn_outbound_shadow_state", {
    p_entity_id: row.entity_id, p_field_key: row.field_key,
  });
  if (shReadErr) throw new Error(`shadow read failed: ${shReadErr.message}`);
  const shadow = Array.isArray(shRows) && shRows.length ? shRows[0] : null;

  if (shadow?.conflict_at) {
    await finish(row.id, "skipped", "row is frozen (conflict_at set) — a human owns it", row.attempts);
    return "skipped";
  }

  const readQ = `query($id:EncodedId!){ property(id:$id){ id customFields { __typename ${f.fragment} } } }`;
  const readLive = async () => {
    const d = await gql(token, readQ, { id: link.source_id });
    return f.read((d.property?.customFields || []).find((c: any) => c.label === f.label));
  };

  const live = await readLive();

  // The SOURCE moved since we last looked. Our side moving is not licence to overwrite theirs.
  // Leave it for the inbound sync, which will score it CONFLICT and freeze it for a person.
  if (shadow && !same(f, live, shadow.source_value)) {
    await finish(row.id, "skipped",
      `Jobber moved since we last saw it (holds ${JSON.stringify(live)}, we last saw ` +
      `${JSON.stringify(shadow.source_value)}) — resolve as a conflict, not an overwrite`, row.attempts);
    return "skipped";
  }

  const desired = row.desired_value;

  // Already equal. This is also the branch a retry lands on after a crash between the Jobber
  // write and the shadow write, which is what makes the crash window benign.
  if (!same(f, live, desired)) {
    const editM = `mutation($id:EncodedId!, $input:PropertyEditInput!){
      propertyEdit(propertyId:$id, input:$input){
        property { id customFields { __typename ${f.fragment} } }
        userErrors { message path } } }`;
    const res = await gql(token, editM, {
      id: link.source_id,
      input: { customFields: [{ customFieldConfigurationId: btoa(row.field_key), ...f.input(desired) }] },
    });
    const ue = res.propertyEdit?.userErrors;
    if (ue?.length) throw new Error(`userErrors ${JSON.stringify(ue).slice(0, 200)}`);

    // SEPARATE request. The mutation's own echo is not evidence.
    const back = await readLive();
    if (!same(f, back, desired)) {
      throw new Error(`READ-BACK MISMATCH: Jobber holds ${JSON.stringify(back)}, expected ${JSON.stringify(desired)}`);
    }
  }

  // ONLY NOW. Re-baseline both sides to the value that is now true in both systems, so the next
  // poll returns IN_SYNC instead of freezing the row.
  const { error: shErr } = await db.rpc("fn_outbound_record_shadow", {
    p_entity_id: row.entity_id, p_field_key: row.field_key,
    p_field_label: row.field_label, p_value: desired,
  });
  if (shErr) throw new Error(`shadow write failed: ${shErr.message}`);

  await finish(row.id, "done", null, row.attempts);
  return "done";
}

Deno.serve(async (req) => {
  // role=service_role only. The gateway verifies the signature (verify_jwt=true); this only decodes.
  try {
    const auth = req.headers.get("Authorization") || "";
    const tok = auth.replace(/^Bearer\s+/i, "");
    const role = JSON.parse(atob(tok.split(".")[1] || "")).role;
    if (role !== "service_role") return new Response("forbidden", { status: 403 });
  } catch {
    return new Response("forbidden", { status: 403 });
  }

  const summary = { claimed: 0, done: 0, skipped: 0, failed: 0, retry: 0 };
  try {
    const { data: rows, error } = await db.rpc("fn_outbound_queue_take", { p_limit: BATCH });
    if (error) throw new Error(error.message);
    summary.claimed = rows?.length ?? 0;
    if (!rows?.length) return new Response(JSON.stringify(summary), { headers: { "Content-Type": "application/json" } });

    const token = await getJobberToken();
    for (const row of rows) {
      try {
        const r = await processRow(token, row);
        if (r === "done") summary.done++; else summary.skipped++;
      } catch (e) {
        const attempts = (row.attempts ?? 0) + 1;
        const msg = String((e as Error).message).slice(0, 500);
        if (attempts >= MAX_ATTEMPTS) { await finish(row.id, "failed", msg, attempts); summary.failed++; }
        else { await finish(row.id, "pending", msg, attempts); summary.retry++; }
        console.error(`[push-cf] property ${row.entity_id} ${row.field_label}: ${msg}`);
      }
    }
  } catch (e) {
    console.error(`[push-cf] fatal: ${(e as Error).message}`);
    return new Response(JSON.stringify({ ...summary, fatal: (e as Error).message }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
  console.log(`[push-cf] ${JSON.stringify(summary)}`);
  return new Response(JSON.stringify(summary), { headers: { "Content-Type": "application/json" } });
});
