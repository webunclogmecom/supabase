import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { arrowPath, type Annotation, type MapArrow, type MapPin } from "@/lib/access-pdf-types";
import { driverHoursRows, formatDateET } from "@/lib/format";
import { loadGoogleMaps } from "@/lib/google-maps";
import { normalizePins, pinEntries, pinLabel, type MapPins } from "@/lib/site-map-pins";
import { MarkedImage } from "@/components/MarkedImage";

const TITLE_FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Display", "Segoe UI", Roboto, sans-serif';
const TEXT_FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI Variable Text", "Segoe UI", Roboto, sans-serif';

// ---------- Props ----------

export type DriverPageSection = "access" | "grease_trap" | "lift_station" | "water_tank" | "job";

export type DriverPagePhoto = {
  photo_id: string | number;
  section: DriverPageSection;
  note: string | null;
  marks: Annotation[] | null;
  rot: number | null;
  rot_now: number | null;
  url: string;
  thumb: string | null;
};

type Val = string | number | boolean | null | undefined;

/** Access + equipment facts. Every key is optional; a missing key is not shown. */
export type DriverPageFacts = {
  key_tag?: Val;
  gt_systems?: Val;
  gallons?: Val;
  manholes?: Val;
  cleanouts?: Val;
  sample_ports?: Val;
  lift_stations?: Val;
  water_tanks?: Val;
  water_tank_capacity?: Val;
  gate?: Val;
  gate_code?: Val;
  how_access?: Val;
  lock_box_code?: Val;
  key_instruction?: Val;
  alarm?: Val;
  alarm_instruction?: Val;
  equipment_where?: Val;
  access_point?: Val;
  light_switches?: Val;
  obstacles?: Val;
  [k: string]: unknown;
};

export type DriverPageContact = { name?: string | null; role?: string | null; phone?: string | null };

export type DriverPageSiteMap = {
  pins?: MapPins | null;
  arrows?: MapArrow[] | null;
};

export type DriverPageData = {
  property: {
    name: string | null;
    address: string | null;
    city: string | null;
    lat: number | null;
    lng: number | null;
    client_code: string | null;
    client_name: string | null;
  };
  version: number | null;
  approved_at: string | null;
  approved_by: string | null;
  content: {
    facts?: DriverPageFacts | null;
    hours?: unknown;
    notes?: string | null;
    contacts?: DriverPageContact[] | null;
    site_map?: DriverPageSiteMap | null;
    include_map?: boolean | null;
  };
};

const SECTIONS: { key: DriverPageSection; title: string }[] = [
  { key: "access", title: "Access photos" },
  { key: "grease_trap", title: "Grease trap" },
  { key: "lift_station", title: "Lift station" },
  { key: "water_tank", title: "Water tank" },
  { key: "job", title: "Job pictures" },
];

// ---------- helpers ----------

const has = (v: unknown) => v !== null && v !== undefined && String(v).trim() !== "";
const text = (v: unknown) => String(v);
function yesNo(v: unknown): string {
  if (typeof v === "boolean") return v ? "Yes" : "No";
  const s = String(v).trim().toLowerCase();
  if (["yes", "true", "y", "1"].includes(s)) return "Yes";
  if (["no", "false", "n", "0"].includes(s)) return "No";
  return String(v);
}
const dirHref = (p: MapPin) => `https://www.google.com/maps/dir/?api=1&destination=${p.lat},${p.lng}`;
const validPin = (p: unknown): p is MapPin =>
  !!p && typeof (p as MapPin).lat === "number" && typeof (p as MapPin).lng === "number";

/** Rotate a normalized point clockwise by `turns` quarter turns. */
function rotPt(x: number, y: number, turns: number): [number, number] {
  let px = x, py = y;
  for (let i = 0; i < turns; i++) [px, py] = [1 - py, px];
  return [px, py];
}
function rotateMarks(marks: Annotation[], deg: number): Annotation[] {
  const turns = ((Math.round(deg / 90) % 4) + 4) % 4;
  if (!turns) return marks;
  return marks.map((m) => {
    if (m.kind === "arrow") {
      const [x1, y1] = rotPt(m.x1, m.y1, turns);
      const [x2, y2] = rotPt(m.x2, m.y2, turns);
      return { ...m, x1, y1, x2, y2 };
    }
    if (m.kind === "ring" || m.kind === "rect") {
      const a = rotPt(m.x, m.y, turns);
      const b = rotPt(m.x + m.w, m.y + m.h, turns);
      return { ...m, x: Math.min(a[0], b[0]), y: Math.min(a[1], b[1]), w: Math.abs(a[0] - b[0]), h: Math.abs(a[1] - b[1]) };
    }
    const [x, y] = rotPt(m.x, m.y, turns);
    return { ...m, x, y };
  });
}

