// gdo-lookup: the Ops Portal's GDO lookup (Trello #242, ebj6IVxa). Fred, 2026-11-24: "go with D1 and all recommended,
// build it". Picks and defaults: Building Apps/Ops Portal/docs/00-fred-picks-2026-11-24-gdo-lookup.md.
//
// One POST, four actions. Staff only: verify_jwt = true (pinned in config.toml) and hr.check_app_action as the caller.
//   search {q?, site_id?}  Miami-Dade's public permit list (the county's document index), grouped one entry per permit,
//                          with which of our clients' records hold each number. With site_id and no q: every permit on
//                          the site's county parcels and on the parcels of the permits already on the site (Part 5 of
//                          round 2: the address alone found 1 of Wynd 28's 3 permits). A name also searches the
//                          addresses where that business is: our sites, then the places Google Maps gave the
//                          portal (pick S; `places`, found in the browser with the portal's site-restricted key,
//                          because Places refuses this server's key: HTTP 403, 2026-11-23).           gdo_lookup
//   read {url}             one county permit file read for holder, address, dates and cleaning (pick V). A text PDF is
//                          read by the permit reader parse-gdo-permit uses (_shared/gdo-permit-read.ts); a scan is read
//                          from its picture by Claude (pick E1).                                                gdo_lookup
//   file {url}             the county's file passed through as a PDF: the county serves it as a download, which a
//                          window cannot show (round 3 default "pass").                                         gdo_lookup
//   take {url, number}     the county's file copied into the gdo-permits bucket, never over an existing file, so the
//                          new permit row has its document. The save itself is client.upsert_gdo_permit from the
//                          portal, with its own checks.                                                    gdo_lookup_take
//
// 🛑 Never returns a permit page as text: page 1 carries the contact's name and mailing address and the county's
// temporary password for its reporting site. Only the fields below leave this function.
// 🛑 Files are fetched only from the county's own store (FILE_RE); anything else is refused (no open proxy).
// County calls are 0.5 s apart within a request (the Slack @GDO bot's courtesy). The county keeps 5 digits in its
// index (GDO-11423); our numbers have 6 since #227 (GDO-011423). Models and keys: docs/reference/anthropic-api-usage.md.

import Anthropic from "npm:@anthropic-ai/sdk";
import { checkAppAction } from "../_shared/access-check.ts";
import { flattenPdf, parsePermit } from "../_shared/gdo-permit-read.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const COUNTY = "https://api-ecmrer.miamidade.gov/derm/documents";
const FILE_RE = /^https:\/\/stecmrerportal\.blob\.core\.windows\.net\/dermdocuments\/[0-9a-f]{6,64}\.pdf$/i;
const MAX_PDF_BYTES = 15 * 1024 * 1024;
const MODEL = "claude-opus-5-5";
const ALLOW_HEADERS_FALLBACK = "authorization, x-client-info, apikey, content-type, x-app-source";

// ---------------------------------------------------------------------------------------------------- http helpers
function cors(req: Request): Record<string, string> {
  const requested = req.headers.get("access-control-request-headers");
  return {
    "Access-Control-Allow-Origin": req.headers.get("origin") ?? "*",
    "Access-Control-Allow-Headers": requested && requested.length ? requested : ALLOW_HEADERS_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin, Access-Control-Request-Headers",
  };
}
const json = (req: Request, body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(req), "Content-Type": "application/json" } });

