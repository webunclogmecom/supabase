// intake-slack-post: the Slack post when an intake form comes back, and when a Site file version waits for approval.
// Fred, 2026-11-05 (office training film): "Build a Slack post first", then from the mockups "go with option B short": a header
// and two lines, the reader opens the link for the rest. Never tags the person who made the version.
// WHO IS TAGGED (Trello #218, 2026-11-17): every person who can approve a Site file today, as the database returns them in
// `approvers` (the HR App's switch "Approve site files", minus the maker of the version), mapped by email to a Slack tag. Fred:
// "tag the persons who can approve the form (also remember to include the links on the notification so they can just click
// on it and it opens the submitted review)". Until then only Diego and Serena were tagged; that list is now the fallback for
// a database that does not send `approvers`. An approver with no Slack id here is named in plain text, never dropped.
// Shape and rules: docs/reference/slack-notifications.md.
//
// WHO CALLS IT: only the database. public.trg_slack_event_request (triggers zz_slack_form_back on public.property_intakes
// and zz_slack_version_waiting on public.property_pages) queues the call through pg_net, in the same transaction as the
// form or the version. So intake-submit, the public no-login function, is NOT changed and holds no Slack token, and a
// rolled-back write posts nothing. Whatever happens here, the form or the version is already saved.
//
// POSTS ONCE: public.fn_slack_event_claim inserts (kind, id) into public.slack_event_posts first; a second delivery of the
// same event finds the row and posts nothing. A Slack failure is written on that row and NEVER retried (the guide's
// section 5: an unreadable answer may mean it posted). public.fn_notification_health_items lists any event with no
// posted_at from 15 minutes on, in Fred's health email.
//
// NO CODES: the message is built only from the named keys public.fn_slack_event_claim returns. That function never reads
// a lock box code, a gate code, a form's answers, a link code or a version's content. Links use the form's and the
// property's id, never a code.
//
// A COLLECTOR TYPES THEIR OWN NAME on a public form, so it is escaped, its line breaks collapsed, and the sections are
// verbatim: "<!channel>", a bare @here or a pasted URL stay plain text, and a name cannot forge a line of the post.
//
// AUTH: verify_jwt=true PLUS an in-handler service_role gate.
// Body: { kind: "form_back"|"version_waiting", id: number, dry_run?: boolean, post_test?: boolean }
//   dry_run returns the message and writes nothing. post_test lets a test client's event post once, marked [TEST]; only a
//   holder of the server key can ask for it, and it cannot mark a real client's event as a test (the database decides).
//   Without post_test a test client's event posts nothing, so the collector's live test scripts stay out of the channel.
// Check: node scripts/checks/intake_slack_post.mjs (runs this file against stubs).

import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";
import { isSecretKeyCaller } from "../_shared/service-caller.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHANNEL = "C0BJYHQKZM1"; // #apps-notifications
const PLANNER = "https://planner.unclogme.app";
// Never on a test; never the person who made the version, who cannot approve their own.
// Slack ids by staff email (looked up in Slack 2026-11-17). A new approver gets a line here; until then they are named.
const SLACK_IDS: Record<string, string> = {
  "aaron@unclogme.com": "U0AMVRCEBHP",
  "contact@unclogme.com": "U0AL9JZ4V7C", // Diego
  "fred@ayache.com": "U0AN9B9MVHN",
  "serena@unclogme.com": "U0BKM57UPSS",
  "yannick@ayache.com": "U0AL2N6NMBM",
};
// Used only when the database sends no `approvers` (the body of 2026-11-05).
const FALLBACK = [{ name: "Diego", email: "contact@unclogme.com" }, { name: "Serena Natali", email: "serena@unclogme.com" }];

type Facts = {
  kind: "form_back" | "version_waiting"; ref_id: number; test: boolean;
  client_code: string | null; client_name: string | null; address: string | null; city: string | null;
  who: string | null;
  approvers?: { email: string; name: string }[];
  // form_back
  status?: string | null; answered?: number | null; of?: number | null; photos?: number | null;
  // version_waiting
  property_id?: number; version?: number; restored_from?: number | null; live_version?: number | null;
};

const json = (p: unknown, status = 200) =>
  new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });

