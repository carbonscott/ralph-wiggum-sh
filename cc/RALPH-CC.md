# Ralph Loop — Claude Code Session Edition

Drop-in alternative to `cc-headless/ralph.sh --max-iterations N`,
designed to run entirely inside a live Claude Code chat session using
the `Agent()` subagent tool instead of headless `claude -p`. Use this
when `-p` mode is unavailable or restricted.

Same prompt template, same `tasks.json`, same `.lnb/` notebook, same
`archive/` directory, same per-iteration semantics. The only thing
that changes is who spawns the per-iteration agent.

## How to invoke

In a Claude Code chat, type one of:

> /ralph-lnb max-iterations 10

> /ralph-lnb max-iterations 5, task-file tasks.json

> /ralph-lnb max-iterations 5, prompt ./custom-prompt.md

If you skipped `install.sh`, the long form still works:

> follow $RALPH_REPO/cc/RALPH-CC.md, max-iterations 10

Defaults when unspecified:

- `max-iterations` = 10
- `task-file` = `tasks.json`
- `prompt` = the installed repo's `shared/PROMPT.md`
- `notebook` = `.lnb`

## Prerequisites

1. `RALPH_REPO` must be exported in the shell where Claude Code runs
   (e.g. `export RALPH_REPO=~/codes/ralph-wiggum-lnb`). All
   repo-relative paths below reference `$RALPH_REPO`. Verify with
   `echo "$RALPH_REPO"`.
2. The main Claude Code session must be in `acceptEdits` permission mode
   (or you must approve each subagent tool call manually). Subagents
   inherit the parent session's permission mode. This replaces
   `ralph.sh`'s `--permission-mode acceptEdits` flag.
3. `tasks.json` must exist in the current directory. Copy the starter
   and edit it: `cp "$RALPH_REPO/shared/tasks.json.example" tasks.json`,
   then describe your stories. Nothing else needs to live in the
   project dir — the prompt template, `ralph-prep.sh`, `ralph-lib.sh`,
   and `coding-dev.yaml` all stay in the repo and are invoked/sourced
   by absolute path.
4. `jq` and `lab-notebook` must be on `$PATH` (same as for `ralph.sh`).

## Procedure for the main Claude Code session

When the user invokes this file, the main session (you) must do the
following. Do not deviate, do not add steps, do not narrate beyond the
minimum specified.

### Setup

1. Verify `RALPH_REPO` is exported. Call:

   ```
   Bash("test -n \"$RALPH_REPO\" || { echo 'RALPH_REPO is not exported; see Prereq item 1' >&2; exit 1; }")
   ```

   If this fails, stop and report the error to the user. Do not continue.
2. Parse `max-iterations`, `task-file`, and `prompt` from the user's
   message. Apply defaults for anything unspecified. `prompt` is
   optional — if the user did not supply it, leave it unset and omit
   `--prompt` from the `ralph-prep.sh` call in Loop step 1.
3. Derive the notebook context once, so every subsequent log call uses
   the same value:

   ```
   Bash("jq -r '.branch // .project // \"ralph-dev\"' <task-file>")
   ```

   Capture stdout into `<context>`. This mirrors how `ralph-prep.sh`
   derives it, so both runners agree on the context slug.
4. Announce once: `"Starting ralph loop, max-iterations=N, task-file=X, prompt=P, context=<context>"`.
   One line, nothing more. Use the user-supplied prompt path for `P`
   if they passed one; otherwise use the literal string
   `shared/PROMPT.md` so readers can tell at a glance which template
   is in play.

### Loop

For `i` in `1..max-iterations`:

1. **Build the prompt.** Call:

   ```
   Bash("$RALPH_REPO/cc/ralph-prep.sh --iteration i --max-iterations N --task-file <task-file>[ --prompt <prompt>]")
   ```

   Append `--prompt <prompt>` only if the user supplied one in Setup
   step 2; otherwise omit the flag so `ralph-prep.sh` uses its own
   default (`shared/PROMPT.md`).

   Pass the same `N` you parsed in Setup so the start log entry records
   the cap alongside the iteration number (matches `ralph.sh`'s log
   format). Capture the tool result's stdout. This is the filled
   prompt. Do not read, quote, or summarize it — just hold it for the
   next step. `$RALPH_REPO` must be exported in the shell where the
   `Bash()` call runs (see Prerequisites item 1); an unset variable
   yields an empty path and the call fails with a clear error.

