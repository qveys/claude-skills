#!/usr/bin/env bash
# wsh-step.sh — airy visual step banners for cockpit sessions (readable in Wave)
# Usage:
#   wsh-step.sh phase  2 6 "Identité Théo Marceau"
#   wsh-step.sh step   2.1 "TOOLS.md"
#   wsh-step.sh done   "Phase 2"
#   wsh-step.sh cmd    step 2.1 "TOOLS.md"   # one-liner for wsh-live.sh banner / remote send
#
# PORTABILITY (why `cmd` emits only flat printf, never shell functions):
#   The `cmd` one-liners are typed into the pane's shell, which on macOS is zsh
#   (locally AND after an `ssh`/`wsh ssh` hop). zsh refuses inline function
#   definitions packed onto one line inside a `{ ... }` group — it dies with
#   `parse error near '}'`. So emit_cmd precomputes every width/pad here in bash
#   and emits ONLY `printf` statements (a `{ list; }` group is fine in both
#   shells). No `box_top(){…}` helpers ever reach the pane.
set -euo pipefail

# Absolute path to THIS script, captured at TOP LEVEL. selftest-step re-invokes the
# script (`"$SELF_PATH" cmd …` / `defs`), and it must resolve in bash AND zsh: inside
# a function zsh rebinds $0 to the function name (FUNCTION_ARGZERO), so a function-
# local `$0` would point at `run_step_selftest` and break `zsh wsh-step.sh selftest-step`.
SELF_PATH="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/$(basename "$0")"

W="${WSH_STEP_WIDTH:-72}"

# The banner layout lives in ONE place: the pane-side functions emitted by
# emit_defs (__wsh_banner & friends). Both the live `defs` path and the direct CLI
# render (case dispatch below) run those exact functions, so they cannot drift.
# `emit_cmd` is the lone second encoding — a flat-printf one-liner kept only because
# zsh can't parse inline `f(){…}` (see header) — and is pinned byte-identical to
# `defs` by `selftest-step`.

# Escape a string for use inside single quotes in a generated shell one-liner.
sq() { printf '%s' "${1:-}" | sed "s/'/'\\\\''/g"; }

# Count Unicode code points (≈ display columns for Latin text) independent of the
# shell locale: total bytes minus UTF-8 continuation bytes (0x80–0xBF). This keeps
# box borders aligned for accented French titles (é, è) and the em-dash (—), where
# the locale-dependent ${#str} would otherwise count bytes and short the border.
# Caveat: assumes width-1 glyphs (true for Latin/punctuation); wide CJK still off.
char_len() {
  local s="${1:-}" bytes cont
  bytes=$(printf '%s' "$s" | wc -c)
  cont=$(printf '%s' "$s" | LC_ALL=C tr -dc '\200-\277' | wc -c)
  printf '%s' $(( bytes - cont ))
}

# Portable tty-color prelude for emit_cmd one-liners (evaluated in the pane).
cmd_color_init() {
  # Trailing ';' — the prelude is spliced before the printf statements in the one-liner.
  # ANSI-C quoting ($'…') in the pane — 0 pane forks (vs 10 `$(printf …)` before)
  # and a shorter one-liner the human watches get typed. Valid in bash and zsh.
  printf '%s' "if [ -t 1 ] || [ -n \"\${WSH_FORCE_COLOR:-}\" ]; then __r=\$'\\033[0m'; __rc=\$'\\033[1;38;5;45m'; __ry=\$'\\033[1;38;5;226m'; __rg=\$'\\033[1;38;5;46m'; __hm=\$'\\033[1;38;5;201m'; __pc=\$'\\033[1;38;5;51m'; __tw=\$'\\033[1;38;5;255m'; __sy=\$'\\033[1;38;5;208m'; __dg=\$'\\033[1;38;5;82m'; __dm=\$'\\033[38;5;39m'; else __r=; __rc=; __ry=; __rg=; __hm=; __pc=; __tw=; __sy=; __dg=; __dm=; fi; "
}

# --- emit_cmd primitives -----------------------------------------------------
# Each prints ONE `printf ...;` statement (no shell functions) for the one-liner.
# Widths/pads are computed HERE in bash; the pane only runs flat printf.

# A run of N box-drawing dashes, as a literal UTF-8 string.
dashes() { printf '%*s' "$1" '' | tr ' ' '─'; }

# Full-width rule line in a given color var (e.g. __ry). $1 = color var name.
emit_rule() {
  local cvar="$1" d
  d=$(dashes "$W")
  printf "printf '%%b%s%%b\\\\n' \"\$%s\" \"\$__r\"; " "$d" "$cvar"
}

