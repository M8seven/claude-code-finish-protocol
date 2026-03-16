# Il protocollo /finish

**Gestione del ciclo di vita delle sessioni per assistenti AI di coding.**

Le sessioni di coding con AI sono stateless: il contesto evapora, il codice resta uncommitted, la documentazione diverge dalla realta'. Il protocollo `/finish` e' un sistema di fine sessione a due fasi che gestisce backup, operazioni git, aggiornamenti della documentazione e memoria cross-sessione con un singolo comando.

Dividendo il lavoro tra una fase bash a zero token e agenti AI paralleli con il modello piu' economico disponibile, e' ~4x piu' veloce e ~75% piu' economico rispetto a un approccio sequenziale.

## Il problema

Ogni sessione di coding AI ha gli stessi punti di rottura:

1. **Perdita di contesto.** La sessione finisce, e tutto cio' che l'AI ha imparato sul codebase — decisioni architetturali, contesto di debug, riferimenti esterni — scompare. La sessione successiva parte da zero.

2. **Lavoro non committato.** Gli sviluppatori chiudono il terminale con modifiche staged, file modificati o codice nuovo che non e' mai arrivato in un commit. Il lavoro si perde o resta in limbo.

3. **Drift della documentazione.** File di stato, TODO list e guide di progetto restano indietro rispetto al codice. Nessuno li aggiorna a mano. L'AI potrebbe, ma spreca token costosi per lavoro meccanico ripetitivo.

4. **Spreco di token.** Aggiornare quattro file di documentazione in sequenza con un modello frontier (Opus) costa ~$0.15–0.30 per sessione. Su centinaia di sessioni, si accumula — e la maggior parte di questo lavoro non richiede ragionamento avanzato.

Nessuno strumento esistente risolve tutti questi problemi insieme. `claude-sessions` scrive journal markdown ma non ha automazione git. Aider auto-committa per-edit ma non ha ciclo di vita della documentazione. Cursor genera commit message AI ma nient'altro. I sistemi di memory bank risolvono la persistenza del contesto ma non la chiusura della sessione.

## Architettura

