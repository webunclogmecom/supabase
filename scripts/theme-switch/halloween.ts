// Halloween look + the light/dark switch. Source of truth: Supabase/scripts/theme-switch/halloween.ts
// (byte-identical in the eight staff apps; Building Apps/docs/halloween/README.md "Light / dark switch").
// Until HALLOWEEN_UNTIL: "dark" = Dark Halloween, "light" = White Halloween.
// After it: "dark" = plain Dark (app-assets/theme/), "light" = the app's normal look.
// The choice is per app (this site's localStorage). First visit: dark until the cutoff, light after.
const HALLOWEEN_UNTIL = Date.UTC(2026, 10, 4, 5, 0, 0); // 2026-11-04 00:00 ET
const ASSETS = "https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/app-assets/";
const KEY = "unclogme.theme";

export type ThemeMode = "light" | "dark";
let currentApp = "";

export const isHalloween = () => Date.now() < HALLOWEEN_UNTIL;

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
}

export function startHalloween(app: string) {
  if (typeof document === "undefined") return;
  currentApp = app;
  apply(getThemeMode());
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
