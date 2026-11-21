// Checks the Thanksgiving window of the shared holiday file.
//   node --experimental-strip-types scripts/theme-switch/halloween.test.mjs [git ref of the file before the change]
// With a ref (default HEAD~1 is NOT assumed: pass one), the file at that ref is the control: it must FAIL the
// window cases, or this test proves nothing.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const et = (ms) => new Date(ms).toLocaleString("en-US", { timeZone: "America/New_York" });
const FROM = Date.UTC(2026, 10, 25, 5, 0, 0);
const UNTIL = Date.UTC(2026, 10, 28, 5, 0, 0);
const CASES = [
  ["one second before it starts", FROM - 1000, false],
  ["its first second", FROM, true],
  ["Thanksgiving Day at noon ET", Date.UTC(2026, 10, 26, 17, 0, 0), true],
  ["its last second", UNTIL - 1000, true],
  ["the second it ends", UNTIL, false],
  ["today, 2026-11-20", Date.UTC(2026, 10, 21, 3, 0, 0), false],
];

// The file is copied to a temp .mts first: a bare .ts beside no package.json loads as CommonJS and cannot be imported.
async function run(source) {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "hw-")), "halloween.mts");
  fs.writeFileSync(file, source);
  const m = await import(pathToFileURL(file).href);
  const out = [];
  out.push(["the start is 12:00 AM ET on Wednesday Nov 25", et(FROM) === "11/25/2026, 12:00:00 AM"]);
  out.push(["the end is 12:00 AM ET on Saturday Nov 28", et(UNTIL) === "11/28/2026, 12:00:00 AM"]);
  for (const [name, at, want] of CASES) {
    out.push([name + " -> " + (want ? "on" : "off"), typeof m.isThanksgiving === "function" && m.isThanksgiving(at) === want]);
  }
  // outside a browser the file must do nothing and must not throw
  let quiet = true;
  try { m.startHalloween("hub"); m.startThanksgiving?.("portal"); } catch { quiet = false; }
  out.push(["startHalloween and startThanksgiving do nothing outside a browser", quiet]);
  out.push(["the light / dark exports are still there", ["getThemeMode", "setThemeMode", "isHalloween", "startHalloween"].every((k) => typeof m[k] === "function")]);
  return out;
}

const now = await run(fs.readFileSync(path.join(here, "halloween.ts"), "utf8"));
let failed = 0;
for (const [name, ok] of now) { console.log((ok ? "PASS " : "FAIL ") + name); if (!ok) failed++; }

const ref = process.argv[2];
if (ref) {
  const old = execFileSync("git", ["show", ref + ":scripts/theme-switch/halloween.ts"], { cwd: path.join(here, "..", ".."), encoding: "utf8" });
  const before = await run(old);
  const windowCases = before.filter(([name]) => / -> (on|off)$/.test(name));
  const controlFails = windowCases.filter(([, ok]) => !ok).length;
  const ok = controlFails === windowCases.length;
  console.log((ok ? "PASS " : "FAIL ") + "CONTROL: the file at " + ref + " fails all " + windowCases.length + " window cases (it failed " + controlFails + ")");
  if (!ok) failed++;
}
console.log(failed ? "FAILED " + failed : "ALL PASS");
process.exit(failed ? 1 : 0);