class CountyDown extends Error {}
class Refused extends Error {
  constructor(public status: number, message: string) { super(message); }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Our database, as the service role (the caller's access was checked first). Read only, except take's file. */
async function rest<T = unknown>(path: string): Promise<T> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Accept-Profile": "public" },
  });
  if (!r.ok) throw new Error(`our records: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
  return (await r.json()) as T;
}
const inList = (xs: (string | number)[]) => `(${xs.map((x) => `"${String(x).replace(/"/g, "")}"`).join(",")})`;

// ---------------------------------------------------------------------------------------------------- the county
type CountyRow = {
  caseNumber?: string; facilityName?: string; houseNumber?: string; streetDirection?: string; streetName?: string;
  streetType?: string; unitNumber?: string; zipCode?: string; city?: string; folio?: string; date?: string; url?: string;
};
const BASE = {
  page: "1", limit: "100", sortOrder: "date_desc", searchTerm: "", facilityName: "", caseNumber: "GDO", folio: "",
  documentType: "OPERATING PERMIT", startDate: "", endDate: "", houseNumber: "", streetDirection: "", streetName: "",
  streetType: "", zipCode: "", description: "",
};

function makeCounty() {
  let last = 0;
  let calls = 0;
  async function one(over: Record<string, string>, page: number): Promise<{ data: CountyRow[]; total: number }> {
    const wait = last + 500 - Date.now();
    if (wait > 0) await sleep(wait);
    last = Date.now();
    calls++;
    let r: Response;
    try {
      r = await fetch(COUNTY, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ ...BASE, ...over, page: String(page) }),
        signal: AbortSignal.timeout(20_000),
      });
    } catch (e) {
      throw new CountyDown(`no answer: ${(e as Error).message}`);
    }
    // A busy or broken county can answer 200 with an HTML page: only a JSON body with a data list is an answer.
    const ctype = r.headers.get("content-type") ?? "";
    if (!r.ok || !ctype.includes("json")) throw new CountyDown(`HTTP ${r.status} ${ctype}`);
    const j = await r.json().catch(() => null) as { data?: CountyRow[]; total?: number } | null;
    if (!j || !Array.isArray(j.data)) throw new CountyDown("no data list in the answer");
    return { data: j.data, total: Number(j.total ?? j.data.length) || 0 };
  }
  /** Every row of a search, up to maxPages of 100. */
  async function all(over: Record<string, string>, maxPages = 5): Promise<{ rows: CountyRow[]; total: number; cut: boolean }> {
    const rows: CountyRow[] = [];
    let total = 0;
    for (let page = 1; page <= maxPages; page++) {
      const a = await one(over, page);
      total = a.total;
      rows.push(...a.data);
      if (rows.length >= total || a.data.length === 0) return { rows, total, cut: false };
    }
    return { rows, total, cut: rows.length < total };
  }
  return { all, calls: () => calls };
}

const clean = (s: unknown) => String(s ?? "").replace(/\s+/g, " ").trim();
const digitsOf = (n: string) => String(Number(String(n).replace(/\D/g, "")));
const six = (n: string) => "GDO-" + digitsOf(n).padStart(6, "0");
const five = (n: string) => "GDO-" + digitsOf(n).padStart(5, "0");
const addrOf = (x: CountyRow) =>
  [x.houseNumber, x.streetDirection, x.streetName, x.streetType].map(clean).filter(Boolean).join(" ");

type Permit = {
  number: string; county_number: string; index_name: string; address: string; unit: string; zip: string; city: string;
  folio: string; newest_doc: string; first_doc: string; docs: number; url: string; via: string[];
  ours: { gdo_id: number; client_id: number | null; client_code: string | null; property_id: number | null; status: string | null }[];
};

/** One entry per permit: its newest permit document, and how many it has. */
function group(rows: { row: CountyRow; via: string }[]): Permit[] {
  const by = new Map<string, Permit & { _newest: string }>();
  for (const { row: x, via } of rows) {
    const k = clean(x.caseNumber);
    if (!/^GDO-\d+$/i.test(k) || !x.url) continue;
    const key = digitsOf(k);
    const d = clean(x.date).slice(0, 10);
    let g = by.get(key);
    if (!g) {
      g = {
        number: six(k), county_number: k, index_name: "", address: "", unit: "", zip: "", city: "", folio: "",
        newest_doc: "", first_doc: d, docs: 0, url: "", via: [], ours: [], _newest: "",
      };
      by.set(key, g);
    }
    g.docs++;
    if (!g.via.includes(via)) g.via.push(via);
    if (d && (!g.first_doc || d < g.first_doc)) g.first_doc = d;
    if (!g._newest || clean(x.date) > g._newest) {
      g._newest = clean(x.date);
      g.newest_doc = d;
      g.index_name = clean(x.facilityName);
      g.address = addrOf(x);
      g.unit = clean(x.unitNumber).replace(/^#+/, "");
      g.zip = clean(x.zipCode).slice(0, 5);
      g.city = clean(x.city);
      g.folio = clean(x.folio);
      g.url = String(x.url);
    }
  }
  // A permit found twice (by name and by an address) counts each document once.
  const seen = new Set<string>();
  for (const { row: x } of rows) {
    const id = `${clean(x.caseNumber)}|${x.url}`;
    if (seen.has(id)) {
      const g = by.get(digitsOf(clean(x.caseNumber)));
      if (g) g.docs--;
    } else seen.add(id);
  }
  return [...by.values()].map(({ _newest, ...p }) => p);
}

// ---------------------------------------------------------------------------------------------------- what was typed
const CLIENT_CODE = /^\s*(?:permit\s+)?(\d{1,4})[-\s]?([A-Za-z]{1,6})\s*$/i;
const PERMIT_NO = /^\s*(?:permit\s*)?(?:GDO[-\s]*(\d{1,6})|(\d{4,6}))\s*$/i;
const DIRS: Record<string, string> = {
  N: "N", S: "S", E: "E", W: "W", NE: "NE", NW: "NW", SE: "SE", SW: "SW", NORTH: "N", SOUTH: "S", EAST: "E",
  WEST: "W", NORTHEAST: "NE", NORTHWEST: "NW", SOUTHEAST: "SE", SOUTHWEST: "SW",
};

/** "112 Northwest 28th Street, Miami 33127" -> house 112, street 28, zip 33127. */
export function parseAddress(text: string, zipHint = ""): { house: string; street: string; zip: string } | null {
  const m = /^\s*(\d{1,6})\s+(.+?)\s*$/.exec(text);
  if (!m) return null;
  const zip = (/\b(\d{5})(?:-\d{4})?\b/.exec(m[2])?.[1] ?? zipHint.slice(0, 5)) || "";
  const toks = m[2].replace(/[,#.]/g, " ").split(/\s+/).filter(Boolean);
  let i = 0;
  if (DIRS[toks[0]?.toUpperCase() ?? ""]) i = 1;
  const street = (toks[i] ?? "").toUpperCase().replace(/^(\d+)(ST|ND|RD|TH)$/, "$1");
  return { house: m[1], street, zip };
}

export function classify(q: string): { kind: "client" | "permit" | "address" | "name"; value: string } {
  const t = q.trim();
  const c = CLIENT_CODE.exec(t);
  // A client code is ours first, even after the word permit (the Slack bot's order: Diego typed "permit 192-frk").
  if (c && !/^\d+$/.test(c[2])) return { kind: "client", value: `${c[1].padStart(3, "0")}-${c[2].toUpperCase()}` };
  const p = PERMIT_NO.exec(t);
  if (p) return { kind: "permit", value: p[1] ?? p[2] };
  if (/^\s*\d{1,6}\s+\S/.test(t)) return { kind: "address", value: t };
  return { kind: "name", value: t };
}

const READ_AS = { client: "Client code", permit: "Permit number", address: "Address", name: "Business name", site: "This site's address" };

// ---------------------------------------------------------------------------------------------------- search
type Ctx = { county: ReturnType<typeof makeCounty>; rows: { row: CountyRow; via: string }[]; cut: boolean; asked: Set<string> };

async function byAddress(ctx: Ctx, house: string, zip: string, street: string, via: string) {
  if (!house || (!zip && !street)) return;
  // One county search per address: a client with five units at one address asks once.
  const k = `${house}|${zip || street}`;
  if (ctx.asked.has(k)) return;
  ctx.asked.add(k);
  const over: Record<string, string> = { houseNumber: house };
  if (zip) over.zipCode = zip;
  else over.streetName = street;
  const a = await ctx.county.all(over, 5);
  ctx.cut ||= a.cut;
  for (const row of a.rows) if (sameHouse(row, house)) ctx.rows.push({ row, via });
}

// The county's house number filter is not exact: 650 also brings 5650 (measured 2026-11-23 on 650 NW 33 St, 33127).
const sameHouse = (row: CountyRow, house: string) => digitsOf(clean(row.houseNumber)) === digitsOf(house);

async function folioOfAddress(ctx: Ctx, house: string, zip: string): Promise<string[]> {
  if (!house || !zip) return [];
  const first = await ctx.county.all({ houseNumber: house, zipCode: zip }, 1);
  let folios = first.rows.filter((r) => sameHouse(r, house)).map((r) => clean(r.folio)).filter(Boolean);
  // No GDO permit filed at the address: any county document there names its parcel.
  if (!folios.length) {
    const any = await ctx.county.all({ houseNumber: house, zipCode: zip, caseNumber: "", documentType: "" }, 1);
    folios = any.rows.filter((r) => sameHouse(r, house)).map((r) => clean(r.folio)).filter(Boolean);
  }
  return [...new Set(folios)];
}

type Site = { id: number; client_id: number | null; address: string | null; zip: string | null; county: string | null; name: string | null };

async function siteOf(siteId: number): Promise<Site> {
  const s = await rest<Site[]>(
    `properties?select=id,client_id,address,zip,county,name&id=eq.${siteId}&deleted_at=is.null`,
  );
  if (!s.length) throw new Refused(404, "That site was not found.");
  return s[0];
}

async function sitePermitNumbers(siteId: number): Promise<string[]> {
  const g = await rest<{ gdo_number: string }[]>(
    `gdos?select=gdo_number&property_id=eq.${siteId}&status=neq.INACTIVE&gdo_number=like.GDO-*`,
  );
  return [...new Set(g.map((x) => x.gdo_number).filter((n) => /^GDO-\d+$/.test(n)))];
}

async function ours(perms: Permit[]) {
  if (!perms.length) return;
  const nums = [...new Set(perms.map((p) => p.number))];
  // Exact GDO-nnnnnn numbers only, so a placeholder (client.gdos.is_placeholder, not a public.gdos column) never matches.
  const rows: { id: number; gdo_number: string; status: string | null; property_id: number | null; client_id: number | null }[] = [];
  for (let i = 0; i < nums.length; i += 80) {
    rows.push(...await rest<typeof rows>(
      `gdos?select=id,gdo_number,status,property_id,client_id&gdo_number=in.${inList(nums.slice(i, i + 80))}`,
    ));
  }
  const live = rows;
  const propIds = [...new Set(live.filter((r) => r.client_id == null && r.property_id != null).map((r) => r.property_id!))];
  const propClient = new Map<number, number>();
  if (propIds.length) {
    for (const p of await rest<{ id: number; client_id: number }[]>(`properties?select=id,client_id&id=in.${inList(propIds)}`)) {
      propClient.set(p.id, p.client_id);
    }
  }
  const clientIds = [...new Set(live.map((r) => r.client_id ?? propClient.get(r.property_id ?? -1)).filter((x): x is number => x != null))];
  const codes = new Map<number, string>();
  if (clientIds.length) {
    for (const c of await rest<{ id: number; client_code: string | null }[]>(`clients?select=id,client_code&id=in.${inList(clientIds)}`)) {
      codes.set(c.id, c.client_code ?? "");
    }
  }
  const byNum = new Map<string, Permit["ours"]>();
  for (const r of live) {
    const cid = r.client_id ?? propClient.get(r.property_id ?? -1) ?? null;
    const list = byNum.get(r.gdo_number) ?? [];
    list.push({ gdo_id: r.id, client_id: cid, client_code: cid != null ? codes.get(cid) ?? null : null, property_id: r.property_id, status: r.status });
    byNum.set(r.gdo_number, list);
  }
  for (const p of perms) p.ours = byNum.get(p.number) ?? [];
}

type Place = { name?: unknown; address?: unknown; house?: unknown; zip?: unknown };
async function search(body: { q?: string; site_id?: number; places?: Place[]; places_ok?: boolean }) {
  const county = makeCounty();
  const ctx: Ctx = { county, rows: [], cut: false, asked: new Set() };
  const q = clean(body.q).slice(0, 120);
  const siteId = Number(body.site_id) || null;
  const site = siteId ? await siteOf(siteId) : null;
  const siteAddr = site ? parseAddress(site.address ?? "", site.zip ?? "") : null;
  const notes: string[] = [];
  let readAs: string;
  let label = q;
  let siteFolios: string[] = [];

  if (!q && site) {
    readAs = READ_AS.site;
    label = [site.address, site.zip].filter(Boolean).join(", ");
    const folios = new Set(await folioOfAddress(ctx, siteAddr?.house ?? "", siteAddr?.zip ?? ""));
    siteFolios = [...folios];
    // the parcels of the permits already on this site
    for (const n of await sitePermitNumbers(site.id)) {
      const a = await county.all({ caseNumber: five(n) }, 1);
      for (const r of a.rows) if (digitsOf(clean(r.caseNumber)) === digitsOf(n) && clean(r.folio)) folios.add(clean(r.folio));
    }
    for (const f of [...folios].slice(0, 6)) {
      const a = await county.all({ folio: f }, 3);
      ctx.cut ||= a.cut;
      for (const row of a.rows) ctx.rows.push({ row, via: "parcel" });
    }
    if (!folios.size && siteAddr) await byAddress(ctx, siteAddr.house, siteAddr.zip, siteAddr.street, "address");
  } else if (!q) {
    throw new Refused(400, "Type a permit number, a business name, an address or a client code.");
  } else {
    if (site && siteAddr) siteFolios = await folioOfAddress(ctx, siteAddr.house, siteAddr.zip);
    const c = classify(q);
    readAs = READ_AS[c.kind];
    if (c.kind === "permit") {
      const a = await county.all({ caseNumber: five(c.value) }, 2);
      for (const row of a.rows) if (digitsOf(clean(row.caseNumber)) === digitsOf(c.value)) ctx.rows.push({ row, via: "number" });
    } else if (c.kind === "address") {
      const a = parseAddress(c.value);
      if (a) await byAddress(ctx, a.house, a.zip, a.street, "address");
    } else if (c.kind === "client") {
      const cl = await rest<{ id: number; client_code: string; name: string | null }[]>(
        `clients?select=id,client_code,name&client_code=eq.${encodeURIComponent(c.value)}`,
      );
      if (!cl.length) {
        // "650 Main" reads like a code; with no such client it is an address.
        const a = /^\s*\d{1,6}\s+\S/.test(q) ? parseAddress(q) : null;
        if (a) {
          readAs = READ_AS.address;
          await byAddress(ctx, a.house, a.zip, a.street, "address");
        } else notes.push(`No client of ours has the code ${c.value}.`);
      } else {
        label = `${c.value}${cl[0].name ? " " + cl[0].name : ""}`;
        const props = await rest<{ id: number; address: string | null; zip: string | null }[]>(
          `properties?select=id,address,zip&client_id=eq.${cl[0].id}&deleted_at=is.null&is_billing=is.false&limit=6`,
        );
        for (const p of props) {
          const a = parseAddress(p.address ?? "", p.zip ?? "");
          if (a) await byAddress(ctx, a.house, a.zip, a.street, `client:${p.id}`);
        }
        const nums = await rest<{ gdo_number: string }[]>(
          `gdos?select=gdo_number&client_id=eq.${cl[0].id}&status=neq.INACTIVE&gdo_number=like.GDO-*`,
        );
        for (const n of [...new Set(nums.map((x) => x.gdo_number))].slice(0, 8)) {
          const a = await county.all({ caseNumber: five(n) }, 1);
          for (const row of a.rows) if (digitsOf(clean(row.caseNumber)) === digitsOf(n)) ctx.rows.push({ row, via: "number" });
        }
      }
    } else {
      // a business: its name on the county's list, then the addresses where it is (pick S)
      const a = await county.all({ facilityName: c.value.toUpperCase() }, 5);
      ctx.cut ||= a.cut;
      for (const row of a.rows) ctx.rows.push({ row, via: "name" });
      const like = `*${c.value.replace(/[*,()"]/g, " ").trim()}*`;
      const mine = await rest<{ id: number; client_code: string; name: string | null }[]>(
        `clients?select=id,client_code,name&name=ilike.${encodeURIComponent(like)}&limit=3`,
      );
      for (const cl of mine) {
        const props = await rest<{ id: number; address: string | null; zip: string | null }[]>(
          `properties?select=id,address,zip&client_id=eq.${cl.id}&deleted_at=is.null&is_billing=is.false&limit=3`,
        );
        for (const p of props) {
          const ad = parseAddress(p.address ?? "", p.zip ?? "");
          if (ad) await byAddress(ctx, ad.house, ad.zip, ad.street, `site:${cl.client_code}`);
        }
      }
      if (body.places_ok === false) notes.push("Google Maps did not answer, so only the county's list and our sites were searched.");
      for (const p of (Array.isArray(body.places) ? body.places : []).slice(0, 3)) {
        const house = String(p.house ?? ""), zip = String(p.zip ?? "");
        if (!/^\d{1,6}$/.test(house) || !/^\d{5}$/.test(zip)) continue;
        const label = `${clean(p.name).slice(0, 80)} (${clean(p.address).replace(/, USA$/, "").slice(0, 120)})`;
        await byAddress(ctx, house, zip, "", `maps:${label}`);
      }
    }
  }

  const permits = group(ctx.rows);
  await ours(permits);
  return {
    read_as: readAs,
    label,
    permits,
    site: site ? { id: site.id, client_id: site.client_id, folios: siteFolios, house: siteAddr?.house ?? "", zip: siteAddr?.zip ?? "" } : null,
    cut: ctx.cut,
    notes,
    county_calls: county.calls(),
  };
}

// ---------------------------------------------------------------------------------------------------- read
async function fetchCountyPdf(url: string): Promise<Uint8Array> {
  if (!FILE_RE.test(url)) throw new Refused(400, "That is not a file from the county's permit list.");
  let r: Response;
  try {
    r = await fetch(url, { signal: AbortSignal.timeout(30_000) });
  } catch (e) {
    throw new CountyDown(`file: ${(e as Error).message}`);
  }
  if (!r.ok) throw new CountyDown(`file: HTTP ${r.status}`);
  const bytes = new Uint8Array(await r.arrayBuffer());
  if (bytes.length > MAX_PDF_BYTES) throw new Refused(413, "The county's file is over 15 MB.");
  if (String.fromCharCode(...bytes.subarray(0, 4)) !== "%PDF") throw new CountyDown("file: not a PDF");
  return bytes;
}

/** Page 1 cuts the holder at about 60 letters ("... DBA CHIPOTLE MEXICA"); a later page prints it whole. */
export function fullName(first: string, flat: string): string {
  if (!first || first.length < 50) return first;
  let best = first;
  for (const m of flat.matchAll(/Permit Issued To:\s*(.{2,160}?)\s+(?:This page|Page \d|Facility Location:|Contact Name)/gi)) {
    const l = m[1].replace(/\s+/g, " ").trim();
    if (l.length > best.length && l.startsWith(first)) best = l;
  }
  return best;
}

function b64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

const SCAN_PROMPT =
  "This file comes from Miami-Dade County's public list of grease (GDO) operating permits. It may be a scanned " +
  "picture. Read ONLY these facts from the permit itself: the permit number (e.g. GDO-014655), the business it is " +
  "issued to exactly as printed after \"Permit Issued To:\" or in the PERMITTEE block (the company, never a person's " +
  "name), the facility location (street address, unit, city, ZIP), the dates the permit is valid from and through " +
  "(as YYYY-MM-DD), and how often the grease trap must be cleaned at a minimum, in days. Leave out everything else: " +
  "never return a contact person, a mailing address, a password or a PIN. Use null for a fact you cannot read with " +
  "certainty. Set is_permit to false if this is not a GDO operating permit.";

const SCAN_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["is_permit", "permit_number", "issued_to", "facility_location", "valid_from", "valid_through", "cleaning_every_days"],
  properties: {
    is_permit: { type: "boolean" },
    permit_number: { anyOf: [{ type: "string" }, { type: "null" }] },
    issued_to: { anyOf: [{ type: "string" }, { type: "null" }] },
    facility_location: { anyOf: [{ type: "string" }, { type: "null" }] },
    valid_from: { anyOf: [{ type: "string", format: "date" }, { type: "null" }] },
    valid_through: { anyOf: [{ type: "string", format: "date" }, { type: "null" }] },
    cleaning_every_days: { anyOf: [{ type: "integer" }, { type: "null" }] },
  },
};

