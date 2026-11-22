// Checks the Thanksgiving window of the shared holiday file.
//   node --experimental-strip-types scripts/theme-switch/halloween.test.mjs [git ref of the file before the change]
// With a ref (default HEAD~1 is NOT assumed: pass one), the file at that ref is the control: it must FAIL at least one
// window case (the cases its change moved), or this test proves nothing. Since 2026-11-22 (the start moved to Monday
// 9:00 AM ET) a file from before that day fails the Monday and Tuesday cases.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const et = (ms) => new Date(ms).toLocaleString("en-US", { timeZone: "America/New_York" });
const FROM = Date.UTC(2026, 10, 23, 14, 0, 0); // Monday 9:00 AM ET (Fred, 2026-11-22)
const UNTIL = Date.UTC(2026, 10, 28, 5, 0, 0);
const CASES = [
  ["one second before it starts", FROM - 1000, false],
  ["its first second", FROM, true],
  ["Monday Nov 23 at noon ET", Date.UTC(2026, 10, 23, 17, 0, 0), true],
  ["Tuesday Nov 24 at noon ET", Date.UTC(2026, 10, 24, 17, 0, 0), true],
  ["Monday Nov 23 at 8:59 AM ET", Date.UTC(2026, 10, 23, 13, 59, 0), false],
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
  out.push(["the start is 9:00 AM ET on Monday Nov 23", et(FROM) === "11/23/2026, 9:00:00 AM"]);
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
  const failedNames = windowCases.filter(([, ok]) => !ok).map(([name]) => name);
  const ok = failedNames.length > 0;
  console.log((ok ? "PASS " : "FAIL ") + "CONTROL: the file at " + ref + " fails " + failedNames.length + " of " + windowCases.length + " window cases" + (failedNames.length ? ": " + failedNames.join("; ") : " (it must fail at least one)"));
  if (!ok) failed++;
}
console.log(failed ? "FAILED " + failed : "ALL PASS");
process.exit(failed ? 1 : 0);
