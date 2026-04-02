# Lisa

Autonomous agent loop for code development. Spawns a fresh Claude (or Amp)
instance per iteration. Each iteration completes one story, logs progress to
a [lab-notebook](https://github.com/carbonscott/lab-notebook), and moves on.

Combines the best of [Ralph](https://github.com/mikeyobrien/ralph-orchestrator)
(file-based task tracking, external bash loop) with structured notebook
logging (queryable history, pattern discovery).

## Quick Start

```bash
# In your project directory:
cp ~/codes/lisa/PROMPT.md .
cp ~/codes/lisa/tasks.md.example tasks.md
# Edit tasks.md with your stories

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
| `tasks.md` | Your stories with checkboxes (copy from `tasks.md.example`) |
| `coding-dev.yaml` | Lab-notebook schema for code dev workflows |

## Task File Format

Markdown with YAML frontmatter and checkboxes:

```markdown
---
project: MyApp
branch: lisa/feature-name
---
# Feature Name

## US-001: Story title
- [ ] Acceptance criterion 1
- [ ] Acceptance criterion 2
- [ ] Typecheck passes
```

The agent finds the first story with unchecked items, implements it,
checks them off, and emits a promise.

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
--task-file FILE        Task file (default: tasks.md)
--notebook DIR          Notebook directory (default: .lnb)
--context SLUG          Notebook context (default: from branch)
--tool claude|amp       Agent to use (default: claude)
--archive-dir DIR       Archive directory (default: archive/)
```

## Archive

When the `branch` field in `tasks.md` changes between runs, Lisa archives
the previous task file and notebook to `archive/<date>-<branch>/`.
