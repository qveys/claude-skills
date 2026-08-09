# Step 1.6 — `release <session>` et sémantique `keep` sticky

Phase 1 · après step-1.5 · **Modèle : Sonnet**

## Objectif

Livrer la sous-commande `release <session>` (rendre une session sans la détruire) et la
sémantique `--keep` sticky : une session marquée keep n'est JAMAIS détruite par un
agent — `stop` y devient `release`.

## Contexte minimal (extraits spec v12, §3)

- **`release <session>`** : argument OBLIGATOIRE — pas de défaut `last-session` (avec
  une clé de run partagée, un sous-agent relâcherait sans le savoir la session courante
  de l'agent principal). Fonction interne `release_session()`, appelée aussi par le
  chemin `stop`-sur-keep. Effets :
  - supprime `last-session-<key>` si elle pointe cette session ;
  - session issue de `WSH_COCKPIT_ADOPT` → **rétrograde le claim en pré-claim**
    (clé réservée `released`, primitive mono-écrivain temp+`mv` de `claim.sh`, I4 :
    seule la clé propriétaire écrit) — ré-adoptable via l'étape 2 uniquement (donc
    avec sonde), jamais par le scan ;
  - session **créée** (hors ADOPT) → supprime le claim : retour au pool scannable
    (étape 3) ;
  - ne touche NI le tmux, NI le bloc Wave, NI `keep-<slug>`, NI `seq-<slug>` /
    `oneshot-ssh-<slug>` : fichiers *par session*, et le compteur de framing doit
    rester continu — le remettre à zéro ferait matcher au prochain adoptant un footer
    `└─[#N] exit` périmé du scrollback (`wait-done` menteur, `output` extrayant le
    mauvais segment).
- **`keep` est sticky (v12)** : `keep-<slug>` est une propriété de la SESSION (volonté
  de l'utilisateur), pas du claim. Il survit au `release` et à toute ré-adoption : un
  adoptant sans `--keep` d'une session marquée keep n'en prend jamais la pleine
  propriété — son `stop` voit le marqueur et passe par `release_session`, jamais
  `teardown_session`, quel que soit le détenteur du claim. Même règle pour une keep
  créée-relâchée reprise au scan. Le marqueur ne part que par l'hygiène `gc` (session
  morte — fiche 1.7).
- Qui POSE `keep-<slug>` : le wrapper (fiche 1.9). Ici : tout le chemin côté skill
  (lecture du marqueur par `stop`, `release`, stickiness).
- **Défaut (sans keep)** : `stop` détruit (comportement actuel, `teardown_session`) —
  la fenêtre pré-ouverte disparaît immédiatement, sans linger (décision actée).

## Tâches

- [ ] **RED d'abord** : cas `selftest-adopt` montrés rouges puis verts — `release` sans
      argument → erreur d'usage ; `release` par une clé non propriétaire → refus (I4) ;
      release d'une adoptée → claim `released`, ré-adoption étape 2 avec sonde, **par
      l'agent qui l'a relâchée aussi** ; release d'une créée → claim supprimé, session
      re-scannable ; **continuité du compteur `seq`** après release + ré-adoption
      (aucun match de footer périmé) ; keep sticky chemin 1 (adoptée sans `--keep`,
      `stop` ⇒ release, session et bloc vivants) ; keep sticky chemin 2 (keep
      créée-relâchée reprise au scan ⇒ keep hérité, `stop` ⇒ release) ; release par un
      sous-agent en fin de tâche (claim rétrogradé).
- [ ] Implémenter `release` (dispatch wsh-live.sh + `release_session()` dans
      session.sh ou claim.sh), le chemin `stop`-sur-keep, la stickiness.
- [ ] `selftest-guard` et les cas précédents de `selftest-adopt` restent verts
      (`stop` garde sa garde own-session, exit 8).

## Critère done

Cas ci-dessus verts (RED documenté), une session keep n'est détruite par AUCUN chemin
agent (prouvé sur les deux chemins), continuité `seq` prouvée, selftests existants verts.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.7`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
