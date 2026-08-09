# Step 1.7 — `gc` : sessions keep épargnées, passe d'hygiène des marqueurs, `doctor`

Phase 1 · après step-1.6 · **Modèle : Sonnet**

## Objectif

`gc` respecte les sessions keep, nettoie tous les marqueurs orphelins (claims, keep,
`.won`, et les fichiers d'état par session) sans jamais raser l'état d'une session
vivante, et `doctor` signale les claims probablement oubliés.

## Contexte minimal (extraits spec v12, §3)

- **Sessions keep** : `gc` ignore la session tant qu'un client y est attaché (règle
  existante : `gc_should_kill`, gc.sh:21-38 — jamais tuer une session attachée) ; une
  keep **détachée** (bloc Wave fermé — geste naturel de fin) ET idle > 24 h retombe
  dans le balayage normal — sinon deadlock : une session que « seul l'utilisateur
  ferme » ne mourrait jamais. `gc` ne balaie toujours que `^cockpit-` (gc.sh:98) et
  saute sa propre session (acquis lot 2).
- **Passe d'hygiène des marqueurs** — tout marqueur dont la session est morte est
  supprimé :
  - **Placement fail-safe** : listing FIABLE exigé — `mux_list_sessions`
    (mux.sh:30-33) du backend courant (tmux OU zellij, jamais un appel tmux direct)
    avec **rc=0** ; échec transitoire ≠ zéro session (« never act on uncertain
    state », gc.sh:60). Sous zellij sans serveur, la passe ne tourne pas — assumé.
  - Correspondance marqueur↔session : slugifier les noms des sessions VIVANTES (même
    fonction de slug que l'écriture), supprimer tout marqueur dont le slug n'apparaît
    pas — jamais de dé-slugification.
  - Périmètre : `adopt-claim-*`, `keep-*`, `last-session-user-preopen-*`,
    `last-session-claude-*` (un fichier par run — accumulation sans borne sinon),
    `seq-`, `oneshot-ssh-`, `pane-` (zellij), `tab-`, `block-`, `cm-`, `prefix-` de
    sessions mortes. **Pas de `rm` sec pour `block-` et `cm-`** : tenter d'abord
    `block_id_close` (wave.sh:149-158) et `ssh -O exit` (best-effort).
  - **Seuil d'âge anti-course : ignorer tout marqueur < 5 min** (fenêtres transitoires
    d'écriture multi-fichiers ; `gc` part en arrière-plan à chaque spawn —
    wsh-live.sh:425,503 — y compris pendant la rafale `--and` du wrapper).
  - **Passe dédiée `.won-<pid>`** (adoptant crashé entre rename et écriture) —
    conditions CUMULATIVES : pid mort (`kill -0` en échec) ET âge >
    2×`WSH_WAIT_TIMEOUT` (600 s défaut ; une sonde légitime peut durer 300 s — le
    seuil 5 min serait exactement la fenêtre de course). Session vivante →
    restauration en pré-claim par la primitive no-clobber `ln`/`rm` (fiche 1.2, I1) ;
    morte → suppression. Le balayage générique `adopt-claim-*` **ignore les
    `.won-*`** (leur « slug » apparent ne matche aucune session — un `rm` naïf
    dé-claimerait une session vivante).
  - `adopt-warned-<key>@<slug>` : hygiène par âge — slug mort ET > 24 h.
- **`teardown_session`** nettoie déjà claim + `prefix-` (fiche 1.3) — cette passe
  couvre ce que teardown ne voit jamais : keep fermée à la main, crash de claude.
- **`doctor`** (lib/doctor.sh) : signaler, informatif seulement, les claims dont la clé
  n'a plus d'activité récente — candidats au `release` oublié d'un sous-agent.

## Tâches

- [ ] **RED d'abord** : cas de selftest (dans `selftest-gc` ou `selftest-adopt`, suivant
      le pattern existant) montrés rouges puis verts — marqueur frais (< 5 min) JAMAIS
      mangé même session morte ; marqueurs orphelins balayés (claim, keep, prefix,
      last-session de run) ; `.won` de pid mort restauré (session vivante) / purgé
      (morte) ; `.won` récent ou pid vivant intact ; balayage générique n'avale pas les
      `.won-*` ; listing en échec → passe inerte (aucune suppression) ; keep attachée
      épargnée, keep détachée idle > 24 h balayée ; `gc` ne touche pas sa propre
      session (non-régression cas 23 existant).
- [ ] Implémenter la passe d'hygiène dans gc.sh, la règle keep dans
      `gc_should_kill`/`cmd_gc`, l'ajout `doctor`.
- [ ] Les manipulations de fichiers de test restent dans un `HOME`/cache de test ou à
      préfixe dédié — jamais les vrais marqueurs de l'utilisateur.
- [ ] `selftest-gc`, `selftest-guard`, `selftest-claim`, `selftest-adopt` verts.

## Critère done

Cas ci-dessus verts (RED documenté), la passe ne supprime JAMAIS rien sur listing
douteux ni marqueur frais (prouvé), keep épargnée/balayée selon la règle 24 h,
selftests existants verts.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.8`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
