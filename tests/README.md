# Smoke tests

Smoke test for the ralph loop against a throwaway 2-story fixture.
Exercises both modes so you can verify the `/ralph-lnb` skill and
`cc-headless/ralph.sh` still work end-to-end after editing
`shared/ralph-lib.sh`, `shared/PROMPT.md`, etc.

## Files

- `tasks.json` — 2-story fixture (create `hello.txt`, append a line)
- `setup-sandbox.sh` — scaffolds a timestamped sandbox under `$TMPDIR`
- `prompt-diff.sh` — exit-code regression test asserting the two runners
  (`cc-headless/ralph.sh` and `cc/ralph-prep.sh`) build byte-identical
  prompts, and that recent history is queried before the iteration's own
  `start` entry is logged. Run with `bash tests/prompt-diff.sh` (exits 0 on
  pass; prints a diff and exits non-zero on divergence). Self-contained:
  uses its own `$TMPDIR` sandboxes and needs no install.
- `archive.sh` — drives `cc/ralph-prep.sh` to assert the `.ralph/state.json`
  cursor, the archive-on-branch-change trigger (snapshots only `tasks.json`,
  never the notebook), and the refuse-respin guard (an all-green recorded
  batch is refused with exit 3 unless `--force`). Run with
  `bash tests/archive.sh` (exits 0 on pass).
- `concurrency.sh` — proves the per-loop writer design: two loops on different
  branches pointed at one shared notebook each emit, concurrently, under their
  own `ralph-<branch>` writer, landing in distinct `entries/ralph-*.jsonl`
  files with nothing lost. Run with `bash tests/concurrency.sh` (exits 0 on
  pass; SKIPs cleanly if `lab-notebook` is not on `$PATH`).
- `upgrade.sh` — exercises `migrate_old_layout`, the one-time shim that moves
  an old root-scattered install (`./.lnb`, `./.lnb.env`, `./.ralph-last-branch`,
  `./archive/`) under `.ralph/` without data loss and is a clean no-op
  afterwards — both in isolation and end-to-end through `cc/ralph-prep.sh`.
  Run with `bash tests/upgrade.sh` (exits 0 on pass).

Run all four at once with
`for t in prompt-diff archive concurrency upgrade; do bash "tests/$t.sh"; done`
(each is self-contained and exits 0 on pass; `setup-sandbox.sh` is a scaffolder,
not a pass/fail test, so it is deliberately excluded).

Prerequisite: run `../install.sh` once from the repo so `ralph` is on
`$PATH` and `/ralph-lnb` is registered as a Claude Code skill. If you
prefer not to install, the sandbox-setup script also prints
absolute-path fallbacks you can use instead.

## Running in Claude Code (non-headless)

1. From the repo root: `./tests/setup-sandbox.sh`. Note the sandbox
   path it prints.
2. Open a new session in the sandbox:
   ```
   cd /tmp/ralph-smoke-YYYYMMDD-HHMMSS && claude
   ```
3. Make sure the session is in `acceptEdits` mode (Shift+Tab, or
   `/permissions`). Subagents inherit the main session's permission
   mode, so this replaces `cc-headless/ralph.sh`'s
   `--permission-mode acceptEdits` flag.
4. In the session: `/ralph-lnb max-iterations 3` (the sandbox-setup
   script prints the exact line to use, including the no-install
   fallback if you haven't run `../install.sh` yet).
5. Expected: Claude creates `hello.txt` with the two expected lines
   and reports `ALL_DONE` within 2 iterations.
6. Verify:
   ```
   cat hello.txt
   jq '.stories[].passes' tasks.json   # both should be true
   ls .ralph/.lnb/
   ```

## Running headless

```
cd /tmp/ralph-smoke-YYYYMMDD-HHMMSS && ralph --max-iterations 3
```

The sandbox-setup script prints the exact command (assuming you've
run `../install.sh` from the repo once). See `../skill/SKILL.md.template`
and `../cc-headless/ralph.sh --help` for details on each mode.

## Cleanup

```
rm -rf /tmp/ralph-smoke-*
```

Sandboxes are timestamped, so old runs are never overwritten.

## Gotchas

- Needs `jq` and `lab-notebook` on `$PATH` (same prerequisites as
  ralph itself).
- The sandbox only contains `tasks.json`. The runners pick up
  `shared/PROMPT.md` from the repo automatically, and all helper
  scripts are invoked live from the repo by absolute path — so
  uncommitted changes to `shared/PROMPT.md`, `shared/ralph-lib.sh`,
  etc. still affect the test. This is by design: smoke tests validate
  the current source tree.
- The fixture's `branch: "ralph/smoke-test"` is just a label used for
  the notebook context and prompt substitution. Ralph does not run
  `git checkout`.