function bearerRole(req: Request): string | null {
  if (isSecretKeyCaller(req)) return "service_role";
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

// the guide's rule 9
const esc = (t: string) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const oneLine = (t: string | null | undefined) => String(t ?? "").replace(/\s+/g, " ").trim();
const clean = (t: string | null | undefined, missing: string) => esc(oneLine(t) || missing);
const plural = (n: number, one: string) => `${n} ${one}${n === 1 ? "" : "s"}`;

function buildPost(f: Facts): { header: string; message: string; text: string } {
  const tag = f.test ? "[TEST] " : "";
  const who = clean(f.who, "someone");
  const subject = `${clean(f.client_code, "no code")} ${clean(f.client_name, "no name")}`;
  const place = [f.address, f.city].map(oneLine).filter(Boolean).join(", ");
  const where = place ? `, ${esc(place)}` : "";
  // The database already leaves out the maker of a version. A form's collector types their own name, so a person is left out
  // when the first word of what was typed is their first name (Serena on her own form).
  const first = (t: string | null | undefined) => oneLine(t).split(" ")[0].toLowerCase();
  const people = Array.isArray(f.approvers) ? f.approvers : FALLBACK;
  const mentions = f.test ? "" : people
    .filter((p) => !(f.who && first(p.name) && first(p.name) === first(f.who)))
    .map((p) => (SLACK_IDS[String(p.email).toLowerCase()] ? `<@${SLACK_IDS[String(p.email).toLowerCase()]}> ` : `${clean(p.name, "someone")} `))
    .join("");

  if (f.kind === "form_back") {
    const url = `${PLANNER}/forms/${f.ref_id}`;
    // the same words as the card on the Forms list, from the same view. A count that could not be read is left out (rule 5).
    const counts = f.answered == null || f.of == null || f.photos == null ? "" : ` · ${f.answered} of ${f.of} answered · ${plural(f.photos, "photo")}`;
    return {
      header: "📨 Intake form back",
      message: `📨 ${tag}${mentions}*<${url}|${subject}>*${where}\n${who} · ${clean(f.status, "not read")}${counts}`,
      text: `📨 ${tag}Intake form back: ${subject}, from ${who}`,
    };
  }

  // ?review=N opens that version's review on the page (Picture Planner reads it; a page that does not yet only opens the property).
  const url = `${PLANNER}/property/${f.property_id}?review=${f.version}`;
  const parts = [who, `version ${f.version}`, f.live_version ? `version ${f.live_version} is live` : "nothing live yet"];
  if (f.restored_from) parts.push(`restored from version ${f.restored_from}`);
  return {
    header: "📄 Site file waiting for approval",
    message: `📄 ${tag}${mentions}*<${url}|${subject}>*${where}\n${parts.join(" · ")}`,
    text: `📄 ${tag}Site file waiting for approval: ${subject}, version ${f.version}, from ${who}`,
  };
}

const db = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json", "x-app-source": "intake-slack-post" };

async function claim(kind: string, id: number, postTest: boolean, dryRun: boolean) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_slack_event_claim`, {
    method: "POST", headers: db,
    body: JSON.stringify({ p_kind: kind, p_id: id, p_post_test: postTest, p_dry_run: dryRun }),
  });
  if (!r.ok) throw new Error(`claim refused (${r.status})`);
  return await r.json();
}

// Writes the result on the claim row. Its own failure is only logged: the health item then lists the event.
async function record(kind: string, id: number, ts: string | null, error: string | null) {
  try {
    await fetch(`${SUPABASE_URL}/rest/v1/slack_event_posts?event_kind=eq.${kind}&ref_id=eq.${id}`, {
      method: "PATCH", headers: db,
      body: JSON.stringify({ posted_at: error ? null : new Date().toISOString(), message_ts: ts, error }),
    });
  } catch (e) { console.error("record:", e instanceof Error ? e.message : String(e)); }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);
  const body = (await req.json().catch(() => null)) ?? {};
  const kind = body.kind, id = Number(body.id);
  if ((kind !== "form_back" && kind !== "version_waiting") || !Number.isSafeInteger(id) || id <= 0) {
    return json({ error: "kind and id required" }, 400);
  }
  const dryRun = body.dry_run === true;

  let facts: (Facts & { skip?: string }) | null;
  try { facts = await claim(kind, id, body.post_test === true, dryRun); }
  catch (e) { console.error("slack post:", e instanceof Error ? e.message : String(e)); return json({ posted: false, reason: "claim failed" }); }
  if (!facts || facts.skip) return json({ posted: false, reason: facts?.skip ?? "nothing returned" });

  const post = buildPost(facts);
  if (dryRun) return json({ dry_run: true, ...post });

  const token = Deno.env.get("SLACK_BOT_TOKEN");
  let ts: string | null = null, error: string | null = null;
  if (!token) error = "SLACK_BOT_TOKEN is not set";
  else {
    try {
      const as = await slackIdentity(token, "Picture Planner", "picture-planner");
      const r = await fetch("https://slack.com/api/chat.postMessage", {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
        body: JSON.stringify({
          channel: CHANNEL, text: post.text,
          // verbatim here only, the helper is shared: <@U..> tags and <url|label> links still work, typed text is not parsed
          blocks: [slackHeader(post.header), ...slackSections(post.message).map((b: any) => ({ ...b, text: { ...b.text, verbatim: true } }))],
          unfurl_links: false, unfurl_media: false, ...as,
        }),
        signal: AbortSignal.timeout(10_000),
      });
      const j = await r.json().catch(() => null);
      if (j?.ok) ts = j.ts ?? null; else error = `Slack: ${j?.error ?? "the answer could not be read"}`;
    } catch (e) { error = `Slack: ${e instanceof Error ? e.message : String(e)}`; }
  }
  if (error) console.error("slack post:", error);
  await record(kind, id, ts, error);
  return json({ posted: !error, ts, reason: error }); // always 200: nothing retries this, and nobody is waiting on it
});
