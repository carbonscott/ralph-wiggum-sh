# Smoke tests

Smoke test for the ralph loop against a throwaway 2-story fixture.
Exercises both modes so you can verify `RALPH-CC.md` and `ralph.sh`
still work end-to-end after editing `ralph-lib.sh`, `PROMPT.md`, etc.

## Files

- `tasks.json` — 2-story fixture (create `hello.txt`, append a line)
- `setup-sandbox.sh` — scaffolds a timestamped sandbox under `$TMPDIR`

## Running in Claude Code (non-headless)

1. From the repo root: `./tests/setup-sandbox.sh`. Note the sandbox
   path it prints.
2. Open a new session in the sandbox:
   ```
   cd /tmp/ralph-smoke-YYYYMMDD-HHMMSS && claude
   ```
3. Make sure the session is in `acceptEdits` mode (Shift+Tab, or
   `/permissions`). Subagents inherit the main session's permission
   mode, so this replaces `ralph.sh`'s `--permission-mode acceptEdits`
   flag.
4. In the session: `follow RALPH-CC.md, max-iterations 3`
5. Expected: Claude creates `hello.txt` with the two expected lines
   and reports `ALL_DONE` within 2 iterations.
6. Verify:
   ```
   cat hello.txt
   jq '.stories[].passes' tasks.json   # both should be true
   ls .lnb/
   ```

## Running headless

```
cd /tmp/ralph-smoke-YYYYMMDD-HHMMSS && ./ralph.sh --max-iterations 3
```

See `../RALPH-CC.md` and `../ralph.sh --help` for details on each mode.

## Cleanup

```
rm -rf /tmp/ralph-smoke-*
```

Sandboxes are timestamped, so old runs are never overwritten.

## Gotchas

- Needs `jq` and `lab-notebook` on `$PATH` (same prerequisites as
  ralph itself).
- The sandbox symlinks scripts from the repo, so uncommitted changes
  to `ralph-lib.sh` / `PROMPT.md` / etc. affect the test. This is by
  design — smoke tests validate the current source tree.
- The fixture's `branch: "ralph/smoke-test"` is just a label used for
  the notebook context and prompt substitution. Ralph does not run
  `git checkout`.