# Box top/bottom border. $1 left-corner $2 right-corner $3 border-color var.
emit_box_edge() {
  local lc="$1" rc="$2" cvar="$3" d
  d=$(dashes $((W - 2)))
  printf "printf '%%b%s%s%s%%b\\\\n' \"\$%s\" \"\$__r\"; " "$lc" "$d" "$rc" "$cvar"
}

# Centered line inside a closed box (│ … │). $1 text $2 text-color var $3 border-color var.
emit_box_line() {
  local text="$1" tvar="$2" bvar="$3"
  local inner=$((W - 2)) len pad right
  len=$(char_len "$text")
  pad=$(( (inner - len) / 2 )); [ "$pad" -lt 0 ] && pad=0
  right=$(( inner - len - pad )); [ "$right" -lt 0 ] && right=0
  printf "printf '%%b│%%b%%*s%%b%%s%%b%%*s%%b│%%b\\\\n' \"\$%s\" \"\$__r\" %s '' \"\$%s\" '%s' \"\$__r\" %s '' \"\$%s\" \"\$__r\"; " \
    "$bvar" "$pad" "$tvar" "$(sq "$text")" "$right" "$bvar"
}

# Portable shell one-liner — runs in any pane (zsh or bash, local or remote SSH)
# WITHOUT this script and WITHOUT defining any shell function. A `{ list; }` group
# of flat printf statements parses identically in bash and zsh.
emit_cmd() {
  local kind="${1:-}"; shift || true
  local W="$W" colors out
  colors=$(cmd_color_init)
  case "$kind" in
    phase)
      local num="${1:-?}" total="${2:-?}" title="${3:-}"
      out="{ ${colors}printf '\\n\\n\\n'; "
      out+=$(emit_box_edge '┌' '┐' __rc)
      out+=$(emit_box_line "PHASE ${num} / ${total}" __pc __rc)
      [ -n "$title" ] && out+=$(emit_box_line "$title" __tw __rc)
      out+=$(emit_box_edge '└' '┘' __rc)
      out+="printf '\\n\\n'; }"
      printf '%s' "$out"
      ;;
    step)
      local id="${1:-?}" label="${2:-}"
      out="{ ${colors}printf '\\n\\n'; "
      out+=$(emit_rule __ry)
      out+=$(printf "printf '  %%b▸%%b  %%b[%%s]%%b  %%b%%s%%b\\\\n' \"\$__sy\" \"\$__r\" \"\$__sy\" '%s' \"\$__r\" \"\$__tw\" '%s' \"\$__r\"; " "$(sq "$id")" "$(sq "$label")")
      out+=$(emit_rule __ry)
      out+="printf '\\n\\n'; }"
      printf '%s' "$out"
      ;;
    done)
      local msg="${1:-OK}" text len pad
      text="✓  ${msg}"
      len=$(char_len "$text")
      pad=$(( (W - len) / 2 )); [ "$pad" -lt 0 ] && pad=0
      out="{ ${colors}printf '\\n\\n'; "
      out+=$(emit_rule __rg)
      out+=$(printf "printf '%%*s%%b%%s%%b\\\\n' %s '' \"\$__dg\" '%s' \"\$__r\"; " "$pad" "$(sq "$text")")
      out+=$(emit_rule __rg)
      out+="printf '\\n\\n\\n'; }"
      printf '%s' "$out"
      ;;
    header)
      local title="${1:-Cockpit Grok}" session="${2:-}"
      out="{ ${colors}printf '\\n\\n\\n'; "
      out+=$(emit_box_edge '┌' '┐' __rc)
      out+=$(emit_box_line "$title" __hm __rc)
      [ -n "$session" ] && out+=$(emit_box_line "session: ${session}" __dm __rc)
      out+=$(emit_box_edge '└' '┘' __rc)
      out+="printf '\\n\\n\\n'; }"
      printf '%s' "$out"
      ;;
    *)
      echo "usage: $0 cmd {header|phase|step|done} ..." >&2
      return 2
      ;;
  esac
}