Il protocollo usa un design a due fasi: le operazioni meccaniche girano in bash (zero token AI), le operazioni intelligenti girano come agenti AI paralleli (modello piu' economico disponibile).

```
L'utente digita: /finish
       |
       v
+---------------------------+
|  FASE 1: finish.sh        |  bash, 0 token
|  (meccanica)               |
|                            |
|  1. Rileva progetto        |
|  2. Carica config          |
|  3. Cattura contesto git   |
|  4. Backup (tar.gz)        |
|  5. Git bundle (settimanale)|
|  6. Albero directory       |
|  7. Stage codice sicuro    |
|  8. Esporta stato JSON     |
+-------------+--------------+
              |
              v
      /tmp/finish_state.json
      /tmp/finish_context.md
              |
              v
+---------------------------+
|  FASE 2: finish.md         |  AI, multi-agente
|  (intelligente)            |
|                            |
|  4x agenti Haiku           |
|  (paralleli):              |
|  +--------+ +--------+    |
|  | STATUS | |  TODO  |    |
|  +--------+ +--------+    |
|  +--------+ +--------+    |
|  | CLAUDE | | MEMORY |    |
|  +--------+ +--------+    |
|                            |
|  1x chiamata Sonnet:       |
|  generazione commit msg    |
|                            |
|  Bash: commit, push,       |
|  stampa riepilogo          |
+----------------------------+
```

L'intuizione chiave: tutto cio' che non richiede giudizio AI gira in bash. Rilevamento progetto, backup, staging file, generazione tree, cattura contesto git — nessuna di queste operazioni ha bisogno di un language model. Scaricandole su uno script shell, la fase AI parte con tutto il contesto pre-assemblato e deve solo fare cio' in cui l'AI e' realmente brava: leggere le modifiche al codice e scrivere aggiornamenti significativi alla documentazione.

## Componenti

| File | Posizione | Scopo |
|---|---|---|
| `finish.sh` | `<workspace>/.claude/finish.sh` | Fase 1: operazioni meccaniche (backup, git, staging, export stato) |
| `finish.md` | `~/.claude/commands/finish.md` | Fase 2: orchestrazione AI (4 agenti + commit + push) |
| `projects.json` | `<workspace>/.claude/projects.json` | Registry progetti (config per-progetto) |
| `session-end-safety.sh` | `~/.claude/hooks/session-end-safety.sh` | Rete di sicurezza: avvisa su lavoro uncommitted all'avvio sessione |

## Il flusso

### Fase 1 — Meccanica (bash, ~3–5 secondi)

**Step 1: Rilevamento progetto.** Lo script risolve `pwd` e controlla due fonti in ordine: (a) lookup nel registry `projects.json` per path, (b) risalita da cwd cercando `.git`, `CLAUDE.md` o `package.json`. Funziona con o senza registry.

**Step 2: Caricamento config.** Se trovato nel registry, carica le impostazioni per-progetto: git abilitato, backup abilitato, directory docs, esclusioni tree, path dei file status/TODO, esclusioni backup.

**Step 3: Cattura contesto git.** Per i progetti con git abilitato, scrive `/tmp/finish_context.md` con gli ultimi 15 commit, diff stat e file untracked. Questo file diventa l'input primario degli agenti AI.

**Step 4: Backup.** Crea un `tar.gz` con timestamp in una directory backup centralizzata, escludendo `.git`, `node_modules`, `.venv` ed esclusioni specifiche del progetto. Rotazione: ultime 3 copie.

**Step 5: Git bundle.** Una volta a settimana, crea un bundle git completo (tutti i branch, storia completa). Rotazione: ultime 2 copie. Salta se esiste un bundle di meno di 7 giorni.

**Step 6: Albero directory.** Genera uno snapshot tree profondita'-3 nella directory docs del progetto, escludendo le directory di rumore.

**Step 7: Staging codice sicuro.** Esegue `git add -u` per i file tracciati, poi effettua lo stage dei file untracked uno per uno, saltando `.env`, `.p8`, `.pem`, `credentials` e `secrets/`. Non usa mai `git add -A`.

**Step 8: Export stato.** Scrive `/tmp/finish_state.json` con tutti i path, flag e risultati per la fase AI.

### Fase 2 — Intelligente (agenti AI, ~15–20 secondi)

**Step 9: Aggiornamento documentazione parallelo.** Quattro agenti Haiku partono simultaneamente, ciascuno con proprieta' esclusiva su un file:

- **Agent-STATUS**: Aggiorna `PROJECT_STATUS.md` con data sessione, ultimo commit, riassunto sessione, blockers.
- **Agent-TODO**: Sposta i task completati in una sezione COMPLETATI con date, aggiunge nuovi task scoperti durante la sessione.
- **Agent-CLAUDE**: Aggiorna la guida `CLAUDE.md` del progetto con nuove convenzioni, cambiamenti di stato o note strutturali.
- **Agent-MEMORY**: Salva memorie cross-sessione (decisioni architetturali, riassunti di contenuti esterni, feedback utente) nella directory memory del progetto.

**Step 10: Generazione commit message.** Una singola chiamata Sonnet analizza `git diff --cached --stat` e genera un commit message convenzionale (`feat:`, `fix:`, `refactor:`, `chore:`).

**Step 11: Commit e push.** Bash committa il codice (messaggio generato dall'AI), poi committa i doc separatamente con un messaggio fisso (`docs: update project docs via /finish`). Chiede all'utente conferma per il push.

**Step 12: Riepilogo.** Stampa un report strutturato: nome progetto, data, path/dimensione backup, path/dimensione bundle, stato di ogni file doc, hash commit, stato push e eventuali warning.

## Ottimizzazione multi-agente

Perche' quattro agenti paralleli invece di un singolo passaggio sequenziale?

**Costo.** I modelli Haiku costano ~60x meno di Opus. Quattro chiamate Haiku costano meno di una singola chiamata Opus che gestisce tutti e quattro i file.

**Velocita'.** Quattro agenti in parallelo completano nel tempo del piu' lento (~4–5 secondi), non nella somma di tutti e quattro (~16–20 secondi sequenziali).

**La proprieta' dei file previene conflitti.** Ogni agente possiede esattamente un file (o una directory, nel caso della memoria). Nessun agente legge o scrive sui file di un altro agente. Il commander (il prompt `finish.md` stesso) passa il contesto condiviso (git log, diff stat, riassunto sessione) a tutti gli agenti in anticipo. Questo elimina conflitti di merge, race condition e la necessita' di protocolli di coordinamento.

**La selezione del modello e' deliberata.** Gli aggiornamenti della documentazione sono task strutturati e poco creativi: leggi il diff, aggiorna una riga di stato, sposta un elemento TODO. Haiku gestisce bene questo lavoro. Il commit message riceve Sonnet perche' deve sintetizzare un diff in una frase significativa — leggermente piu' difficile, ma comunque non territorio Opus.

## Rete di sicurezza

Cosa succede se dimentichi `/finish`?

L'hook `session-end-safety.sh` si esegue ad ogni avvio di sessione Claude Code (configurato come hook SessionStart in `settings.json`). Fa:

1. Rileva il progetto corrente da `cwd` usando lo stesso lookup del registry di `finish.sh`.
2. Controlla se git e' abilitato per il progetto.
3. Esegue `git diff`, `git diff --cached` e controlla i file untracked.
4. Se esistono modifiche uncommitted, stampa un warning: `[session-end] WARNING: N uncommitted file(s) in project. Run /finish next session.`

Questo e' intenzionalmente un warning, non un auto-commit. Auto-committare alla fine della sessione e' pericoloso — il codice potrebbe essere in uno stato rotto, i test potrebbero non passare, e lo sviluppatore potrebbe non volere quelle modifiche committate. La rete di sicurezza ti assicura solo di saperlo.

## Confronto

| Funzionalita' | /finish | claude-sessions | Aider --commit | Cursor | Memory banks |
|---|---|---|---|---|---|
| Documentazione sessione | 4 file | Journal | No | No | No |
| Automazione commit git | Staged + msg | No | Per-edit | Solo msg | No |
| Backup (tar.gz) | Rotazione 3 | No | No | No | No |
| Git bundle | Settimanale | No | No | No | No |
| Memoria cross-sessione | Per-progetto | No | No | No | Si' |
| Protezione file sensibili | Filtro staging | N/A | No | No | N/A |
| Ottimizzato per token | Agenti Haiku | N/A | N/A | N/A | Varia |
| Funziona senza config | Marker walk-up | Si' | Si' | Si' | Varia |
| Comando singolo | Si' | No | Automatico | Automatico | No |

## Performance

Misurate su 50+ sessioni su progetti da 5 a 200 file.

### Prima dell'ottimizzazione (v1: Opus sequenziale)

```
Fase 1 (bash):            ~5 sec
Fase 2 (Opus, seriale):   ~80 sec
Totale:                    ~85 sec
Costo token:               ~100% pricing Opus
```

### Dopo l'ottimizzazione (v2: Haiku parallelo + Sonnet)

```
Fase 1 (bash):            ~4 sec
Fase 2 (4x Haiku):        ~5 sec (parallelo)
Fase 2 (1x Sonnet):       ~3 sec
Fase 2 (bash commit):     ~2 sec
Totale:                    ~14–23 sec
Costo token:               ~25% dell'originale
```

**Risultato: ~4x piu' veloce, ~75% piu' economico.**

## Portabilita'

L'architettura a due fasi e' tool-agnostica. La Fase 1 (`finish.sh`) e' puro bash — funziona con qualsiasi strumento che puo' eseguire comandi shell. La Fase 2 (`finish.md`) e' un template di prompt — adatta le istruzioni degli agenti per l'API multi-agente del tuo strumento.

Requisiti chiave:
- **Esecuzione shell**: lo strumento deve poter eseguire script bash
- **I/O file**: lo strumento deve poter leggere e scrivere file
- **Multi-agente o chiamate sequenziali**: agenti paralleli sono piu' veloci ma non obbligatori
- **Selezione modello**: opzionale; usa il modello piu' economico disponibile per gli aggiornamenti doc

Il protocollo non dipende da funzionalita' specifiche di Claude Code. La sintassi `/command` e' il sistema di slash command di Claude Code, ma la logica sottostante e' trasferibile.

## Setup

Vedi **[SETUP.md](SETUP.md)** per la guida completa di installazione passo-passo.

## Licenza

MIT

---

- `README.md` — English
- `README.it.md` — Italiano

Autore: M87
