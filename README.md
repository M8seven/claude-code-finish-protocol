# The /finish Protocol

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.19061530.svg)](https://doi.org/10.5281/zenodo.19061530)

**Session lifecycle management for AI coding assistants.**

AI coding sessions are stateless: context evaporates, code stays uncommitted, documentation drifts from reality. The `/finish` protocol is a two-phase end-of-session system that handles backup, git operations, documentation updates, and cross-session memory in a single command.

By splitting work between a zero-token bash phase and parallel AI agents using the cheapest available model, it runs ~4x faster and ~75% cheaper than a naive sequential approach.

## The Problem

Every AI coding session faces the same failure modes:

1. **Context loss.** The session ends, and everything the AI learned about the codebase — architectural decisions, debugging context, external references — disappears. The next session starts cold.

2. **Uncommitted work.** Developers close the terminal with staged changes, modified files, or new code that never made it into a commit. Work is lost or left in limbo.

3. **Documentation drift.** Project status files, TODO lists, and coding guides fall behind the actual state of the code. Nobody updates them manually. The AI could, but it burns expensive tokens doing repetitive mechanical work.

4. **Token waste.** Updating four documentation files sequentially with a frontier model (Opus-class) costs ~$0.15–0.30 per session. Across hundreds of sessions, this adds up — and most of this work requires no advanced reasoning.

No existing tool solves all of these together. `claude-sessions` writes markdown journals but has no git automation. Aider auto-commits per-edit but has no documentation lifecycle. Cursor generates AI commit messages but nothing else. Memory bank systems solve context persistence but not session closure. Claude Code's own SessionEnd hooks provide low-level triggers but no orchestrated workflow.

## Architecture

The protocol uses a two-phase design: mechanical operations run in bash (zero AI tokens), intelligent operations run as parallel AI agents (cheapest model available).

```
User types: /finish
       │
       ▼
┌───────────────────────────┐
│  PHASE 1: finish.sh       │  bash, 0 tokens
│  (mechanical)              │
│                            │
│  1. Detect project         │
│  2. Load config            │
│  3. Git context capture    │
│  4. Backup (tar.gz)        │
│  5. Git bundle (weekly)    │
│  6. Directory tree         │
│  7. Stage safe code        │
│  8. Export state JSON       │
└────────────┬──────────────┘
             │
             ▼
     /tmp/finish_state.json
     /tmp/finish_context.md
             │
             ▼
┌───────────────────────────┐
│  PHASE 2: finish.md        │  AI, multi-agent
│  (intelligent)             │
│                            │
│  4x Haiku agents           │
│  (parallel):               │
│  ┌────────┐ ┌────────┐    │
│  │ STATUS │ │  TODO  │    │
│  └────────┘ └────────┘    │
│  ┌────────┐ ┌────────┐    │
│  │ CLAUDE │ │ MEMORY │    │
│  └────────┘ └────────┘    │
│                            │
│  1x Sonnet call:           │
│  commit message gen        │
│                            │
│  Bash: commit, push,       │
│  print summary             │
└───────────────────────────┘
```

The key insight: everything that does not require AI judgment runs in bash. Project detection, backup, file staging, tree generation, git context capture — none of these need a language model. By offloading them to a shell script, the AI phase starts with all context pre-assembled and only has to do what AI is actually good at: reading code changes and writing meaningful documentation updates.

## Components

| File | Location | Purpose |
|---|---|---|
| `finish.sh` | `<workspace>/.claude/finish.sh` | Phase 1: mechanical ops (backup, git, staging, state export) |
| `finish.md` | `~/.claude/commands/finish.md` | Phase 2: AI orchestration (4 agents + commit + push) |
| `projects.json` | `<workspace>/.claude/projects.json` | Project registry (per-project config) |
| `session-end-safety.sh` | `~/.claude/hooks/session-end-safety.sh` | Safety net: warns on uncommitted work at session start |

## The Flow

### Phase 1 — Mechanical (bash, ~3–5 seconds)

**Step 1: Project detection.** The script resolves `pwd` and checks two sources in order: (a) `projects.json` registry lookup by path, (b) walk-up from cwd looking for `.git`, `CLAUDE.md`, or `package.json` markers. Works with or without a registry.

**Step 2: Config loading.** If found in registry, loads per-project settings: git enabled, backup enabled, docs directory, tree excludes, status/TODO file paths, backup excludes.

**Step 3: Git context capture.** For git-enabled projects, writes `/tmp/finish_context.md` with the last 15 commits, diff stat, and untracked files. This file becomes the AI agents' primary input.

**Step 4: Backup.** Creates a timestamped `tar.gz` in a central backups directory, excluding `.git`, `node_modules`, `.venv`, and project-specific excludes. Rotates to keep the last 3 backups.

**Step 5: Git bundle.** Once per week, creates a full git bundle (all branches, full history). Rotates to keep the last 2. Skips if a bundle less than 7 days old exists.

**Step 6: Directory tree.** Generates a depth-3 tree snapshot in the project's docs directory, excluding noise directories.

**Step 7: Safe code staging.** Runs `git add -u` for tracked files, then stages untracked files one-by-one, skipping `.env`, `.p8`, `.pem`, `credentials`, and `secrets/`. Never uses `git add -A`.

**Step 8: State export.** Writes `/tmp/finish_state.json` with all paths, flags, and results for the AI phase.

### Phase 2 — Intelligent (AI agents, ~15–20 seconds)

**Step 9: Parallel documentation update.** Four Haiku-class agents launch simultaneously, each with exclusive file ownership:

- **Agent-STATUS**: Updates `PROJECT_STATUS.md` with session date, last commit, session summary, blockers.
- **Agent-TODO**: Moves completed tasks to a COMPLETED section with dates, adds new tasks discovered during the session.
- **Agent-CLAUDE**: Updates the project's `CLAUDE.md` guide with any new conventions, state changes, or structural notes.
- **Agent-MEMORY**: Saves cross-session memories (architectural decisions, external content summaries, user feedback) to the project's memory directory.

**Step 10: Commit message generation.** A single Sonnet-class call analyzes `git diff --cached --stat` and generates a conventional commit message (`feat:`, `fix:`, `refactor:`, `chore:`).

**Step 11: Commit and push.** Bash commits the code (AI-generated message), then commits docs separately with a fixed message (`docs: update project docs via /finish`). Prompts the user for push confirmation.

**Step 12: Summary.** Prints a structured report: project name, date, backup path/size, bundle path/size, each doc file status, commit hashes, push status, and any warnings.

## Multi-Agent Optimization

Why four parallel agents instead of one sequential pass?

**Cost.** Haiku-class models cost ~60x less than Opus-class. Four Haiku calls cost less than a single Opus call that handles all four files.

**Speed.** Four agents running in parallel complete in the time of the slowest one (~4–5 seconds), not the sum of all four (~16–20 seconds sequential).

**File ownership prevents conflicts.** Each agent owns exactly one file (or one directory, in the case of memory). No agent reads or writes another agent's files. The commander (the `finish.md` prompt itself) passes shared context (git log, diff stat, session summary) to all agents upfront. This eliminates merge conflicts, race conditions, and the need for coordination protocols.

**Model selection is deliberate.** Documentation updates are structured, low-creativity tasks: read the diff, update a status line, move a TODO item. Haiku handles this well. The commit message gets Sonnet because it needs to synthesize a diff into a meaningful one-liner — slightly harder, but still not Opus territory.

## Safety Net

What happens if you forget `/finish`?

The `session-end-safety.sh` hook runs on every Claude Code session start (configured as a SessionStart hook in `settings.json`). It:

1. Detects the current project from `cwd` using the same registry lookup as `finish.sh`.
2. Checks if git is enabled for the project.
3. Runs `git diff`, `git diff --cached`, and checks for untracked files.
4. If any uncommitted changes exist, prints a warning: `[session-end] WARNING: N uncommitted file(s) in project. Run /finish next session.`

This is intentionally a warning, not an auto-commit. Auto-committing on session end is dangerous — the code may be in a broken state, tests may not pass, and the developer may not want those changes committed. The safety net just ensures you know about it.

## Comparison

| Feature | /finish | claude-sessions | Aider --commit | Cursor | Memory banks |
|---|---|---|---|---|---|
| Session documentation | 4 files | Journal | No | No | No |
| Git commit automation | Staged + msg | No | Per-edit | Msg only | No |
| Backup (tar.gz) | 3-rotation | No | No | No | No |
| Git bundle | Weekly | No | No | No | No |
| Cross-session memory | Per-project | No | No | No | Yes |
| Sensitive file protection | Staging filter | N/A | No | No | N/A |
| Token-optimized | Haiku agents | N/A | N/A | N/A | Varies |
| Works without config | Marker walk-up | Yes | Yes | Yes | Varies |
| Single command | Yes | No | Automatic | Automatic | No |

## Performance

Measured across 50+ sessions on projects ranging from 5 to 200 files.

### Before optimization (v1: sequential Opus)

```
Phase 1 (bash):           ~5 sec
Phase 2 (Opus, serial):   ~80 sec
Total:                     ~85 sec
Token cost:                ~100% Opus pricing
```

### After optimization (v2: parallel Haiku + Sonnet)

```
Phase 1 (bash):           ~4 sec
Phase 2 (4x Haiku):       ~5 sec (parallel)
Phase 2 (1x Sonnet):      ~3 sec
Phase 2 (bash commit):    ~2 sec
Total:                     ~14–23 sec
Token cost:                ~25% of original
```

**Result: ~4x faster, ~75% cheaper.**

## Portability

The two-phase architecture is tool-agnostic. Phase 1 (`finish.sh`) is pure bash — it works with any tool that can run shell commands. Phase 2 (`finish.md`) is a prompt template — adapt the agent instructions for your tool's multi-agent API.

Key requirements:
- **Shell execution**: the tool must be able to run bash scripts
- **File I/O**: the tool must be able to read and write files
- **Multi-agent or sequential calls**: parallel agents are faster but not required
- **Model selection**: optional; use the cheapest model available for doc updates

The protocol does not depend on Claude Code-specific features. The `/command` syntax is Claude Code's slash command system, but the underlying logic is transferable.

## Setup

See **[SETUP.md](SETUP.md)** for a complete step-by-step installation guide.

## License

MIT

---

- `README.md` — English
- `README.it.md` — Italiano

Author: M87