2. **Spawn the worker.** Call:

   ```
   Agent(
       subagent_type="general-purpose",
       description="ralph iteration i",
       prompt=<stdout from step 1>
   )
   ```

   The subagent will complete one story and return a final message
   ending with either `<promise>DONE</promise>` or
   `<promise>ALL_DONE</promise>`.

3. **Check the return.** Inspect the subagent's final message. **Check
   `ALL_DONE` first — `<promise>ALL_DONE</promise>` contains
   `<promise>DONE</promise>` as a substring, so the order is
   load-bearing.** (Same reason `cc-headless/ralph.sh`'s grep checks
   `ALL_DONE` before `DONE`.)

   - Contains `<promise>ALL_DONE</promise>`:
     - Call `Bash("LAB_NOTEBOOK_DIR=<notebook> lab-notebook emit --context <context> --type done --tags ralph-harness 'ralph-cc: all stories complete at iteration i'")`
       using the `<context>` derived in Setup step 3.
     - Break the loop. Go to "Post-loop".
   - Contains `<promise>DONE</promise>`:
     - Say exactly: `"iteration i: DONE, continuing"`. One line.
     - Continue to next iteration.
   - Neither marker:
     - Call `Bash(...)` to log a blocker entry (same shape as above but
       `--type blocker` and `"ralph-cc: iteration i ended without promise"`).
     - Break the loop. Go to "Post-loop".

### Post-loop

1. If the loop ended on `ALL_DONE`, optionally query the notebook for a
   summary, using the `<context>` derived in Setup step 3:

   ```
   Bash("LAB_NOTEBOOK_DIR=<notebook> lab-notebook sql \"SELECT ts, type, issue, substr(content,1,200) FROM entries WHERE context='<context>' AND type IN ('start','done','impl','blocker') ORDER BY ts\"")
   ```

   Report a 3-5 sentence summary to the user covering what each story
   accomplished.

2. If the loop ended on `max-iterations`, report:
   `"Hit iteration cap (N). Stopped. Check .lnb/ for progress."`

3. If the loop ended on a missing marker, report:
   `"Iteration i returned without a promise marker. Stopped. Check .lnb/ for the blocker entry and the subagent's final message."`

## Stop conditions (summary)

- `<promise>ALL_DONE</promise>` seen → success.
- `max-iterations` reached → capped.
- No promise marker in a subagent return → blocker.

## Context budgeting

Each iteration adds ~50 tokens (the subagent's final narration plus the
promise marker) to the main session's context. A 20-iteration run is
roughly 1k tokens — acceptable. Keep your own between-iteration
narration to one short line ("iteration i: DONE, continuing"). Do not
summarize subagent output, do not re-read `tasks.json` yourself
(`ralph-prep.sh` already does it every iteration), do not print anything
the user doesn't need.

## Differences from `ralph.sh`

| Aspect | `ralph.sh` | This flow |
|---|---|---|
| Entry | terminal: `ralph --max-iterations N` | chat: `/ralph-lnb max-iterations N` |
| Per-iter agent | `claude -p --permission-mode acceptEdits` | `Agent(subagent_type="general-purpose")` |
| Permission mode | CLI flag | inherited from main session |
| Intermediate display | stream-json via `format_stream` | native Claude Code subagent UI |
| Stop on no marker | no (only stops on non-zero exit code) | yes |
| Main-session context cost | 0 | ~50 tokens/iter |
| State storage | same | same |

## Relationship to `shared/ralph-lib.sh`

`ralph-prep.sh` sources `../shared/ralph-lib.sh` for the same helper
functions that `cc-headless/ralph.sh` uses (`read_task_meta`,
`archive_previous_run`, `ensure_notebook`, `log_to_notebook`,
`query_recent_history`, `build_prompt`). A change to
`shared/ralph-lib.sh` affects both runners.
