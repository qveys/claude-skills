#!/usr/bin/env bash
# collect.sh — extraction DÉTERMINISTE de l'état final des sessions Claude Code.
#
# Parcourt ~/.claude/projects/*/*.jsonl et sort UNE ligne par session, champs séparés par « | » :
#   PROJET|ID8|DERNIERE_ACTIVITE|TAILLE|TYPE_DERNIERE_ENTREE|intr=N|TAG|SUJET|…FIN
#   (les « | » présents dans SUJET/FIN sont remplacés par « ¦ » : les colonnes restent stables)
#
#   DERNIERE_ACTIVITE     : heure locale (fuseau système, format YYYY-MM-DDTHH:MM) — convertie
#                          depuis le timestamp ISO UTC du transcript, pas l'UTC brut
#   TYPE_DERNIERE_ENTREE : file-history-snapshot ≈ tour terminé proprement ; autre chose = à examiner
#                          (PARSE_ERROR = dernière ligne illisible par jq — ne pas juger cette session)
#   intr=N               : occurrences de « Request interrupted » dans les 8 dernières lignes
#   TAG                  : HUMAIN | AUTO_SECREVIEW | PREWARM | SIDECHAIN
#   FIN                  : queue (~260 car.) du dernier texte assistant — la matière première du verdict
#                          (préfixée du marqueur « [FIN=USER : …] » quand la dernière entrée est un
#                          message utilisateur resté sans réponse — cf. references/verdicts.md)
#
# Sortie PAR DÉFAUT pré-triée : les reviews sécurité CI (TAG=AUTO_SECREVIEW), les préchauffages
# (TAG=PREWARM, LaunchAgent) et les sessions vides (ni sujet ni texte assistant) ne sortent plus en
# lignes individuelles — elles sont comptées et regroupées en lignes d'agrégat qui commencent par
# « # » (donc jamais confondues avec une ligne de donnée) :
#   # AGG|AUTO_SECREVIEW|<projet>|total=N|conclues=X|a_examiner=Y|findings_listes=Z
#     conclues=X   : FIN contient « no security vulnerabilities found » (insensible à la casse)
#                    OU le littéral JSON `"findings": []` (avec ou sans espace)
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

# LC_ALL=C : tr/grep/sed traitent alors les octets bruts, sans jamais se plaindre d'une
# séquence UTF-8 invalide (locale C = pas de notion de « caractère », que des octets). Les
# motifs accentués du script (« vulnérabilité confirmée », « Réponds uniquement: ok »…) restent
# valides : ils matchent octet à octet, indépendamment de la locale — ne pas les modifier.
export LC_ALL=C

DAYS=7
PROJECT=""
EXCLUDE=""
INCLUDE_SIDECHAINS=0
RAW=0
USAGE="usage : collect.sh [--days N] [--project SUBSTR] [--exclude ID8] [--include-sidechains] [--raw]"
while [ $# -gt 0 ]; do
  case "$1" in
    --days|--project|--exclude)
      # Valeur obligatoire : sans ce garde, « collect.sh --days » déréférencerait $2 sous set -u.
      [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      case "$1" in
        --days) DAYS="$2" ;;
        --project) PROJECT="$2" ;;
        --exclude) EXCLUDE="$2" ;;
      esac
      shift 2 ;;
    --include-sidechains) INCLUDE_SIDECHAINS=1; shift ;;
    --raw) RAW=1; shift ;;
    *) echo "argument inconnu : $1" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done
# --days doit être un entier strictement positif : un « find -mtime -abc » ou « -0 » casserait
# la collecte avec une erreur cryptique au lieu d'un message clair.
case "$DAYS" in
  ''|*[!0-9]*|0) echo "--days doit être un entier > 0 (reçu : « $DAYS »)" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq est requis (brew install jq / apt install jq)" >&2; exit 3; }
# strflocaltime() (jq ≥ 1.6) est indispensable à la colonne DERNIERE_ACTIVITE : sans ce garde,
# un jq trop ancien ferait silencieusement retomber chaque ligne sur le repli stat (mtime),
# faussant le regroupement « jour par jour » — mieux vaut échouer tout de suite, clairement.
jq -n 'now | strflocaltime("%Y")' >/dev/null 2>&1 \
  || { echo "jq ≥ 1.6 requis : strflocaltime() est absent de ce jq ($(jq --version 2>/dev/null || echo '?'))" >&2; exit 3; }

