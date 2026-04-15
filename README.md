# Ralph Wiggum

Autonomous agent loop for code development. Spawns a fresh Claude instance
per iteration. Each iteration completes one story, logs progress to
a [lab-notebook](https://github.com/carbonscott/lab-notebook), and moves on.

Based on the [Ralph Wiggum technique](https://ghuntley.com/ralph/) with
structured notebook logging (queryable history, pattern discovery). See also
[Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).

## Install

```bash
git clone https://github.com/carbonscott/ralph-wiggum-lnb ~/codes/ralph-wiggum-lnb
~/codes/ralph-wiggum-lnb/install.sh
```

Two install artifacts:

- `~/.local/bin/ralph` → symlink to the headless runner. Put `~/.local/bin`
  on `$PATH` if it isn't already (`install.sh` warns you if not).
- `~/.claude/skills/ralph-lnb/SKILL.md` → the `ralph-lnb` skill. Claude
  Code exposes user-invocable skills as slash commands, so it appears
  as `/ralph-lnb` in chat.

After install, the invocations become:

- **Headless**: `ralph --max-iterations 3`
- **Claude Code chat**: `/ralph-lnb max-iterations 3` (restart any
  running sessions — skills load at session start)

`install.sh` is idempotent. Re-run it after moving or re-cloning the
repo — it rewrites the skill with the new path. Override the bin
location with `RALPH_BIN_DIR=/usr/local/bin ./install.sh`. Undo with
`./uninstall.sh` — if you overrode `RALPH_BIN_DIR` on install, pass
the same value on uninstall so it can find the symlink to remove.

If you prefer not to install, the absolute-path invocations in the
Quick Start below still work.

## Quick Start

```bash
# In your project directory:
cp ~/codes/ralph-wiggum-lnb/shared/PROMPT.md .
cp ~/codes/ralph-wiggum-lnb/shared/tasks.json.example tasks.json
# Edit tasks.json with your stories
```

The runner auto-initializes `.lnb/` with the coding schema on the first
iteration — no manual `lab-notebook init` needed.

Then pick one runner:

**Headless** (uses `claude -p`):

```bash
~/codes/ralph-wiggum-lnb/cc-headless/ralph.sh --max-iterations 5
```

**Inside a Claude Code session** (uses the `Agent()` subagent tool — no `-p` needed):

Start Claude Code in `acceptEdits` mode, then in the session:

> follow ~/codes/ralph-wiggum-lnb/cc/RALPH-CC.md, max-iterations 5

No extra files need to live in your project dir — `PROMPT.md` +
`tasks.json` is the entire footprint. Helper scripts, the shared lib,
and the notebook schema all stay in the repo and are invoked or sourced
by absolute path.

## How It Works

```
tasks.json (what to do)  +  .lnb/ (what happened)  +  PROMPT.md (how to do it)
           │                       │                           │
           └───────────┬───────────┘                           │
                       ▼                                       │
              runner   builds prompt ◄─────────────────────────┘
                     │
              ┌──────┴──────────────────────┐
              │  for each iteration:        │
              │    query notebook → history  │
              │    inject tasks + history    │
              │    spawn fresh agent         │
              │    agent works on 1 story    │
              │    agent logs throughout     │
              │    agent emits promise       │
              │    check DONE / ALL_DONE    │
              └─────────────────────────────┘
```

## Two runners, same loop

Ralph ships two entry points that share the same `PROMPT.md`, `tasks.json`,
`.lnb/`, and `archive/` state:

- **`cc-headless/ralph.sh`** — the original. Runs in a terminal, spawns
  a fresh `claude -p` per iteration. Truly stateless outer loop.
- **`cc/RALPH-CC.md`** — drop-in alternative that runs inside a live
  Claude Code chat session and uses the `Agent()` subagent tool. Use
  when `-p` mode is unavailable or restricted. See `cc/RALPH-CC.md` for
  the full invocation recipe and stop-condition semantics.

Both modes complete one story per iteration, emit `<promise>DONE</promise>`
or `<promise>ALL_DONE</promise>`, and keep state in the same places.

## Layout

The repo splits into three directories so the mode boundary is obvious:

- `cc-headless/` — files specific to the headless `claude -p` runner
- `cc/` — files specific to the in-session Claude Code runner
- `shared/` — prompt template, shared bash helpers, notebook schema, and
  task file example used by both runners

## Files

| File | Purpose |
|------|---------|
| `cc-headless/ralph.sh` | Headless runner — uses `claude -p` |
| `cc/RALPH-CC.md` | Driver doc for the Claude Code session runner |
| `cc/ralph-prep.sh` | Per-iteration bookkeeping + prompt builder; stdout is the filled prompt |
| `shared/ralph-lib.sh` | Shared bash helpers sourced by both runners |
| `shared/PROMPT.md` | Prompt template with `<!-- FILL:xxx -->` markers |
| `shared/tasks.json.example` | Starter task file (copy to your project as `tasks.json`) |
| `shared/coding-dev.yaml` | Lab-notebook schema for code dev workflows |

## Task File Format

JSON with stories and `passes` flags. The rigid structure prevents agents
from accidentally rewriting content — the only sanctioned mutation is
flipping `"passes": false` to `"passes": true`.

```json
{
  "project": "MyApp",
  "branch": "ralph/feature-name",
  "description": "Feature description",
  "stories": [
    {
      "id": "US-001",
      "title": "Story title",
      "acceptanceCriteria": [
        "Criterion 1",
        "Criterion 2",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false
    }
  ]
}
```

The agent finds the first story with `"passes": false` (by priority),
implements it, sets `"passes": true`, and emits a promise.

## Notebook Schema

The `coding-dev.yaml` schema provides entry types tailored for coding:

| Type | When to use |
|------|------------|
| `start` | Beginning work on a story |
| `plan` | Implementation approach decided |
| `impl` | Progress during implementation |
| `test` | Test results (pass/fail) |
| `review` | PR review feedback |
| `fix` | Changes from review feedback |
| `pattern` | Reusable codebase pattern discovered |
| `blocker` | Something blocking progress |
| `done` | Story completed |
| `dead-end` | Approach abandoned |

Query patterns from all iterations:
```bash
LAB_NOTEBOOK_DIR=.lnb lab-notebook sql \
  "SELECT content FROM entries WHERE type='pattern' ORDER BY ts"
```

## `cc-headless/ralph.sh` options

```
--max-iterations N      Safety cap (default: 10)
--prompt FILE           Prompt template (default: PROMPT.md)
--task-file FILE        Task file (default: tasks.json)
--notebook DIR          Notebook directory (default: .lnb)
--context SLUG          Notebook context (default: from branch)
--archive-dir DIR       Archive directory (default: archive/)
```

For the Claude Code session runner, `max-iterations`, `task-file`, and
related parameters are passed inline when invoking the driver doc — see
`cc/RALPH-CC.md`.

## Archive

When the `branch` field in `tasks.json` changes between runs, both runners
archive the previous task file and notebook to `archive/<date>-<branch>/`.
