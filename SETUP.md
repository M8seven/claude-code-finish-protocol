# /finish Setup Guide

Everything you need to install the `/finish` protocol on a new machine with Claude Code.

## Prerequisites

- macOS or Linux
- Claude Code installed
- `jq` installed (`brew install jq` / `apt install jq`)
- `tree` installed (`brew install tree` / `apt install tree`)
- Git configured

## Target Structure

After installation:

```
~/.claude/
├── commands/
│   └── finish.md              # AI prompt — intelligent phase
├── hooks/
│   └── session-end-safety.sh  # Safety net — warns on uncommitted work
└── settings.json              # Must include SessionStart hook

<WORKSPACE>/
├── .claude/
│   ├── finish.sh              # Bash script — mechanical phase
│   └── projects.json          # Project registry
└── backups/                   # Auto-created — tar.gz + git bundles
```

Replace `<WORKSPACE>` with your projects root (e.g., `~/code`, `~/projects`).

---

## Step 1 — Create directories

```bash
mkdir -p ~/.claude/commands
mkdir -p ~/.claude/hooks
mkdir -p <WORKSPACE>/.claude
mkdir -p <WORKSPACE>/backups
```

---

## Step 2 — Create `projects.json`

**File:** `<WORKSPACE>/.claude/projects.json`

This registers each project with its configuration.

```json
{
  "<slug>": {
    "name": "<Display Name>",
    "path": "~/<path/to/project>",
    "git": true,
    "backup": true,
    "backup_exclude": [".git", "node_modules"],
    "docs_dir": "docs",
    "tree_exclude": ".git|node_modules",
    "status_file": "PROJECT_STATUS.md",
    "todo_file": "TODO.md"
  }
}
```

### Fields

| Field | Type | Description |
|---|---|---|
| `name` | string | Display name |
| `path` | string | Absolute path (supports `~`) |
| `git` | bool | Whether the project uses git |
| `backup` | bool | Whether to create tar.gz backups |
| `backup_exclude` | string[] | Patterns to exclude from backup |
| `docs_dir` | string/null | Directory for STATUS/TODO files. `null` = no docs |
| `tree_exclude` | string | Pipe-separated patterns for tree |
| `status_file` | string | Status file name (inside docs_dir) |
| `todo_file` | string | TODO file name (inside docs_dir) |

### Example

```json
{
  "my-webapp": {
    "name": "My WebApp",
    "path": "~/projects/my-webapp",
    "git": true,
    "backup": true,
    "backup_exclude": [".git", "node_modules", ".next"],
    "docs_dir": "docs",
    "tree_exclude": ".git|node_modules|.next",
    "status_file": "PROJECT_STATUS.md",
    "todo_file": "TODO.md"
  }
}
```

> The system also works WITHOUT projects.json — it auto-detects projects by walking up from cwd looking for `.git`, `CLAUDE.md`, or `package.json`. Without a registry, only backup is performed (no doc updates).

---

## Step 3 — Create `finish.sh`

**File:** `<WORKSPACE>/.claude/finish.sh`

Edit the first 3 lines to match your setup:

```bash
HUB_DEV="$HOME/<your-workspace>"       # ← your workspace root
PROJECTS_JSON="$HUB_DEV/.claude/projects.json"
BACKUPS_DIR="$HUB_DEV/backups"
```

### Full script

