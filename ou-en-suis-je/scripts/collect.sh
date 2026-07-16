#!/usr/bin/env bash
# collect.sh — extraction DÉTERMINISTE de l'état final des sessions Claude Code.
#
# Parcourt ~/.claude/projects/*/*.jsonl et sort UNE ligne par session, champs séparés par « | » :
#   PROJET|ID8|DERNIERE_ACTIVITE|TAILLE|TYPE_DERNIERE_ENTREE|intr=N|TAG|SUJET|…FIN
#   (les « | » présents dans SUJET/FIN sont remplacés par « ¦ » : les colonnes restent stables)
#
#   TYPE_DERNIERE_ENTREE : file-history-snapshot ≈ tour terminé proprement ; autre chose = à examiner
#                          (PARSE_ERROR = dernière ligne illisible par jq — ne pas juger cette session)
#   intr=N               : occurrences de « Request interrupted » dans les 8 dernières lignes
#   TAG                  : HUMAIN | AUTO_SECREVIEW | PREWARM | SIDECHAIN
#   FIN                  : queue (~260 car.) du dernier texte assistant — la matière première du verdict
#
# Sortie PAR DÉFAUT pré-triée : les reviews sécurité CI (TAG=AUTO_SECREVIEW), les préchauffages
# (TAG=PREWARM, LaunchAgent) et les sessions vides (ni sujet ni texte assistant) ne sortent plus en
# lignes individuelles — elles sont comptées et regroupées en lignes d'agrégat qui commencent par
# « # » (donc jamais confondues avec une ligne de donnée) :
#   # AGG|AUTO_SECREVIEW|<projet>|total=N|conclues=X|a_examiner=Y|findings_listes=Z
#     conclues=X   : FIN contient « no security vulnerabilities found » (insensible à la casse)
#                    OU le littéral JSON `"findings": []`
#     a_examiner=Y : le reste (FIN vide ou autre contenu), hors findings survivants (cf. EXCEPTION)
#   # AGG|PREWARM|total=N
#   # AGG|VIDE|total=N|ids=id1,id2,…
# EXCEPTION : un AUTO_SECREVIEW dont la fin contient un finding qui « survit » (vulnérabilité
# confirmée) reste en ligne individuelle — trop important pour disparaître dans un agrégat — mais
# est aussi compté dans findings_listes de l'agrégat de son projet.
# `--raw` désactive tout ce pré-tri : une ligne par session, aucune ligne `# AGG`.
#
# Usage : collect.sh [--days N] [--project SUBSTR] [--exclude ID8] [--include-sidechains] [--raw]
# Variable d'environnement : OEJ_DIR (défaut ~/.claude/ou-en-suis-je) — dossier contenant
#   dispositions.tsv ; utile pour pointer les tests vers un dossier temporaire isolé.
# Ne lit JAMAIS un fichier en entier (head/tail seulement) : coût constant même sur des .jsonl de 8 Mo.
set -euo pipefail

DAYS=7
PROJECT=""
EXCLUDE=""
INCLUDE_SIDECHAINS=0
RAW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --exclude) EXCLUDE="$2"; shift 2 ;;
    --include-sidechains) INCLUDE_SIDECHAINS=1; shift ;;
    --raw) RAW=1; shift ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq est requis (brew install jq / apt install jq)" >&2; exit 3; }

PROJ_DIR="$HOME/.claude/projects"
if [ ! -d "$PROJ_DIR" ]; then
  echo "(pas de dossier $PROJ_DIR : aucune session Claude Code sur cette machine)"
  exit 0
fi

# Fichier temporaire recevant les candidats à l'agrégation (AUTO_SECREVIEW/PREWARM/VIDE) : la
# boucle principale ci-dessous tourne dans un sous-shell (pipe depuis find), donc des compteurs
# bash n'y survivraient pas (bash 3.2, pas de tableaux associatifs de toute façon) — on écrit sur
# disque à la place, et on agrège en awk une fois la boucle terminée.
AGGTMP=""
if [ "$RAW" = 0 ]; then
  AGGTMP=$(mktemp)
  trap 'rm -f "$AGGTMP"' EXIT
fi

# dispositions de Quentin (scripts/dispose.sh) : ID8 <tab> STATUT <tab> date <tab> note, en append.
DISP="${OEJ_DIR:-$HOME/.claude/ou-en-suis-je}/dispositions.tsv"

