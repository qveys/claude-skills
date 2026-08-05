#!/usr/bin/env bash
# Relais de sessions d'un chantier (skill chantier-relais) — générique, aucun projet en dur.
# Boucle : lit « NEXT: » dans STATE.md → lance claude avec le modèle exigé par
# la fiche → quand le pilote quitte la session (/exit), relance pour l'étape
# suivante. S'arrête sur NEXT: PAUSE, NEXT: FIN, fiche introuvable, erreur de
# lancement de claude, ou Ctrl+C.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/.." || exit 1
command -v claude >/dev/null 2>&1 || { echo "■ claude introuvable dans le PATH — relais impossible."; exit 1; }

# Nom du chantier : titre de STATE.md (« # STATE — chantier <NOM> »), sinon le dossier projet.
chantier=$(sed -n '1s/^# *STATE *[—-]* *\(chantier \)\{0,1\}//p' "$DIR/STATE.md")
[ -n "$chantier" ] || chantier=$(basename "$PWD")

while :; do
  next=$(grep -m1 '^NEXT:' "$DIR/STATE.md" | awk '{print $2}')
  case "${next:-}" in
    "" | PAUSE | FIN)
      echo "■ Relais arrêté (NEXT: ${next:-absent})."
      break
      ;;
  esac

  fiche=$(ls "$DIR/$next"-*.md 2>/dev/null | head -1)
  if [ -z "$fiche" ]; then
    echo "■ Fiche introuvable pour « $next » — arrêt du relais."
    break
  fi

  model=$(grep -m1 'Modèle :' "$fiche" | sed -E 's/.*Modèle : ?\**([A-Za-z]+).*/\1/' | tr '[:upper:]' '[:lower:]')
  case "$model" in sonnet | opus | haiku | fable) ;; *) model=sonnet ;; esac

  echo ""
  echo "▶ $next · modèle : $model · fiche : $(basename "$fiche")"
  echo "  Ctrl+C dans les 5 s pour interrompre le relais."
  sleep 5 || break

  claude --model "$model" "Chantier $chantier — session d'exécution lancée par le relais (skill chantier-relais). Lis execution/CONVENTIONS.md, execution/STATE.md puis la fiche execution/$(basename "$fiche"), et exécute UNIQUEMENT cette fiche. À la fin : mets à jour STATE.md (statut, ligne NEXT, décisions, bloqueurs), commit et push selon les conventions du chantier, puis annonce au pilote qu'il peut taper /exit pour passer le relais." || {
    echo "■ claude s'est terminé en erreur — arrêt du relais."
    break
  }
done