let anthropic: Anthropic | null = null;

/** Pick E1: a permit the county only has as a scan, read from its picture. */
async function readScan(pdf: Uint8Array) {
  anthropic ??= new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });
  // claude-opus-5-5: thinking cannot be turned off, effort is the control; the default server-side fallback answers a
  // refusal on another model inside the same call (as gdo-permit-label).
  // deno-lint-ignore no-explicit-any
  const msg: any = await anthropic.beta.messages.create({
    model: MODEL,
    max_tokens: 4000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low", format: { type: "json_schema", schema: SCAN_SCHEMA } },
    messages: [{
      role: "user",
      content: [
        { type: "document", source: { type: "base64", media_type: "application/pdf", data: b64(pdf) } },
        { type: "text", text: SCAN_PROMPT },
      ],
    }],
  // deno-lint-ignore no-explicit-any
  } as any);
  if (msg.stop_reason === "refusal" || msg.stop_reason === "max_tokens") return { ok: false as const, why: msg.stop_reason };
  // deno-lint-ignore no-explicit-any
  const text = (msg.content ?? []).filter((c: any) => c?.type === "text").map((c: any) => c.text ?? "").join("");
  try {
    return { ok: true as const, out: JSON.parse(text) as Record<string, unknown>, model: String(msg.model ?? MODEL) };
  } catch {
    return { ok: false as const, why: "not_json" };
  }
}

