# Slack message to John: the evidence endpoint is live

**Status: DRAFT, NOT SENT.** Written 2026-08-24. Fred sends it.
**Supersedes** [`2026-08-21-gdo-late-evidence-questions-for-john.md`](2026-08-21-gdo-late-evidence-questions-for-john.md),
which asked five questions John's own messages had already answered.

**Formatted as Slack mrkdwn, not Markdown**, because that is where John writes. So `*bold*` with single
asterisks, no `##` headers, no `---` rules, and links as `<url|text>`. ⚠ **Slack has no table syntax**,
which is why the response codes below are a list rather than the table the repo docs use.

Everything stated in it was verified against Prod before it was written: 10 assertions on the happy
path and the refusals, plus a JPEG/PNG control proving the stored extension follows the real bytes.

---

## The message (copy from here)

```
*The evidence endpoint is live.* You can flip the strict flag whenever you're ready.

`POST https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/rpa-derm-evidence`
Same `x-rpa-key` as the other two.

```
{
  "visit_id": 6216,
  "run_id": "the same run_id you used on the result",
  "screenshot": "<base64 JPEG or PNG>"
}
```

*Two rules worth knowing:*

- *Fill-once.* It can only ever turn "no image" into "an image". It will never replace one we already hold, not even with a different image, and that's enforced in the database predicate rather than in a branch, so it holds even if you call it twice at the same moment. *Retry it as often as you like, in any order. It cannot do damage.*
- *Result first, then evidence.* Evidence for a `(visit_id, run_id)` we've never seen is a `404`, not a stored orphan. So the sequence is: post the result with a `screenshot_missing_reason` saying why the image isn't there yet, then attach once the email lands.

*Responses:*
- `200 {"attached":true, "screenshot_path":"...", "cleared_missing_reason":"..."}` stored, and the missing-reason on the row is cleared in the same write
- `200 {"attached":false, "already_had_evidence":true, ...}` that result already has an image. This is the normal answer to a retry, not an error
- `404 {"error":"result_not_found_for_visit_run"}` post the result first

*One change on our side you should know about.* We now detect the image format from the bytes. `rpa-derm-result` used to store every image as `.jpg` with `image/jpeg` regardless of what it actually was. That was harmless while you were sending portal screenshots, which really were JPEG, but *the rendered email is PNG*, so from your first post it would have been stored mislabelled. Both endpoints now store the real extension and content type. *Send the email render exactly as it is and don't re-encode it.* JPEG and PNG are both fine.

*The docs are updated.* The API reference now has a section *4b* covering this endpoint end to end, the request body, every response, the full error list, and the result-before-evidence ordering. It also has the corrected rollout-gate status and a note on the image-format change:
https://github.com/webunclogmecom/supabase/blob/main/postman/README.md

The Postman collection has a new folder, *"4. Evidence (late attach)"*, that runs top to bottom against dry-run data: post a result with no image, attach it, attach again to see the fill-once no-op, then attach to an unknown run to see the 404. Run *"1. Queue - dry-run"* first so the visit id gets captured. Import the current version from here:
https://raw.githubusercontent.com/webunclogmecom/supabase/main/postman/gdo-reporting-bot.postman_collection.json

*A few things I'd still like from you:*

1. What exact `screenshot_missing_reason` string will you send when the email hasn't arrived yet? Staff see it, so I'd rather agree the wording than parse whatever turns up.
2. How late can that email be? Seconds, minutes, or occasionally the next day? It decides whether we need to show staff a "waiting for evidence" state or just store one quietly.
3. Do you want to attach evidence to failed runs too, or only to successes? Both work today, I just want to know which you intend.
4. *Is the bot stuck on the portal login?* I'm seeing 4 `ERROR_LOGIN_FAILED` results on visit 6617, most recent Aug 19, and no successful filing since Aug 17.
```

---

## Notes for Fred, not part of the message

- **Nothing has been sent.** Say the word and I will post it, but Slack posts as you, so I want your
  go-ahead in the moment rather than assuming.
- ⚠ **The JSON body is inside a nested code fence.** When you paste into Slack, paste the inner block
  as its own snippet or Slack will end the outer fence early. Safest is to paste the message, then
  paste the JSON separately.
- **Written in English** because your substantive exchange with him (ruling-B, fill-once, the
  sequencing) has been in English, even though his last check-in was in Spanish. Say if you want it in
  Spanish and I will redo it; the field names stay English either way.
- **Question 4 is the one I would watch.** No successful filing since 2026-08-17 plus four login
  failures on one visit is consistent with the bot being blocked at the portal, which matters more
  right now than the endpoint does.
- 🛑 **LINK GITHUB, NOT THE POSTMAN CLOUD WORKSPACE.** The collection was updated in the REPO. Nothing
  was pushed to `fred-532d2ca4-3599912.postman.co`, so the cloud workspace still serves the OLD
  three-folder collection with no evidence folder. Sending John the workspace link would show him a
  collection that contradicts the message. Both GitHub URLs above were verified 200 and confirmed to
  contain the new content before being put in front of him.
  ⚠ **Open item for Fred: re-import the JSON into the Postman workspace** so the two stop drifting.
- **Reply in his thread** rather than posting fresh, so it sits with his question about the date.
- Deployed today: `rpa-derm-evidence` (new), `rpa-derm-result` (format sniffing), `config.toml`, the
  Postman README and collection, plus corrections to `integration.md` and the roadmap. Commits
  `4e09259` and `c208a94`.
