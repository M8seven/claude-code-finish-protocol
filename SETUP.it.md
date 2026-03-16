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

# --- 1. Rileva progetto da pwd ---
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
    echo "Errore: nessun progetto rilevato." >&2
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

# --- 2. Conferma ---
echo "Progetto rilevato: $PROJECT_NAME ($PROJECT_PATH)"

if [[ "$IN_REGISTRY" == false ]]; then
  read -rp "Non in registry. Solo backup? [y/N] " ans
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

# --- 3. Carica config progetto ---
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

# --- 4. Contesto git ---
CONTEXT_FILE="/tmp/finish_context.md"
BACKUP_PATH=""
BACKUP_SIZE=""
TREE_PATH=""

if [[ "$USE_GIT" == true ]] && [[ -d "$PROJECT_PATH/.git" ]]; then
  {
    echo "# Contesto Git: $PROJECT_NAME"
    echo "## Data: $(date '+%Y-%m-%d %H:%M')"
    echo ""
    echo "## Commit recenti"
    echo '```'
    git -C "$PROJECT_PATH" log --oneline -15 2>/dev/null || echo "(nessuno)"
    echo '```'
    echo ""
    echo "## Diff stat"
    echo '```'
    git -C "$PROJECT_PATH" diff --stat 2>/dev/null || echo "(nessuna modifica)"
    echo '```'
    echo ""
    echo "## File untracked"
    echo '```'
    git -C "$PROJECT_PATH" ls-files --others --exclude-standard 2>/dev/null || echo "(nessuno)"
    echo '```'
  } > "$CONTEXT_FILE"
  echo "Contesto git salvato: $CONTEXT_FILE"
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
  echo "Backup creato: $BACKUP_PATH ($BACKUP_SIZE)"

  # Rotazione: ultime 3 copie
  find "$TARGET_DIR" -maxdepth 1 -name "backup_${PROJECT_NAME}_*.tar.gz" -type f \
    | sort -r \
    | tail -n +4 \
    | while read -r old; do
        rm -f "$old"
        echo "Rimosso backup vecchio: $(basename "$old")"
      done
fi

# --- 5b. Git bundle (settimanale) ---
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
    echo "Git bundle: (skip — bundle recente esistente)"
  else
    TIMESTAMP="${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
    BUNDLE_FILE="bundle_${PROJECT_NAME}_${TIMESTAMP}.bundle"
    BUNDLE_PATH="$TARGET_DIR/$BUNDLE_FILE"
    git -C "$PROJECT_PATH" bundle create "$BUNDLE_PATH" --all
    BUNDLE_SIZE=$(du -h "$BUNDLE_PATH" | cut -f1)
    echo "Git bundle: $BUNDLE_PATH ($BUNDLE_SIZE)"

    # Rotazione: ultime 2 copie
    find "$TARGET_DIR" -maxdepth 1 -name "bundle_${PROJECT_NAME}_*.bundle" -type f \
      | sort -r \
      | tail -n +3 \
      | while read -r old; do
          rm -f "$old"
          echo "Rimosso bundle vecchio: $(basename "$old")"
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
  echo "Tree salvato: $TREE_PATH"
fi

# --- 7. Stage codice sicuro ---
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
    echo "Codice staged: $STAGED_COUNT file"
  else
    echo "Codice staged: nessuna modifica"
  fi
fi

# --- 8. Esporta stato per fase AI ---
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

