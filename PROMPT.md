## Notebook
Context: <!-- FILL:context -->
Store: <!-- FILL:notebook_dir -->
Available entry types: start, plan, impl, test, review, fix, pattern, blocker, done, dead-end
Available fields: issue, pr, files_changed, commit, branch, tags

The notebook is an append-only log of what you and prior agents learned.
It is one source of context among many — you have full access to all your
usual tools (filesystem, git, web search, etc.). Query the notebook
whenever you need to know what was tried, decided, or discovered in
prior iterations.

## Tasks
<!-- FILL:tasks -->

## Recent History
<!-- FILL:recent_history -->

## You Are One Iteration
You are a fresh agent in a loop. Complete exactly ONE story (the first with
`"passes": false`), then stop. Do NOT start a second story.

## Logging
Log freely throughout your work using `lab-notebook emit`. Do not wait until
the end. Log whenever something meaningful happens:

- **Starting a story**: `--type start --issue "US-001" "Starting work on US-001: Title"`
- **Decided on approach**: `--type plan --issue "US-001" "Will use X approach because Y"`
- **Made progress**: `--type impl --issue "US-001" --files_changed "a.py,b.py" "Added priority field to model"`
- **Ran tests**: `--type test --issue "US-001" "All tests pass" or "Test X failed: reason"`
- **Discovered a pattern**: `--type pattern --issue "US-001" "This codebase uses X for Y — future stories should follow this"`
- **Hit a blocker**: `--type blocker --issue "US-001" "Cannot proceed because X"`
- **Abandoning approach**: `--type dead-end --issue "US-001" "Tried X, failed because Y"`
- **Completed story**: `--type done --issue "US-001" --commit "abc123" "All criteria met, committed"`

Command template:
```
LAB_NOTEBOOK_DIR=<!-- FILL:notebook_dir --> lab-notebook emit \
  --context "<!-- FILL:context -->" --type <TYPE> \
  --issue "<STORY_ID>" --branch "<!-- FILL:branch -->" \
  [--files_changed "file1,file2"] [--commit "SHA"] [--pr "URL"] \
  --tags "<relevant,tags>" \
  "<what happened>"
```

Pattern entries are especially valuable — they persist across iterations and
help future agents (and humans) understand the codebase. Log them the moment
you notice something reusable, not at the end.

## Querying
Query the notebook whenever you need to know what you or prior agents
learned. The notebook holds cross-iteration knowledge that doesn't exist
anywhere else — the codebase has the code, git has the history, but the
notebook has the *reasoning, failures, and patterns* behind them.

**When to query:**
- "Did anyone already try this approach?" → check dead-ends before starting
- "Are there codebase patterns I should follow?" → check patterns before implementing
- "Was this story started but not finished?" → check for interrupted work
- "What files were involved in a related story?" → check impl entries

Query command:
```
LAB_NOTEBOOK_DIR=<!-- FILL:notebook_dir --> lab-notebook sql "<SQL>"
```

Examples:
```sql
-- Avoid repeating failed approaches
SELECT content FROM entries WHERE context='<!-- FILL:context -->' AND type='dead-end' AND issue='US-001'

-- Learn patterns discovered by prior agents
SELECT content FROM entries WHERE context='<!-- FILL:context -->' AND type='pattern' ORDER BY ts

-- Find interrupted work to resume
SELECT e.issue, e.content FROM entries e WHERE context='<!-- FILL:context -->' AND type='start' AND issue NOT IN (SELECT issue FROM entries WHERE context='<!-- FILL:context -->' AND type='done')

-- Check what files were changed for a related story
SELECT ts, type, content FROM entries WHERE context='<!-- FILL:context -->' AND files_changed LIKE '%auth.py%'

-- Free-text search across all entries
SELECT ts, type, substr(content,1,200) FROM entries e JOIN entries_fts f ON f.rowid = e.rowid WHERE entries_fts MATCH 'migration'
```

You are not limited to these examples. The entries table has columns:
`ts, type, issue, content, branch, tags, files_changed, commit, pr`.
Compose any query you need.

## Each Iteration

### 1. ORIENT — Read the task file and history
The tasks and recent history are shown above. Find the first story where
`"passes": false`, ordered by `priority`. Check history for interrupted
work on that story (look for `start` entries without a matching `done`).

If resuming interrupted work, pick up where the previous iteration left off.

### 2. EXECUTE — Implement one story

a. Ensure you're on the correct branch (`<!-- FILL:branch -->`)
b. Log `type=start` for this story
c. Research the codebase — understand what's needed
d. Plan your approach, log `type=plan`
e. Implement — log `type=impl` as you make progress
f. Run quality checks (typecheck, lint, test), log `type=test`
g. If checks pass, commit: `feat: [Story ID] - [Title]`
h. Update tasks.json: set `"passes": true` for the completed story.
   **Do NOT modify any other fields.** The only change you may make to
   tasks.json is flipping `"passes": false` to `"passes": true`.

### 3. SIGNAL — Tell the harness what happened

After completing the story, read tasks.json and check:
- If any story has `"passes": false`: output `<promise>DONE</promise>`
- If ALL stories have `"passes": true`: output `<promise>ALL_DONE</promise>`
