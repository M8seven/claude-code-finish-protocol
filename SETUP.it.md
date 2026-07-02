# Guida Setup /finish

> **Quick start:** Dai questo file a Claude Code e digli: *"Configura /finish sulla mia macchina."*
> Claude ti chiedera' dove si trovano i tuoi progetti (es. `~/code`, `~/projects`) e creera' tutto automaticamente.
>
> **Attenzione:** Tutti i file di configurazione contengono path assoluti al tuo workspace. Se sposti la cartella workspace in futuro, dovrai aggiornare i path in `finish.sh`, `finish.md` e `session-end-safety.sh` — altrimenti il sistema si rompe.

Tutto il necessario per installare il protocollo `/finish` su una nuova macchina con Claude Code.

## Compatibilita'

| OS | Stato | Note |
|---|---|---|
| **macOS** | Pienamente supportato | Piattaforma di sviluppo primaria |
| **Linux** | Pienamente supportato | `finish.sh` ha fallback Linux per `date` e `stat` |
| **Windows** | Solo WSL | Richiede Windows Subsystem for Linux. PowerShell/CMD nativi non supportati |

## Prerequisiti

- macOS o Linux
- Claude Code installato
- `jq` installato (`brew install jq` / `apt install jq`)
- `tree` installato (`brew install tree` / `apt install tree`)
- Git configurato

## Struttura target

Dopo l'installazione:

```
~/.claude/
├── commands/
│   └── finish.md              # Prompt AI — fase intelligente
├── hooks/
│   └── session-end-safety.sh  # Rete di sicurezza — avvisa su uncommitted
└── settings.json              # Deve includere hook SessionStart

<WORKSPACE>/
├── .claude/
│   ├── finish.sh              # Script bash — fase meccanica
│   └── projects.json          # Registry progetti
└── backups/                   # Auto-creato — tar.gz + git bundle
```

Sostituisci `<WORKSPACE>` con la root dei tuoi progetti (es. `~/code`, `~/projects`).

---

## Passo 1 — Crea le directory

```bash
mkdir -p ~/.claude/commands
mkdir -p ~/.claude/hooks
mkdir -p <WORKSPACE>/.claude
mkdir -p <WORKSPACE>/backups
```

---

## Passo 2 — Crea `projects.json`

**File:** `<WORKSPACE>/.claude/projects.json`

Registra ogni progetto con la sua configurazione.

```json
{
  "<slug>": {
    "name": "<Nome Display>",
    "path": "~/<percorso/al/progetto>",
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

### Campi

| Campo | Tipo | Descrizione |
|---|---|---|
| `name` | string | Nome display |
| `path` | string | Percorso assoluto (supporta `~`) |
| `git` | bool | Se il progetto usa git |
| `backup` | bool | Se creare backup tar.gz |
| `backup_exclude` | string[] | Pattern da escludere dal backup |
| `docs_dir` | string/null | Directory per STATUS/TODO. `null` = niente doc |
| `tree_exclude` | string | Pattern separati da pipe per tree |
| `status_file` | string | Nome del file status (dentro docs_dir) |
| `todo_file` | string | Nome del file TODO (dentro docs_dir) |

### Esempio

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

> Il sistema funziona anche SENZA projects.json — auto-rileva i progetti risalendo da cwd cercando `.git`, `CLAUDE.md` o `package.json`. Senza registry fa solo backup, niente aggiornamento doc.

---

## Passo 3 — Crea `finish.sh`

**File:** `<WORKSPACE>/.claude/finish.sh`

Modifica le prime 3 righe per il tuo setup:

```bash
HUB_DEV="$HOME/<tuo-workspace>"       # ← la root del tuo workspace
PROJECTS_JSON="$HUB_DEV/.claude/projects.json"
BACKUPS_DIR="$HUB_DEV/backups"
```

### Script completo

```bash
#!/bin/bash
set -e