```bash
#!/bin/bash
set -e

HUB_DEV="$HOME/Hub/dev"
PROJECTS_JSON="$HUB_DEV/.claude/projects.json"
BACKUPS_DIR="$HUB_DEV/backups"

# --- 1. Detect project from pwd ---
PWD_REAL="$(pwd -P)"

IN_REGISTRY=false
CONFIG=""
PROJECT_NAME=""
PROJECT_PATH=""

if [[ -f "$PROJECTS_JSON" ]]; then
  while IFS= read -r key; do
    custom_path=$(jq -r --arg k "$key" '.[$k].path // empty' "$PROJECTS_JSON")
    if [[ -n "$custom_path" ]]; then
      expanded="${custom_path/#\~/$HOME}"
      if [[ "$PWD_REAL" == "$expanded" ]] || [[ "$PWD_REAL" == "$expanded/"* ]]; then
        PROJECT_NAME="$key"
        PROJECT_PATH="$expanded"
        CONFIG=$(jq -e --arg name "$key" '.[$name]' "$PROJECTS_JSON" 2>/dev/null)
        IN_REGISTRY=true
        break
      fi
    fi
  done < <(jq -r 'keys[]' "$PROJECTS_JSON")
fi

if [[ -z "$PROJECT_NAME" ]]; then
  SEARCH_DIR="$PWD_REAL"
  while [[ "$SEARCH_DIR" != "/" ]]; do
    if [[ -d "$SEARCH_DIR/.git" ]] || [[ -f "$SEARCH_DIR/CLAUDE.md" ]] || [[ -f "$SEARCH_DIR/package.json" ]]; then
      PROJECT_PATH="$SEARCH_DIR"
      PROJECT_NAME="$(basename "$SEARCH_DIR")"
      break
    fi
    SEARCH_DIR="$(dirname "$SEARCH_DIR")"
  done

  if [[ -z "$PROJECT_NAME" ]]; then
    echo "Error: no project detected." >&2
    exit 1
  fi

  if [[ -f "$PROJECTS_JSON" ]]; then
    while IFS= read -r key; do
      reg_path=$(jq -r --arg k "$key" '.[$k].path // empty' "$PROJECTS_JSON")
      if [[ -n "$reg_path" ]]; then
        expanded="${reg_path/#\~/$HOME}"
        if [[ "$PROJECT_PATH" == "$expanded" ]]; then
          PROJECT_NAME="$key"
          CONFIG=$(jq -e --arg name "$key" '.[$name]' "$PROJECTS_JSON" 2>/dev/null)
          IN_REGISTRY=true
          break
        fi
      fi
    done < <(jq -r 'keys[]' "$PROJECTS_JSON")
  fi
fi

# --- 2. Confirmation ---
echo "Project detected: $PROJECT_NAME ($PROJECT_PATH)"

if [[ "$IN_REGISTRY" == false ]]; then
  read -rp "Not in registry. Backup only? [y/N] " ans
  case "$ans" in
    [yY]) ONLY_BACKUP=true ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
else
  read -rp "Confirm? [Y/n] " ans
  case "$ans" in
    [nN]) echo "Cancelled."; exit 0 ;;
  esac
  ONLY_BACKUP=false
fi

# --- 3. Load project config ---
USE_GIT=false
USE_BACKUP=true
BACKUP_EXCLUDES=()
DOCS_DIR=""
TREE_EXCLUDE=""
STATUS_FILE=""
TODO_FILE=""

if [[ "$IN_REGISTRY" == true ]]; then
  USE_GIT=$(echo "$CONFIG" | jq -r '.git // false')
  USE_BACKUP=$(echo "$CONFIG" | jq -r '.backup // true')
  DOCS_DIR=$(echo "$CONFIG" | jq -r '.docs_dir // empty')
  TREE_EXCLUDE=$(echo "$CONFIG" | jq -r '.tree_exclude // empty')
  STATUS_FILE=$(echo "$CONFIG" | jq -r '.status_file // empty')
  TODO_FILE=$(echo "$CONFIG" | jq -r '.todo_file // empty')

  while IFS= read -r exc; do
    [[ -n "$exc" ]] && BACKUP_EXCLUDES+=("$exc")
  done < <(echo "$CONFIG" | jq -r '.backup_exclude[]? // empty')
fi

# --- 4. Git context ---
CONTEXT_FILE="/tmp/finish_context.md"
BACKUP_PATH=""
BACKUP_SIZE=""
TREE_PATH=""

if [[ "$USE_GIT" == true ]] && [[ -d "$PROJECT_PATH/.git" ]]; then
  {
    echo "# Git Context: $PROJECT_NAME"
    echo "## Date: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "## Recent commits"
    echo '```'
    git -C "$PROJECT_PATH" log --oneline -15 2>/dev/null || echo "(none)"
    echo '```'
    echo ""
    echo "## Diff stat"
    echo '```'
    git -C "$PROJECT_PATH" diff --stat 2>/dev/null || echo "(no changes)"
    echo '```'
    echo ""
    echo "## Untracked files"
    echo '```'
    git -C "$PROJECT_PATH" ls-files --others --exclude-standard 2>/dev/null || echo "(none)"
    echo '```'
  } > "$CONTEXT_FILE"
  echo "Git context saved: $CONTEXT_FILE"
else
  rm -f "$CONTEXT_FILE"
fi

