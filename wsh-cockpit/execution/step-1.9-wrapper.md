# Step 1.9 — Le wrapper `claude-cockpit.sh` + `selftest-wrapper`

Phase 1 · après step-1.8 · **Modèle : Sonnet**

## Objectif

Livrer `wsh-cockpit/scripts/claude-cockpit.sh` — le geste utilisateur tout-en-un qui
pré-ouvre les cockpits puis lance claude — avec son `selftest-wrapper` (claude mocké),
et l'exposer dans le PATH.

## Contexte minimal (extraits spec v12, §1)

```bash
claude-cockpit [cockpit-1] [--and cockpit-2]... [-- args-claude]
# groupe = [prefix] [--keep] [+ tout flag de spawn relayé tel quel : --tab, --pre, …]
```

1. **Par groupe** (séparé par `--and`) : appel `wsh-live.sh spawn <opts>` ; `--keep` est
   extrait (marqueur `keep-<slug>` posé sitôt le nom de session connu), TOUT le reste
   est relayé tel quel (pass-through futur-proof, `--tab` compris).
   - **Isolation de clé obligatoire** : chaque spawn tourne sous
     `WSH_COCKPIT_AGENT=user-preopen-<n>` (n = index du groupe) + flag interne
     `--preopen` — portée limitée à l'appel de spawn, **jamais exportée vers claude**
     (sinon `last-session-default` court-circuiterait claim et sonde).
   - **`--force` systématique** : cockpits neufs à chaque run, jamais de réutilisation
     inter-runs. Le pré-claim est posé par le spawn lui-même (création = claim du
     créateur, fiches 1.2-1.3) — aucune fenêtre où un autre claude saisirait la session.
   - **Parsing — refus avec erreur claire** : valeur d'option contenant littéralement
     `--and` ou `--` ; deux groupes de même préfixe (l'étape 1 du registre ne saurait
     les distinguer).
2. **Puis** : `export WSH_COCKPIT_ADOPT=sess1[,sess2...]` et
   `export WSH_COCKPIT_AGENT=claude-<runid>` (runid = horodatage+pid du wrapper) ;
   **unset `WSH_COCKPIT_PREFIX`** (pour ses spawns comme dans l'environnement transmis —
   `normalize_prefix` la consulte AVANT `WSH_COCKPIT_AGENT`, session.sh:47-59) ; lance
   `claude [args après --]` **en avant-plan — pas `exec`**. À la sortie normale :
   balayage — `stop` de toute session vivante au claim `claude-<runid>` ou
   `user-preopen-<n>` non-keep, `release` des keep. Un crash du wrapper = un crash de
   claude : fenêtres laissées ouvertes jusqu'à fermeture manuelle (assumé — `gc` ne tue
   jamais une session attachée).
3. **Un spawn échoue → claude n'est PAS lancé.** Erreur claire ; les cockpits déjà
   ouverts restent visibles pour diagnostic (pas de rollback automatique).

Exposition PATH (§1) : lien symbolique `~/.local/bin/claude-cockpit` si ce dossier est
déjà dans le PATH, sinon alias dans `~/.zshrc` — **constater à l'implémentation, dans
cet ordre de préférence** ; ne modifier `~/.zshrc` qu'avec accord explicite du pilote
(sinon documenter la commande d'installation dans SKILL.md et s'arrêter là).

## Tâches

- [ ] **RED d'abord** : `selftest-wrapper` (claude mocké par un stub dans le PATH du
      test qui journalise env + args) montré rouge puis vert — parsing des groupes
      `--and` ; extraction `--keep` vs pass-through (dont `--tab`) ; refus valeur
      contenant `--and`/`--` ; refus deux groupes de même préfixe ; contenu exact de
      `WSH_COCKPIT_ADOPT` et `WSH_COCKPIT_AGENT=claude-<runid>` vus par le stub ;
      `WSH_COCKPIT_PREFIX` absent de l'environnement du stub ; clés `user-preopen-<n>`
      jamais dans l'environnement du stub ; abort sans lancement de claude si un spawn
      échoue ; balayage de sortie (non-keep stoppées, keep relâchées) après sortie
      normale du stub.
- [ ] Implémenter `claude-cockpit.sh` (bash 3.2, `set -euo pipefail`, tableaux
      potentiellement vides via `${ARR[@]+"${ARR[@]}"}`).
- [ ] Exposition PATH selon le constat (symlink préféré).
- [ ] `selftest-guard`, `selftest-claim`, `selftest-adopt` restent verts.

## Critère done

`selftest-wrapper` vert (RED documenté), un scénario bout-en-bout en session jetable
(2 groupes dont un `--keep`, stub claude) laisse l'état attendu : sessions non-keep
détruites, keep vivante et relâchée, aucun marqueur orphelin. Selftests existants verts.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.10`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
