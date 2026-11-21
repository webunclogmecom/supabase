// Halloween look + the light/dark switch + the Thanksgiving look. Source of truth: Supabase/scripts/theme-switch/halloween.ts
// (byte-identical in the eight staff apps; Building Apps/docs/halloween/README.md "Light / dark switch";
// Building Apps/docs/thanksgiving/README.md). Check: node --experimental-strip-types scripts/theme-switch/halloween.test.mjs
// Until HALLOWEEN_UNTIL: "dark" = Dark Halloween, "light" = White Halloween.
// After it: "dark" = plain Dark (app-assets/theme/), "light" = the app's normal look.
// The choice is per app (this site's localStorage). First visit: dark until the cutoff, light after.
const HALLOWEEN_UNTIL = Date.UTC(2026, 10, 4, 5, 0, 0); // 2026-11-04 00:00 ET
const ASSETS = "https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/app-assets/";
const KEY = "unclogme.theme";

export type ThemeMode = "light" | "dark";
let currentApp = "";

export const isHalloween = () => Date.now() < HALLOWEEN_UNTIL;

// Thanksgiving "Turkey Crew" look (Building Apps/docs/thanksgiving/README.md). On from Wednesday 2026-11-25 00:00 ET
// to Saturday 2026-11-28 00:00 ET (ET is UTC-5 in November). It rides on top of light or dark and changes neither.
const THANKSGIVING_FROM = Date.UTC(2026, 10, 25, 5, 0, 0);
const THANKSGIVING_UNTIL = Date.UTC(2026, 10, 28, 5, 0, 0);
export const isThanksgiving = (now: number = Date.now()) => now >= THANKSGIVING_FROM && now < THANKSGIVING_UNTIL;

export function getThemeMode(): ThemeMode {
  try {
    const v = localStorage.getItem(KEY);
    if (v === "light" || v === "dark") return v;
  } catch {
    // storage blocked: fall through to the default
  }
  return isHalloween() ? "dark" : "light";
}

function addSheet(id: string, href: string) {
  if (document.getElementById(id)) return;
  const link = document.createElement("link");
  link.id = id;
  link.rel = "stylesheet";
  link.href = href;
  document.head.appendChild(link);
}

function apply(mode: ThemeMode) {
  const html = document.documentElement;
  html.setAttribute("data-hw-app", currentApp);
  if (isHalloween()) {
    html.classList.add("halloween");
    html.setAttribute("data-hw-mode", mode);
    if (!html.hasAttribute("data-hw-boo")) html.setAttribute("data-hw-boo", Math.random() < 0.5 ? "fly" : "rise");
    addSheet("hw-css", ASSETS + "halloween/halloween.css");
    addSheet("hw-css-app", ASSETS + "halloween/halloween-" + currentApp + ".css");
  } else {
    html.classList.remove("halloween");
    html.removeAttribute("data-hw-mode");
    html.classList.toggle("app-dark", mode === "dark");
    if (mode === "dark") {
      addSheet("theme-dark", ASSETS + "theme/dark.css");
      addSheet("theme-dark-app", ASSETS + "theme/dark-" + currentApp + ".css");
    }
  }
  applyThanksgiving();
}

// ---- Thanksgiving: the class, two stylesheets, and the title-row helper -------------------------------------------
// Everything a person sees comes from the stylesheets (app-assets/thanksgiving/): this code only writes a class,
// attributes and CSS variables, so an empty stylesheet switches the look off with no build.
const TG_VARS = ["--tg-l", "--tg-r", "--tg-textw", "--tg-up"];
let tgObserver: MutationObserver | null = null;
let tgTimer = 0;
let tgRow: HTMLElement | null = null;

function clearTitleRow() {
  if (!tgRow) return;
  tgRow.removeAttribute("data-tg-title");
  tgRow.removeAttribute("data-tg-cards");
  for (const v of TG_VARS) tgRow.style.removeProperty(v);
  tgRow = null;
}

