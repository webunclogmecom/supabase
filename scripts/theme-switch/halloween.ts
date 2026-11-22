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
const TG_VARS = ["--tg-l", "--tg-r", "--tg-textw", "--tg-up", "--tg-pad", "--tg-padt"];
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

// Names the page for the stylesheet (data-tg-page on <html>: the address's path, or "sign-in" on a sign-in page),
// finds the row that holds the page's title and tells the stylesheet where a picture may stand in it:
// data-tg-title = "right" (in the row's free part), "left" (the row is full) or "top" (a phone),
// data-tg-cards = how many postcards fit (0, 3, 4 or 5), and six lengths:
// --tg-l where the picture may start, --tg-r what the row's own controls take on the right,
// --tg-textw how wide the title's words may run, --tg-up the gap between the top bar and the row,
// --tg-pad and --tg-padt the row's own left and top padding.
function markTitleRow() {
  const html = document.documentElement;
  // every app's sign-in page is the same split screen; its orange panel is the mark
  const signIn = document.querySelector('[class*="135deg,#f14714"]') !== null;
  const page = signIn ? "sign-in" : location.pathname.replace(/\/+$/, "") || "/";
  if (html.getAttribute("data-tg-page") !== page) html.setAttribute("data-tg-page", page);
  // The marks come off first: the row is found and measured as the page stands WITHOUT the look, so a second run gives
  // the same answer as the first whatever the stylesheet does to a marked row. Nothing is painted in between.
  clearTitleRow();
  if (signIn) return;
  // an app with no <main> is searched whole, minus its top bar, menus and dialogs
  const scope: HTMLElement = document.querySelector("main") ?? document.body;
  const chrome = scope === document.body ? '[role="dialog"],header,nav,aside' : '[role="dialog"]';
  const first = (tag: string) =>
    Array.from(scope.querySelectorAll<HTMLElement>(tag)).find(
      (x) => !x.classList.contains("sr-only") && x.offsetWidth > 0 && !x.closest(chrome),
    );
  // the page's title: its h1, or its first h2 on a page that has no h1 (Pumped grease, Stamp Studio)
  const h1 = first("h1") ?? first("h2");
  // a screen with no top bar is a loading, refusal or error card, not a page: it gets no row
  const bar = document.querySelector(".shell-header, header, nav.border-b");
  if (!h1 || !bar) return;
  // the title's row: the title itself when nothing wraps it, else the widest box around it that is still a row
  let row: HTMLElement = h1;
  while (row.parentElement && row.parentElement !== scope && row.parentElement.getBoundingClientRect().height < 170) {
    row = row.parentElement;
  }
  const box = row.getBoundingClientRect();
  if (window.scrollY < 1 && box.top > 420) return; // a title that far down the screen is not the page's title row
  const style = getComputedStyle(row);
  const pad = parseFloat(style.paddingLeft) || 0;
  const padTop = parseFloat(style.paddingTop) || 0;
  // what already stands in the row beside the title (buttons, tiles): a picture must end before it
  const lefts: number[] = [];
  for (const e of Array.from(row.querySelectorAll<HTMLElement>("*"))) {
    if (e === h1 || e.contains(h1) || e.closest("h1,h2,p") || e.offsetWidth === 0) continue;
    lefts.push(e.getBoundingClientRect().left);
  }
  for (const e of Array.from(scope.querySelectorAll<HTMLElement>("button,a,input,select,[role=tab]"))) {
    if (row.contains(e) || e.offsetWidth === 0 || e.closest("header,nav")) continue;
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
  // the gap under the top bar as it is with the page at its top (a bar that stays on screen is counted from there)
  const barStyle = getComputedStyle(bar);
  const stays = barStyle.position === "sticky" || barStyle.position === "fixed";
  const barBottom = stays
    ? (parseFloat(barStyle.top) || 0) + (bar as HTMLElement).offsetHeight
    : bar.getBoundingClientRect().bottom + window.scrollY;
  const up = Math.max(0, Math.round(box.top + window.scrollY - barBottom));
  // the words end before the picture starts, wherever in the row they begin
  const textw = Math.round(box.width * 0.4 - (h1.getBoundingClientRect().left - box.left));
  const want = [left, right, Math.max(120, textw), up, Math.round(pad), Math.round(padTop)];
  TG_VARS.forEach((v, i) => row.style.setProperty(v, want[i] + "px"));
  row.setAttribute("data-tg-title", side);
  row.setAttribute("data-tg-cards", String(cards));
  tgRow = row;
}

function queueTitleRow() {
  window.clearTimeout(tgTimer);
  tgTimer = window.setTimeout(markTitleRow, 150);
}

function applyThanksgiving() {
  const html = document.documentElement;
  // the Planner's Site file is a customer page: the look never loads there (no stylesheet, no Google font list)
  const on = isThanksgiving() && !(currentApp === "planner" && /^\/driver(\/|$)/.test(location.pathname));
  html.classList.toggle("thanksgiving", on);
  if (on) {
    html.setAttribute("data-tg-app", currentApp);
    addSheet("tg-css", ASSETS + "thanksgiving/thanksgiving.css");
    addSheet("tg-css-app", ASSETS + "thanksgiving/thanksgiving-" + currentApp + ".css");
    // the stylesheet moves the top bar's margin: measure the title row again once it has landed
    document.getElementById("tg-css-app")?.addEventListener("load", queueTitleRow);
    if (!tgObserver) {
      // a move to another page, or a row that fills in later, changes the page's children: mark the row again
      tgObserver = new MutationObserver(queueTitleRow);
      tgObserver.observe(document.body, { childList: true, subtree: true });
      window.addEventListener("resize", queueTitleRow);
    }
    markTitleRow();
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

// For an app with its own light / dark switch (the Ops Portal): the Thanksgiving look alone. It never reads or sets
// the light / dark choice and loads nothing from halloween/ or theme/.
export function startThanksgiving(app: string) {
  if (typeof document === "undefined") return;
  currentApp = app;
  applyThanksgiving();
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