const ISO = /^\d{4}-\d{2}-\d{2}$/;
async function read(body: { url?: string }) {
  const pdf = await fetchCountyPdf(String(body.url ?? ""));
  const parsed = await parsePermit(pdf);
  if (parsed.isDermPermit && parsed.fields.gdo_number) {
    const f = parsed.fields;
    const holder = fullName(clean(f.issued_to), await flattenPdf(pdf));
    return {
      read: true, source: "text",
      fields: {
        gdo_number: f.gdo_number, issued_to: holder || null, facility_location: f.facility_location ?? null,
        permit_effective: f.permit_effective ?? null, permit_expiration: f.permit_expiration ?? null,
        max_frequency_days: f.max_frequency_days ?? null, capacity_gpm: f.capacity_gpm ?? null,
      },
      missing: parsed.missing,
    };
  }
  const s = await readScan(pdf);
  if (!s.ok || s.out.is_permit !== true) {
    return { read: false, source: "scan", why: s.ok ? "not_a_permit" : s.why };
  }
  const o = s.out;
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim().slice(0, 200) : null);
  const num = str(o.permit_number);
  const days = typeof o.cleaning_every_days === "number" && o.cleaning_every_days > 0 && o.cleaning_every_days <= 365
    ? Math.round(o.cleaning_every_days) : null;
  const fields = {
    gdo_number: num && /GDO[-\s]*\d{1,6}/i.test(num) ? six(num) : null,
    issued_to: str(o.issued_to),
    facility_location: str(o.facility_location),
    permit_effective: ISO.test(String(o.valid_from)) ? String(o.valid_from) : null,
    permit_expiration: ISO.test(String(o.valid_through)) ? String(o.valid_through) : null,
    max_frequency_days: days,
    capacity_gpm: null,
  };
  const missing = Object.entries(fields).filter(([k, v]) => v == null && k !== "capacity_gpm").map(([k]) => k);
  return { read: true, source: "scan", fields, missing, model: s.model };
}