HUB_DEV="$HOME/Hub/dev"
PROJECTS_JSON="$HUB_DEV/.claude/projects.json"
BACKUPS_DIR="$HUB_DEV/backups"

# Fail-fast: un registry corrotto non deve degradare silenziosamente a "non registrato"
if [[ -f "$PROJECTS_JSON" ]] && ! jq empty "$PROJECTS_JSON" 2>/dev/null; then
  echo "Errore: $PROJECTS_JSON non è JSON valido." >&2
  exit 1
fi

# Cerca un path nel registry. mode="prefix" matcha anche le sottocartelle,
# mode="exact" solo il path preciso. Se matcha setta PROJECT_NAME/PROJECT_PATH/
# CONFIG/IN_REGISTRY e ritorna 0.
match_registry_by_path() {
  local target="$1" mode="$2" key custom_path expanded
  [[ -f "$PROJECTS_JSON" ]] || return 1
  while IFS= read -r key; do
    custom_path=$(jq -r --arg k "$key" '.[$k].path // empty' "$PROJECTS_JSON")
    [[ -n "$custom_path" ]] || continue
    expanded="${custom_path/#\~/$HOME}"
    if [[ "$target" == "$expanded" ]] || { [[ "$mode" == "prefix" ]] && [[ "$target" == "$expanded/"* ]]; }; then
      CONFIG=$(jq -e --arg name "$key" '.[$name]' "$PROJECTS_JSON" 2>/dev/null) || CONFIG=""
      [[ -n "$CONFIG" ]] || continue   # entry null/rotta: non fingere che sia registrata
      PROJECT_NAME="$key"
      PROJECT_PATH="$expanded"
      IN_REGISTRY=true
      return 0
    fi
  done < <(jq -r 'keys[]' "$PROJECTS_JSON")
  return 1
}

# Tiene solo il file più recente che matcha il pattern nella dir
rotate_keep_last() {
  local dir="$1" pattern="$2" label="$3"
  command find "$dir" -maxdepth 1 -name "$pattern" -type f \
    | sort -r \
    | tail -n +2 \
    | while read -r old; do
        rm -f "$old"
        echo "Rimosso $label vecchio: $(basename "$old")"
      done
}

# --- 1. Detect project from pwd ---
PWD_REAL="$(pwd -P)"

# First try: match by custom path in projects.json
IN_REGISTRY=false
CONFIG=""
PROJECT_NAME=""
PROJECT_PATH=""

match_registry_by_path "$PWD_REAL" prefix || true

# Second try: walk up from cwd to find project root (.git, CLAUDE.md, package.json)
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
    echo "Errore: nessun progetto rilevato (nessun .git, CLAUDE.md o package.json trovato risalendo da cwd)." >&2
    exit 1
  fi

  # Check if this detected dir matches a registry entry by path
  match_registry_by_path "$PROJECT_PATH" exact || true
fi

# --- 2. Confirmation ---
echo "Progetto rilevato: $PROJECT_NAME ($PROJECT_PATH)"

# Guard: blocca backup di Hub o Hub/dev interi (genera tarball monolitici corrotti)
case "$PROJECT_PATH" in
  "$HOME/Hub"|"$HOME/Hub/dev"|"$HOME/Hub/dev/backups")
    echo "❌ Rifiuto: '$PROJECT_PATH' è troppo grande per un singolo tarball." >&2
    echo "   Lancia /finish da una sotto-cartella di progetto specifico." >&2
    exit 1
    ;;
esac

if [[ "$IN_REGISTRY" == false ]]; then
  read -rp "Cartella non registrata. Vuoi solo il backup? [y/N] " ans
  case "$ans" in
    [yY]) ONLY_BACKUP=true ;;
    *) echo "Annullato."; exit 0 ;;
  esac
