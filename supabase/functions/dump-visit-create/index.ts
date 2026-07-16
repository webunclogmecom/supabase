// dump-visit-create — public QR endpoint for drivers to self-schedule a dump visit.
//
// FLOW: driver scans the QR on the truck -> Lovable "DUMP Schedule" page (holds NO secret)
//       -> POST here with {k, driver_id, dump} -> we create the visit as service_role
//       -> trg_push_visit_insert pushes it to Jobber automatically (we never call jobber-push-visit)
//       -> driver attaches the dump manifest photo to the Jobber visit note, as he already does.
//
// SECURITY MODEL (mirrors get-derm-doc): anon-callable, so THIS FUNCTION does its own authorization.
//   - verify_jwt = false  (the driver's phone has no JWT)
//   - the service_role key lives ONLY here, server-side; the page never sees it
//   - the QR carries a shared secret (DUMP_QR_KEY). Check is FAIL-CLOSED: a missing env var REJECTS
//     (copying webhook-airtable:1089-1100 — deliberately NOT sync-jobber-visit-drift:283, which
//     fails OPEN when its var is unset).
//   - the client is NEVER taken from the caller: `dump` is a key into a server-side whitelist, so the
//     worst a leaked URL can do is create a $0 dump visit on one of two fixed disposal sites.
//
// WHY NOT grant anon EXECUTE on create_calendar_visit: anon is WRITE-NONE by design, established
// twice (2026-07-11 phase3 visit-lifecycle lock revoked it from PUBLIC+anon in BOTH public.* and
// ops.*; 2026-07-12 anon_surface_harden closed the rest). create_calendar_visit already grants
// service_role, so this ships without touching the anon grant surface at all.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const QR_KEY = Deno.env.get("DUMP_QR_KEY") ?? "";

// Server-side whitelist. Verified against Prod 2026-07-16. The caller sends only the KEY ('DH'|'DP').
// property_id is deliberately the is_primary row: both dumps carry a billing-address duplicate, and
// Pompano's billing dup (Oakland Park) is a genuinely different address ~4mi from the facility.
const DUMPS = {
  DH: {
    label: "Homestead", client_id: 365, job_id: 1720, property_id: 98,
    address: "8950 SW 232nd Street, Cutler Bay", lat: 25.5517444, lng: -80.3368324, county: "Miami-Dade",
  },
  DP: {
    label: "Pompano", client_id: 76, job_id: 1662, property_id: 155,
    address: "2401 N Powerline Road, Pompano Beach", lat: 26.2632563, lng: -80.1552085, county: "Broward",
  },
} as const;

const SERVICE_LINE_ITEM_DUMP = 22; // "22 - Service Call - Labor" — requires_derm=false (explicit false,
                                   // unlike a free-text 'DUMP' item which classifies to NULL/unknown).
// create_calendar_visit has NO dedupe; a double-tap would create two DB visits AND two Jobber visits.
// SCOPE IS (site + DRIVER), never site alone: two drivers legitimately hit the same dump within 90
// minutes on a normal night, and each needs HIS OWN visit to attach HIS OWN manifest photo to. Keying
// on the site alone would silently absorb the second driver into the first driver's visit and leave
// him nowhere to put his manifest — which is the entire reason this app exists.
const IDEMPOTENCY_MINUTES = 90;

// Drivers: ops.v_calendar_driver is NOT a driver list (it returns all 7 active employees incl.
// Fred/Yannick). Active Technicians auto-appear; DRIVER_EXTRA_IDS covers non-Technician roles who
// actually drive (Grecia=1 42 assignments/90d, Aaron=26 21). Pending Fred's confirmation.
const DRIVER_EXTRA_IDS = [1, 26];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const db = createClient(SUPABASE_URL, SERVICE_KEY);

const etDate = () =>
  new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date()); // YYYY-MM-DD in ET — matches what trg_aa_reconcile_operating_date will derive.

const mapsUrl = (d: { lat: number; lng: number }) =>
  `https://www.google.com/maps/dir/?api=1&destination=${d.lat},${d.lng}`;

