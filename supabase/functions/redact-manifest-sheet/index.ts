// redact-manifest-sheet — FP Blackout generator (rev 2, adversarial-review fixes wf_511c398b).
//
// Redacts a shared DERM address sheet for one (manifest, client): black everything except the form
// header [0, header_y) and the client's own Stamp band. Targets come from derm.fn_blackout_targets
// (fully-banded sheets only, order-consistency + page-identity gated, fingerprint-stale). Output:
// manifests/redacted/m<manifest_id>-<fp10>.jpg; the superseded object is DELETED after a successful
// swap; ledger derm.redacted_manifest_docs flips atomically; failures land in
// derm.redacted_manifest_errors with exponential backoff (<=48h); every run appends one heartbeat row
// to derm.blackout_sweep_log.
//
// AUTH: verify_jwt=true (config.toml pinned) + an in-handler role gate — the caller's JWT must carry
// role=service_role (the gateway already verified the signature; same pattern as jobber-push-visit).
// Invoked by pg_cron (*/10, limit 3 — edge CPU cap ~2s/request => small batches) and the backlog driver.

import { decode, Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BLACK = 0x000000ff;
const TIME_BUDGET_MS = 15000;

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const payload = JSON.parse(atob(tok.split(".")[1] ?? ""));
    return payload?.role ?? null;
  } catch {
    return null;
  }
}

// Minimal EXIF orientation sniff (JPEG APP1, tag 0x0112). Returns 1 when absent/unreadable.
function exifOrientation(b: Uint8Array): number {
  try {
    if (b[0] !== 0xff || b[1] !== 0xd8) return 1;
    let o = 2;
    while (o + 4 < b.length) {
      if (b[o] !== 0xff) break;
      const marker = b[o + 1];
      const size = (b[o + 2] << 8) | b[o + 3];
      if (marker === 0xe1 && size >= 14) {
        const t = o + 4;
        if (String.fromCharCode(...b.subarray(t, t + 4)) === "Exif") {
          const tiff = t + 6;
          const le = b[tiff] === 0x49;
          const rd16 = (p: number) => (le ? b[p] | (b[p + 1] << 8) : (b[p] << 8) | b[p + 1]);
          const rd32 = (p: number) =>
            le
              ? b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24)
              : (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
          const ifd = tiff + rd32(tiff + 4);
          const n = rd16(ifd);
          for (let i = 0; i < n; i++) {
            const e = ifd + 2 + i * 12;
            if (rd16(e) === 0x0112) return rd16(e + 8) || 1;
          }
        }
      }
      if (marker === 0xda) break; // start of scan
      o += 2 + size;
    }
  } catch {
    // fall through
  }
  return 1;
}

const dermHeaders = {
  "Content-Type": "application/json",
  "Content-Profile": "derm",
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
};

async function recordError(manifestId: number, msg: string) {
  // read attempts -> exponential backoff (2^n hours, capped 48)
  let attempts = 1;
  try {
    const g = await fetch(
      `${SUPABASE_URL}/rest/v1/redacted_manifest_errors?manifest_id=eq.${manifestId}&select=attempts`,
      { headers: { ...dermHeaders, "Accept-Profile": "derm" } },
    );
    const rows = g.ok ? await g.json() : [];
    if (rows.length) attempts = Number(rows[0].attempts) + 1;
  } catch { /* best effort */ }
  const backoffH = Math.min(Math.pow(2, attempts), 48);
  await fetch(`${SUPABASE_URL}/rest/v1/redacted_manifest_errors?on_conflict=manifest_id`, {
    method: "POST",
    headers: { ...dermHeaders, Prefer: "resolution=merge-duplicates" },
    body: JSON.stringify({
      manifest_id: manifestId,
      attempts,
      last_error: msg.slice(0, 500),
      next_retry_at: new Date(Date.now() + backoffH * 3600_000).toISOString(),
    }),
  }).catch(() => {});
}