else
  read -rp "Confermi? [Y/n] " ans
  case "$ans" in
    [nN]) echo "Annullato."; exit 0 ;;
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
# Path per-progetto: due /finish paralleli su progetti diversi non si pestano.
# SAFE_NAME usato anche per dir/file di backup: niente metacaratteri glob nei
# pattern di find, niente path strani da basename non-registry.
SAFE_NAME="${PROJECT_NAME//[^A-Za-z0-9._-]/_}"
CONTEXT_FILE="/tmp/finish_context_${SAFE_NAME}.md"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TARGET_DIR="$BACKUPS_DIR/$SAFE_NAME"
BACKUP_PATH=""
BACKUP_SIZE=""
TREE_PATH=""

# Risolve il path reale di status/todo: il registry a volte include docs_dir
# nel filename (vmbridge: "docs/STATUS.md") o tiene il file alla root del
# progetto (red/blue: "state.md" con docs_dir diverso). Preferisce il file
# che esiste; per file nuovi il default è docs_dir/<file>.
resolve_doc_path() {
  local f="$1"
  [[ -z "$f" ]] && { echo ""; return; }
  if [[ -f "$PROJECT_PATH/$f" ]]; then echo "$PROJECT_PATH/$f"; return; fi
  if [[ -n "$DOCS_DIR" && "$DOCS_DIR" != "." && -f "$PROJECT_PATH/$DOCS_DIR/$f" ]]; then
    echo "$PROJECT_PATH/$DOCS_DIR/$f"; return
  fi
  if [[ -n "$DOCS_DIR" && "$DOCS_DIR" != "." ]]; then
    echo "$PROJECT_PATH/$DOCS_DIR/$f"
  else
    echo "$PROJECT_PATH/$f"
  fi
}
STATUS_PATH=$(resolve_doc_path "$STATUS_FILE")
TODO_PATH=$(resolve_doc_path "$TODO_FILE")

# Capture session cost from statusline (best effort — needs stdin JSON)
SESSION_COST=""
_statusline_out=$(bash ~/.claude/statusline-command.sh 2>/dev/null <<< '{}' || true)
if [[ -n "$_statusline_out" ]]; then
  _cost_raw="${_statusline_out##*\$}"
  # Accetta solo un numero: se il formato dello statusline cambia, meglio vuoto che spazzatura
  [[ "$_cost_raw" =~ ^[0-9]+([.][0-9]+)?$ ]] || _cost_raw=""
  [[ -n "$_cost_raw" && "$_cost_raw" != "0.000" ]] && SESSION_COST="$_cost_raw"
fi

if [[ "$USE_GIT" == true ]] && [[ -d "$PROJECT_PATH/.git" ]]; then
  {
    echo "# Git Context: $PROJECT_NAME"
    echo "## Data: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    if [[ -n "$SESSION_COST" ]]; then
      echo "## Session Info"
      echo "- Cost: \$$SESSION_COST"
      echo ""
    fi
    echo "## Recent commits"
    echo '```'
    git -C "$PROJECT_PATH" log --oneline -15 --invert-grep \
      --grep="docs: update project docs via /finish" 2>/dev/null || echo "(nessun commit)"
    echo '```'
    echo ""
    echo "## Diff stat"
    echo '```'
    git -C "$PROJECT_PATH" diff --stat 2>/dev/null || echo "(nessuna modifica)"
    echo '```'
    echo ""
    echo "## Untracked files"
    echo '```'
    git -C "$PROJECT_PATH" ls-files --others --exclude-standard 2>/dev/null || echo "(nessuno)"
    echo '```'
  } > "$CONTEXT_FILE"
  echo "Git context salvato: $CONTEXT_FILE"
else
  rm -f "$CONTEXT_FILE"
fi