# --- 9. Riepilogo ---
echo ""
echo "=== FINISH (meccanico) ==="
echo "Progetto:  $PROJECT_NAME"
echo "Path:      $PROJECT_PATH"
[[ -n "$BACKUP_PATH" ]] && echo "Backup:    $BACKUP_PATH ($BACKUP_SIZE)" || echo "Backup:    (skip)"
[[ -n "$BUNDLE_PATH" ]] && echo "Bundle:    $BUNDLE_PATH ($BUNDLE_SIZE)" || echo "Bundle:    (skip)"
[[ -n "$TREE_PATH" ]] && echo "Tree:      $TREE_PATH" || echo "Tree:      (skip)"
[[ -f "$CONTEXT_FILE" ]] && echo "Context:   $CONTEXT_FILE" || echo "Context:   (skip)"
[[ "$CODE_STAGED" -eq 1 ]] && echo "Staged:    $STAGED_COUNT file" || echo "Staged:    nessuno"
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
echo y | bash <WORKSPACE>/.claude/finish.sh
```

Questo fa: detect progetto, backup, tree, git context, git bundle, stage codice sicuro.
Leggi `/tmp/finish_state.json` per lo stato e `/tmp/finish_context.md` per il git context.

---

## FASE 2 — Aggiorna doc + memory (4 agenti Haiku in parallelo)

**Salta se** `docs_dir` e' vuoto nello state.

Lancia 4 agenti in parallelo con `model: "haiku"`. Passa a ciascuno:
- Il contenuto di `/tmp/finish_context.md` (git log + diff stat)
- Il `project_path` e `docs_dir` dallo state
- Un riassunto di cosa e' stato fatto nella sessione (deduci dalla conversazione)

### Agent-STATUS
Aggiorna `<project_path>/<docs_dir>/<status_file>`:
- Se non esiste, crealo con: titolo, stato attuale (data, ultimo commit), cronologia sessioni
- Se esiste, aggiorna data/commit in "Stato Attuale", aggiungi entry in "Cronologia Sessioni"
- Includi riga "Blockers:" se ci sono stati ostacoli
- NON rimuovere nulla di esistente

### Agent-TODO
Aggiorna `<project_path>/<docs_dir>/<todo_file>`:
- Se non esiste, crealo con sezioni DA FARE / IN CORSO / COMPLETATI
- Se esiste, sposta task completati sotto COMPLETATI con data, aggiungi nuovi task sotto DA FARE
- NON rimuovere nulla di esistente

### Agent-CLAUDE
Aggiorna `<project_path>/CLAUDE.md`:
- Se esiste, aggiorna sezioni rilevanti (stato, ultimo commit, modifiche). NON stravolgere la struttura
- Se non esiste, crealo con struttura minima

### Agent-MEMORY
Salva memory in `~/.claude/projects/<project-key>/memory/` (project-key = cwd con `/` → `-`):
- Salva contenuti esterni ricevuti (video, doc, screenshot) → riassunto dettagliato del CONTENUTO
- Salva decisioni architetturali, feedback utente, stato progetto se cambiato
- NON salvare: cose nel codice, git history, contenuti gia' in CLAUDE.md
- Crea/aggiorna `MEMORY.md` come indice

---

## FASE 3 — Commit codice (Sonnet)

**Salta se** `use_git` e' false nello state, o `code_staged` e' 0.

Il codice e' gia' staged da finish.sh. Devi solo:
1. Analizza `git diff --cached --stat` per capire cosa e' stato modificato
2. Genera un commit message appropriato (conventional commits: `feat:`, `fix:`, `refactor:`, `chore:`)
3. Committa:
   ```bash
   git commit -m "<messaggio>"
   ```

---

## FASE 4 — Commit doc + push + riepilogo (bash)

**Salta se** `use_git` e' false nello state.

```bash
cd <project_path>
git add CLAUDE.md 2>/dev/null || true
git add "<docs_dir>/<status_file>" "<docs_dir>/<todo_file>" "<docs_dir>/tree.txt" 2>/dev/null || true
git diff --cached --quiet || git commit -m "docs: update project docs via /finish"
```

Chiedi: **"Vuoi pushare? [y/N]"**
- Se si': `git push`
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
Pushed:         si' / no
Warning:        <eventuali note>
===================================
```

---

## REGOLE

- Tocca SOLO file del progetto rilevato. Mai file di altri progetti.
- Config da projects.json — nessun hardcoded.
- Leggi prima di modificare.
- Minimo indispensabile.
- Agenti doc: usa `model: "haiku"` per risparmiare token.
- MAI `git add -A`. MAI committare `.env`, `.p8`, `credentials`, `secrets/`.
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