# --- 5. Backup ---
if [[ "$USE_BACKUP" == true ]] || [[ "$ONLY_BACKUP" == true ]]; then
  TARGET_DIR="$BACKUPS_DIR/$PROJECT_NAME"
  mkdir -p "$TARGET_DIR"

  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  BACKUP_FILE="backup_${PROJECT_NAME}_${TIMESTAMP}.tar.gz"
  BACKUP_PATH="$TARGET_DIR/$BACKUP_FILE"

  EXCLUDE_ARGS=(
    --exclude='.git'
    --exclude='node_modules'
    --exclude='.venv'
    --exclude='__pycache__'
    --exclude='.next'
  )
  for exc in "${BACKUP_EXCLUDES[@]}"; do
    EXCLUDE_ARGS+=("--exclude=$exc")
  done

  PARENT_DIR="$(dirname "$PROJECT_PATH")"
  BASE_NAME="$(basename "$PROJECT_PATH")"
  tar -czf "$BACKUP_PATH" "${EXCLUDE_ARGS[@]}" -C "$PARENT_DIR" "$BASE_NAME"
  BACKUP_SIZE=$(du -h "$BACKUP_PATH" | cut -f1)
  echo "Backup created: $BACKUP_PATH ($BACKUP_SIZE)"

  # Rotation: keep last 3
  find "$TARGET_DIR" -maxdepth 1 -name "backup_${PROJECT_NAME}_*.tar.gz" -type f \
    | sort -r \
    | tail -n +4 \
    | while read -r old; do
        rm -f "$old"
        echo "Removed old backup: $(basename "$old")"
      done
fi

# --- 5b. Git bundle (weekly) ---
BUNDLE_PATH=""
BUNDLE_SIZE=""

if [[ "$USE_GIT" == true ]] && [[ -d "$PROJECT_PATH/.git" ]]; then
  TARGET_DIR="${TARGET_DIR:-$BACKUPS_DIR/$PROJECT_NAME}"
  mkdir -p "$TARGET_DIR"

  RECENT_BUNDLE=""
  SEVEN_DAYS_AGO=$(date -v -7d +%s 2>/dev/null || date -d '7 days ago' +%s)
  while IFS= read -r bf; do
    BF_MTIME=$(stat -f %m "$bf" 2>/dev/null || stat -c %Y "$bf" 2>/dev/null)
    if [[ -n "$BF_MTIME" ]] && [[ "$BF_MTIME" -ge "$SEVEN_DAYS_AGO" ]]; then
      RECENT_BUNDLE="$bf"
      break
    fi
  done < <(find "$TARGET_DIR" -maxdepth 1 -name "bundle_${PROJECT_NAME}_*.bundle" -type f | sort -r)

  if [[ -n "$RECENT_BUNDLE" ]]; then
    echo "Git bundle: skip (recent bundle exists)"
  else
    TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
    BUNDLE_FILE="bundle_${PROJECT_NAME}_${TIMESTAMP}.bundle"
    BUNDLE_PATH="$TARGET_DIR/$BUNDLE_FILE"
    git -C "$PROJECT_PATH" bundle create "$BUNDLE_PATH" --all
    BUNDLE_SIZE=$(du -h "$BUNDLE_PATH" | cut -f1)
    echo "Git bundle: $BUNDLE_PATH ($BUNDLE_SIZE)"

    # Rotation: keep last 2
    find "$TARGET_DIR" -maxdepth 1 -name "bundle_${PROJECT_NAME}_*.bundle" -type f \
      | sort -r \
      | tail -n +3 \
      | while read -r old; do
          rm -f "$old"
          echo "Removed old bundle: $(basename "$old")"
        done
  fi
fi

# --- 6. Tree ---
if [[ -n "$DOCS_DIR" ]] && [[ "$ONLY_BACKUP" != true ]]; then
  FULL_DOCS="$PROJECT_PATH/$DOCS_DIR"
  mkdir -p "$FULL_DOCS"
  TREE_PATH="$FULL_DOCS/tree.txt"

  TREE_ARGS=(-L 3 --dirsfirst)
  [[ -n "$TREE_EXCLUDE" ]] && TREE_ARGS+=(-I "$TREE_EXCLUDE")

  tree "${TREE_ARGS[@]}" "$PROJECT_PATH" > "$TREE_PATH"
  echo "Tree saved: $TREE_PATH"
fi

