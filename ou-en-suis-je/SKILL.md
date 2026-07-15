---
name: ou-en-suis-je
description: >-
  Utilise ce skill dès que Quentin veut faire le point sur son travail récent
  avec Claude Code : savoir ce qui est terminé, ce qui reste ouvert,
  interrompu, bloqué ou en attente d'une action de sa part (push, review,
  réponse), toutes sessions et tous projets confondus — y compris l'état des
  chaînes tournant dans les cockpits tmux/Wave autonomes. Déclenche-le quand
  il a perdu le fil (« où en suis-je ? », « je ne sais plus où j'en étais »),
  quand il demande un bilan, un récap ou un point sur ses
  sessions/conversations de la période, ou quand il veut vérifier que rien ne
  traîne ni n'est resté bloqué avant de passer à autre chose (fin de journée,
  week-end). Ne pas utiliser pour : les statistiques de coûts/tokens (plugin
  session-report), l'avancement d'un seul chantier ou projet précis, un run
  CI, le simple listing des sessions tmux actives, ou le diagnostic de
  performance d'une session en cours.
---

# /ou-en-suis-je — récap de l'état de toutes les sessions

## Principe (leçon du 2026-07-12)

Deux sous-agents à qui on demande de « juger » librement des sessions divergent sur plus de la
moitié des verdicts. Ce skill sépare donc strictement :

1. **Extraction déterministe** — des scripts figés, jamais d'improvisation ;
2. **Jugement** — des règles écrites, appliquées sur la sortie des scripts.

Ne JAMAIS lire un `.jsonl` de session en entier (certains font 8 Mo). Ne JAMAIS demander à un
agent un verdict sans lui donner les règles verbatim.

Les commandes ci-dessous sont relatives au dossier du skill (annoncé à l'invocation).

## Étapes

1. **Fenêtre.** Défaut 7 jours ; si Quentin précise (« depuis lundi », « sur 2 jours »), adapter
   `--days`.

2. **Extraction.**
   ```bash
   scripts/collect.sh --days 7 --exclude <id8>
   ```
   Une ligne par session : `PROJET|ID8|DERNIERE_ACTIVITE|TAILLE|TYPE_DERNIERE_ENTREE|intr=N|TAG|SUJET|…FIN`.
   La sortie est **pré-triée** : les reviews CI (`AUTO_SECREVIEW`), les préchauffages
   (`PREWARM`, LaunchAgent) et les sessions vides (ni sujet ni texte assistant) ne sortent plus
   en lignes individuelles — elles sont comptées et regroupées en lignes d'agrégat `# AGG|…` en
   fin de sortie ; seuls les findings sécurité qui « survivent » restent en ligne individuelle
   (à reporter dans la section ⚠️). Options : `--project SUBSTR` (filtrer un projet), `--exclude
   ID8` (écarter la session courante : son UUID apparaît dans le chemin du scratchpad de
   session), `--include-sidechains`, `--raw` (désactive le pré-tri : une ligne par session,
   aucune ligne `# AGG` — utile pour déboguer `collect.sh` lui-même).

3. **Verdicts.** Lire `references/verdicts.md` et appliquer les règles sur chaque **ligne de
   données restante** (celles qui ne commencent pas par `# AGG|`), dans l'ordre (VIDE → AUTO →
   À_REPRENDRE → ATTEND_QUENTIN → OBSOLÈTE → TERMINÉE). Les lignes `# AGG|AUTO_SECREVIEW|…` et
   `# AGG|VIDE|…` sont déjà pré-agrégées par `collect.sh` : ne pas les rejuger une par une, se
   recopier telles quelles dans les sections AUTO/vides du rendu avec leurs compteurs
   (total/conclues/a_examiner/findings_listes ou total/ids) ; `# AGG|PREWARM|…` n'entre dans
   aucun tableau de sessions.
   - ≤ ~60 lignes HUMAIN : juger soi-même directement.
   - Au-delà : déléguer par lots à **2 scouts maximum en parallèle**, en collant dans leur prompt
     les règles VERBATIM et leurs lignes brutes (jamais les chemins de fichiers seuls) ; consolider
     ensuite et arbitrer soi-même toute incohérence en relisant la fin du fichier concerné
     (`tail -n 120 … | jq`).

4. **Croisement mémoire.** Avant de classer une session « ouverte », vérifier
   `tableau-de-bord-chantiers` et les fiches chantier : une attente couverte par une session ou
   une fiche plus récente devient OBSOLÈTE. La session courante est toujours EN_COURS (l'exclure
   des tableaux).

