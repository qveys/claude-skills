# Step 1.4 — Adoption (étape 2) : `WSH_COCKPIT_ADOPT`, sonde systématique, rollback

Phase 1 · après step-1.3 · **Modèle : Sonnet**

## Objectif

`spawn` sait adopter un cockpit pré-ouvert offert via `WSH_COCKPIT_ADOPT` : consommation
atomique du pré-claim, garde busy-pane élargie, sonde de situation systématique, rollback
no-clobber sur tout échec — insérée entre l'étape 1 (registre, fiche 1.3) et le scan.

## Contexte minimal (extraits spec v12, §2)

- **Candidates** : sessions de `WSH_COCKPIT_ADOPT` (liste `,`) vivantes portant un
  pré-claim (`user-preopen-*` ou `released`). **Ciblée** si un préfixe est demandé
  (préfixe enregistré égal ; non matché → étape 3 : un préfixe explicite ne va JAMAIS
  vers un cockpit arbitraire) ; **nominale** (première libre de la liste) uniquement
  sans préfixe. Une candidate libre **prime** sur toute `last-session` résiduelle hors
  registre.
- **Adopter = `claim_consume` + vérif de contenu (I2) + sonde + `claim_finalize`**
  (primitives fiche 1.2). Échec à n'importe quel stade → rollback (primitive `ln`/`rm`)
  et candidate suivante — jamais de claim conservé sans sonde réussie.
- **Garde busy-pane élargie** : avant la sonde, `mux_pane_command` (mux.sh:104-110)
  doit rapporter shell nu OU hop SSH (`ssh`, `tailscale`, `mosh`) — un pane pré-hoppé
  est un cas d'usage voulu (FIDO2 déjà donné). Mitigation best-effort : capturer la
  dernière ligne du pane, refuser si du texte suit le prompt (commande en cours de
  frappe indétectable par `pane_current_command` — limite documentée). Autres états
  (vim, less…) → rollback, suivante.
- **Sonde systématique et non optionnelle** : `hostname; pwd; whoami` + `remote-init`
  auto best-effort si hôte distant — comportement `--situate` appliqué d'office, en
  **framing auto-porté** (`WSH_LIVE_SEP_REINIT=1`, même mécanique que le probe de
  `remote-init` — wsh-live.sh:800/847 ; scénario : keep relâchée re-hoppée à la main
  dans le même run). Sortie : `adopted user cockpit: <sess>` puis la sonde.
- **Jamais adopter la session tmux hébergeant claude** : réutiliser la garde
  own-session du socle (`session_is_own`, session.sh:133-162) — refus, warning,
  fallback.
- **Session morte dans la liste** → warning stderr au premier constat seulement, mémo
  `adopt-warned-<key>@<slug>` (séparateur `@`, impossible dans clé/slug après leur
  `tr`), puis fallback.
- **Bloc et audit** : ne pas re-`open` si un client est déjà attaché (même logique que
  la réutilisation actuelle, wsh-live.sh:440-466) ; `audit_log_start` émis pour la
  session adoptée.
- Famine bornée assumée : une fenêtre `.won` peut durer `WSH_WAIT_TIMEOUT` (300 s
  défaut) ; les concurrents passent leur chemin.

## Tâches

- [ ] **RED d'abord** : cas `selftest-adopt` montrés rouges puis verts — adoption simple
      (avec sonde **prouvée exécutée**, pas déduite) ; course A/B sur une même candidate
      (un seul gagnant par comptage, le perdant passe à la suivante) ; rollback
      busy-pane (pane occupé par `less` → candidate suivante, pré-claim restauré) ;
      pane hoppé SSH adoptable ; refus de sa propre session ; session morte → warning
      une seule fois ; préfixe explicite non matché → création, jamais d'adoption
      nominale ; candidate libre prime sur `last-session` résiduelle.
- [ ] Implémenter l'étape 2 dans la résolution de `spawn` (entre registre et scan),
      avec les primitives de `claim.sh` uniquement.
- [ ] `WSH_COCKPIT_ADOPT` absent/vide → étape 2 inexistante (comportement inchangé).
- [ ] `selftest-guard` et `selftest-claim` restent verts.

## Critère done

Cas ci-dessus verts (RED documenté), la sonde est observée dans la sortie du selftest
d'adoption, aucun chemin ne conserve un claim après échec de sonde, selftests existants
verts.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.5`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