find "$PROJ_DIR" -maxdepth 2 -name "*.jsonl" -mtime -"$DAYS" | sort | while IFS= read -r f; do
  proj=$(basename "$(dirname "$f")")
  if [ -n "$PROJECT" ]; then
    case "$proj" in *"$PROJECT"*) ;; *) continue ;; esac
  fi
  id=$(basename "$f" .jsonl | cut -c1-8)
  if [ -n "$EXCLUDE" ] && [ "$id" = "$EXCLUDE" ]; then continue; fi
  # La DERNIÈRE ligne du tsv pour cet ID8 l'emporte (fichier append-only) : un REPRENDRE/ATTEND
  # postérieur à un CLOS ré-ouvre la session, et inversement un CLOS postérieur la referme.
  if [ -f "$DISP" ] && awk -F'\t' -v i="$id" '$1==i{s=$2} END{exit !(s=="CLOS")}' "$DISP"; then
    continue
  fi
  tag=""

  if head -c 4000 "$f" | grep -Eq '"isSidechain":[[:space:]]*true'; then
    [ "$INCLUDE_SIDECHAINS" = 1 ] || continue
    tag="SIDECHAIN"
  fi

  ts=$(tail -n 30 "$f" | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | tail -n 1 | cut -c1-16 || true)
  [ -n "$ts" ] || ts=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M' "$f" 2>/dev/null \
                    || stat -c '%y' "$f" 2>/dev/null | cut -c1-16 | tr ' ' 'T')
  size_kb=$(( $(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f") / 1024 ))
  ltype=$(tail -n 1 "$f" | jq -r '.type // "?"' 2>/dev/null || echo 'PARSE_ERROR')
  intr=$(tail -n 8 "$f" | grep -c 'Request interrupted' || true)

  # Sujet : premier texte utilisateur qui n'est ni une commande/balise locale (<command-…>,
  # [quelque-chose]) ni un Caveat système — on ignore les espaces de tête, certains clients
  # indentent ces lignes (ex. « <command-message>model</command-message> »).
  subject=$(head -n 40 "$f" \
    | jq -r 'select(.type=="user") | .message.content | if type=="string" then . else (.[]? | select(.type=="text") | .text) end' 2>/dev/null \
    | grep -vE '^[[:space:]]*(<|\[|Caveat)' | head -n 1 | cut -c 1-110 | sed 's/|/¦/g' || true)
  [ -n "$subject" ] || subject="(pas de sujet)"

  if [ -z "$tag" ]; then
    case "$subject" in
      "Review this change for security vulnerabilities."*) tag="AUTO_SECREVIEW" ;;
      "Réponds uniquement: ok"*) tag="PREWARM" ;;
      *) tag="HUMAIN" ;;
    esac
  fi

  fin=$(tail -n 120 "$f" \
    | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null \
    | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/|/¦/g' || true)
  fin=$(printf '%s' "$fin" | tail -c 260)
  [ -n "$fin" ] || fin="(aucun texte assistant en fin de fichier)"

  line=$(printf '%s|%s|%s|%sKo|%s|intr=%s|%s|%s|…%s' \
    "$proj" "$id" "$ts" "$size_kb" "$ltype" "$intr" "$tag" "$subject" "$fin")

  if [ "$RAW" = 1 ]; then
    printf '%s\n' "$line"
    continue
  fi

  # VIDE : ni sujet ni texte assistant final → pas de ligne individuelle, comptée à part.
  if [ "$subject" = "(pas de sujet)" ] && [ "$fin" = "(aucun texte assistant en fin de fichier)" ]; then
    printf 'VIDE\t%s\n' "$id" >> "$AGGTMP"
    continue
  fi

  if [ "$tag" = "AUTO_SECREVIEW" ]; then
    # Exception : un finding qui « survit » remonte quand même en ligne individuelle (section ⚠️
    # du rapport) — mais compte aussi dans findings_listes de l'agrégat de son projet.
    case "$fin" in
      *"the finding survives"*|*"finding survives"*|*"vulnérabilité confirmée"*|*"vulnerability confirmed"*)
        printf 'AUTO_SECREVIEW\t%s\tFINDING\n' "$proj" >> "$AGGTMP"
        printf '%s\n' "$line"
        ;;
      *)
        # Conclue = FIN contient « no security vulnerabilities found » (insensible à la casse)
        # OU le littéral JSON `"findings": []`. Sinon (FIN vide ou autre contenu) : à examiner.
        finlc=$(printf '%s' "$fin" | tr '[:upper:]' '[:lower:]')
        concluded=0
        case "$finlc" in
          *"no security vulnerabilities found"*) concluded=1 ;;
        esac
        case "$fin" in
          *'"findings": []'*) concluded=1 ;;
        esac
        if [ "$concluded" = "1" ]; then
          printf 'AUTO_SECREVIEW\t%s\tCONCLUE\n' "$proj" >> "$AGGTMP"
        else
          printf 'AUTO_SECREVIEW\t%s\tA_EXAMINER\n' "$proj" >> "$AGGTMP"
        fi
        ;;
    esac
    continue
  fi

  if [ "$tag" = "PREWARM" ]; then
    printf 'PREWARM\n' >> "$AGGTMP"
    continue
  fi

  printf '%s\n' "$line"
done

if [ "$RAW" = 0 ] && [ -s "$AGGTMP" ]; then
  awk -F'\t' '
    $1=="PREWARM"{prewarm++}
    $1=="VIDE"{videN++; ids[videN]=$2}
    $1=="AUTO_SECREVIEW"{
      proj=$2; st=$3
      if(!(proj in seen)){ seen[proj]=1; order[++n]=proj }
      tot[proj]++
      if(st=="CONCLUE") concl[proj]++
      else if(st=="A_EXAMINER") aexam[proj]++
      else if(st=="FINDING") find[proj]++
    }
    END{
      for(i=1;i<=n;i++){
        p=order[i]
        printf "# AGG|AUTO_SECREVIEW|%s|total=%d|conclues=%d|a_examiner=%d|findings_listes=%d\n", p, tot[p], concl[p]+0, aexam[p]+0, find[p]+0
      }
      if(prewarm>0) printf "# AGG|PREWARM|total=%d\n", prewarm+0
      if(videN>0){
        idlist=""
        for(i=1;i<=videN;i++) idlist = idlist (i==1?"":",") ids[i]
        printf "# AGG|VIDE|total=%d|ids=%s\n", videN, idlist
      }
    }
  ' "$AGGTMP"
fi