async function drivers() {
  const { data, error } = await db
    .from("employees")
    .select("id, full_name, role")
    .eq("status", "ACTIVE")
    .or(`role.eq.Technician,id.in.(${DRIVER_EXTRA_IDS.join(",")})`)
    .order("full_name");
  if (error) throw new Error(`drivers: ${error.message}`);
  return data ?? [];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // FAIL-CLOSED: no configured key => reject everything. Never fall through to "open".
  if (!QR_KEY) {
    console.error("[dump] DUMP_QR_KEY not set — rejecting");
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }

  if (String(body.k ?? "") !== QR_KEY) {
    console.warn("[dump] bad key");
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const action = String(body.action ?? "create");

  try {
    // The page calls this on load to render its pickers (anon can't read employees itself).
    if (action === "bootstrap") {
      return json({
        ok: true,
        drivers: await drivers(),
        dumps: Object.entries(DUMPS).map(([k, d]) => ({ key: k, label: d.label, address: d.address, county: d.county })),
      });
    }

    if (action !== "create") return json({ ok: false, error: "unknown action" }, 400);

    const dumpKey = String(body.dump ?? "") as keyof typeof DUMPS;
    const dump = DUMPS[dumpKey];
    if (!dump) return json({ ok: false, error: "pick a dump" }, 400);

    const driverId = Number(body.driver_id);
    if (!driverId) return json({ ok: false, error: "pick who you are" }, 400);

    const allowed = await drivers();
    const driver = allowed.find((d) => d.id === driverId);
    if (!driver) return json({ ok: false, error: "unknown driver" }, 400);

    // IDEMPOTENCY — THIS driver double-tapping must not create a second Jobber visit. Scoped to
    // (site + driver): a different driver heading to the same dump gets his own visit (see above).
    const since = new Date(Date.now() - IDEMPOTENCY_MINUTES * 60_000).toISOString();
    const { data: dupes, error: dupeErr } = await db
      .from("visits")
      .select("id, public_id, start_at, assigned_driver_id")
      .eq("client_id", dump.client_id)
      .eq("assigned_driver_id", driverId)
      .eq("visit_status", "scheduled")
      .is("deleted_at", null)
      .gte("start_at", since)
      .order("start_at", { ascending: false })
      .limit(1);
    if (dupeErr) throw new Error(`dupe check: ${dupeErr.message}`);

    if (dupes?.length) {
      const v = dupes[0];
      console.log(`[dump] idempotent hit — returning ${driver.full_name}'s existing visit ${v.id} for ${dumpKey}`);
      return json({
        ok: true, already: true, visit_id: v.id, public_id: v.public_id, driver: driver.full_name,
        dump_key: dumpKey, dump: dump.label, county: dump.county,
        address: dump.address, start_at: v.start_at, maps_url: mapsUrl(dump),
      });
    }

    const startAt = new Date();
    const endAt = new Date(startAt.getTime() + 60 * 60_000);

    // The ONLY sanctioned visit-creating path. It forces source='visit-calendar' (required: 'manual'
    // is CHECK-legal but is in neither trigger WHEN nor the push gate => would never reach Jobber)
    // and visit_status='scheduled', and seeds visit_team + line_items + visit_locations.
    const { data: visit, error } = await db.rpc("create_calendar_visit", {
      p_client_id: dump.client_id,
      p_job_id: dump.job_id,
      p_service_line_item_ids: [SERVICE_LINE_ITEM_DUMP],
      p_visit_date: etDate(),           // advisory — the BEFORE trigger re-derives it from start_at in ET
      p_property_id: dump.property_id,
      p_start_at: startAt.toISOString(),
      p_end_at: endAt.toISOString(),
      p_title: "Dump",                  // trg_prefix_visit_title prepends "000-DH Homestead Dump - "
      p_notes: `Dump run — ${driver.full_name} (via truck QR). Attach the dump manifest photo here.`,
      p_driver_id: driverId,
      p_team_ids: [driverId],
    });

    if (error) {
      // e.g. job archived => "create_calendar_visit: job X is not an active job for client Y".
      console.error(`[dump] create failed for ${dumpKey}:`, error.message);
      return json({ ok: false, error: "could not create the visit", detail: error.message }, 500);
    }

    const v = Array.isArray(visit) ? visit[0] : visit;
    console.log(`[dump] created visit ${v?.id} ${dumpKey} driver=${driver.full_name} — trigger will push to Jobber`);

    // Every field the receipt renders is echoed here ON PURPOSE — dump_key (drives the wrong-dump
    // identity colour), county, label, address, driver, time. The page must render the receipt from
    // THIS body, never from what the thumb tapped: if the server disagrees with his tap, he has to
    // SEE it rather than drive 45mi to the wrong county behind a confidently-wrong link.
    return json({
      ok: true, already: false, visit_id: v?.id, public_id: v?.public_id, driver: driver.full_name,
      dump_key: dumpKey, dump: dump.label, county: dump.county,
      address: dump.address, start_at: v?.start_at, maps_url: mapsUrl(dump),
    });
  } catch (e) {
    console.error("[dump] FATAL:", e instanceof Error ? e.message : String(e));
    return json({ ok: false, error: "server error" }, 500);
  }
});
