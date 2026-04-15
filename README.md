# Ralph Wiggum

Autonomous agent loop for code development. Spawns a fresh Claude instance
per iteration. Each iteration completes one story, logs progress to
a [lab-notebook](https://github.com/carbonscott/lab-notebook), and moves on.

Based on the [Ralph Wiggum technique](https://ghuntley.com/ralph/) with
structured notebook logging (queryable history, pattern discovery). See also
[Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).

## Quick Start

```bash
# In your project directory:
cp ~/codes/ralph-wiggum-lnb/PROMPT.md .
cp ~/codes/ralph-wiggum-lnb/tasks.json.example tasks.json
# Edit tasks.json with your stories

# Initialize notebook with coding schema
mkdir -p .lnb && cp ~/codes/ralph-wiggum-lnb/coding-dev.yaml .lnb/schema.yaml
lab-notebook init .lnb
```

Then pick one runner:

**Headless** (uses `claude -p`):

```bash
~/codes/ralph-wiggum-lnb/ralph.sh --max-iterations 5
```

**Inside a Claude Code session** (uses the `Agent()` subagent tool — no `-p` needed):

```bash
# Copy the driver doc + helper scripts into your project
cp ~/codes/ralph-wiggum-lnb/{RALPH-CC.md,ralph-prep.sh,ralph-lib.sh} .
chmod +x ralph-prep.sh
```

Start Claude Code in `acceptEdits` mode, then in the session:

> follow RALPH-CC.md, max-iterations 5

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

- **`ralph.sh`** — the original. Runs in a terminal, spawns a fresh
  `claude -p` per iteration. Truly stateless outer loop.
- **`RALPH-CC.md`** — drop-in alternative that runs inside a live Claude
  Code chat session and uses the `Agent()` subagent tool. Use when `-p`
  mode is unavailable or restricted. See `RALPH-CC.md` for the full
  invocation recipe and stop-condition semantics.

Both modes complete one story per iteration, emit `<promise>DONE</promise>`
or `<promise>ALL_DONE</promise>`, and keep state in the same places.

## Files

| File | Purpose |
|------|---------|
| `ralph.sh` | Headless runner — uses `claude -p` |
| `ralph-lib.sh` | Shared bash helpers sourced by `ralph.sh` and `ralph-prep.sh` |
| `ralph-prep.sh` | Per-iteration bookkeeping + prompt builder; stdout is the filled prompt |
| `RALPH-CC.md` | Driver doc for the Claude Code session runner |
| `PROMPT.md` | Prompt template with `<!-- FILL:xxx -->` markers |
| `tasks.json` | Your stories with `passes` flags (copy from `tasks.json.example`) |
| `coding-dev.yaml` | Lab-notebook schema for code dev workflows |

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

## `ralph.sh` options

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
`RALPH-CC.md`.

## Archive

When the `branch` field in `tasks.json` changes between runs, both runners
archive the previous task file and notebook to `archive/<date>-<branch>/`.