// ---------- Page ----------

type Item = { id: string; title: string; url: string; thumb: string; note: string; marks: Annotation[] };

export function DriverPage({
  page,
  photos,
  signFailures = 0,
  onPhotoError,
}: {
  page: DriverPageData;
  photos: DriverPagePhoto[];
  signFailures?: number;
  onPhotoError?: () => void;
}) {
  const { property, content } = page;
  const facts = content.facts ?? {};
  const pins = normalizePins(content.site_map?.pins);
  const gt = pins.gt ?? null;
  const truck = pins.truck ?? null;
  const arrows = (content.site_map?.arrows ?? []).filter((a) => arrowPath(a).length >= 2);
  const showMap = content.include_map !== false && (pinEntries(pins).length > 0 || arrows.length > 0);
  const hours = driverHoursRows(content.hours);
  const contacts = (content.contacts ?? []).filter((c) => c && (has(c.name) || has(c.phone)));
  const [openIndex, setOpenIndex] = useState<number | null>(null);

  const sections = useMemo(
    () =>
      SECTIONS.map((s) => ({
        ...s,
        items: photos
          .filter((p) => p.section === s.key)
          .map<Item>((p) => {
            const marks = p.marks ?? [];
            const diff = (p.rot_now ?? 0) - (p.rot ?? 0);
            return {
              id: String(p.photo_id),
              title: s.title,
              url: p.url,
              thumb: p.thumb || p.url,
              note: p.note ?? "",
              marks: diff ? rotateMarks(marks, diff) : marks,
            };
          }),
      })).filter((s) => s.items.length > 0),
    [photos],
  );
  const allItems = useMemo(() => sections.flatMap((s) => s.items), [sections]);

  const addressLine = (() => {
    const a = has(property.address) ? String(property.address) : "";
    if (!has(property.city)) return a;
    const c = String(property.city).trim();
    return a.toLowerCase().includes(c.toLowerCase()) ? a : a ? `${a}, ${c}` : c;
  })();
  const heading = [property.client_code, property.client_name].filter(has).join(" · ");
  const addressHref = addressLine
    ? `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(addressLine)}`
    : null;
  const directionsTarget = truck
    ? { kind: "truck" as const, href: dirHref(truck), name: "Directions to the truck spot" }
    : gt
      ? { kind: "gt" as const, href: dirHref(gt), name: "Directions to the grease trap" }
      : addressHref
        ? { kind: "address" as const, href: addressHref, name: "Directions to the address" }
        : null;

  const accessRows: [string, ReactNode][] = [];
  if (has(facts.key_tag)) accessRows.push(["Key tag", <Code key="kt">{text(facts.key_tag)}</Code>]);
  if (has(facts.gate)) accessRows.push(["Gate", yesNo(facts.gate)]);
  if (has(facts.gate_code)) accessRows.push(["Gate code", <Code key="g">{text(facts.gate_code)}</Code>]);
  if (has(facts.how_access)) accessRows.push(["How we get in", text(facts.how_access)]);
  if (has(facts.lock_box_code)) accessRows.push(["Lock box code", <Code key="l">{text(facts.lock_box_code)}</Code>]);
  if (has(facts.key_instruction)) accessRows.push(["Key instructions", text(facts.key_instruction)]);
  if (has(facts.alarm)) accessRows.push(["Alarm", yesNo(facts.alarm)]);
  if (has(facts.alarm_instruction)) accessRows.push(["Alarm instructions", text(facts.alarm_instruction)]);
  if (has(facts.equipment_where)) accessRows.push(["Where the equipment is", text(facts.equipment_where)]);
  if (has(facts.access_point)) accessRows.push(["Best way in", text(facts.access_point)]);
  if (has(facts.light_switches)) accessRows.push(["Light switches", text(facts.light_switches)]);
  if (has(facts.obstacles)) accessRows.push(["Obstacles", text(facts.obstacles)]);

  const num = (v: unknown) => (typeof v === "number" ? v.toLocaleString("en-US") : text(v));
  const equipRows: [string, string][] = [];
  if (has(facts.gt_systems)) equipRows.push(["Grease trap systems", num(facts.gt_systems)]);
  if (has(facts.gallons)) equipRows.push(["Total capacity", `${num(facts.gallons)} gallons`]);
  if (has(facts.manholes)) equipRows.push(["Manholes", num(facts.manholes)]);
  if (has(facts.cleanouts)) equipRows.push(["Clean outs", num(facts.cleanouts)]);
  if (has(facts.sample_ports)) equipRows.push(["Sample ports", num(facts.sample_ports)]);
  if (has(facts.lift_stations)) equipRows.push(["Lift stations", num(facts.lift_stations)]);
  if (has(facts.water_tanks)) equipRows.push(["Water tanks", num(facts.water_tanks)]);
  if (has(facts.water_tank_capacity))
    equipRows.push(["Water tank capacity", `${num(facts.water_tank_capacity)} gallons`]);

  return (
    <div data-site-file className="@container min-h-screen overflow-x-clip bg-dp-bg text-dp-ink" style={{ fontFamily: "system-ui, -apple-system, Segoe UI, Roboto, sans-serif" }}>
      <div
        data-sf-column
        className={showMap
          ? "mx-auto w-full max-w-[680px] space-y-3 px-3 pb-10 pt-4 @min-[640px]:px-4 @min-[1024px]:grid @min-[1024px]:max-w-[1100px] @min-[1024px]:grid-cols-[460px_minmax(0,1fr)] @min-[1024px]:items-start @min-[1024px]:gap-x-5 @min-[1024px]:gap-y-3 @min-[1024px]:space-y-0"
          : "mx-auto w-full max-w-[680px] space-y-3 px-3 pb-10 pt-4 @min-[640px]:px-4"}
      >
        <header className="px-1 pb-1 @min-[1024px]:col-span-2">
          <div className="text-[11px] font-bold uppercase tracking-[0.14em] text-dp-orange" style={{ fontFamily: TEXT_FONT }}>UnclogMe · Site file</div>
          {heading && <h1 className="mt-1 break-words text-2xl font-semibold leading-tight pointer-fine:@min-[900px]:text-xl" style={{ fontFamily: TITLE_FONT }}>{heading}</h1>}
          {has(property.name) && property.name !== property.client_name && (
            <div className="mt-0.5 break-words text-base font-semibold">{property.name}</div>
          )}
          {addressLine && <div className="mt-0.5 break-words text-[15px] text-dp-muted">{addressLine}</div>}
          {page.approved_at === null ? (
            <div className="mt-2 text-[13px] font-semibold text-dp-muted">Not approved yet</div>
          ) : has(page.approved_by) ? (
            <div className="mt-2 inline-flex items-center gap-1.5 rounded-full bg-dp-green-pale px-3 py-1 text-[13px] font-semibold text-dp-green">
              <span aria-hidden>✓</span>
              Checked by {page.approved_by}
              {` on ${formatDateET(page.approved_at)}`}
            </div>
          ) : null}
        </header>

        {showMap && (
          <div data-sf-left className="@min-[1024px]:sticky @min-[1024px]:top-4">
            <div data-sf-map className="relative isolate">
              <DriverMap
                center={property.lat != null && property.lng != null ? { lat: property.lat, lng: property.lng } : (gt ?? truck ?? arrowPath(arrows[0])[0])}
                pins={pins}
                arrows={arrows}
              />
              {directionsTarget && <DirectionsButton target={directionsTarget} onMap />}
            </div>
          </div>
        )}

        {!showMap && directionsTarget && <div data-sf-directions-row className="flex"><DirectionsButton target={directionsTarget} onMap={false} /></div>}

        <div data-sf-cards className="space-y-3">
          {(accessRows.length > 0 || has(content.notes)) && (
          <Card title="Access">
            {accessRows.length > 0 && (
              <dl className="divide-y divide-dp-line">
                {accessRows.map(([k, v]) => (
                  <Row key={k} label={k}>
                    {v}
                  </Row>
                ))}
              </dl>
            )}
            {has(content.notes) && (
              <div className={accessRows.length > 0 ? "mt-3 border-t border-dp-line pt-3" : ""}>
                <div className="text-[13px] font-semibold text-dp-muted">Notes</div>
                <p className="mt-1 whitespace-pre-line break-words text-[15px] leading-relaxed">{text(content.notes)}</p>
              </div>
            )}
          </Card>
          )}

          {hours.length > 0 && (
          <Card title="When we can come">
            <dl className="divide-y divide-dp-line">
              {hours.map((h) => (
                <Row key={h.day} label={h.day}>
                  <span className={h.text === "No access" ? "text-dp-muted" : ""}>{h.text}</span>
                </Row>
              ))}
            </dl>
          </Card>
          )}

          {equipRows.length > 0 && (
          <Card title="Equipment">
            <dl className="divide-y divide-dp-line">
              {equipRows.map(([k, v]) => (
                <Row key={k} label={k}>
                  {v}
                </Row>
              ))}
            </dl>
          </Card>
          )}

          {contacts.length > 0 && (
          <Card title="Contacts">
            <ul className="divide-y divide-dp-line">
              {contacts.map((c, i) => {
                const tel = has(c.phone) ? String(c.phone).replace(/[^\d+ ]/g, "").trim() : "";
                const contactName = has(c.name) ? String(c.name).trim() : "";
                const callLabel = contactName ? `Call ${contactName}` : "Call";
                return (
                  <li key={i} className="flex items-center justify-between gap-3 py-2.5">
                    <div className="min-w-0">
                      {has(c.name) && <div className="break-words font-semibold">{c.name}</div>}
                      {has(c.role) && <div className="break-words text-[13px] text-dp-muted">{c.role}</div>}
                    </div>
                    {tel && (
                      <a
                        href={`tel:${tel}`}
                        aria-label={callLabel}
                        title={callLabel}
                        data-sf-call
                        className="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-[#1A73E8] text-white hover:bg-[#1967D2]"
                      >
                        <svg aria-hidden="true" focusable="false" viewBox="0 0 24 24" width="22" height="22"><path fill="currentColor" d="M20.01 15.38c-1.23 0-2.42-.2-3.53-.56a.98.98 0 0 0-1.01.24l-1.57 1.97c-2.83-1.35-5.48-3.9-6.89-6.83l1.95-1.66c.27-.28.35-.67.24-1.02-.37-1.11-.56-2.3-.56-3.53 0-.54-.45-.99-.99-.99H4.19C3.65 3 3 3.24 3 3.99 3 13.28 10.73 21 20.01 21c.71 0 .99-.63.99-1.18v-3.45c0-.54-.45-.99-.99-.99z" /></svg>
                      </a>
                    )}
                  </li>
                );
              })}
            </ul>
          </Card>
          )}

          {signFailures > 0 && (
          <div className="rounded-2xl border border-dp-line bg-dp-orange-pale px-4 py-3 text-[14px] text-dp-ink">
            {signFailures === 1 ? "1 photo could not load right now." : `${signFailures} photos could not load right now.`}
          </div>
          )}

          {sections.map((s) => (
          <Card key={s.key} title={s.title}>
            <ol className="grid grid-cols-2 gap-2.5">
              {s.items.map((it, i) => (
                <li key={it.id} className="min-w-0">
                  <button
                    type="button"
                    onClick={() => setOpenIndex(allItems.indexOf(it))}
                    aria-label={`Open ${s.title} photo ${i + 1}`}
                    className="relative block aspect-[4/3] w-full overflow-hidden rounded-xl bg-dp-bg"
                  >
                    <img src={it.thumb} alt="" loading="lazy" onError={onPhotoError} className="h-full w-full object-cover" />
                    <span className="absolute left-2 top-2 grid h-7 w-7 place-items-center rounded-full bg-dp-orange text-[13px] font-bold text-dp-card shadow">
                      {i + 1}
                    </span>
                  </button>
                  {it.note && (
                    <p className="mt-1.5 whitespace-pre-line break-words text-[13px] leading-snug text-dp-muted">{it.note}</p>
                  )}
                </li>
              ))}
            </ol>
          </Card>
          ))}
        </div>

        <p data-sf-footer className="pt-2 text-center text-[12px] text-dp-muted @min-[1024px]:col-span-2">
          UnclogMe · Site file.
        </p>
      </div>

      {openIndex !== null && allItems[openIndex] && (
        <PhotoLightbox
          items={allItems}
          index={openIndex}
          onIndexChange={setOpenIndex}
          onClose={() => setOpenIndex(null)}
          onPhotoError={onPhotoError}
        />
      )}
    </div>
  );
}

