# Ralph-Wiggum-LNB

![The Ralph-LNB Loop](docs/ralph-lnb-loop.svg)

Autonomous agent loop for code development. Spawns a fresh Claude instance
per iteration. Each iteration completes one story, logs progress to
a [lab-notebook](https://github.com/carbonscott/lab-notebook), and moves on.

Based on the [Ralph Wiggum technique](https://ghuntley.com/ralph/) with
structured notebook logging (queryable history, pattern discovery). See also
[Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).

## Prerequisites

Ralph depends on the [`lab-notebook`](https://github.com/carbonscott/lab-notebook)
CLI being on `$PATH` — it's called on every iteration (notebook init,
emit, sql). Install it first:

```bash
# Recommended (isolated install):
uv tool install git+https://github.com/carbonscott/lab-notebook

# Or with pip:
pip install git+https://github.com/carbonscott/lab-notebook
```

Verify with `lab-notebook --help`. Update later with
`uv tool install --force git+https://github.com/carbonscott/lab-notebook`.

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

For headless-only use without install, you can invoke the script by
absolute path: `~/codes/ralph-wiggum-lnb/cc-headless/ralph.sh`. The
chat runner (`/ralph-lnb`) requires `install.sh` — it renders the
skill with concrete paths baked in.

## Quick Start

```bash
# In your project directory:
cp ~/codes/ralph-wiggum-lnb/shared/tasks.json.example tasks.json
# Edit tasks.json with your stories
```

The runner uses `shared/PROMPT.md` from the installed repo by default.
Copy it locally and pass `--prompt ./PROMPT.md` only if you want to
customize the template. **Upgrading from an older checkout?** A stale
`./PROMPT.md` in your project dir is no longer auto-picked up — delete
it if you never customized it, or pass `--prompt ./PROMPT.md`
explicitly if you did.

The runner auto-initializes `.ralph/.lnb` with the coding schema on the
first iteration — no manual `lab-notebook init` needed.

Then pick one runner:

**Headless** (uses `claude -p`):

```bash
ralph --max-iterations 5
```

**Inside a Claude Code session** (uses the `Agent()` subagent tool — no `-p` needed):

Start Claude Code in `acceptEdits` mode, then in the session:

> /ralph-lnb max-iterations 5

(Restart any running Claude Code sessions after install — skills load
at session start.)

`tasks.json` is the only file you author and commit in your project
dir. Everything ralph generates — the notebook, the per-iteration
prompt, the batch cursor, and archived `tasks.json` snapshots — lives
under one gitignored `.ralph/` directory, with a small `.lnb.env`
pointer at the root so a bare `/lnb recall` finds the notebook; a reset
is just `rm -rf .ralph/`. The prompt template, shared lib, helper
scripts, and notebook schema all stay in the repo and are invoked or
sourced by `ralph` / `/ralph-lnb` (or by absolute path if you skipped
install).

## How It Works

```
tasks.json (what to do)  +  .ralph/.lnb (what happened)  +  PROMPT.md (how to do it)
           │                             │                           │
           └───────────┬─────────────────┘                           │
                       ▼                                             │
              runner   builds prompt ◄───────────────────────────────┘
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
and `.ralph/` state (notebook, per-iteration prompt, batch cursor, archives):

- **`ralph`** (headless, terminal) — runs in a terminal and spawns a
  fresh `claude -p` per iteration. Truly stateless outer loop. Backed
  by `cc-headless/ralph.sh`.
- **`/ralph-lnb`** (chat, Claude Code session) — runs inside a live
  Claude Code chat session and uses the `Agent()` subagent tool
  instead of `-p`. Use when `-p` mode is unavailable or restricted.
  Backed by the skill rendered from `skill/SKILL.md.template`.

Both modes complete one story per iteration, emit `<promise>DONE</promise>`
or `<promise>ALL_DONE</promise>`, and keep state in the same places.

| Aspect | `ralph` (headless) | `/ralph-lnb` (chat) |
|---|---|---|
| Entry | terminal: `ralph --max-iterations N` | chat: `/ralph-lnb max-iterations N` |
| Per-iter agent | `claude -p --permission-mode acceptEdits` | `Agent(subagent_type="general-purpose")` |
| Permission mode | CLI flag | inherited from main session |
| Intermediate display | stream-json via `format_stream` | native Claude Code subagent UI |
| Stop on no marker | no (only stops on non-zero exit code) | yes |
| Main-session context cost | 0 | ~50 tokens/iter |
| State storage | same | same |

## Layout

The repo splits into four directories so the mode boundary is obvious:

- `cc-headless/` — files specific to the headless `claude -p` runner
- `cc/` — prompt builder invoked by the `/ralph-lnb` skill
- `skill/` — skill template rendered into `~/.claude/skills/ralph-lnb/SKILL.md` by `install.sh`
- `shared/` — prompt template, shared bash helpers, notebook schema, and
  task file example used by both runners

## Files

| File | Purpose |
|------|---------|
| `cc-headless/ralph.sh` | Headless runner — uses `claude -p` |
| `cc/ralph-prep.sh` | Per-iteration bookkeeping + prompt builder invoked by the `/ralph-lnb` skill; writes the filled prompt to `.ralph/prompt.md`, stdout is a one-line status |
| `skill/SKILL.md.template` | Skill template — `install.sh` renders this into `~/.claude/skills/ralph-lnb/SKILL.md` with absolute paths |
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
LAB_NOTEBOOK_DIR=.ralph/.lnb lab-notebook sql \
  "SELECT content FROM entries WHERE type='pattern' ORDER BY ts"
```

## Headless runner options (ralph)

```
--max-iterations N      Safety cap (default: 10)
--prompt FILE           Custom prompt template (default: repo's shared/PROMPT.md)
--task-file FILE        Task file (default: tasks.json)
--notebook DIR          Notebook directory (default: .ralph/.lnb)
--context SLUG          Notebook context (default: from branch)
--archive-dir DIR       Archive directory (default: .ralph/archive)
--force                 Re-spin even when this branch's all-green batch
                        was already recorded complete in .ralph/state.json
```

For the Claude Code session runner, invoke it as `/ralph-lnb
max-iterations N` (with `task-file` and other parameters passed
inline). See the rendered `~/.claude/skills/ralph-lnb/SKILL.md` for
the driver doc and stop-condition semantics (or `skill/SKILL.md.template`
in this repo for the pre-substitution source).

## Archive

When the recorded cursor in `.ralph/state.json` shows the `branch` has
changed since the last run, both runners snapshot the previous
`tasks.json` — only the task file, not the notebook (it self-archives by
`context`) — to `.ralph/archive/<date>-<branch>/`. A first run records the
cursor and archives nothing; a same-branch re-run archives nothing.

## Shared notebook across loops / worktrees

By default each project dir (or git worktree) is its own cwd and gets its own
`.ralph/.lnb` notebook — no setup, no contention.

For the power user who wants several loops to *share* one notebook (e.g. one
notebook spanning several worktrees so each loop can learn from the others),
point them all at one path with `--notebook <shared-path>`. There is no extra
flag: ralph attributes every entry to a per-loop writer
`ralph-<branch>` (the branch slug from `tasks.json`, e.g. branch `ralph/foo`
&rarr; writer `ralph-foo`), via `LAB_NOTEBOOK_WRITER` set on each
`lab-notebook emit` call. Because the notebook stores one append-only
`entries/<writer>.jsonl` per writer, concurrent loops on different branches
never collide — each writes its own file, and a single `lab-notebook sql`
query still sees them all. (Two loops sharing **one** branch in **one** cwd
still share both the prompt file and the writer; real isolation is separate
cwds/worktrees and/or distinct branches.)