# --- 7. Stage safe code files ---
CODE_STAGED=0
STAGED_COUNT=0
if [[ "$USE_GIT" == true ]] && [[ -d "$PROJECT_PATH/.git" ]]; then
  cd "$PROJECT_PATH"

  if ! git diff --quiet 2>/dev/null; then
    git add -u
    CODE_STAGED=1
  fi

  while IFS= read -r untracked; do
    [[ -z "$untracked" ]] && continue
    case "$untracked" in
      .env|.env.*|*.p8|*.pem|*credentials*|*secret*|*/secrets/*|*/node_modules/*) continue ;;
    esac
    git add "$untracked"
    CODE_STAGED=1
  done < <(git ls-files --others --exclude-standard 2>/dev/null)

  if [[ "$CODE_STAGED" -eq 1 ]]; then
    STAGED_COUNT=$(git diff --cached --numstat | wc -l | tr -d ' ')
    echo "Code staged: $STAGED_COUNT file(s)"
  else
    echo "Code staged: no changes"
  fi
fi

# --- 8. Export state for AI phase ---
STATE_FILE="/tmp/finish_state.json"
cat > "$STATE_FILE" <<EOFSTATE
{
  "project_name": "$PROJECT_NAME",
  "project_path": "$PROJECT_PATH",
  "in_registry": $IN_REGISTRY,
  "use_git": $USE_GIT,
  "docs_dir": "$DOCS_DIR",
  "status_file": "$STATUS_FILE",
  "todo_file": "$TODO_FILE",
  "backup_path": "$BACKUP_PATH",
  "backup_size": "$BACKUP_SIZE",
  "tree_path": "$TREE_PATH",
  "bundle_path": "$BUNDLE_PATH",
  "bundle_size": "$BUNDLE_SIZE",
  "code_staged": $CODE_STAGED,
  "context_file": "$CONTEXT_FILE"
}
EOFSTATE

# --- 9. Summary ---
echo ""
echo "=== FINISH (mechanical) ==="
echo "Project:   $PROJECT_NAME"
echo "Path:      $PROJECT_PATH"
[[ -n "$BACKUP_PATH" ]] && echo "Backup:    $BACKUP_PATH ($BACKUP_SIZE)" || echo "Backup:    (skip)"
[[ -n "$BUNDLE_PATH" ]] && echo "Bundle:    $BUNDLE_PATH ($BUNDLE_SIZE)" || echo "Bundle:    (skip)"
[[ -n "$TREE_PATH" ]] && echo "Tree:      $TREE_PATH" || echo "Tree:      (skip)"
[[ -f "$CONTEXT_FILE" ]] && echo "Context:   $CONTEXT_FILE" || echo "Context:   (skip)"
[[ "$CODE_STAGED" -eq 1 ]] && echo "Staged:    $STAGED_COUNT file(s)" || echo "Staged:    none"
echo "==========================="
```

Make it executable:

```bash
chmod +x <WORKSPACE>/.claude/finish.sh
```

---

## Step 4 — Create `finish.md`

**File:** `~/.claude/commands/finish.md`

Update the bash command path to point to YOUR `finish.sh`.

````markdown
Execute the end-of-session protocol.

## PHASE 1 — Mechanical (bash)

```bash
echo y | bash <WORKSPACE>/.claude/finish.sh
```

This runs: project detection, backup, tree, git context, git bundle, safe code staging.
Read `/tmp/finish_state.json` for state and `/tmp/finish_context.md` for git context.

---

## PHASE 2 — Update docs + memory (4 Haiku agents in parallel)

**Skip if** `docs_dir` is empty in state.

Launch 4 agents in parallel with `model: "haiku"`. Pass to each:
- Contents of `/tmp/finish_context.md` (git log + diff stat)
- `project_path` and `docs_dir` from state
- A summary of what was done in the session (infer from conversation)

### Agent-STATUS
Update `<project_path>/<docs_dir>/<status_file>`:
- If missing, create with: title, current status (date, last commit), session history
- If exists, update date/commit in "Current Status", add entry in "Session History"
- Include "Blockers:" line if there were obstacles
- NEVER remove existing content

### Agent-TODO
Update `<project_path>/<docs_dir>/<todo_file>`:
- If missing, create with sections TODO / IN PROGRESS / COMPLETED
- If exists, move completed tasks to COMPLETED with date, add new tasks to TODO
- NEVER remove existing content

### Agent-CLAUDE
Update `<project_path>/CLAUDE.md`:
- If exists, update relevant sections (status, last commit, changes). DON'T restructure
- If missing, create with minimal structure

### Agent-MEMORY
Save memory to `~/.claude/projects/<project-key>/memory/` (project-key = cwd with `/` → `-`):
- Save external content received (videos, docs, screenshots) → detailed CONTENT summary
- Save architectural decisions, user feedback, project state changes
- DON'T save: things in code, git history, content already in CLAUDE.md
- Create/update `MEMORY.md` as index

---

## PHASE 3 — Code commit (Sonnet)

**Skip if** `use_git` is false in state, or `code_staged` is 0.

Code is already staged by finish.sh. Just:
1. Analyze `git diff --cached --stat` to understand what changed
2. Generate an appropriate commit message (conventional commits: `feat:`, `fix:`, `refactor:`, `chore:`)
3. Commit:
   ```bash
   git commit -m "<message>"
   ```

---

## PHASE 4 — Doc commit + push + summary (bash)

**Skip if** `use_git` is false in state.

```bash
cd <project_path>
git add CLAUDE.md 2>/dev/null || true
git add "<docs_dir>/<status_file>" "<docs_dir>/<todo_file>" "<docs_dir>/tree.txt" 2>/dev/null || true
git diff --cached --quiet || git commit -m "docs: update project docs via /finish"
```

Ask: **"Push to remote? [y/N]"**
- If yes: `git push`
- If no: note that commits are local only

Print summary:
```
=== SESSION END <name> ===
Project:       <name>
Date:          YYYY-MM-DD HH:MM
Backup:        <path> (<size>)
Tree:          <path>
Status:        updated / created / skipped
TODO:          updated / created / skipped
CLAUDE.md:     updated / skipped
Memory:        <N> files saved
Code commit:   <hash> <message> / none
Docs commit:   <hash> / none
Pushed:        yes / no
Warning:       <any notes>
===================================
```

---

## RULES

- Only touch files in the detected project. Never touch other projects.
- Config from projects.json — no hardcoded paths.
- Read before modifying.
- Minimum viable changes only.
- Doc agents: use `model: "haiku"` to save tokens.
- NEVER `git add -A`. NEVER commit `.env`, `.p8`, `credentials`, `secrets/`.
````

---

## Step 5 — Create the safety hook

**File:** `~/.claude/hooks/session-end-safety.sh`

```bash
#!/bin/bash
# Warns on uncommitted work at session start
set -e

PWD_REAL="$(pwd -P)"
PROJECTS_JSON="$HOME/<WORKSPACE>/.claude/projects.json"

if [[ ! -f "$PROJECTS_JSON" ]]; then
  exit 0
fi

USE_GIT=false
while IFS= read -r key; do
  custom_path=$(jq -r --arg k "$key" '.[$k].path // empty' "$PROJECTS_JSON")
  if [[ -n "$custom_path" ]]; then
    expanded="${custom_path/#\~/$HOME}"
    if [[ "$PWD_REAL" == "$expanded" ]] || [[ "$PWD_REAL" == "$expanded/"* ]]; then
      USE_GIT=$(jq -r --arg k "$key" '.[$k].git // false' "$PROJECTS_JSON")
      break
    fi
  fi
done < <(jq -r 'keys[]' "$PROJECTS_JSON")

if [[ "$USE_GIT" != "true" ]]; then
  exit 0
fi

if ! git -C "$PWD_REAL" rev-parse --git-dir &>/dev/null; then
  exit 0
fi

if git -C "$PWD_REAL" diff --quiet && git -C "$PWD_REAL" diff --cached --quiet && [[ -z "$(git -C "$PWD_REAL" ls-files --others --exclude-standard)" ]]; then
  exit 0
fi

CHANGED=$(git -C "$PWD_REAL" status --porcelain | wc -l | tr -d ' ')
echo "[session-end] WARNING: $CHANGED uncommitted file(s) in $(basename "$PWD_REAL"). Run /finish next session." >&2
```

Make it executable:

```bash
chmod +x ~/.claude/hooks/session-end-safety.sh
```

---

## Step 6 — Update `settings.json`

Add the SessionStart hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/session-end-safety.sh 2>&1 || true"
          }
        ]
      }
    ]
  }
}
```

If you already have other hooks in SessionStart, add this as an additional entry.

---

## Step 7 — Paths to customize

All hardcoded paths are in the first lines of each file:

| File | Variable | Default | Change to |
|---|---|---|---|
| `finish.sh` | `HUB_DEV` | `$HOME/Hub/dev` | Your workspace root |
| `finish.sh` | `PROJECTS_JSON` | `$HUB_DEV/.claude/projects.json` | Path to your registry |
| `finish.sh` | `BACKUPS_DIR` | `$HUB_DEV/backups` | Where to save backups |
| `finish.md` | bash line | `<WORKSPACE>/.claude/finish.sh` | Path to your finish.sh |
| `session-end-safety.sh` | `PROJECTS_JSON` | `$HOME/<WORKSPACE>/.claude/projects.json` | Path to your registry |

---

## Verify installation

1. `cd` into a registered project
2. Test finish.sh manually:
   ```bash
   echo y | bash <WORKSPACE>/.claude/finish.sh
   ```
   Should print: backup path, tree path, context file, staged count
3. In Claude Code, type `/finish` — should execute the full protocol

---

## Available commands after installation

| Command | What it does |
|---|---|
| `/finish` | End session: backup + docs + memory + commit + push |

---

Author: M87
