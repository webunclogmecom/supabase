// The check for plan.ts. Run: node supabase/functions/hr-sign-in/plan.test.mjs (Node 22.13+, no Deno needed).
// The repo's package.json says "type": "commonjs", so Node will not load plan.ts as an ES module directly: the test
// strips its types and imports the result from a data: URL. plan.ts must stay import-free for that to work.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const src = stripTypeScriptTypes(readFileSync(new URL("./plan.ts", import.meta.url), "utf8"));
const { inviteMessage, planAction } = await import("data:text/javascript;base64," + Buffer.from(src).toString("base64"));

// the four actions
assert.deepEqual(planAction("reset_email"), { auth: "recover", notify: "none" });
assert.deepEqual(planAction("invite"), { auth: "invite", notify: "slack" });
assert.deepEqual(planAction("turn_off"), { auth: "ban", ban: "876000h", notify: "slack+email" });
assert.deepEqual(planAction("turn_on"), { auth: "unban", ban: "none", notify: "slack+email" });
// anything else fails (the old bare `else` unbanned it)
for (const bad of ["sign_out", "", "INVITE", "turn_on ", undefined]) assert.throws(() => planAction(bad), /no plan/);

const F = "Aaron";
const exists = "Aaron already has a sign-in. If they never chose a password, use Send password reset.";
const rate = "Too many emails this hour. Try again later.";
const retry = "The invite may not have gone out. Wait a minute and reload before sending again.";
const other = "The invite could not be sent. Nothing changed.";

assert.equal(inviteMessage({ name: "AuthApiError", status: 422, code: "email_exists" }, F), exists);
assert.equal(inviteMessage({ status: 422 }, F), exists);
assert.equal(inviteMessage({ status: 400, code: "email_exists" }, F), exists);
assert.equal(inviteMessage({ status: 429, code: "over_email_send_rate_limit" }, F), rate);
assert.equal(inviteMessage({ status: 400, code: "over_email_send_rate_limit" }, F), rate);
assert.equal(inviteMessage({ name: "AuthRetryableFetchError", status: 504 }, F), retry);
assert.equal(inviteMessage({ status: 504 }, F), retry);
assert.equal(inviteMessage({ status: 500, code: "unexpected_failure" }, F), retry);
assert.equal(inviteMessage({ status: 0 }, F), retry);
assert.equal(inviteMessage({ name: "AuthRetryableFetchError" }, F), retry);
assert.equal(inviteMessage({ status: 400, code: "validation_failed" }, F), other);
assert.equal(inviteMessage({ status: 403 }, F), other);
assert.equal(inviteMessage(null, F), other);
// decided by status and code, never by the text
assert.equal(inviteMessage({ status: 400, message: "rate limit exceeded, email already exists" }, F), other);
// the retryable sentence never claims nothing changed
assert.ok(!retry.includes("Nothing changed"));
assert.ok(!inviteMessage({ status: 504 }, F).includes("Nothing changed"));
assert.ok(!inviteMessage({ status: 0 }, F).includes("Nothing changed"));
// no em or en dashes in any sentence
const dash = new RegExp("[" + String.fromCharCode(0x2013, 0x2014) + "]");
for (const s of [exists, rate, retry, other]) assert.ok(!dash.test(s));

console.log("plan.test.mjs: all checks passed");