// Finds the row that holds the page's title and tells the stylesheet where a picture may stand in it:
// data-tg-title = "right" (in the row's free part), "left" (the row is full) or "top" (a phone),
// data-tg-cards = how many postcards fit (0, 3, 4 or 5), and four lengths:
// --tg-l where the picture may start, --tg-r what the row's own controls take on the right,
// --tg-textw how wide the title's words may run, --tg-up the gap between the top bar and the row.
function markTitleRow() {
  const html = document.documentElement;
  const page = location.pathname.replace(/\/+$/, "") || "/";
  if (html.getAttribute("data-tg-page") !== page) html.setAttribute("data-tg-page", page);
  const main = document.querySelector("main");
  const h1 = main
    ? Array.from(main.querySelectorAll("h1")).find((x) => !x.classList.contains("sr-only") && x.offsetWidth > 0)
    : undefined;
  if (!main || !h1 || !h1.parentElement) {
    clearTitleRow();
    return;
  }
  let row: HTMLElement = h1.parentElement;
  while (row.parentElement && row.parentElement !== main && row.parentElement.getBoundingClientRect().height < 170) {
    row = row.parentElement;
  }
  if (tgRow && tgRow !== row) clearTitleRow();
  // measured as if no length were set, so a second run gives the same answer as the first
  const had = TG_VARS.map((v) => row.style.getPropertyValue(v));
  for (const v of TG_VARS) row.style.removeProperty(v);
  const box = row.getBoundingClientRect();
  const pad = parseFloat(getComputedStyle(row).paddingLeft) || 0;
  // what already stands in the row beside the title (buttons, tiles): a picture must end before it
  const lefts: number[] = [];
  for (const e of Array.from(row.querySelectorAll<HTMLElement>("*"))) {
    if (e === h1 || e.contains(h1) || e.closest("h1,p") || e.tagName === "P" || e.offsetWidth === 0) continue;
    lefts.push(e.getBoundingClientRect().left);
  }
  for (const e of Array.from(main.querySelectorAll<HTMLElement>("button,a,input,select,[role=tab]"))) {
    if (row.contains(e) || e.offsetWidth === 0) continue;
    const q = e.getBoundingClientRect();
    if (q.top < box.bottom - 2 && q.bottom > box.top + 2) lefts.push(q.left);
  }
  const beside = lefts.filter((x) => x > box.left + box.width * 0.3);
  const left = Math.round(box.width * 0.43);
  const right = beside.length ? Math.round(box.right - Math.min(...beside) + 20) : 0;
  const room = box.width - left - right;
  const phone = window.innerWidth <= 640;
  const side = phone ? "top" : room >= 320 ? "right" : "left";
  const fit = phone ? Math.floor((box.width - 2 * pad) / 92) : side === "right" ? Math.floor((room - 138) / 100) : 0;
  const cards = fit < 3 ? 0 : Math.min(5, fit);
  const bar = document.querySelector(".shell-header, header");
  const up = bar ? Math.max(0, Math.round(box.top - bar.getBoundingClientRect().bottom)) : 0;
  const want = [left + "px", right + "px", Math.round(box.width * 0.4 - pad) + "px", up + "px"];
  TG_VARS.forEach((v, i) => row.style.setProperty(v, had[i] === want[i] ? had[i] : want[i]));
  if (row.getAttribute("data-tg-title") !== side) row.setAttribute("data-tg-title", side);
  if (row.getAttribute("data-tg-cards") !== String(cards)) row.setAttribute("data-tg-cards", String(cards));
  tgRow = row;
}

function queueTitleRow() {
  window.clearTimeout(tgTimer);
  tgTimer = window.setTimeout(markTitleRow, 150);
}

function applyThanksgiving() {
  const html = document.documentElement;
  const on = isThanksgiving();
  html.classList.toggle("thanksgiving", on);
  if (on) {
    html.setAttribute("data-tg-app", currentApp);
    addSheet("tg-css", ASSETS + "thanksgiving/thanksgiving.css");
    addSheet("tg-css-app", ASSETS + "thanksgiving/thanksgiving-" + currentApp + ".css");
    if (!tgObserver) {
      // a move to another page, or a row that fills in later, changes the page's children: mark the row again
      tgObserver = new MutationObserver(queueTitleRow);
      tgObserver.observe(document.body, { childList: true, subtree: true });
      window.addEventListener("resize", queueTitleRow);
    }
    queueTitleRow();
  } else {
    html.removeAttribute("data-tg-app");
    html.removeAttribute("data-tg-page");
    document.getElementById("tg-css")?.remove();
    document.getElementById("tg-css-app")?.remove();
    if (tgObserver) {
      tgObserver.disconnect();
      tgObserver = null;
      window.removeEventListener("resize", queueTitleRow);
    }
    window.clearTimeout(tgTimer);
    clearTitleRow();
  }
}

// A tab left open over the start or the end changes at that moment, without a reload.
function watchThanksgivingEdge() {
  const now = Date.now();
  const next = now < THANKSGIVING_FROM ? THANKSGIVING_FROM : now < THANKSGIVING_UNTIL ? THANKSGIVING_UNTIL : 0;
  if (!next || next - now > 2000000000) return; // a browser timer cannot wait longer than about 24 days
  window.setTimeout(() => {
    applyThanksgiving();
    watchThanksgivingEdge();
  }, next - now + 1000);
}

export function startHalloween(app: string) {
  if (typeof document === "undefined") return;
  currentApp = app;
  apply(getThemeMode());
  watchThanksgivingEdge();
}

export function setThemeMode(mode: ThemeMode) {
  try {
    localStorage.setItem(KEY, mode);
  } catch {
    // storage blocked: the choice lasts until the page is reloaded
  }
  apply(mode);
  window.dispatchEvent(new CustomEvent<ThemeMode>("unclogme-theme", { detail: mode }));
}
