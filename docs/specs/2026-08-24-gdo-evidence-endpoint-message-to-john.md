# Message to John: the evidence endpoint is live

**Status: DRAFT, NOT SENT.** Written 2026-08-24. Fred picks the channel and sends it.
**Supersedes** [`2026-08-21-gdo-late-evidence-questions-for-john.md`](2026-08-21-gdo-late-evidence-questions-for-john.md),
which asked five questions John's own messages had already answered. Do not send that one.

Everything below is live on Prod and was tested end to end against dry-run data before this was
written: 10 assertions on the happy path and the refusals, plus a JPEG/PNG control proving the stored
extension follows the real bytes rather than being hardcoded.

---

## The message

Hola John,

**The endpoint is live.** You can turn the strict flag on whenever you are ready.

### `POST https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/rpa-derm-evidence`

Same `x-rpa-key` as the other two. Body:

```json
{
  "visit_id": 6216,
  "run_id": "the SAME run_id you used on the result",
  "screenshot": "<base64 JPEG or PNG>"
}
```

`manifest_id` and `dry_run` are accepted and ignored, so you can reuse your result body if that is
easier. Anything else is a 400.

**Responses**

| Code | Body | Meaning |
|---|---|---|
| 200 | `{"attached":true,"screenshot_path":"...","screenshot_stored":true,"cleared_missing_reason":"..."}` | Stored. Whatever `screenshot_missing_reason` was on the row is cleared in the same write. |
| 200 | `{"attached":false,"already_had_evidence":true,"screenshot_path":"..."}` | That result already has an image. This is the normal answer to a retry, not an error. |
| 404 | `{"error":"result_not_found_for_visit_run"}` | Post the result first. |

### The two things worth knowing

**1. Fill-once.** The endpoint can only ever turn "no image" into "an image". It will never replace an
image we already hold, not even with a different one, and that is enforced in the database predicate
rather than in a branch, so it holds even if you call it twice at the same moment. **Retry it as often
as you like, in any order. It cannot do damage.** If an image ever genuinely needs correcting, that is
a human decision and we do it on our side.

**2. Post the result first, then attach.** Evidence for a `(visit_id, run_id)` we have never seen is a
404 rather than a stored orphan. So the sequence is always:

1. `POST /rpa-derm-result` with a `screenshot_missing_reason` saying why the image is not there yet,
2. `POST /rpa-derm-evidence` with the same `run_id` once the email arrives.

### One change on our side you should know about

**We now detect the image format from the bytes.** `rpa-derm-result` used to store every image as
`.jpg` with `image/jpeg` regardless of what it actually was. That was harmless while you were sending
portal screenshots, which really were JPEG. **The rendered email is PNG**, so from your first post it
would have been stored mislabelled. Both endpoints now read the real format and store the matching
extension and content type.

**So send the email render exactly as it is and do not re-encode it.** JPEG and PNG are both fine.

### Postman

The collection has a new folder, **"4. Evidence (late attach)"**, that runs top to bottom against
dry-run data: post a result with no image, attach it, attach again to see the fill-once no-op, and
attach to an unknown run to see the 404. Run "1. Queue - dry-run" first so the visit id is captured.

### A few things I would still like from you

1. **What exact `screenshot_missing_reason` string will you send** when the email has not arrived? We
   would rather agree the wording than parse whatever turns up, because staff see it.
2. **How late can the email be?** Seconds, minutes, or occasionally the next day? It decides whether
   we need to show staff a "waiting for evidence" state rather than just storing one quietly.
3. **Do you want to attach evidence to failed runs too, or only to successes?** Both work today, I
   just want to know which you intend.
4. **Is the bot stuck on the portal login?** We see four `ERROR_LOGIN_FAILED` results on visit 6617,
   the most recent on 2026-08-19, and no successful filing since 2026-08-17.
5. Still open from before, and no longer urgent, but I would like the answer: **when a ticket you have
   already filed comes back on our queue hours later, does the bot re-file it or skip it?**

Gracias,
Fred

---

## Notes for Fred, not part of the message

- **Nothing was sent.** Channel and timing are yours.
- **Question 4 is the one I would watch.** No successful filing since 2026-08-17 and four login
  failures on the same visit is consistent with the bot being blocked at the portal, which would
  matter more than this endpoint.
- **What was actually deployed today:** `rpa-derm-evidence` (new), `rpa-derm-result` (format
  sniffing), `config.toml`, the Postman README and collection, plus corrections to `integration.md`
  and the roadmap. Commit `4e09259`.
- **The strict-flag sequencing is his own proposal** and I have simply confirmed it: he flips it once
  he has run a round trip against the new endpoint.
