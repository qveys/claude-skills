# Conventions d'exécution — chantier claude-cockpit-wrapper

Source maîtresse : `docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md` (v12),
amendée par `execution/findings-revue-spec-v11.md` (5 findings de revue, prérequis du plan).
Les fiches `step-X.Y` n'en copient que le strict nécessaire.

## Rituel de session (obligatoire)

1. Charger UNIQUEMENT, dans cet ordre : `CONVENTIONS.md` (ce fichier) + `STATE.md` + la fiche
   `step-X.Y` courante.
2. **Contrôle modèle** (filet — le relais lance normalement le bon) : comparer le modèle actif à
   la ligne « Modèle : » de la fiche ; mismatch → s'arrêter et demander `/model <bon modèle>`.
3. Exécuter la fiche. Ne pas déborder sur l'étape suivante, même si « il ne reste qu'un petit
   truc ».
4. Fin de session : mettre à jour `STATE.md` (statut, **ligne `NEXT:`**, décisions, bloqueurs),
   commit, push, puis **annoncer de taper `/exit`** (hors relais : `/clear`).

## Relais entre sessions — `execution/next.sh`

Boucle NEXT → modèle de la fiche → `claude --model …` → `/exit` du pilote → étape suivante.
S'arrête sur `NEXT: PAUSE`, `NEXT: FIN`, fiche introuvable, ou Ctrl+C. Filet : une session morte
sans mise à jour de NEXT → la même fiche est rejouée (les fiches restent rejouables).

## Règles non négociables

- Commits **signés** (`git commit -S`), messages en français, **AUCUNE attribution IA**
  (pas de Co-Authored-By, pas de « Generated with »). Jamais `--no-gpg-sign`.
  ⚠️ La signature passe par l'agent SSH 1Password : **l'app 1Password doit être ouverte et
  déverrouillée**, sinon `failed to write commit object` — c'est LE blocage récurrent du
  chantier. Si ça échoue : `NEXT: PAUSE` + bloqueur dans STATE.md demandant d'ouvrir 1Password.
- Branche de travail : `feat/claude-cockpit-wrapper`. `git push` de la **branche** en fin de
  session (rituel). **Jamais de push sur `main`** : `main` exige une PR (ruleset : signatures,
  revue Copilot, résolution de tous les fils de revue ; merge commits autorisés). La PR de fin
  de lot est une fiche dédiée en fin de chaîne.
- bash 3.2 (macOS) : pas de tableaux associatifs, `set -euo pipefail`, `${TMUX:-}`/`${TMUX_PANE:-}`,
  idiome `${ARR[@]+"${ARR[@]}"}` pour les tableaux potentiellement vides.
- tmux : JAMAIS de `kill-session` sans cible explicite ancrée `-t "=nom"`, JAMAIS de
  `kill-server`. Sessions de test à préfixe dédié, nettoyées par `trap … EXIT`. Les selftests
  se lancent depuis une session tmux **jetable** (`new-session -d` + `send-keys` non ancré +
  fichier de sortie), jamais depuis le terminal réel de l'utilisateur.
- TDD RED-first pour tout comportement nouveau : montrer le test rouge avant le fix, le dire
  dans STATE.md ou le rapport de la fiche.
- Ne pas affaiblir les gardes des lots 1-2 (`session_is_own`, `deny_own_session`,
  `looks_like_session`, ancrage `=`) : toute modification passe par un cas de selftest qui
  échoue d'abord. `selftest-guard` (41 cas) doit rester vert à chaque fin de fiche qui touche
  `scripts/`.

## Modèle par session

Pas d'opusplan : le blueprint est payé au découpage, chaque fiche EST le plan.
| Cas | Modèle |
|---|---|
| Défaut (implémentation au contrat clair, mécanique compris) | Sonnet |
| Fiches de jugement (plan, audit, arbitrage qui redécoupe) | Fable |
| Blocage réel en cours de session | Consigner dans STATE.md, escalader, redescendre |

⚠️ Ne JAMAIS mettre « Modèle : Haiku » sur une fiche : Haiku n'est pas disponible en
« auto mode on » sur cette machine — le mécanique pur reste sur Sonnet.

## Décisions actées (ne PAS re-questionner)

1. Les 5 findings de `execution/findings-revue-spec-v11.md` sont des **prérequis** : la spec est
   amendée (v12) avant/pendant le plan, pas après coup.
2. Le wrapper s'appuie sur les primitives des lots 1-2 (gardes own-session exit 8, échec fort
   exit 4, flag `--session`/`-s`, `mux_session_name`/`mux_session_panes`) — il ne les réimplémente
   pas.
3. Sémantique « = » de tmux : mesurée commande par commande dans `docs/gotchas.md` — mesurer
   avant d'affirmer, ne jamais déduire (3 erreurs « par déduction » déjà payées au lot 1).
4. `gc` ne balaie que `^cockpit-` ; une session attachée n'est jamais candidate ; `gc` saute sa
   propre session.
5. Les artefacts de chantier volumineux (rapports de fiche) vont dans `execution/`, pas dans
   `docs/` ; `docs/` ne reçoit que ce qui sert le skill livré.