Deno.serve(async (req) => {
  if (bearerRole(req) !== "service_role") {
    return json({ error: "service_role required" }, 403);
  }

  let body: { limit?: number } = {};
  try {
    body = await req.json();
  } catch { /* defaults */ }
  const limit = Math.min(Math.max(Number(body.limit ?? 3), 1), 5);
  const t0 = Date.now();

  const tr = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_blackout_targets`, {
    method: "POST",
    headers: dermHeaders,
    body: JSON.stringify({ p_limit: limit }),
  });
  if (!tr.ok) {
    return json({ error: "targets rpc failed", status: tr.status, detail: await tr.text() }, 500);
  }
  const targets: {
    manifest_id: number;
    client_id: number;
    ticket_key: string;
    source_url: string;
    effective_page: number;
    band_y0: number;
    band_y1: number;
    header_y: number | null;
    fingerprint: string;
    old_url: string | null;
  }[] = await tr.json();

  let generated = 0;
  const errors: { manifest_id: number; error: string }[] = [];

  for (const t of targets) {
    if (Date.now() - t0 > TIME_BUDGET_MS) break; // stay under the edge CPU/wall budget
    try {
      const src = await fetch(t.source_url);
      if (!src.ok) throw new Error(`source fetch ${src.status}`);
      const raw = new Uint8Array(await src.arrayBuffer());
      const ori = exifOrientation(raw);
      // orientation 3 = 180° (no axis swap, direction-unambiguous): rotate so the pixels match the
      // browser-displayed image the bands were placed on. Other non-1 orientations stay fail-safe.
      if (ori !== 1 && ori !== 3) throw new Error(`exif-orientation ${ori} (bands were placed on the browser-rotated image)`);
      let img = await decode(raw);
      if (!(img instanceof Image)) throw new Error("animated/unsupported image");
      if (ori === 3) img = img.rotate(180);
      const W = img.width, H = img.height;

      const y0 = Math.max(1, Math.round((H * Number(t.band_y0)) / 100));
      const y1 = Math.min(H, Math.round((H * Number(t.band_y1)) / 100));
      if (y1 <= y0) throw new Error(`degenerate band ${t.band_y0}..${t.band_y1}`);
      const headerY = t.header_y == null ? 0 : Math.max(0, Math.round((H * Number(t.header_y)) / 100));

      // visible = [1, headerY] + [y0, y1]; black the rest, full width (1-based coords)
      if (headerY + 1 < y0) img.drawBox(1, headerY + 1, W, y0 - headerY - 1, BLACK);
      if (y1 < H) img.drawBox(1, y1 + 1, W, H - y1, BLACK);

      const out = await img.encodeJPEG(80);
      const name = `redacted/m${t.manifest_id}-${String(t.fingerprint).slice(0, 10)}.jpg`;
      const up = await fetch(`${SUPABASE_URL}/storage/v1/object/manifests/${name}`, {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "Content-Type": "image/jpeg",
          "x-upsert": "true",
        },
        body: out,
      });
      if (!up.ok) throw new Error(`upload ${up.status} ${await up.text()}`);

      const url = `${SUPABASE_URL}/storage/v1/object/public/manifests/${name}`;
      const ins = await fetch(
        `${SUPABASE_URL}/rest/v1/redacted_manifest_docs?on_conflict=manifest_id`,
        {
          method: "POST",
          headers: { ...dermHeaders, Prefer: "resolution=merge-duplicates" },
          body: JSON.stringify({
            manifest_id: t.manifest_id,
            client_id: t.client_id,
            url,
            fingerprint: t.fingerprint,
            band_y0: t.band_y0,
            band_y1: t.band_y1,
            header_y: t.header_y,
            effective_page: t.effective_page,
            source_url: t.source_url,
            generated_at: new Date().toISOString(),
          }),
        },
      );
      if (!ins.ok) throw new Error(`ledger upsert ${ins.status} ${await ins.text()}`);

      // delete the superseded public object (never leave a stale wider-band copy fetchable)
      if (t.old_url && t.old_url !== url) {
        const oldPath = t.old_url.split("/object/public/manifests/")[1];
        if (oldPath?.startsWith("redacted/")) {
          await fetch(`${SUPABASE_URL}/storage/v1/object/manifests/${oldPath}`, {
            method: "DELETE",
            headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
          }).catch(() => {});
        }
      }
      // clear any retry-ledger entry
      await fetch(`${SUPABASE_URL}/rest/v1/redacted_manifest_errors?manifest_id=eq.${t.manifest_id}`, {
        method: "DELETE",
        headers: dermHeaders,
      }).catch(() => {});
      generated++;
    } catch (e) {
      const msg = String((e as Error)?.message ?? e);
      errors.push({ manifest_id: t.manifest_id, error: msg });
      await recordError(t.manifest_id, msg);
    }
  }

  // heartbeat (best effort)
  await fetch(`${SUPABASE_URL}/rest/v1/blackout_sweep_log`, {
    method: "POST",
    headers: dermHeaders,
    body: JSON.stringify({
      processed: targets.length,
      generated,
      error_count: errors.length,
      errors: errors.length ? errors : null,
    }),
  }).catch(() => {});

  return json({ processed: targets.length, generated, errors: errors.map((e) => e.manifest_id) });
});
