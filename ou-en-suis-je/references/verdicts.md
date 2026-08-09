# Règles de verdict — /ou-en-suis-je

Le verdict se décide d'abord sur la **sortie de `collect.sh`** (colonnes FIN, TYPE_DERNIERE_ENTREE,
intr, TAG), jamais sur l'intuition d'un agent — c'est la classification initiale. Une disposition de
`dispositions.tsv` (Règle 0 ci-dessous) s'applique avant toute classification et impose son statut.
Sans disposition, le seul override explicite est OBSOLÈTE (voir plus bas), qui croise cette
classification avec l'état de la mémoire (fiches chantier). En cas de doute sur une ligne :
`tail -n 120 <fichier> | jq …` pour relire la vraie fin — ne jamais lire le fichier entier.

Les lignes commençant par `# AGG|` sont déjà agrégées par `collect.sh` (VIDE, AUTO_SECREVIEW,
PREWARM) : ne jamais les redécomposer session par session, lire directement leurs compteurs.
`--raw` désactive ce pré-tri (une ligne par session) si l'on doit déboguer `collect.sh` lui-même.

## Règle 0 — les dispositions de Quentin priment sur tout

Si `~/.claude/ou-en-suis-je/dispositions.tsv` contient une ligne pour la session
(`ID8 <tab> STATUT <tab> date <tab> note`), ce statut l'emporte sur toute déduction :
`CLOS` = ne jamais lister (déjà filtré par collect.sh) ; `ATTEND`/`REPRENDRE` = verdict
imposé, la note de Quentin remplace le « reste à faire » déduit. Ne JAMAIS re-déduire un
verdict contredisant une disposition — c'est le feedback explicite de l'utilisateur.

## Verdicts (dans cet ordre de test)

**Hors verdicts — `TYPE_DERNIERE_ENTREE=PARSE_ERROR`** : la dernière ligne du transcript est
illisible (ou le fichier est vide) ; ne pas juger cette ligne, ne pas la compter dans les
totaux de verdicts — la signaler à part (section ⚠️ du rendu) et relire la vraie fin du
fichier (`tail -n 120 <fichier> | jq`) avant tout classement.

### VIDE
- Pas de sujet ET pas de texte assistant en fin de fichier — c'est l'unique critère,
  appliqué par `collect.sh` lui-même.
- Depuis `collect.sh` v2 : ces sessions sont **déjà retirées** de la sortie par défaut et
  remontées en une seule ligne `# AGG|VIDE|total=N|ids=id1,id2,…` ; ne rien rejuger, lire le
  compteur (et les ids si un `dispose.sh` groupé est utile). `--raw` retrouve le détail
  session par session.
- Une ligne qui sort dans les données n'est jamais VIDE : `collect.sh` l'a déjà écartée sinon.
  Ne jamais redéduire VIDE à la main sur une ligne individuelle. En cas de doute, une petite
  TAILLE est au plus un indice pour un autre verdict (ex. À_REPRENDRE), jamais un critère VIDE.

### AUTO (agrégée, jamais une ligne de tableau par session)
- TAG = `AUTO_SECREVIEW` (reviews sécurité CI) ou `SIDECHAIN`.
- Depuis `collect.sh` v2 : les `AUTO_SECREVIEW` sans finding survivant sont **déjà
  pré-agrégées** par projet en
  `# AGG|AUTO_SECREVIEW|<projet>|total=N|conclues=X|a_examiner=Y|findings_listes=Z` ; ne pas
  les rejuger une par une, lire directement les compteurs. `--raw` désactive ce pré-tri pour
  déboguer `collect.sh` lui-même. `SIDECHAIN`, lui, n'est PAS pré-agrégé par le script (reste
  en lignes individuelles quand `--include-sidechains` est actif) et continue à s'agréger à la
  main en une ligne par repo : « N reviews — X conclues, Y interrompues ».