# --- 5. Backup ---
if [[ "$USE_BACKUP" == true ]] || [[ "$ONLY_BACKUP" == true ]]; then
  mkdir -p "$TARGET_DIR"

  BACKUP_FILE="backup_${SAFE_NAME}_${TIMESTAMP}.tar.gz"
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
  # Scrittura atomica: un crash a metà tar non lascia un .tar.gz troncato
  # che la rotation promuoverebbe a unico backup
  tar -czf "${BACKUP_PATH}.tmp" "${EXCLUDE_ARGS[@]}" -C "$PARENT_DIR" "$BASE_NAME" \
    || { rm -f "${BACKUP_PATH}.tmp"; echo "Errore: tar fallito, backup precedente intatto." >&2; exit 1; }
  mv "${BACKUP_PATH}.tmp" "$BACKUP_PATH"
  BACKUP_SIZE=$(command du -h "$BACKUP_PATH" | cut -f1)
  echo "Backup creato: $BACKUP_PATH ($BACKUP_SIZE)"

  rotate_keep_last "$TARGET_DIR" "backup_${SAFE_NAME}_*.tar.gz" "backup"
fi

# --- 5b. Git bundle (weekly, full history backup) ---
BUNDLE_PATH=""
BUNDLE_SIZE=""

if [[ "$USE_GIT" == true ]] && [[ -d "$PROJECT_PATH/.git" ]]; then
  mkdir -p "$TARGET_DIR"

  # Check if a recent bundle (< 7 days) already exists
  RECENT_BUNDLE=""
  SEVEN_DAYS_AGO=$(date -v -7d +%s 2>/dev/null || date -d '7 days ago' +%s)
  while IFS= read -r bf; do
    # -f%m senza spazio: con lo spazio, GNU stat interpreta -f come --file-system
    # e sputa garbage su stdout invece di fallire pulito
    BF_MTIME=$(stat -f%m "$bf" 2>/dev/null || stat -c %Y "$bf" 2>/dev/null)
    if [[ -n "$BF_MTIME" ]] && [[ "$BF_MTIME" -ge "$SEVEN_DAYS_AGO" ]]; then
      RECENT_BUNDLE="$bf"
      break
    fi
  done < <(command find "$TARGET_DIR" -maxdepth 1 -name "bundle_${SAFE_NAME}_*.bundle" -type f | sort -r)

  if [[ -n "$RECENT_BUNDLE" ]]; then
    echo "Git bundle: (skip — recent bundle exists)"
  else
    BUNDLE_FILE="bundle_${SAFE_NAME}_${TIMESTAMP}.bundle"
    BUNDLE_PATH="$TARGET_DIR/$BUNDLE_FILE"
    git -C "$PROJECT_PATH" bundle create "${BUNDLE_PATH}.tmp" --all \
      || { rm -f "${BUNDLE_PATH}.tmp"; echo "Errore: bundle fallito, bundle precedente intatto." >&2; exit 1; }
    mv "${BUNDLE_PATH}.tmp" "$BUNDLE_PATH"
    BUNDLE_SIZE=$(command du -h "$BUNDLE_PATH" | cut -f1)
    echo "Git bundle: $BUNDLE_PATH ($BUNDLE_SIZE)"

    rotate_keep_last "$TARGET_DIR" "bundle_${SAFE_NAME}_*.bundle" "bundle"
  fi
fi