5. **Cockpits autonomes.** Une session peut être close alors que le vrai travail continue dans
   un tmux/Wave autonome — et y planter en silence (cas réel : chaîne bloquée sur « Please run
   /login » qu'aucune session ne voyait). Donc :
   ```bash
   scripts/cockpits.sh
   ```
   Lecture seule (capture-pane) — ne JAMAIS envoyer de touches à un cockpit depuis ce skill.
   Classer chaque cockpit vivant : **tourne** / **terminé** / **bloqué sur X** (citer la ligne
   fautive du pane).

6. **Rendu** — format validé par Quentin (revue du 2026-07-13) ; le suivre précisément :

   ```text
   # 📋 Où en suis-je ? — <période couverte>

   **Réponse courte en gras** (ex. « Non, pas tout : 1 échec, 3 attentes ») + compteurs :
   N sessions relevées (X humaines, Y reviews CI, Z cockpits), fenêtre et périmètre
   explicites, session courante exclue.

   Légende : ✅ aboutie · 🟡 partielle / attend Quentin · ⏸️ interrompue · ❌ échec · ⚪ obsolète

   ## 📅 Sessions, jour par jour        ← un bloc ### par jour, ordre chronologique
   ### <Jour JJ/MM>
   | Session | Projet | Chantier / tâche | Verdict | Reste à faire |
   (lignes = uniquement les sessions 🟡 ⏸️ ❌ ; puis UNE ligne de synthèse par jour :
   « ✅ N terminées — chantiers : mémoire centralisée, wsh-cockpit-optim… » ; ⚪ idem en synthèse)

   ## 🖥️ Cockpits autonomes             ← tableau Cockpit | État (tourne / terminé / bloqué sur X)
   ## ⚠️ À ne pas perdre                 ← findings sécurité survivants, dettes signalées
   (ces deux sections couvrent ce qui n'est PAS une session — travail vivant hors transcripts,
   dettes transversales ; les garder courtes et les OMETTRE entièrement si elles sont vides)
   ## ⚡ À faire maintenant              ← liste numérotée par priorité (consolidation des
      « Reste à faire »), en séparant « je peux le lancer pour toi » de « action à toi »
      (pushes git agrégés en un seul item)

   *Généré le <date> via collect.sh/cockpits.sh ; fenêtre N jours ; verdicts : references/verdicts.md.*
   ```

   Pourquoi ces choix (feedback explicite de Quentin) : le tri par date en tableaux journaliers
   avec légende émoji est le format qu'il préfère lire ; les sessions ✅ terminées ne
   l'intéressent pas en détail — leur compte et les chantiers couverts suffisent, jamais une
   ligne par session terminée ; et il veut repartir avec des propositions d'action immédiates,
   pas seulement un état des lieux.

7. **Feedback (partie intégrante du skill).** Après le rendu, inviter Quentin à statuer sur
   chaque 🟡/⏸️/❌ (AskUserQuestion ou réponse libre), et enregistrer CHAQUE retour :
   ```bash
   scripts/dispose.sh ID8 CLOS|ATTEND|REPRENDRE "note"
   ```
   - `CLOS` (fait, caduc, abandonné, traité hors Claude) → filtré dès `collect.sh`, ne
     réapparaîtra plus jamais dans un récap.
   - `ATTEND` / `REPRENDRE` → la session reste listée, avec la note de Quentin en contexte.
   Avant de juger (étape 3), lire `~/.claude/ou-en-suis-je/dispositions.tsv` s'il existe :
   les dispositions priment sur les règles de verdict (les notes ATTEND/REPRENDRE remplacent
   le « reste à faire » déduit). C'est cette boucle qui empêche le récap de se tromper deux
   fois sur la même session.

8. **Clôture.** Proposer (sans le faire d'office) de mettre à jour la fiche mémoire
   `tableau-de-bord-chantiers` avec les 🔴/🟡. Si Quentin veut aussi l'angle coûts/tokens,
   proposer le plugin `session-report` (rapport HTML d'usage) — ne pas le lancer d'office.

## Pièges connus

- Le lot d'un scout doit être fermé : lui donner SES lignes, pas la liste complète des fichiers
  (le 2026-07-12, un scout a débordé et analysé les deux lots → contradictions).
- `TYPE_DERNIERE_ENTREE=file-history-snapshot` ≈ tour fini proprement, mais le contenu de FIN
  prime toujours.
- Les mentions `@chemin` dans les rapports d'agents peuvent déclencher des lectures automatiques
  de fichiers — ne pas s'en étonner, ne pas en tenir compte.
- Sessions « Review this change for security vulnerabilities » = CI, jamais des conversations.
- `cockpits.sh` est strictement en lecture : si un cockpit est bloqué, le **signaler** dans le
  rapport, ne pas tenter de le débloquer (ça peut exiger une action de Quentin, ex. /login).
