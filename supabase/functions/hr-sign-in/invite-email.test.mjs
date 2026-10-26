// The check for invite-email.ts. Run: node supabase/functions/hr-sign-in/invite-email.test.mjs (Node 22.13+).
// Same loader as plan.test.mjs: strip the types, import from a data: URL (invite-email.ts must stay import-free).
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const src = stripTypeScriptTypes(readFileSync(new URL("./invite-email.ts", import.meta.url), "utf8"));
const { inviteEmail, expiresLabel } = await import("data:text/javascript;base64," + Buffer.from(src).toString("base64"));

const link = "https://wbasvhvvismukaqdnouk.supabase.co/auth/v1/verify?token=abc&type=invite&redirect_to=https%3A%2F%2Fhub.unclogme.app%2Freset-password%2Finvite";
// 2026-10-26 19:42 UTC = 3:42 PM EDT
const m = inviteEmail({ firstName: "Jerald", inviterName: "Serena", link, expiresAt: new Date("2026-10-26T19:42:00Z") });
assert.equal(m.subject, "Set up your UnclogMe account");
assert.equal(m.expiresLabel, "3:42 PM ET");
assert.ok(m.html.includes("Hi Jerald, Serena invited you to UnclogMe."));
assert.ok(m.html.includes("Link works until 3:42 PM ET"));
assert.ok(m.html.includes(">Choose your password</a>"));
// the link: the button, the fallback href and the fallback text; & is escaped in HTML
const escLink = link.replace(/&/g, "&amp;");
assert.equal(m.html.split(escLink).length - 1, 3);
assert.ok(!m.html.includes(link) || !link.includes("&"), "the raw & must not appear unescaped");
assert.ok(m.text.includes(link), "the text version carries the raw link");
assert.ok(!/\{\{|\}\}/.test(m.html), "no template placeholders");
assert.ok(!/[–—]/.test(m.html + m.text), "no dashes");
assert.ok(!m.html.includes("SiteURL"));
// hub.unclogme.app is always an explicit link, never bare text Gmail would auto-link in its own blue
assert.ok(!m.html.replace(/<a\b[^>]*>[\s\S]*?<\/a>/g, "").includes("hub.unclogme.app"), "bare hub.unclogme.app outside a link");
assert.equal(m.html.split('>hub.unclogme.app</a>').length - 1, 2);

// names are escaped
const x = inviteEmail({ firstName: "<b>Eve</b>", inviterName: "Tom & \"Co\"", link, expiresAt: new Date("2026-10-26T19:42:00Z") });
assert.ok(x.html.includes("Hi &lt;b&gt;Eve&lt;/b&gt;, Tom &amp; &quot;Co&quot; invited you"));
assert.ok(!x.html.includes("<b>Eve</b>"));

// expiry across midnight ET names the day; winter time is EST
assert.equal(expiresLabel(new Date("2026-10-27T04:15:00Z")), "12:15 AM ET on Oct 27");
assert.equal(expiresLabel(new Date("2026-12-01T20:05:00Z")), "3:05 PM ET");

// empty names fall back
const e = inviteEmail({ firstName: "", inviterName: "", link, expiresAt: new Date("2026-10-26T19:42:00Z") });
assert.ok(e.html.includes("Hi there, An admin invited you"));
console.log("invite-email.ts: all checks passed");
