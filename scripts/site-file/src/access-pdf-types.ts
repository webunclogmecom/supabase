// Annotation coordinates are stored NORMALIZED (0..1) relative to photo box,
// so they scale correctly between the editor preview and the PDF output.

export type AnnotationColor = "red" | "blue" | "green" | "yellow" | "orange" | "white";

export const COLOR_HEX: Record<AnnotationColor, string> = {
  red: "#ef4444",
  blue: "#3b82f6",
  green: "#22c55e",
  yellow: "#eab308",
  orange: "#f97316",
  white: "#ffffff",
};

export type CircleAnn = {
  id: string;
  kind: "circle";
  x: number;
  y: number;
  number: number;
  color: AnnotationColor;
};

export type ArrowAnn = {
  id: string;
  kind: "arrow";
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  color: AnnotationColor;
};

export type TextAnn = {
  id: string;
  kind: "text";
  x: number;
  y: number;
  text: string;
  color: AnnotationColor;
};

// Hollow outlined circle (no number, transparent middle) drawn from a bounding box.
export type RingAnn = {
  id: string;
  kind: "ring";
  x: number; // top-left of bbox, normalized
  y: number;
  w: number; // width, normalized
  h: number; // height, normalized
  color: AnnotationColor;
};

// Hollow outlined rectangle (transparent middle).
export type RectAnn = {
  id: string;
  kind: "rect";
  x: number;
  y: number;
  w: number;
  h: number;
  color: AnnotationColor;
};

export type Annotation = CircleAnn | ArrowAnn | TextAnn | RingAnn | RectAnn;

// Page layout: US Letter portrait in PDF points (72pt = 1in). jsPDF default.
export const PAGE_W = 612;
export const PAGE_H = 792;
export const PAGE_MARGIN = 24;

export type MapPin = { lat: number; lng: number };

// Directional arrow drawn on the site map (e.g. "drive in this way").
// `points` holds 2+ vertices so an arrow can bend around corners.
// `from`/`to` are legacy two-point arrows kept for older saved data.
export type MapArrow = {
  id: string;
  points?: MapPin[];
  from?: MapPin;
  to?: MapPin;
};

export function arrowPath(a: MapArrow): MapPin[] {
  if (a.points && a.points.length >= 2) return a.points;
  if (a.from && a.to) return [a.from, a.to];
  return [];
}

export type PhotoCategory = "access" | "greaseTrap" | "liftStation" | "waterTank" | "job";

export const PHOTO_CATEGORIES: { key: PhotoCategory; title: string; hint: string }[] = [
  {
    key: "access",
    title: "Access photos",
    hint: "How to get in: entrances, gates, codes, where to park.",
  },
  {
    key: "greaseTrap",
    title: "Grease trap",
    hint: "The trap itself: lids, bolts, chambers, interior condition.",
  },
  {
    key: "liftStation",
    title: "Lift station",
    hint: "The lift station: its access, its control panel and the station itself.",
  },
  {
    key: "waterTank",
    title: "Water tank",
    hint: "The water tank: its capacity plate and the tank itself.",
  },
  {
    key: "job",
    title: "Job pictures & description",
    hint: "Work in progress, cleanouts, jetting, cleanup expectations.",
  },
];

export type SavedSection = "access" | "grease_trap" | "lift_station" | "water_tank" | "job";

/** The ONE place the builder section key maps to the saved section key. */
export function savedSectionKey(c: PhotoCategory): SavedSection {
  if (c === "greaseTrap") return "grease_trap";
  if (c === "liftStation") return "lift_station";
  if (c === "waterTank") return "water_tank";
  return c;
}
export function categoryFromSaved(s: unknown): PhotoCategory {
  return PHOTO_CATEGORIES.find((c) => savedSectionKey(c.key) === s)?.key ?? "access";
}

export type FactValue = string | number | boolean | null;
export type DayKey = "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun";
export type BuilderHours = Partial<Record<DayKey, { open: string; close: string }>>;
export type BuilderContact = { name: string; phone: string; role: string };

export type BuilderState = {
  facts: Record<string, FactValue>;
  hours: BuilderHours;
  contacts: BuilderContact[];
  annotations: Record<string, Annotation[]>; // photoId (string) -> anns
  selections: Record<PhotoCategory, string[]>; // ordered photo ids (strings) per category
  photoNotes: Record<string, string>; // key: `${category}:${photoId}`
  sharedNotes: string;
  mapCenter: MapPin;
  mapZoom: number;
  mapPins: import("./site-map-pins").MapPins;
  mapArrows: MapArrow[];
  includeMap: boolean;
};

/** Rotate mark coordinates clockwise by `deg` (90-degree steps). */
export function rotateAnnotations(marks: Annotation[], deg: number): Annotation[] {
  const turns = ((Math.round(deg / 90) % 4) + 4) % 4;
  if (!turns) return marks;
  const rp = (x: number, y: number): [number, number] => {
    let px = x, py = y;
    for (let i = 0; i < turns; i++) [px, py] = [1 - py, px];
    return [px, py];
  };
  return marks.map((m) => {
    if (m.kind === "arrow") {
      const [x1, y1] = rp(m.x1, m.y1);
      const [x2, y2] = rp(m.x2, m.y2);
      return { ...m, x1, y1, x2, y2 };
    }
    if (m.kind === "ring" || m.kind === "rect") {
      const a = rp(m.x, m.y);
      const b = rp(m.x + m.w, m.y + m.h);
      return { ...m, x: Math.min(a[0], b[0]), y: Math.min(a[1], b[1]), w: Math.abs(a[0] - b[0]), h: Math.abs(a[1] - b[1]) };
    }
    const [x, y] = rp(m.x, m.y);
    return { ...m, x, y };
  });
}