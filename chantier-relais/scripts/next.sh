#!/usr/bin/env bash
# Relais de sessions du chantier Agentic OS.
# Boucle : lit « NEXT: » dans STATE.md → lance claude avec le modèle exigé par
# la fiche → quand Quentin quitte la session (/exit), relance pour l'étape
# suivante. S'arrête sur NEXT: PAUSE, NEXT: FIN, fiche introuvable, ou Ctrl+C.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR/.." || exit 1

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

  claude --model "$model" "Chantier Agentic OS — session d'exécution lancée par le relais. Lis execution/CONVENTIONS.md, execution/STATE.md puis la fiche execution/$(basename "$fiche"), et exécute UNIQUEMENT cette fiche. À la fin : mets à jour STATE.md (statut, ligne NEXT, décisions, bloqueurs), commit signé, push, puis annonce à Quentin qu'il peut taper /exit pour passer le relais."
done
