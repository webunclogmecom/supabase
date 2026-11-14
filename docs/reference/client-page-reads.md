# The reads behind the portal's Clients pages and the manifest dialog

*The database side of the Client App's move into the Ops Portal (Trello #161, Stage E). Plan:
`Building Apps/Ops Portal/docs/specs/2026-11-13-client-app-move-plan.md` (section "Outside the app, in the Supabase repo",
B1 to B4, and decision 3). Fred, 2026-11-14 about 12:40 AM ET: "AA to FF all yes, and all defaults".*

Every function here is read only, STABLE, SECURITY DEFINER owned by postgres with `search_path` pinned to `''`, EXECUTE
revoked from PUBLIC and anon by name and granted to `authenticated` only (the exceptions are named). Each starts with
`hr.fn_require_any_app(array[...], 'view')`, the gate `public.get_record_history` has, then the staff check of the DERM
reads. **Pick BB (decision 3):** a person with the Client App alone opens every Clients page and the manifest dialog, so
each read accepts the Client App OR the app whose page also calls it.

Standing check: `scripts/checks/client_page_reads.sql` (run as owner inside BEGIN ... ROLLBACK; it raises on a failure).

## The manifest row states: one core, two gated readers (2026-11-14_0135)

Migration `docs/migrations/2026-11-14_0135_derm_manifest_row_states_per_client.sql`, undo
`2026-11-14_rollback_derm_manifest_row_states_per_client.sql` (it refuses while `derm.get_manifest_dialog` exists).

| function | gate | returns |
|---|---|---|
| `derm.fn_manifest_row_states_core()` | none. SECURITY INVOKER, EXECUTE for the owner only (revoked from PUBLIC, anon, authenticated, service_role) | the Manifests list's row states, every ticket |
| `derm.manifest_row_states()` | DERM Tracker View, then the staff check (unchanged) | the core's answer |
| `derm.manifest_row_states_for_client(p_client_id bigint)` | Client App OR DERM Tracker View | the core's entries for the tickets holding a live manifest row of that client |

- **One copy of the rules.** The core is the 2026-11-13_0148 body of `derm.manifest_row_states()` byte for byte, without
  its gate; the wrapper keeps the gate and calls the core. The migration compared the old and the new answer on every row
  inside its own transaction, and the rehearsal checked the per-client read for all 204 clients holding a live manifest
  row (together their entries are exactly the 181 entries of the list).
- **Shape:** the same object as `derm.manifest_row_states()` (the CLAUDE.md section "THE MANIFESTS ROWS READ"): keys are
  the list's row keys (`Miami-Dade #<number>`, `Broward #<number>`), each entry with `manifest_ids`, `needs`, `worst`,
  `papers`, `stamps`, `copies`, `city`, `visit`, `sheets`. An entry's `manifest_ids` lists every row of its ticket, other
  clients' included (ids only). A client with no live row gets `{}`.
- 112-YA (client 381) today: `{"Miami-Dade #111111": {...}, "Miami-Dade #111112": {...}}`.
- **Cost:** the core reads every ticket (about 0.15 s), so the per-client read costs the same.
  ponytail: pass the client's keys into the core if a client page read gets slow.
- **A new reader of the row states calls the core from behind its own gate**; never copy the rows' rules.
