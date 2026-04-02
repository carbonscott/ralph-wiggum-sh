# Lisa

Autonomous agent loop for code development. Spawns a fresh Claude instance
per iteration. Each iteration completes one story, logs progress to
a [lab-notebook](https://github.com/carbonscott/lab-notebook), and moves on.

Combines the best of [Ralph](https://github.com/mikeyobrien/ralph-orchestrator)
(file-based task tracking, external bash loop) with structured notebook
logging (queryable history, pattern discovery).

## Quick Start

```bash
# In your project directory:
cp ~/codes/lisa/PROMPT.md .
cp ~/codes/lisa/tasks.json.example tasks.json
# Edit tasks.json with your stories

# Initialize notebook with coding schema
mkdir -p .lnb && cp ~/codes/lisa/coding-dev.yaml .lnb/schema.yaml
lab-notebook init .lnb

# Run
~/codes/lisa/lisa.sh --max-iterations 5
```

## How It Works

```
tasks.md (what to do)  +  .lnb/ (what happened)  +  PROMPT.md (how to do it)
         │                       │                           │
         └───────────┬───────────┘                           │
                     ▼                                       │
              lisa.sh builds prompt ◄────────────────────────┘
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

## Files

| File | Purpose |
|------|---------|
| `lisa.sh` | Runner script — the loop |
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
  "branch": "lisa/feature-name",
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

## Options

```
--max-iterations N      Safety cap (default: 10)
--prompt FILE           Prompt template (default: PROMPT.md)
--task-file FILE        Task file (default: tasks.json)
--notebook DIR          Notebook directory (default: .lnb)
--context SLUG          Notebook context (default: from branch)
--archive-dir DIR       Archive directory (default: archive/)
```

## Archive

When the `branch` field in `tasks.json` changes between runs, Lisa archives
the previous task file and notebook to `archive/<date>-<branch>/`.