// ---------- small pieces ----------

function Card({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="rounded-2xl border border-dp-line bg-dp-card p-4">
      <h2 className="mb-2 text-[17px] font-semibold pointer-fine:@min-[900px]:text-[15px]" style={{ fontFamily: TITLE_FONT }}>{title}</h2>
      {children}
    </section>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5 py-2.5 @min-[640px]:flex-row @min-[640px]:items-baseline @min-[640px]:gap-4">
      <dt className="shrink-0 text-[13px] font-semibold text-dp-muted @min-[640px]:w-44">{label}</dt>
      <dd className="min-w-0 whitespace-pre-line break-words text-[15px]">{children}</dd>
    </div>
  );
}

function Code({ children }: { children: ReactNode }) {
  return <span className="break-all font-mono text-[26px] font-bold tracking-wider pointer-fine:@min-[900px]:text-lg pointer-fine:@min-[900px]:font-semibold pointer-fine:@min-[900px]:tracking-wide">{children}</span>;
}

function DirectionsButton({ target, onMap }: { target: { kind: "truck" | "gt" | "address"; href: string; name: string }; onMap: boolean }) {
  return (
    <a
      href={target.href}
      target="_blank"
      rel="noreferrer"
      aria-label={target.name}
      title={target.name}
      data-sf-directions={target.kind}
      style={{ fontFamily: TEXT_FONT }}
      className={onMap ? "absolute left-3 top-3 z-10 inline-flex min-h-12 items-center gap-2 rounded-full bg-[#1A73E8] pl-3.5 pr-5 text-[16px] font-semibold text-white shadow-[0_2px_8px_rgba(0,0,0,0.4)] hover:bg-[#1967D2] pointer-fine:@min-[900px]:min-h-11 pointer-fine:@min-[900px]:text-sm" : "flex min-h-[52px] w-full items-center justify-center gap-2 rounded-full bg-[#1A73E8] pl-[22px] pr-[22px] text-[16px] font-semibold text-white hover:bg-[#1967D2] @min-[768px]:min-h-12 @min-[768px]:w-auto @min-[768px]:pl-[18px] @min-[768px]:pr-6 pointer-fine:@min-[900px]:min-h-11 pointer-fine:@min-[900px]:text-sm"}
    >
      <svg aria-hidden="true" focusable="false" viewBox="0 0 24 24" width="22" height="22" className="shrink-0"><path fill="currentColor" fillRule="evenodd" d="M21.71 11.29l-9-9c-.39-.39-1.02-.39-1.41 0l-9 9c-.39.39-.39 1.02 0 1.41l9 9c.39.39 1.02.39 1.41 0l9-9c.39-.38.39-1.01 0-1.41zM14 14.5V12h-4v3H8v-4c0-.55.45-1 1-1h5V7.5l3.5 3.5-3.5 3.5z" /></svg>
      <span>Directions</span>
    </a>
  );
}