# --- 6. Stage safe code files ---
# Il tree (sezione 7) viene generato DOPO questo staging, di proposito: così
# tree.txt non viene auto-stagiato qui e resta al commit docs della fase AI
# (FASE 4), come da design.
CODE_STAGED=0
STAGED_COUNT=0
if [[ "$USE_GIT" == true ]] && [[ -d "$PROJECT_PATH/.git" ]]; then
  cd "$PROJECT_PATH"

  echo "── Files touched (HEAD diff) ──"
  git diff HEAD --stat 2>/dev/null | tail -20 || true
  echo ""

  # Stage tracked modified files (git add -u is safe — only tracked files)
  if ! git diff --quiet 2>/dev/null; then
    git add -u
    CODE_STAGED=1
  fi

  # Stage untracked files, excluding sensitive ones, binari e file pesanti.
  # -z + read -d '': coi nomi non-ASCII git quota/escapa l'output normale e
  # git add fallirebbe (uccidendo lo script via set -e)
  while IFS= read -r -d '' untracked; do
    [[ -z "$untracked" ]] && continue
    # Skip sensitive files
    case "$untracked" in
      .env|.env.*|*.p8|*.pem|*credentials*|*secret*|*/secrets/*|*/node_modules/*) continue ;;
      # Skip binari/archivi che non vanno versionati (gonfiano il repo)
      *.tar|*.tar.gz|*.tgz|*.zip|*.gz|*.bundle|*.iso|*.dmg|*.log) echo "  skip binario: $untracked" >&2; continue ;;
    esac
    # Guard dimensione: non auto-stagiare file > 5MB (probabile binario/dump)
    fsize=$(stat -f%z "$PROJECT_PATH/$untracked" 2>/dev/null || stat -c%s "$PROJECT_PATH/$untracked" 2>/dev/null || echo 0)
    if [[ "$fsize" -gt 5242880 ]]; then
      echo "  skip >5MB ($((fsize/1048576))M): $untracked" >&2
      continue
    fi
    # Guard contenuto: il filtro sul nome non basta, un config.json con dentro
    # una API key passerebbe. grep -I salta i binari.
    if LC_ALL=C grep -qIE 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{36}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}' "$PROJECT_PATH/$untracked" 2>/dev/null; then
      echo "  skip possibile secret nel contenuto: $untracked" >&2
      continue
    fi
    # Un pathspec che git rifiuta non deve uccidere l'intera run
    git add -- "$untracked" || { echo "  skip (git add fallito): $untracked" >&2; continue; }
    CODE_STAGED=1
  done < <(git ls-files -z --others --exclude-standard 2>/dev/null)

  if [[ "$CODE_STAGED" -eq 1 ]]; then
    STAGED_COUNT=$(git diff --cached --numstat | wc -l | tr -d ' ')
    echo "Code staged: $STAGED_COUNT file(s) pronti per il commit"
  else
    echo "Code staged: nessuna modifica"
  fi
fi

# --- 7. Tree (DOPO lo staging: vedi commento in sezione 6) ---
if [[ -n "$DOCS_DIR" ]] && [[ "$ONLY_BACKUP" != true ]]; then
  FULL_DOCS="$PROJECT_PATH/$DOCS_DIR"
  mkdir -p "$FULL_DOCS"
  TREE_PATH="$FULL_DOCS/tree.txt"

  TREE_ARGS=(-L 3 --dirsfirst)
  [[ -n "$TREE_EXCLUDE" ]] && TREE_ARGS+=(-I "$TREE_EXCLUDE")

  tree "${TREE_ARGS[@]}" "$PROJECT_PATH" > "$TREE_PATH"
  echo "Tree salvato: $TREE_PATH"
fi

# --- 8. Export config for AI phase ---
# Write a state file so finish.md knows what finish.sh already did.
# context_file vuoto se il file non esiste (use_git=false): la fase AI non
# deve provare ad aprire un path fantasma.
[[ -f "$CONTEXT_FILE" ]] || CONTEXT_FILE=""
STATE_FILE="/tmp/finish_state_${SAFE_NAME}.json"
cat > "$STATE_FILE" <<EOFSTATE
{
  "project_name": "$PROJECT_NAME",
  "project_path": "$PROJECT_PATH",
  "in_registry": $IN_REGISTRY,
  "use_git": $USE_GIT,
  "docs_dir": "$DOCS_DIR",
  "status_file": "$STATUS_FILE",
  "todo_file": "$TODO_FILE",
  "status_path": "$STATUS_PATH",
  "todo_path": "$TODO_PATH",
  "backup_path": "$BACKUP_PATH",
  "backup_size": "$BACKUP_SIZE",
  "tree_path": "$TREE_PATH",
  "bundle_path": "$BUNDLE_PATH",
  "bundle_size": "$BUNDLE_SIZE",
  "code_staged": $CODE_STAGED,
  "context_file": "$CONTEXT_FILE",
  "session_cost": "$SESSION_COST"
}
EOFSTATE
echo "State esportato: $STATE_FILE"

# --- 9. Summary (pre-AI) ---
echo ""
echo "=== FINISH (meccanico) ==="
echo "Progetto:  $PROJECT_NAME"
echo "Path:      $PROJECT_PATH"
[[ -n "$BACKUP_PATH" ]] && echo "Backup:    $BACKUP_PATH ($BACKUP_SIZE)" || echo "Backup:    (skip)"
[[ -n "$BUNDLE_PATH" ]] && echo "Bundle:    $BUNDLE_PATH ($BUNDLE_SIZE)" || echo "Bundle:    (skip)"
[[ -n "$TREE_PATH" ]] && echo "Tree:      $TREE_PATH" || echo "Tree:      (skip)"
[[ -f "$CONTEXT_FILE" ]] && echo "Context:   $CONTEXT_FILE" || echo "Context:   (skip)"
[[ "$CODE_STAGED" -eq 1 ]] && echo "Staged:    $STAGED_COUNT file(s)" || echo "Staged:    nessuno"
echo "==========================="
```

Rendilo eseguibile:

```bash
chmod +x <WORKSPACE>/.claude/finish.sh
```

---

## Passo 4 — Crea `finish.md`

**File:** `~/.claude/commands/finish.md`

Aggiorna il path del comando bash per puntare al TUO `finish.sh`.

````markdown
Esegui il protocollo di fine sessione.

## FASE 1 — Meccanica (bash)

```bash
echo y | bash ~/Hub/dev/.claude/finish.sh
```

Questo fa: detect progetto, backup, tree, git context, git bundle, stage codice sicuro.
I path di stato sono per-progetto: leggili dall'output di finish.sh (`State esportato: /tmp/finish_state_<progetto>.json`, `Git context salvato: /tmp/finish_context_<progetto>.md`). Nel resto di questo file `$STATE_JSON` indica quel path.

---

## FASE 2 — Aggiorna doc + memory (4 agenti Haiku in parallelo)

**Salta se** `docs_dir` è vuoto nello state.

Lancia 4 agenti in parallelo con `model: "haiku"`. Regole sui target:
- Usa `status_path` e `todo_path` dallo state: sono i path ASSOLUTI già risolti da finish.sh (il registry a volte include docs_dir nel filename o tiene il file alla root — non ricomporre mai `<docs_dir>/<status_file>` a mano).
- Se `status_path` (o `todo_path`) è vuoto, salta il relativo agente.
- **Eccezione**: se `status_path` == `todo_path` ed entrambi non vuoti (progetti dove status e todo condividono lo stesso file), fondi Agent-STATUS e Agent-TODO in un UNICO agente che aggiorna entrambe le sezioni in una sola scrittura — due agenti paralleli sullo stesso file si sovrascrivono a vicenda.

Passa a ciascuno:
- Il contenuto del context file (`context_file` nello state; se vuoto, salta il context)
- Il `project_path` e `docs_dir` dallo state
- Un riassunto di cosa è stato fatto nella sessione (deduci dalla conversazione)

### Agent-STATUS
Aggiorna il file a `status_path`:
- Se non esiste, crealo con: titolo, stato attuale (data, ultimo commit), cronologia sessioni
- Se esiste, aggiorna data/commit in "Stato Attuale", aggiungi entry in "Cronologia Sessioni" con data odierna
- Includi riga "Blockers:" se ci sono stati ostacoli
- TRIM: tieni solo le ultime ~5 sessioni in cronologia; le più vecchie sono in `git log` — NON accumulare all'infinito

### Agent-TODO
Aggiorna il file a `todo_path`:
- Se non esiste, crealo con sezioni DA FARE / IN CORSO
- Se esiste, RIMUOVI i task completati (sono in `git log`), aggiungi nuovi task sotto DA FARE; non far crescere un archivio COMPLETATI infinito

### Agent-CLAUDE
Aggiorna `<project_path>/CLAUDE.md`:
- Se esiste, aggiorna sezioni rilevanti (stato, ultimo commit, modifiche). NON stravolgere la struttura
- Se non esiste, crealo con struttura minima

### Pre-step: Context Recovery
Prima di lanciare Agent-MEMORY, recupera contesto da `<project>/.claude/context/`:

```bash
# $STATE_JSON = path stampato da finish.sh in FASE 1
PROJECT_PATH=$(jq -r '.project_path // empty' "$STATE_JSON" 2>/dev/null)
CONTEXT=""
if [[ -n "$PROJECT_PATH" ]]; then
  SEMANTIC="${PROJECT_PATH}/.claude/context/semantic.md"
  MECHANICAL="${PROJECT_PATH}/.claude/context/mechanical.md"
  [[ -f "$SEMANTIC" ]] && CONTEXT="$(cat "$SEMANTIC")"
  if [[ -f "$MECHANICAL" ]]; then
    CONTEXT="${CONTEXT}"$'\n---\n'"$(cat "$MECHANICAL")"
  fi
fi

# Fallback legacy: ~/.claude/snapshots/
if [[ -z "$CONTEXT" ]]; then
  SNAP=$(ls -1t "$HOME/.claude/snapshots/"*.md 2>/dev/null | head -1)
  [[ -n "$SNAP" ]] && CONTEXT="$(cat "$SNAP")"
fi
```

Se `$CONTEXT` non è vuoto, passalo come contesto ad Agent-MEMORY.

### Pre-step: Session Log Extraction
```bash
LESSONS=$(bash ~/.claude/hooks/extract-lessons.sh "/tmp/session-log-${CLAUDE_SESSION_ID:-unknown}.jsonl" 2>/dev/null)
```
Se `$LESSONS` non è vuoto, passalo come contesto aggiuntivo all'Agent-MEMORY insieme al git context.

### Agent-MEMORY
Salva memory in `~/.claude/projects/<project-key>/memory/` (project-key = cwd con `/` → `-`):

**Categorie (in ordine di priorità):**
1. **Errori risolti** — per ogni errore nel session log: errore, causa root, soluzione. Solo se non ovvio dal codice.
2. **Path e workaround** — percorsi di file/config scoperti, workaround per tool/librerie.
3. **Comandi utili** — comandi CLI scoperti durante la sessione che risolvono problemi ricorrenti.
4. **Contenuti esterni** — riassunto di video, doc, screenshot ricevuti dall'utente.
5. **Decisioni architetturali** — scelte di design con motivazione (se non già in CLAUDE.md).
6. **Feedback utente** — correzioni e preferenze espresse dall'utente.
7. **Cosa farei diversamente** — meta-feedback procedurale: passi fatti che a posteriori erano subottimali (es. "ho rifattorizzato prima di testare il fix", "ho usato Opus per task da Haiku"), anche senza correzione esplicita dell'utente. Salva solo se generalizzabile a sessioni future, non se specifico al task corrente.

**NON salvare:** cose nel codice, git history, contenuti già in CLAUDE.md, dettagli effimeri della sessione corrente.
Crea/aggiorna `MEMORY.md` come indice.

---

## FASE 3 — Commit codice (Sonnet)

**Salta se** `use_git` è false nello state, o `code_staged` è 0.

Il codice è già staged da finish.sh. Devi solo:
1. Analizza `git diff --cached --stat` per capire cosa è stato modificato
2. Genera un commit message appropriato (conventional commits: `feat:`, `fix:`, `refactor:`, `chore:`)
3. Committa:
   ```bash
   git commit -m "<messaggio>"
   ```

---

## FASE 4 — Commit doc + push + riepilogo (bash)

**Salta se** `use_git` è false nello state.

```bash
# Commit doc files (se modificati). Path assoluti dallo state (status_path,
# todo_path, tree_path) — un add PER FILE: git add multi-pathspec è
# all-or-nothing, un file mancante farebbe saltare anche gli altri.
cd <project_path>
git add CLAUDE.md 2>/dev/null || true
for f in "<status_path>" "<todo_path>" "<tree_path>"; do
  [[ -n "$f" ]] && git add "$f" 2>/dev/null || true
done
git diff --cached --quiet || git commit -m "docs: update project docs via /finish"
```

Chiedi: **"Vuoi pushare? [y/N]"**
- Se sì: `git push`
- Se no: segnala che i commit sono solo locali

Stampa riepilogo:
```
=== FINE SESSIONE <nome> ===
Progetto:       <nome>
Data:           YYYY-MM-DD HH:MM
Backup:         <path> (<size>)
Tree:           <path>
Status:         aggiornato / creato / saltato
TODO:           aggiornato / creato / saltato
CLAUDE.md:      aggiornato / saltato
Memory:         <N> file salvati
Code commit:    <hash> <message> / nessuno
Docs commit:    <hash> / nessuno
Pushed:         sì / no
Warning:        <eventuali note>
===================================
```

---

## REGOLE

- Tocca SOLO file del progetto rilevato. Mai file di altri progetti.
- Config da `~/Hub/dev/.claude/projects.json` — nessun hardcoded.
- Leggi prima di modificare.
- Minimo indispensabile.
- Agenti doc: usa `model: "haiku"` per risparmiare token.
- MAI `git add -A`. MAI committare `.env`, `.p8`, `credentials`, `secrets/`.
- **context-save.md** e **snapshot** non devono MAI contenere credenziali in chiaro (API key, token, password, api_id, chat_id). Usa riferimenti al tuo file credenziali (fuori dal repo) invece del valore in chiaro.
````

---

## Passo 5 — Crea il safety hook

**File:** `~/.claude/hooks/session-end-safety.sh`

```bash
#!/bin/bash
# Avvisa su lavoro uncommitted all'avvio sessione
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
echo "[session-end] WARNING: $CHANGED file uncommitted in $(basename "$PWD_REAL"). Esegui /finish alla prossima sessione." >&2
```

Rendilo eseguibile:

```bash
chmod +x ~/.claude/hooks/session-end-safety.sh
```

---

## Passo 6 — Aggiorna `settings.json`

Aggiungi l'hook SessionStart a `~/.claude/settings.json`:

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

Se hai gia' altri hook in SessionStart, aggiungi questo come entry aggiuntiva.

---

## Passo 7 — Path da personalizzare

Tutti i path hardcoded sono nelle prime righe di ogni file:

| File | Variabile | Default | Cambia in |
|---|---|---|---|
| `finish.sh` | `HUB_DEV` | `$HOME/Hub/dev` | La root del tuo workspace |
| `finish.sh` | `PROJECTS_JSON` | `$HUB_DEV/.claude/projects.json` | Path al tuo registry |
| `finish.sh` | `BACKUPS_DIR` | `$HUB_DEV/backups` | Dove salvare i backup |
| `finish.md` | riga bash | `<WORKSPACE>/.claude/finish.sh` | Path al tuo finish.sh |
| `session-end-safety.sh` | `PROJECTS_JSON` | `$HOME/<WORKSPACE>/.claude/projects.json` | Path al tuo registry |

---

## Verifica installazione

1. `cd` in un progetto registrato
2. Testa finish.sh manualmente:
   ```bash
   echo y | bash <WORKSPACE>/.claude/finish.sh
   ```
   Deve stampare: path backup, path tree, file context, conteggio staged
3. In Claude Code, digita `/finish` — deve eseguire l'intero protocollo

---

## Comandi disponibili dopo l'installazione

| Comando | Cosa fa |
|---|---|
| `/finish` | Fine sessione: backup + doc + memory + commit + push |

---

Autore: M87
