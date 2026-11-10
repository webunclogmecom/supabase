import type { MapPin } from "./access-pdf-types";

export const GT_PIN_KEYS = ["gt", "gt2", "gt3", "gt4", "gt5", "gt6", "gt7", "gt8", "gt9"] as const;
export const TRUCK_PIN_KEYS = ["truck", "truck2", "truck3"] as const;
export const PIN_KEYS = [...GT_PIN_KEYS, ...TRUCK_PIN_KEYS] as const;
export type PinKey = (typeof PIN_KEYS)[number];
export type MapPins = Partial<Record<PinKey, MapPin>>;
export type PinKind = "gt" | "truck";
export const pinKeys = (kind: PinKind) => kind === "gt" ? GT_PIN_KEYS : TRUCK_PIN_KEYS;
export const pinLabel = (key: PinKey) => key.startsWith("gt") ? `GT${key.slice(2) || "1"}` : `T${key.slice(5) || "1"}`;
export function validMapPin(value: unknown): value is MapPin {
  if (!value || typeof value !== "object") return false;
  const p = value as MapPin;
  return Number.isFinite(p.lat) && Number.isFinite(p.lng) && Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180;
}
export function pinEntries(pins: MapPins): [PinKey, MapPin][] {
  return PIN_KEYS.flatMap((key) => {
    const p = pins[key];
    return validMapPin(p) ? [[key, p] as [PinKey, MapPin]] : [];
  });
}
/** Only allowed keys survive; each kind is compacted in its existing order. */
export function normalizePins(value: unknown): MapPins {
  const source = value && typeof value === "object" ? value as MapPins : {};
  const result: MapPins = {};
  for (const kind of ["gt", "truck"] as const) {
    const keys = pinKeys(kind);
    const points = keys.map((key) => source[key]).filter(validMapPin);
    points.forEach((p, index) => { result[keys[index]] = { lat: p.lat, lng: p.lng }; });
  }
  return result;
}
export function addPin(pins: MapPins, kind: PinKind, point: MapPin): MapPins {
  const next = normalizePins(pins);
  if (!validMapPin(point)) return next;
  const key = pinKeys(kind).find((key) => !next[key]);
  if (key) next[key] = { ...point };
  return next;
}
export function removePin(pins: MapPins, key: PinKey): MapPins {
  const next = { ...pins };
  delete next[key];
  return normalizePins(next);
}
export function clearPins(pins: MapPins, kind: PinKind): MapPins {
  const next = { ...pins };
  for (const key of pinKeys(kind)) delete next[key];
  return normalizePins(next);
}
/** A form replaces only the kinds it answered, preserving the other kind. */
export function replaceFormPins(current: MapPins, offered: MapPins): MapPins {
  let next = normalizePins(current);
  const form = normalizePins(offered);
  for (const kind of ["gt", "truck"] as const) {
    if (!pinKeys(kind).some((key) => form[key])) continue;
    next = clearPins(next, kind);
    for (const key of pinKeys(kind)) if (form[key]) next[key] = form[key];
  }
  return normalizePins(next);
}
export function questionPinKey(questionKey: string): PinKey | null {
  if (questionKey === "site_map.gt_location") return "gt";
  if (questionKey === "site_map.truck_parking") return "truck";
  const match = /^grease_trap\.t([2-9])\.location$/.exec(questionKey);
  return match ? GT_PIN_KEYS[Number(match[1]) - 1] : null;
}
export function farPinWarning(lat: number | null, lng: number | null, pins: MapPins): string | null {
  if (typeof lat !== "number" || typeof lng !== "number" || !Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  const radians = Math.PI / 180;
  const far = pinEntries(pins).map(([key, p]) => {
    const a = Math.sin((p.lat - lat) * radians / 2) ** 2 + Math.cos(lat * radians) * Math.cos(p.lat * radians) * Math.sin((p.lng - lng) * radians / 2) ** 2;
    return { key, distance: 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(Math.max(0, 1 - a))) };
  }).filter((p) => p.distance > 5);
  if (!far.length) return null;
  const name = far.length > 1 ? "Some pins are" : far[0].key === "gt" ? "The GT Location pin is" : far[0].key === "truck" ? "The Truck Parking pin is" : `The ${pinLabel(far[0].key)} pin is`;
  return `${name} about ${Math.max(...far.map((p) => p.distance)).toFixed(1)} km from this property's address. Check the map is on the right property.`;
}