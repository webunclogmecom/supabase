// The light/dark switch in the top bar (canvas row G). Source of truth:
// Supabase/scripts/theme-switch/ThemeSwitch.tsx (byte-identical in the eight staff apps).
// From 768px: a two-part pill (pumpkin = White Halloween, bat moon = Dark Halloween; sun / moon after Halloween).
// Below 768px: one round button showing the current mode; a tap flips it.
import { useEffect, useState, type CSSProperties } from "react";
import { getThemeMode, isHalloween, setThemeMode, type ThemeMode } from "@/lib/halloween";

const Pumpkin = ({ carve }: { carve: string }) => (
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <path d="M12 6c.2-1.6 1-2.6 2.4-3" fill="none" stroke="#4d5a22" strokeWidth="1.8" strokeLinecap="round" />
    <ellipse cx="8.5" cy="14" rx="5" ry="6.5" fill="currentColor" />
    <ellipse cx="15.5" cy="14" rx="5" ry="6.5" fill="currentColor" />
    <ellipse cx="12" cy="14" rx="5.4" ry="7" fill="currentColor" opacity=".85" />
    <path d="M9 12.5l1.2-1.6 1 1.6zM13 12.5l1.2-1.6 1 1.6zM8.6 16c1.8 1.8 5 1.8 6.8 0" fill="none" stroke={carve} strokeWidth="1.2" strokeLinejoin="round" />
  </svg>
);
const BatMoon = ({ bat }: { bat: string }) => (
  <svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true">
    <path d="M15.5 3.5A8.5 8.5 0 1 0 20.5 15 7 7 0 0 1 15.5 3.5z" fill="currentColor" />
    <path d="M3 6c1-.8 2-.8 2.6 0 .3-.6 1-.8 1.4-.3.4-.5 1.1-.3 1.4.3.6-.8 1.6-.8 2.6 0-1 0-1.6.6-2 1.4l-.6-.6-.6.6-.6-.6-.6.6C4.6 6.6 4 6 3 6z" fill={bat} />
  </svg>
);
const Sun = () => (
  <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
  </svg>
);
const Moon = () => (
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" aria-hidden="true">
    <path d="M20.5 14.5A8.5 8.5 0 1 1 9.5 3.5a7 7 0 0 0 11 11z" />
  </svg>
);

// pill colours per look: [pill background, pill border, idle icon]
const LOOK = {
  "hw-light": ["#fbefe5", "#e3d4c6", "#8a7d93"],
  "hw-dark": ["#120d17", "#3a2d44", "#8f839c"],
  light: ["#f1f1f3", "#dedee3", "#7a7a85"],
  dark: ["#14171c", "#30353f", "#7f8693"],
} as const;

export function ThemeSwitch() {
  const [mode, setMode] = useState<ThemeMode | null>(null);
  useEffect(() => {
    setMode(getThemeMode());
    const onChange = (e: Event) => setMode((e as CustomEvent<ThemeMode>).detail);
    window.addEventListener("unclogme-theme", onChange);
    return () => window.removeEventListener("unclogme-theme", onChange);
  }, []);
  if (!mode) return null; // first paint on the server and before the choice is read

  const hw = isHalloween();
  const dark = mode === "dark";
  const [pillBg, pillBorder, idle] = LOOK[`${hw ? "hw-" : ""}${mode}` as keyof typeof LOOK];
  const lightName = hw ? "White Halloween" : "Light";
  const darkName = hw ? "Dark Halloween" : "Dark";
  const carve = dark ? "#0e0a12" : "#5a1a05";
  const bat = dark ? "#120b16" : "#3b1d4a";
  const lightIcon = hw ? <Pumpkin carve={carve} /> : <Sun />;
  const darkIcon = hw ? <BatMoon bat={bat} /> : <Moon />;

  const onLight: CSSProperties = {
    background: "#ffffff",
    color: "#f14714",
    boxShadow: hw ? "0 0 0 1.5px rgba(241,71,20,.55), 0 4px 12px -2px rgba(241,71,20,.45)" : "0 1px 3px rgba(24,24,27,.18)",
  };
  const onDark: CSSProperties = hw
    ? { background: "#2b1a3d", color: "#ffd27a", boxShadow: "0 0 0 1.5px rgba(255,210,122,.45), 0 0 14px rgba(255,210,122,.3)" }
    : { background: "#2a2f38", color: "#ff8a5b", boxShadow: "0 1px 3px rgba(0,0,0,.4)" };
  const off: CSSProperties = { background: "transparent", color: idle, boxShadow: "none" };
  const seg: CSSProperties = {
    width: 34, height: 28, border: 0, borderRadius: 999, display: "grid", placeItems: "center", cursor: "pointer", padding: 0,
    transition: "background-color .35s cubic-bezier(.22,1,.36,1), color .35s cubic-bezier(.22,1,.36,1)",
  };

  return (
    <>
      <div
        role="group"
        aria-label="Light or dark"
        className="hidden md:inline-flex"
        style={{ gap: 2, padding: 3, borderRadius: 999, background: pillBg, border: `1px solid ${pillBorder}`, flex: "none" }}
      >
        <button type="button" title={lightName} aria-label={lightName} aria-pressed={!dark} onClick={() => setThemeMode("light")} style={{ ...seg, ...(dark ? off : onLight) }}>
          {lightIcon}
        </button>
        <button type="button" title={darkName} aria-label={darkName} aria-pressed={dark} onClick={() => setThemeMode("dark")} style={{ ...seg, ...(dark ? onDark : off) }}>
          {darkIcon}
        </button>
      </div>
      {/* the wrapper carries md:hidden: the button's own inline display would beat the class */}
      <span className="md:hidden" style={{ flex: "none" }}>
        <button
          type="button"
          title={dark ? darkName : lightName}
          aria-label={dark ? `Switch to ${lightName}` : `Switch to ${darkName}`}
          onClick={() => setThemeMode(dark ? "light" : "dark")}
          style={{ ...seg, width: 36, height: 36, border: `1px solid ${pillBorder}`, ...(dark ? onDark : onLight) }}
        >
          {dark ? darkIcon : lightIcon}
        </button>
      </span>
    </>
  );
}