// ---------------------------------------------------------------------------------------------------- take
async function put(path: string, pdf: Uint8Array, upsert: boolean): Promise<boolean> {
  const r = await fetch(`${SUPABASE_URL}/storage/v1/object/gdo-permits/${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY, "Content-Type": "application/pdf",
      "x-upsert": upsert ? "true" : "false",
    },
    body: new Blob([pdf], { type: "application/pdf" }),
  });
  if (!r.ok) console.error(`take: ${path} -> ${r.status} ${(await r.text()).slice(0, 160)}`);
  return r.ok;
}

async function take(body: { url?: string; number?: string }) {
  const pdf = await fetchCountyPdf(String(body.url ?? ""));
  const asked = String(body.number ?? "");
  if (!/^GDO-?\d{4,6}$/i.test(asked)) throw new Refused(400, "The permit number is missing.");
  // A text permit names its own file; a scan takes the number the county lists it under.
  const parsed = await parsePermit(pdf);
  const printed = parsed.isDermPermit ? parsed.fields.gdo_number : null;
  if (printed && digitsOf(printed) !== digitsOf(asked)) {
    throw new Refused(409, `That file is permit ${printed}, not ${six(asked)}. Nothing was saved.`);
  }
  const n = six(printed ?? asked);
  // Never over an existing permit file (parse-gdo-permit's rule): the county's copy goes beside it.
  let path = `gdo/${n}.pdf`;
  if (!await put(path, pdf, false)) {
    path = `gdo/${n}-county-${new Date().toISOString().slice(0, 10)}.pdf`;
    if (!await put(path, pdf, true)) throw new Error("The county's file could not be stored.");
  }
  return { ok: true, permit_document_path: path, gdo_number: n };
}

// ---------------------------------------------------------------------------------------------------- serve
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, { error: "method_not_allowed" }, 405);
  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const action = String(body.action ?? "");
  if (!["search", "read", "file", "take"].includes(action)) return json(req, { error: "bad_action" }, 400);
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const denied = await checkAppAction(token, action === "take" ? "gdo_lookup_take" : "gdo_lookup");
  if (denied) return json(req, { error: "no_access", message: denied.message }, denied.status);
  try {
    if (action === "search") return json(req, await search(body as Parameters<typeof search>[0]));
    if (action === "read") return json(req, await read(body as { url?: string }));
    if (action === "take") return json(req, await take(body as { url?: string; number?: string }));
    const pdf = await fetchCountyPdf(String(body.url ?? ""));
    return new Response(pdf, {
      headers: {
        ...cors(req), "Content-Type": "application/pdf", "Content-Disposition": "inline; filename=\"permit.pdf\"",
        "Cache-Control": "private, max-age=600",
      },
    });
  } catch (e) {
    if (e instanceof Refused) return json(req, { error: "refused", message: e.message }, e.status);
    if (e instanceof CountyDown) {
      console.error(`county: ${e.message}`);
      return json(req, { error: "county_down", message: "The county's permit list did not answer. Nothing was searched." }, 502);
    }
    console.error(`gdo-lookup ${action}: ${(e as Error)?.stack ?? e}`);
    return json(req, { error: "failed", message: "The lookup failed. Try again." }, 500);
  }
});