# Variante de stat : sur GNU, `stat -f` = --file-system (peut réussir avec une sortie
# incorrecte), donc un repli `stat -f … || stat -c …` est dangereux. On détecte une fois.
if stat --version >/dev/null 2>&1; then
  STAT_FLAVOR=gnu
else
  STAT_FLAVOR=bsd
fi

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

  # Une seule lecture disque des 120 dernières lignes (un seul fork de tail par fichier, au lieu
  # de quatre) : on la charge dans un tableau bash, puis ts/ltype/intr/fin en dérivent tous en
  # mémoire — printf -v et <<< sont des mécanismes internes au shell, ils ne forkent rien, donc
  # aucun sous-processus supplémentaire n'est introduit par cette découpe en sous-fenêtres.
  tail120=()
  while IFS= read -r _tl || [ -n "$_tl" ]; do tail120+=("$_tl"); done < <(tail -n 120 "$f")
  n120=${#tail120[@]}
  start30=$(( n120 > 30 ? n120 - 30 : 0 ))
  start8=$(( n120 > 8 ? n120 - 8 : 0 ))

  # .timestamp des transcripts est en ISO UTC (« …Z »), avec ou sans millisecondes selon les
  # entrées : strflocaltime() convertit vers l'heure locale (fuseau système, indépendant de
  # LC_ALL=C ci-dessus qui ne régit que les octets/motifs, pas le calendrier) pour rester
  # cohérent avec le repli stat -f '%Sm' ci-dessous, lui aussi en heure locale.
  printf -v _win30 '%s\n' "${tail120[@]:$start30}"
  ts=$(jq -r 'select(.timestamp) | .timestamp
              | sub("\\.[0-9]+Z$";"Z")
              | fromdate
              | strflocaltime("%Y-%m-%dT%H:%M")' <<<"$_win30" 2>/dev/null | tail -n 1 || true)
  if [ -z "$ts" ]; then
    if [ "$STAT_FLAVOR" = bsd ]; then
      ts=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M' "$f")
    else
      ts=$(stat -c '%y' "$f" | cut -c1-16 | tr ' ' 'T')
    fi
  fi
  if [ "$STAT_FLAVOR" = bsd ]; then
    size_kb=$(( $(stat -f '%z' "$f") / 1024 ))
  else
    size_kb=$(( $(stat -c '%s' "$f") / 1024 ))
  fi
  _last1=""
  [ "$n120" -gt 0 ] && _last1="${tail120[$((n120-1))]}"
  ltype=$(jq -r '.type // "?"' <<<"$_last1" 2>/dev/null || echo 'PARSE_ERROR')
  # Fichier vide → _last1 vide → jq ne sort rien MAIS sort en succès : sans ce repli, la
  # colonne TYPE_DERNIERE_ENTREE resterait vide et casserait la stabilité des colonnes.
  [ -n "$ltype" ] || ltype='PARSE_ERROR'
  printf -v _win8 '%s\n' "${tail120[@]:$start8}"
  intr=$(grep -c 'Request interrupted' <<<"$_win8" || true)

  # Sujet : premier texte utilisateur qui n'est ni une commande/balise locale (<command-…>,
  # [quelque-chose]) ni un Caveat système — on ignore les espaces de tête, certains clients
  # indentent ces lignes (ex. « <command-message>model</command-message> »).
  # Fenêtre élargie à 200 lignes (lecture bornée) : le premier message humain peut être précédé
  # de dizaines d'entrées système/contexte injectées, au-delà des 40 premières lignes.
  # Sous LC_ALL=C, `cut -c` compte des OCTETS (plus des caractères) : peut couper au milieu d'un
  # caractère UTF-8 multi-octets et laisser un octet de tête orphelin (0xC2–0xF4) sans sa suite —
  # on l'élague en fin de chaîne pour ne jamais terminer SUJET sur un caractère tronqué.
  subject=$(head -n 200 "$f" \
    | jq -r 'select(.type=="user") | .message.content | if type=="string" then . else (.[]? | select(.type=="text") | .text) end' 2>/dev/null \
    | grep -vE '^[[:space:]]*(<|\[|Caveat)' | head -n 1 | cut -c 1-110 \
    | perl -pe 's/(?:[\xC2-\xDF]|[\xE0-\xEF][\x80-\xBF]{0,1}|[\xF0-\xF4][\x80-\xBF]{0,2})$//' \
    | sed 's/|/¦/g' || true)
  [ -n "$subject" ] || subject="(pas de sujet)"

  if [ -z "$tag" ]; then
    case "$subject" in
      "Review this change for security vulnerabilities."*) tag="AUTO_SECREVIEW" ;;
      "Réponds uniquement: ok"*) tag="PREWARM" ;;
      *) tag="HUMAIN" ;;
    esac
  fi

  # Forme slice :0 obligatoire : "${tail120[@]}" sur un tableau vide (fichier .jsonl vide)
  # est une « unbound variable » sous set -u en bash 3.2 et tuerait toute la boucle.
  printf -v _win120 '%s\n' "${tail120[@]:0}"
  # .message.content peut être une chaîne (forme simple) ou un tableau de blocs
  # (forme riche, avec des blocs {type:"text",...}) selon les entrées : mêmes deux
  # formes que le sujet ci-dessus, même traitement — sinon un message assistant en
  # forme string tombe sur le repli « aucun texte » et se fait classer à tort comme
  # inachevé.
  # Capture le statut de jq (pas de `|| true` qui garderait une sortie partielle) : en cas
  # d'échec, jeter FIN et marquer PARSE_ERROR pour que l'aval ne juge pas un texte périmé.
  fin=""
  if fin_raw=$(jq -r 'select(.type=="assistant") | .message.content | if type=="string" then . else (.[]? | select(.type=="text") | .text) end' <<<"$_win120" 2>/dev/null); then
    fin=$(printf '%s' "$fin_raw" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/|/¦/g')
    # tail -c coupe en OCTETS : peut tomber au milieu d'un caractère UTF-8 multi-octets et laisser
    # FIN commencer par des octets de continuation (0x80–0xBF), invalides en tête de séquence — on
    # les élague pour ne jamais démarrer FIN sur un caractère tronqué.
    fin=$(printf '%s' "$fin" | tail -c 260 | perl -pe 's/^[\x80-\xBF]+//')
  else
    ltype="PARSE_ERROR"
  fi
  [ -n "$fin" ] || fin="(aucun texte assistant en fin de fichier)"
  # Session close sur un message UTILISATEUR resté sans réponse (dernière entrée type=user) :
  # FIN ne montrerait qu'un ancien bilan assistant et masquerait la demande en attente. On
  # préfixe FIN d'un marqueur explicite, avec la demande si elle est extractible — la règle de
  # verdict correspondante (À_REPRENDRE, rendu ⏸️) vit dans references/verdicts.md.
  if [ "$ltype" = "user" ]; then
    lastu=$(jq -r 'select(.type=="user") | .message.content | if type=="string" then . else (.[]? | select(.type=="text") | .text) end' <<<"$_win120" 2>/dev/null \
      | grep -vE '^[[:space:]]*(<|Caveat)' | tail -n 1 | cut -c 1-120 \
      | perl -pe 's/(?:[\xC2-\xDF]|[\xE0-\xEF][\x80-\xBF]{0,1}|[\xF0-\xF4][\x80-\xBF]{0,2})$//' \
      | sed 's/|/¦/g' || true)
    fin="[FIN=USER${lastu:+ : $lastu}] $fin"
  fi

  line=$(printf '%s|%s|%s|%sKo|%s|intr=%s|%s|%s|…%s' \
    "$proj" "$id" "$ts" "$size_kb" "$ltype" "$intr" "$tag" "$subject" "$fin")

  if [ "$RAW" = 1 ]; then
    printf '%s\n' "$line"
    continue
  fi

  # PARSE_ERROR : ne pas agréger (VIDE/PREWARM/AUTO) — le sentinelle « ne pas juger »
  # doit rester visible en ligne individuelle pour l'aval (cf. references/verdicts.md).
  if [ "$ltype" = "PARSE_ERROR" ]; then
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
        # OU le littéral JSON `"findings": []` (avec ou sans espace). Sinon (FIN vide ou autre
        # contenu) : à examiner.
        # || true : un échec de tr ne doit jamais tuer la boucle (set -euo pipefail) et
        # tronquer le rapport en silence — l'exhaustivité déterministe prime.
        finlc=$(printf '%s' "$fin" | tr '[:upper:]' '[:lower:]' || true)
        concluded=0
        case "$finlc" in
          *"no security vulnerabilities found"*) concluded=1 ;;
        esac
        case "$fin" in
          *'"findings": []'*|*'"findings":[]'*) concluded=1 ;;
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