// ---------- Lightbox ----------

function PhotoLightbox({
  items,
  index,
  onIndexChange,
  onClose,
  onPhotoError,
}: {
  items: Item[];
  index: number;
  onIndexChange: (i: number) => void;
  onClose: () => void;
  onPhotoError?: () => void;
}) {
  const [touchX, setTouchX] = useState<number | null>(null);
  const go = (delta: number) => onIndexChange((index + delta + items.length) % items.length);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
      if (e.key === "ArrowRight") go(1);
      if (e.key === "ArrowLeft") go(-1);
    }
    window.addEventListener("keydown", onKey);
    document.body.style.overflow = "hidden";
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  });

  const item = items[index];
  if (typeof document === "undefined") return null;

  return createPortal(
    <div className="fixed inset-0 z-50 flex flex-col bg-black/95 text-white" role="dialog" aria-modal="true" onClick={onClose}>
      <div className="flex shrink-0 items-center justify-between gap-2 px-3 py-2">
        <div className="flex min-w-0 items-center gap-2">
          <span className="text-sm font-semibold">
            {index + 1} / {items.length}
          </span>
          <span className="truncate rounded-full bg-white/15 px-3 py-1 text-xs font-semibold">{item.title}</span>
        </div>
        <button type="button" onClick={onClose} aria-label="Close" className="min-h-11 rounded-full bg-white/15 px-4 text-sm font-semibold">
          Close
        </button>
      </div>
      <div
        className="flex min-h-0 flex-1 flex-col items-center justify-center overflow-y-auto px-3"
        onClick={(e) => e.stopPropagation()}
        onTouchStart={(e) => setTouchX(e.touches[0].clientX)}
        onTouchEnd={(e) => {
          if (touchX === null) return;
          const dx = e.changedTouches[0].clientX - touchX;
          if (Math.abs(dx) > 40) go(dx < 0 ? 1 : -1);
          setTouchX(null);
        }}
      >
        <div className="relative w-full max-w-3xl text-center">
          <MarkedImage
            key={item.id + item.url}
            src={item.url}
            alt={item.title}
            marks={item.marks}
            onError={onPhotoError}
            imgClassName="max-h-[60vh] w-auto rounded"
          />
        </div>
        {item.note && <p className="mt-3 w-full max-w-3xl whitespace-pre-line break-words text-center text-[15px] leading-relaxed text-white/85">{item.note}</p>}
      </div>
      {items.length > 1 && (
        <div className="flex shrink-0 justify-center gap-4 px-3 pb-5 pt-2" onClick={(e) => e.stopPropagation()}>
          <button type="button" aria-label="Previous photo" onClick={() => go(-1)} className="grid h-12 w-16 place-items-center rounded-full bg-white/20 text-2xl">
            ‹
          </button>
          <button type="button" aria-label="Next photo" onClick={() => go(1)} className="grid h-12 w-16 place-items-center rounded-full bg-white/20 text-2xl">
            ›
          </button>
        </div>
      )}
    </div>,
    document.body,
  );
}

