# client.get_client_activity tests

The build files of migration `docs/migrations/2026-10-06_1736_client_activity_history.sql`, kept with
placeholders (`__FN__`, `__S__`, `__CFG__`) so the same text runs as a throwaway `pg_temp` copy.

```
node run_tests.js            # the build as a pg_temp copy: 20 smoke cases
node run_tests.js --live     # the same cases against the live client.get_client_activity
node run_tests.js merge5s    # a mutation control: the named case must FAIL (see MUTATIONS in run_tests.js)
```

Every case writes synthetic audit rows (and one client_status_changes / client_create_attempts row) for the
test client 112-YA inside ONE DO block that always raises, so nothing persists; the results ride in the
raised message. After a change to `function.sql`, run all 11 controls: each must break exactly its case.
