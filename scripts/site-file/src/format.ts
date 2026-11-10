// Pure formatters. This module must stay free of imports.

const fmt = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  month: "short",
  day: "numeric",
  year: "numeric",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});

export function formatET(v: string | null | undefined): string {
  if (!v) return "—";
  const d = new Date(v);
  if (isNaN(d.getTime())) return String(v);
  return fmt.format(d);
}

const DAYS: [string, string[]][] = [
  ["Mon", ["mon", "monday"]],
  ["Tue", ["tue", "tues", "tuesday"]],
  ["Wed", ["wed", "wednesday"]],
  ["Thu", ["thu", "thur", "thurs", "thursday"]],
  ["Fri", ["fri", "friday"]],
  ["Sat", ["sat", "saturday"]],
  ["Sun", ["sun", "sunday"]],
];

export function to12(t: string): string {
  const m = /^(\d{1,2}):(\d{2})/.exec(t);
  if (!m) return t;
  let h = Number(m[1]);
  const ap = h >= 12 ? "PM" : "AM";
  h = h % 12 || 12;
  return `${h}:${m[2]} ${ap}`;
}

function norm(t: string) {
  const m = /^(\d{1,2}):(\d{2})/.exec(t);
  return m ? m[1].padStart(2, "0") + ":" + m[2] : t;
}

export function weeklyHoursLines(value: unknown): string[] {
  if (!value || typeof value !== "object") return [];
  const obj: Record<string, unknown> = {};
  if (Array.isArray(value)) {
    value.forEach((e: any) => {
      if (e && e.day) obj[String(e.day).toLowerCase()] = e;
    });
  } else {
    Object.entries(value as Record<string, unknown>).forEach(([k, v]) => (obj[k.toLowerCase()] = v));
  }
  const lines: string[] = [];
  for (const [label, keys] of DAYS) {
    const k = keys.find((x) => x in obj);
    if (!k) continue;
    const v: any = obj[k];
    if (!v) continue;
    let open: string | undefined, close: string | undefined;
    if (Array.isArray(v)) [open, close] = v;
    else if (typeof v === "object") {
      open = v.open ?? v.from ?? v.start;
      close = v.close ?? v.to ?? v.end;
    } else {
      lines.push(`${label} ${String(v)}`);
      continue;
    }
    if (!open || !close) continue;
    const o = norm(open), c = norm(close);
    if (o === "00:00" && c === "00:00") lines.push(`${label} any time`);
    else lines.push(`${label} ${to12(o)} to ${to12(c)}${c < o ? " (overnight)" : ""}`);
  }
  return lines;
}

const dateFmt = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  month: "short",
  day: "numeric",
  year: "numeric",
});

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/**
 * Date only, e.g. "Sep 25, 2026". A date-only value ("2026-09-15") is
 * formatted from its own parts, never through a time zone; timestamps are
 * shown in Eastern Time.
 */
export function formatDateET(v: string | null | undefined): string {
  if (!v) return "";
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(v).trim());
  if (m) {
    const mo = Number(m[2]);
    if (mo >= 1 && mo <= 12) return `${MONTHS[mo - 1]} ${Number(m[3])}, ${m[1]}`;
  }
  const d = new Date(v);
  if (isNaN(d.getTime())) return String(v);
  return dateFmt.format(d);
}

const FULL_DAYS: [string, string[]][] = [
  ["Monday", DAYS[0][1]],
  ["Tuesday", DAYS[1][1]],
  ["Wednesday", DAYS[2][1]],
  ["Thursday", DAYS[3][1]],
  ["Friday", DAYS[4][1]],
  ["Saturday", DAYS[5][1]],
  ["Sunday", DAYS[6][1]],
];

/**
 * Driver-page hours: every day Monday first. 00:00–00:00 is "Any time",
 * close at or before open is "(overnight)", a missing day is "No access".
 * Returns [] when there are no hours at all.
 */
export function driverHoursRows(value: unknown): { day: string; text: string }[] {
  if (!value || typeof value !== "object") return [];
  const obj: Record<string, any> = {};
  if (Array.isArray(value)) {
    value.forEach((e: any) => {
      if (e && e.day) obj[String(e.day).toLowerCase()] = e;
    });
  } else {
    Object.entries(value as Record<string, unknown>).forEach(([k, v]) => (obj[k.toLowerCase()] = v));
  }
  if (Object.keys(obj).length === 0) return [];
  let any = false;
  const rows = FULL_DAYS.map(([day, keys]) => {
    const k = keys.find((x) => x in obj);
    const v = k ? obj[k] : null;
    let open: string | undefined, close: string | undefined;
    if (Array.isArray(v)) [open, close] = v;
    else if (v && typeof v === "object") {
      open = v.open ?? v.from ?? v.start;
      close = v.close ?? v.to ?? v.end;
    }
    if (!open || !close) return { day, text: "No access" };
    any = true;
    const o = norm(open), c = norm(close);
    if (o === "00:00" && c === "00:00") return { day, text: "Any time" };
    return { day, text: `${to12(o)} to ${to12(c)}${c <= o ? " (overnight)" : ""}` };
  });
  return any ? rows : [];
}