// ---------- Map ----------

const TRUCK_PATH =
  "M2 4h12v11H2z M14 8h5.2l2.8 3.6V15h-8z M4 16a2 2 0 1 0 4 0a2 2 0 1 0-4 0z M15 16a2 2 0 1 0 4 0a2 2 0 1 0-4 0z";

function DriverMap({
  center,
  pins,
  arrows,
}: {
  center: MapPin;
  pins: MapPins;
  arrows: MapArrow[];
}) {
  const divRef = useRef<HTMLDivElement>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    // Google calls this when the key is refused (e.g. wrong domain).
    (window as any).gm_authFailure = () => {
      if (!cancelled) setFailed(true);
    };
    loadGoogleMaps()
      .then(() => {
        if (cancelled || !divRef.current) return;
        const g = window.google.maps;
        const map = new g.Map(divRef.current, {
          center,
          zoom: 19,
          maxZoom: 21,
          mapTypeId: "satellite",
          tilt: 0,
          streetViewControl: false,
          fullscreenControl: true,
          mapTypeControl: false,
          gestureHandling: "greedy",
        });
        const pts: MapPin[] = [];
        for (const [key, point] of pinEntries(pins)) {
          pts.push(point);
          new g.Marker({
            map, position: point, title: pinLabel(key),
            label: { text: pinLabel(key), color: "white", fontWeight: "bold", fontSize: "11px" },
            icon: key.startsWith("gt")
              ? { path: g.SymbolPath.CIRCLE, scale: 14, fillColor: "#ef4444", fillOpacity: 1, strokeColor: "white", strokeWeight: 2 }
              : { path: TRUCK_PATH, scale: 1.6, fillColor: "#ff6a00", fillOpacity: 1, strokeColor: "white", strokeWeight: 1.5, anchor: new g.Point(12, 18), labelOrigin: new g.Point(8, 9.6) },
          });
        }
        for (const a of arrows) {
          const path = arrowPath(a);
          if (path.length < 2) continue;
          pts.push(...path);
          new g.Polyline({
            map,
            path,
            strokeColor: "#ff6a00",
            strokeOpacity: 1,
            strokeWeight: 5,
            icons: [
              {
                icon: { path: g.SymbolPath.FORWARD_CLOSED_ARROW, scale: 4, fillColor: "#ff6a00", fillOpacity: 1, strokeColor: "#ffffff", strokeWeight: 1 },
                offset: "100%",
              },
            ],
          });
        }
        if (pts.length >= 1) {
          const b = new g.LatLngBounds();
          pts.forEach((p) => b.extend(p));
          g.event.addListenerOnce(map, "bounds_changed", () => {
            if (map.getZoom() > 20) map.setZoom(20);
          });
          map.fitBounds(b, 40);
        }
      })
      .catch(() => setFailed(true));
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (failed) {
    return (
      <div className="grid h-[280px] place-items-center rounded-2xl border border-dp-line bg-dp-card text-sm text-dp-muted">
        Map unavailable
      </div>
    );
  }
  return <div ref={divRef} className="h-[300px] w-full overflow-hidden rounded-2xl border border-dp-line bg-dp-line @min-[640px]:h-[380px] @min-[1024px]:h-[480px]" />;
}