- **Exception à remonter individuellement** : un finding sécurité qui « survit » (« the finding
  survives », vulnérabilité confirmée) → `collect.sh` la laisse en ligne individuelle (comptée
  aussi dans `findings_listes` de l'agrégat de son projet) ; à mettre dans la section ⚠️.

### PREWARM (hors verdicts)
- Sessions générées par le LaunchAgent de préchauffage (sujet commençant par « Réponds
  uniquement: ok ») : `collect.sh` ne les liste jamais individuellement, seulement
  `# AGG|PREWARM|total=N`. Ne pas leur appliquer les règles ci-dessous, ne pas les faire
  figurer dans le tableau des sessions — elles sont TERMINÉE par construction (aucune action
  humaine possible dessus).

### À_REPRENDRE (⏸️ ou ❌)
Au moins un de ces signaux :
- FIN annonce une action encore à faire : « je relance… », « je passe maintenant à… »,
  « je vais d'abord… » — sans bilan derrière.
- Erreur terminale : « Request timed out », « api_error », réponse tronquée.
- `intr>0` sans message de clôture postérieur.
- FIN vide sur une session HUMAIN non triviale.
- FIN porte le marqueur `[FIN=USER : …]` : la session s'arrête sur un message utilisateur
  resté sans réponse (la demande citée dans le marqueur est le « reste à faire »).

**Rendu** : ❌ si le signal déclencheur est une erreur terminale (« Request timed out »,
« api_error », réponse tronquée) ; ⏸️ dans tous les autres cas (interruption `intr>0`, FIN
annonçant une action non faite, FIN vide). Si les deux signaux coexistent, ❌ l'emporte.

### ATTEND_QUENTIN (🟡)
- FIN se termine par une question qui **conditionne la suite** (« qu'est-ce que tu préfères ? »,
  « dis-moi comment procéder », « d'accord pour continuer ? »).
- Ou l'action restante est réservée à Quentin par ses règles : `git push` (règle never-push),
  review/merge de PR, déverrouillage 1Password, choix de design exprimé avec un doute
  (règle décision-avant-action-infra).

### OBSOLÈTE (⚪)
- Serait À_REPRENDRE ou ATTEND_QUENTIN, **mais** le sujet est couvert par une session plus
  récente ou par l'état de la mémoire (fiche chantier, tableau-de-bord-chantiers).
- C'est LE croisement qui demande du jugement : vérifier les fiches mémoire avant de classer
  quelque chose comme encore ouvert.

### TERMINÉE (✅)
- FIN est un bilan/clôture : « rien d'autre à faire », « c'est bouclé », « tu peux fermer »,
  récapitulatif final avec ✅.
- TYPE_DERNIERE_ENTREE = `file-history-snapshot` est un indice de fin de tour propre
  (pas une preuve à lui seul).
- Une question purement **optionnelle** (« si tu veux, je peux aussi… ») ne dégrade PAS le
  verdict : rester TERMINÉE et noter le reste en « optionnel ».

## Règles personnelles (décisions Quentin, 2026-07-13)

- Un commit local non poussé = TERMINÉE (le push est un choix, pas une dette — règle never-push).
  Les pushes en attente sont agrégés en UNE ligne récapitulative 🟡 en fin de rapport.
- Une question optionnelle sans réponse depuis **plus de 31 jours** = OBSOLÈTE d'office ;
  avant 31 jours, elle reste listée dans les restes optionnels.
- Sessions cosmétiques (vault Obsidian, CSS, mise en forme…) : **mêmes règles que les autres** —
  une question qui conditionne la suite est 🟡, même pour du cosmétique.
- Session qui délègue la suite à un cockpit tmux/Wave autonome = TERMINÉE ici, MAIS le rapport
  doit **vérifier l'état réel des cockpits** (`scripts/cockpits.sh`, lecture seule) et le rendre
  en section 🖥️ : tourne / terminé / bloqué sur quoi. Raison : une chaîne peut planter en silence
  sans qu'aucune session ne le voie (cas réel : tâche 09b bloquée sur « Please run /login »).
- Fenêtre par défaut : 7 jours. « ces derniers jours » sans précision = 7 ; adapter si demandé.