# Reusable pane-side function defs — source ONCE, then call `__wsh_banner ...`.
# This is the function-based counterpart of `emit_cmd`: instead of re-emitting a
# ~700-char flat-printf one-liner on every banner (which the watching human sees
# typed into the pane before it renders), the pane sources these defs a single
# time and each subsequent banner is a short, readable call:
#
#     __wsh_banner done  'Phase 4 OK — paperclip_mcp live'
#     __wsh_banner phase 2 6 'Identité Théo Marceau'
#     __wsh_banner step  2.1 'TOOLS.md'
#     __wsh_banner header 'Cockpit' 'session-x'
#
# PORTABILITY: emitted as a genuine multi-line block (real newlines), which both
# bash and zsh parse as ordinary function definitions — the zsh one-line `{ f(){} }`
# parse error that forced emit_cmd's flat-printf design does NOT apply here.
# Widths/pads are recomputed in the pane at call time (no bash-side precompute),
# so the same defs work whatever the pane's COLUMNS/locale. This is the SINGLE
# layout source — the direct CLI render delegates here too; only emit_cmd repeats
# the layout (flat-printf fallback), and selftest-step pins it byte-identical.
emit_defs() {
cat <<'DEFS'
__wsh_b_clen() {
  __s=${1:-}
  __b=$(printf '%s' "$__s" | wc -c)
  __c=$(printf '%s' "$__s" | LC_ALL=C tr -dc '\200-\277' | wc -c)
  printf '%s' $(( __b - __c ))
}
__wsh_b_colors() {
  __WSH_BW=${WSH_STEP_WIDTH:-72}
  if [ -t 1 ] || [ -n "${WSH_FORCE_COLOR:-}" ]; then
    # ANSI-C quoting ($'\033…') is a builtin in both bash and zsh — 0 forks, vs the
    # 10 `$(printf …)` subshells this used to spawn on EVERY banner (the hot path).
    __WSH_BR=$'\033[0m'
    __WSH_BRC=$'\033[1;38;5;45m'
    __WSH_BRY=$'\033[1;38;5;226m'
    __WSH_BRG=$'\033[1;38;5;46m'
    __WSH_BHM=$'\033[1;38;5;201m'
    __WSH_BPC=$'\033[1;38;5;51m'
    __WSH_BTW=$'\033[1;38;5;255m'
    __WSH_BSY=$'\033[1;38;5;208m'
    __WSH_BDG=$'\033[1;38;5;82m'
    __WSH_BDM=$'\033[38;5;39m'
  else
    __WSH_BR=; __WSH_BRC=; __WSH_BRY=; __WSH_BRG=; __WSH_BHM=
    __WSH_BPC=; __WSH_BTW=; __WSH_BSY=; __WSH_BDG=; __WSH_BDM=
  fi
}
__wsh_b_rule() {
  printf '%b' "$1"
  printf '%*s' "$__WSH_BW" '' | tr ' ' '─'
  printf '%b\n' "$__WSH_BR"
}
__wsh_b_edge() {
  printf '%b%s' "$3" "$1"
  printf '%*s' $((__WSH_BW - 2)) '' | tr ' ' '─'
  printf '%s%b\n' "$2" "$__WSH_BR"
}
__wsh_b_boxline() {
  __len=$(__wsh_b_clen "$1"); __inner=$((__WSH_BW - 2))
  __pad=$(( (__inner - __len) / 2 )); [ "$__pad" -lt 0 ] && __pad=0
  __right=$(( __inner - __len - __pad )); [ "$__right" -lt 0 ] && __right=0
  printf '%b│%b%*s%b%s%b%*s%b│%b\n' "$3" "$__WSH_BR" "$__pad" '' "$2" "$1" "$__WSH_BR" "$__right" '' "$3" "$__WSH_BR"
}
__wsh_b_center() {
  __len=$(__wsh_b_clen "$1")
  __pad=$(( (__WSH_BW - __len) / 2 )); [ "$__pad" -lt 0 ] && __pad=0
  printf '%*s%b%s%b\n' "$__pad" '' "$2" "$1" "$__WSH_BR"
}
__wsh_banner() {
  __wsh_b_colors
  case "${1:-}" in
    header)
      printf '\n\n\n'
      __wsh_b_edge '┌' '┐' "$__WSH_BRC"
      __wsh_b_boxline "${2:-Cockpit Grok}" "$__WSH_BHM" "$__WSH_BRC"
      [ -n "${3:-}" ] && __wsh_b_boxline "session: ${3}" "$__WSH_BDM" "$__WSH_BRC"
      __wsh_b_edge '└' '┘' "$__WSH_BRC"
      printf '\n\n\n' ;;
    phase)
      printf '\n\n\n'
      __wsh_b_edge '┌' '┐' "$__WSH_BRC"
      __wsh_b_boxline "PHASE ${2:-?} / ${3:-?}" "$__WSH_BPC" "$__WSH_BRC"
      [ -n "${4:-}" ] && __wsh_b_boxline "${4}" "$__WSH_BTW" "$__WSH_BRC"
      __wsh_b_edge '└' '┘' "$__WSH_BRC"
      printf '\n\n' ;;
    step)
      printf '\n\n'
      __wsh_b_rule "$__WSH_BRY"
      printf '  %b▸%b  %b[%s]%b  %b%s%b\n' "$__WSH_BSY" "$__WSH_BR" "$__WSH_BSY" "${2:-?}" "$__WSH_BR" "$__WSH_BTW" "${3:-}" "$__WSH_BR"
      __wsh_b_rule "$__WSH_BRY"
      printf '\n\n' ;;
    done)
      printf '\n\n'
      __wsh_b_rule "$__WSH_BRG"
      __wsh_b_center "✓  ${2:-OK}" "$__WSH_BDG"
      __wsh_b_rule "$__WSH_BRG"
      printf '\n\n\n' ;;
    *)
      printf 'usage: __wsh_banner {header|phase|step|done} ...\n' >&2
      return 2 ;;
  esac
}
DEFS
}

