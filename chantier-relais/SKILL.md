---
name: chantier-relais
description: Transforme un plan ou gros projet en chantier exécutable par sessions Claude courtes et autonomes — fiches d'étapes autoportantes à petit contexte, relais automatique entre sessions (next.sh) avec le bon modèle par étape, et pilotage à distance (tailscale ssh, tmux, iPhone). Utiliser dès que l'utilisateur veut découper un plan en étapes exécutables par petites sessions, mentionne « chantier », « relais », « fiches d'exécution », « une étape par session », « /clear entre chaque étape », veut router le modèle (Sonnet/Opus/Haiku) étape par étape, ou veut suivre/piloter un projet multi-sessions à distance. S'applique aussi quand un plan existant est trop gros pour une seule session Claude.
---

# Chantier-relais — plan d'abord, exécution par fiches, relais automatique

## L'idée en une phrase

On paie le **plan une seule fois** avec le gros modèle (le découpage en fiches), puis chaque fiche s'exécute dans une **session Claude fraîche à petit contexte** (~3 k tokens au lieu de 15 k+), lancée automatiquement par un **script relais** avec le modèle exigé par la fiche — le `/exit` de l'humain est le passage de témoin.

Pourquoi ça marche :
- Un agent ne peut ni quitter sa session ni taper dans son propre terminal → le relais tourne **autour** des sessions, pas dedans.
- Pas d'opusplan : chaque fiche EST le plan — re-planifier à chaque session doublonnerait le travail déjà payé.
- Les fiches sont **rejouables** : une session qui meurt sans finir est simplement relancée sur la même fiche.

## Phase A — Le découpage (une fois, gros modèle)

Créer dans le projet un répertoire `execution/` :

```
execution/
├── CONVENTIONS.md   # invariants : rituel de session, règles, décisions actées
├── STATE.md         # tracker : ligne machine « NEXT: », tableau d'avancement, bloqueurs, journal
├── next.sh          # le relais (copier scripts/next.sh de ce skill, chmod +x)
└── step-X.Y-<slug>.md  # une fiche = une session
```

Gabarits complets : lire `references/templates.md` au moment de générer ces fichiers.

Règles de découpage (l'essentiel) :
- **Une fiche = un livrable vérifiable** en une session. Si une phase contient 8 cases dont 3 sont des chantiers, c'est 4-6 fiches, pas une.
- Chaque fiche est **autoportante** (~1-2 k tokens) : objectif en une phrase, contexte minimal (extraits de la doc maîtresse limités aux éléments touchés — jamais la doc entière), tâches, **critère done vérifiable**, rituel de fin.
- En-tête de fiche : `Phase X · après Y · **Modèle : Sonnet|Opus|Haiku**` — le relais lit cette ligne pour choisir le modèle. Défaut Sonnet ; gros modèle uniquement pour les fiches de jugement (audit, arbitrage qui redécoupe le plan) ; escalade ponctuelle sur blocage réel, consignée dans STATE.md.
- `STATE.md` porte la ligne machine `NEXT: step-X.Y | PAUSE | FIN` — mise à jour en fin de CHAQUE session. `PAUSE` = bloqué sur une action humaine (le relais s'arrête proprement) ; c'est la discipline qui rend le pilotage à distance fiable.
- Figer dans `CONVENTIONS.md` les **décisions déjà actées** pour qu'un agent frais ne les re-questionne pas, et le **rituel** : charger STATE + CONVENTIONS + la fiche courante, RIEN d'autre ; ne pas déborder sur l'étape suivante ; fin = mettre à jour STATE (dont NEXT), commit, push, annoncer `/exit`.

## Phase B — Le relais

`execution/next.sh` (fourni dans `scripts/next.sh`, générique, aucun paramétrage) boucle :

1. lit `NEXT:` dans STATE.md → s'arrête sur `PAUSE`/`FIN`/fiche introuvable ;
2. extrait le modèle de la ligne « Modèle : » de la fiche ;
3. compte à rebours 5 s (Ctrl+C = interrompre la chaîne) ;
4. lance `claude --model <modèle> "<kickoff>"` — le kickoff dit à l'agent quoi lire, quoi exécuter, et de finir par la mise à jour de STATE + l'annonce `/exit` ;
5. au `/exit` de l'humain, reboucle pour l'étape suivante.

Lancement : `./execution/next.sh` depuis la racine du projet — idéalement dans une session tmux visible (skill **wsh-cockpit** : `spawn` + `send`, bannières obligatoires), pour que l'humain regarde en direct et que tout soit journalisé.

⚠️ Si la machine wrappe ses blocs Wave en tmux avec un GC (`tmux-wave-gc.sh`), ne JAMAIS `link-window` la session du relais dans un groupe `wave-*` : le GC détruit les fenêtres au nom inconnu, et tuer une fenêtre liée emporte la session entière.

## Phase C — Pilotage à distance

Tout l'état vit dans deux endroits accessibles à distance : **STATE.md** (fichier) et **le pane tmux** du relais. Le script `scripts/relay-ctl.sh` de ce skill les pilote — localement ou via `tailscale ssh` depuis n'importe quelle machine du tailnet (Mac, iPhone avec Termius/app Tailscale) :

```bash
RC=~/.claude/skills/chantier-relais/scripts/relay-ctl.sh
$RC status --dir <projet>          # NEXT, session tmux, ce qui tourne, dernières lignes
$RC watch [n] --dir <projet>       # voir le pane (n lignes)
$RC set step-0.2 --dir <projet>    # changer NEXT (aussi: PAUSE, FIN)
$RC go --dir <projet>              # (re)lancer le relais — refuse si claude tourne déjà
$RC say "réponse à la question" …  # répondre à la session Claude en cours — refuse si c'est un shell
$RC exit --dir <projet>            # envoyer /exit → passage de relais à distance
$RC stop --dir <projet>            # Ctrl+C (interrompre relais/session)

# Depuis une autre machine :
tailscale ssh <user>@<host> '~/.claude/skills/chantier-relais/scripts/relay-ctl.sh status --dir <projet>'
```

Les gardes de `say`/`exit`/`go` (shell vs claude au premier plan) évitent le pire du pilotage aveugle : injecter du texte dans un shell ou une commande dans un chat. Pour le détail (vue navigateur lecture seule via ttyd + `tailscale serve` — jamais funnel —, usage iPhone, sécurité), lire `references/remote-control.md`.

## Anti-patterns

- Charger la doc maîtresse entière en session d'exécution (c'est tout l'intérêt des fiches de l'éviter).
- opusplan ou re-planification par session — le plan est déjà payé.
- Fiches non rejouables (effets de bord non idempotents sans garde) — le filet « session morte → relance la même fiche » en dépend.
- Oublier `NEXT:` en fin de session — le relais rejouerait la fiche terminée ; le kickoff le rappelle, le rituel de CONVENTIONS.md aussi.
- `link-window` dans un groupe géré par un GC (cf. Phase B).
