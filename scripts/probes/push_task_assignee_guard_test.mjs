// jobber-push-task: a FAILED employee-link lookup must return null (stop the push), never [] (which an
// edit sends as assignedTo and strips the driver from the Task). Extracts assigneeForEmployee from the
// working tree AND from a git ref, and requires the pre-fix body to FAIL the error case: a suite that
// only runs the fixed body cannot tell a real guard from a no-op.
//
//   node scripts/probes/push_task_assignee_guard_test.mjs [pre-fix-ref, default fb9f761]
import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";

const FILE = "supabase/functions/jobber-push-task/index.ts";
const preRef = process.argv[2] ?? "fb9f761";

function extract(src) {
  const start = src.indexOf("async function assigneeForEmployee(");
  if (start < 0) throw new Error("assigneeForEmployee not found");
  const end = src.indexOf("\n}\n", start);
  return src.slice(start, end + 2)
    .replace(/\(employeeId: number\): Promise<string\[\](?: \| null)?>/, "(employeeId)");
}
function load(src) {
  return new Function("db", `${extract(src)}\nreturn assigneeForEmployee;`);
}
function stubDb(result) {
  const chain = { select: () => chain, eq: () => chain, maybeSingle: async () => result };
  return { from: () => chain };
}
const CASES = [
  { name: "lookup ERROR", result: { data: null, error: { message: "boom" } }, want: null },
  { name: "no Jobber link", result: { data: null, error: null }, want: [] },
  { name: "linked", result: { data: { source_id: "GID" }, error: null }, want: ["GID"] },
];

async function run(label, src) {
  let fails = 0;
  for (const c of CASES) {
    const fn = load(src)(stubDb(c.result));
    const got = await fn(7);
    const ok = JSON.stringify(got) === JSON.stringify(c.want);
    if (!ok) fails++;
    console.log(`${label.padEnd(8)} ${c.name.padEnd(15)} got ${JSON.stringify(got).padEnd(8)} ${ok ? "ok" : "FAIL"}`);
  }
  return fails;
}

console.error = () => {}; console.warn = () => {};
const now = await run("current", readFileSync(FILE, "utf8"));
const pre = await run(preRef, execSync(`git show ${preRef}:${FILE}`, { encoding: "utf8" }));
if (now !== 0) { console.log("\nFAIL: the current body does not meet the contract"); process.exit(1); }
if (pre === 0) { console.log(`\nFAIL: the ${preRef} body passes too, so this test cannot see the bug`); process.exit(1); }
console.log(`\nPASS: current body meets all ${CASES.length} cases; ${preRef} fails ${pre} (the control)`);