# Golden test: the three render paths (direct emit_*, cmd one-liner, defs functions)
# MUST be byte-identical for every (type, args), in bash AND zsh, colored AND plain.
# Colors are forced via WSH_FORCE_COLOR so the SGR-reset placement is actually
# compared (off a TTY the resets are empty and the divergence hides). The direct
# path is the reference; cmd≡defs was the only thing the old SKILL.md test checked.
run_step_selftest() {
  local self="$SELF_PATH"   # top-level capture — $0 is unreliable inside a zsh function
  local failures=0 shells="bash zsh"

  cmp_case() {
    local label="$1"; shift
    local ref out oneliner sh
    ref=$(WSH_FORCE_COLOR=1 "$self" "$@") || { echo "FAIL $label [direct errored]" >&2; failures=$((failures+1)); return 0; }
    for sh in $shells; do
      command -v "$sh" >/dev/null 2>&1 || continue
      oneliner=$("$self" cmd "$@")
      out=$(WSH_FORCE_COLOR=1 "$sh" -c "$oneliner" 2>/dev/null) || true
      [ "$out" = "$ref" ] || { echo "FAIL $label [cmd/$sh != direct]" >&2; failures=$((failures+1)); }
      out=$(WSH_FORCE_COLOR=1 "$sh" -c 'eval "$('"$self"' defs)"; __wsh_banner "$@"' _ "$@" 2>/dev/null) || true
      [ "$out" = "$ref" ] || { echo "FAIL $label [defs/$sh != direct]" >&2; failures=$((failures+1)); }
    done
  }

  local long="OVERLONG-TITLE-THAT-EXCEEDS-SEVENTY-COLUMNS-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  cmp_case "done normal"        'done'   "Phase 4 OK — paperclip_mcp live sur Hermes macbook-openclaw"
  cmp_case "phase normal"       phase  2 6 "Identité Théo Marceau"
  cmp_case "step normal"        step   2.1 "TOOLS.md déployé"
  cmp_case "header full"        header "Cockpit Grok" "cockpit-live-x"
  cmp_case "header no-session"  header "Titre seul"
  cmp_case "phase no-title"     phase  1 6
  cmp_case "done empty-msg"     'done'   ""
  cmp_case "accents+emdash"     'done'   "é è ê — ç à œ «»"
  cmp_case "overlong done"      'done'   "$long"
  cmp_case "overlong phase"     phase  1 6 "$long"
  export WSH_STEP_WIDTH=20
  cmp_case "small-width done"   'done'   "hi"
  cmp_case "small-width phase"  phase  3 9 "abc"
  unset WSH_STEP_WIDTH

  if [ "$failures" -ne 0 ]; then
    echo "selftest-step: $failures failure(s)" >&2
    return 1
  fi
  echo "selftest-step: ok (direct ≡ cmd ≡ defs, bash+zsh, colored)"
}

case "${1:-}" in
  # Direct render delegates to the SAME __wsh_banner functions as the live `defs`
  # path — one layout source, so local preview is byte-identical to the pane render
  # by construction (no hand-kept emit_* twin to drift). __wsh_banner already applies
  # the same per-type argument defaults the old emit_* arms did.
  phase|step|done|header)
    eval "$(emit_defs)"
    __wsh_banner "$@"
    ;;
  cmd)    shift; emit_cmd "$@" ;;
  defs)   emit_defs ;;
  selftest-step) run_step_selftest ;;
  *)
    echo "usage: $0 {header|phase|step|done|cmd|defs|selftest-step} ..." >&2
    exit 2
    ;;
esac
