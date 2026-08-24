# Reply to Jonathan, 2026-08-24

Slack mrkdwn, ready to paste. `*single asterisks*` for bold, no `##`, no `---`, no tables.

⚠ **Two parts. Part 1 is what Fred asked for and is ready to send as-is.**
**Part 2 answers Jonathan's question 4 and is OPTIONAL** — it depends on whether Fred wants the row
un-parked. Send it only if the answer is yes, or trim it to the diagnosis and drop the last line.

⚠ Deliberately does NOT mention the email watchdog. Fred: *"no need to tell him we're using the
health watchdog on the email now, just tell him that we will not be using his slack app so he
doesn't need to be a worryhead."*

---

## Part 1 — the Slack app (send this)

```
Jonathan — thanks, all three answers noted and recorded.

*On the Health digests: those were ours, not yours, and they're off your app now.* They were coming
through the GDO Online Report webhook, which is why they wore the RPA bot's name. You were right that
nobody could tell which system was talking. They've been moved off it entirely, so you won't see them
again and there's nothing on your side to change.

The two identical posts 18 minutes apart were us testing the wiring, not the thing misbehaving. It
only ever spoke on a change; we forced those two so we could watch them land. Sorry for the noise in
your channel.

On your other three:

1. `confirmation_email_not_received` and `confirmation_email_wait_interrupted` — noted as the only two
strings. Staff see them as-is for now.
2. Same-minute typical, about an hour worst case. On those numbers we're not building a "waiting for
evidence" state — not worth it for something that short-lived.
3. Successes only. Understood, and it matches what the endpoint already does.
```

---

## Part 2 — question 4, the 11024 row (OPTIONAL, needs Fred's go-ahead)

```
On question 4 — you were right to ask rather than assume, and it isn't what either of us guessed.

*Nobody parked it, and the bot is fine.* The queue has four exclusion gates and exactly one of them
is holding the row: the data-error gate, which refuses to retry a non-retryable failure until
something about the row *changes*. Its freshness anchor is a database timestamp:

```
last change we can see   2026-08-19 04:03 ET
last failed attempt      2026-08-19 12:15 ET   <- newer, so the gate stays shut
```

*You fixed the credential at the county, which our database has no way to see.* So the fix is real
and completely invisible to the gate. That's why your digests show the queue empty on the 21st, 22nd
and 23rd while the row sits excluded, and why no amount of polling would ever have brought it back.

Touching the manifest row re-opens the gate — that's the designed signal, not a workaround. Doing
that now, so it should reach you on the next hourly serve and file clean.

Worth flagging for next time: any fix you make on the county side is structurally invisible to that
gate. If it happens again, ping me and I'll re-open it rather than you waiting on a queue that can't
know.
```

---

## Notes for Fred

- **Part 2's last-but-one paragraph promises the un-park.** If you don't want it done, cut that
  paragraph and the message still works as a diagnosis.
- The un-park itself is one statement, and the migration that built the gate documents this exact
  intent (*"non-retryable data error holds until the manifest row changes (server clock)"*):
  ```sql
  update public.derm_manifests set updated_at = now() where id = 1692;
  ```
  Only column-scoped triggers sit on that table, so a timestamp-only touch fires nothing but the
  audit row.
- The durable fix, not built: a small `requeue` function that records an explicit operator decision,
  so an external fix doesn't need someone to poke a timestamp. Jonathan will hit this again.
