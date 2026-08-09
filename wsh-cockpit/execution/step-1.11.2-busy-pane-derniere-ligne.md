# Step 1.11.2 — Garde busy-pane : mitigation « texte après le prompt »

Phase 1 · corrective issue de l'audit 1.11 (É2) · après step-1.11.1 · **Modèle : Sonnet**

## Objectif

Compléter la garde busy-pane de l'adoption avec la mitigation best-effort exigée par
la spec §2 : une commande en cours de frappe est indétectable par
`pane_current_command` — capturer la dernière ligne du pane et refuser l'adoption si
du texte suit le prompt ; documenter la limite.

## Contexte minimal (rapport d'audit É2)

- Aujourd'hui `adopt_pane_ready()` (session.sh:466-468) ne consulte que
  `mux_pane_command` via la prédicate pure `adopt_state_allowed()`. Aucune capture de
  dernière ligne ; la limite n'est documentée nulle part.
- ⚠️ Décision actée n°3 du chantier : **mesurer avant d'affirmer.** Le prompt réel de
  la machine est un zsh powerlevel-style AVEC segment droit (`❯ … ─╯` observé en
  session tmux pendant l'audit) : une heuristique naïve « du texte après le dernier
  caractère de prompt » refuserait TOUTES les adoptions. Première tâche = capturer de
  vraies dernières lignes de panes cockpit (prompt vide ; texte tapé sans Entrée ;
  après une commande) et calibrer sur ces mesures.
- Sens du best-effort : le refus ne vaut que si on RECONNAÎT un prompt avec du texte
  résiduel après lui ; une ligne qu'on ne sait pas classer ne doit PAS bloquer
  l'adoption (un faux positif rendrait des cockpits sains inadoptables — pire que la
  limite assumée). La limite (formes de prompt non reconnues, texte non détecté) se
  documente dans `docs/gotchas.md`.
- Architecture calquée sur l'existant : prédicate PURE sur chaîne (testable sans
  vrai pane, même raisonnement que `adopt_state_allowed`) + un seul point de câblage
  dans `adopt_pane_ready` (capture via le backend mux — attention au gotcha « cibler
  par session_id, pas par nom frais »). Échec de la capture elle-même → ne pas
  bloquer (best-effort, cohérent avec la philosophie fail-safe du dépôt).
- Le rollback sur refus existe déjà (`try_adopt_session` : pane non prêt →
  `claim_rollback`, adopt 11) — ne pas le dupliquer.

## Tâches

- [ ] Mesurer les dernières lignes réelles (session tmux jetable) : prompt au repos,
      `send-keys -l 'texte sans entrée'`, après exécution d'une commande. Consigner
      les formes observées en commentaire de la prédicate.
- [ ] **RED d'abord** : cas `selftest-adopt` sur la prédicate pure (prompt nu → ok ;
      prompt + texte tapé → refus ; ligne inclassable → ok/limite) + un cas réel :
      session avec texte tapé sans Entrée offerte à l'adoption → refusée, claim
      restauré à l'identique (calque du cas 11 busy-pane).
- [ ] Implémenter la prédicate + le câblage dans `adopt_pane_ready`.
- [ ] Documenter la limite dans `docs/gotchas.md` (formes non détectées, RPROMPT).
- [ ] `selftest-adopt` (en isolation), `selftest-guard`, `selftest-claim` verts.

## Critère done

Cas verts (RED documenté), un pane avec frappe en cours est refusé à l'adoption avec
claim restauré, un pane sain avec le prompt réel de la machine reste adoptable, la
limite est documentée.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.11.3`) → commit signé → push de la
branche → annoncer de taper `/exit`.
