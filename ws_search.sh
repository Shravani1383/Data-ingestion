#!/usr/bin/env bash
# ws_search — multi-keyword parallel code search
# Scope: -d <dir>  and/or  -p <file>  (repeatable)
# Lines: -L inline refs in table, -D full detail block
set -euo pipefail

BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BLUE='\033[0;34m'; RED='\033[0;31m'
[ ! -t 1 ] && BOLD='' DIM='' RESET='' GREEN='' YELLOW='' CYAN='' BLUE='' RED=''

WORKSPACE="${WORKSPACE_ROOT:-$(pwd)}"
TARGET_PATHS=()
JOBS=$(nproc 2>/dev/null || echo 4)
REGEX=false; ICASE=false; WWORD=false
CONTEXT=0; FTYPE=''; IGLOB=''; XGLOB=''
KWFILE=''; SHOW_LINES=false; DETAIL=false; JSON=false; MAX=500
KEYWORDS=()
SKIP='--glob=!node_modules/** --glob=!.git/** --glob=!dist/** --glob=!build/** --glob=!.next/** --glob=!__pycache__/**'

usage() { cat << 'HELP'
ws_search — multi-keyword parallel code search

USAGE
  ws_search.sh [OPTIONS] keyword1 [keyword2 ...]
  ws_search.sh [OPTIONS] -f keywords.txt

SCOPE
  -d <dir>     Search root directory           [default: $PWD]
  -p <path>    Specific file or glob (repeatable)
                 -p src/auth/AuthService.ts
                 -p "src/auth/*.ts"
                 -p AuthService.ts -p routes.ts

SEARCH
  -r           Regex mode (default: literal)
  -i           Case-insensitive
  -w           Whole word
  -C <n>       Context lines                   [default: 0]
  -f <file>    Keywords file (one per line, # = comment)
  -j <n>       Parallel jobs                   [default: nproc]
  -t <ext>     File type: ts js py go rs java
  -g <glob>    Include glob
  -x <glob>    Exclude glob

OUTPUT
  -L           Show line numbers inline in summary table
  -D           Show full matching lines under summary table
  --json       JSON output
  -h           Help

EXAMPLES
  ws_search.sh login
  ws_search.sh -d src/auth login password register
  ws_search.sh -p src/auth/AuthService.ts login password
  ws_search.sh -p src/auth/AuthService.ts -p src/api/routes.ts -L login register
  ws_search.sh -p "src/**/*.test.ts" -L assert expect
  ws_search.sh -d src -f keywords.txt -L -t ts
  ws_search.sh -r -D "async \w+\(" "throw new \w+"
  ws_search.sh --json -d src/auth login password
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) WORKSPACE="$2"; shift ;;
    -p) TARGET_PATHS+=("$2"); shift ;;
    -f) KWFILE="$2"; shift ;;
    -j) JOBS="$2"; shift ;;
    -r) REGEX=true ;;
    -i) ICASE=true ;;
    -w) WWORD=true ;;
    -C) CONTEXT="$2"; shift ;;
    -t) FTYPE="$2"; shift ;;
    -g) IGLOB="$2"; shift ;;
    -x) XGLOB="$2"; shift ;;
    -L) SHOW_LINES=true ;;
    -D) DETAIL=true ;;
    --json) JSON=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo -e "${RED}Unknown: $1${RESET}" >&2; exit 1 ;;
    *) KEYWORDS+=("$1") ;;
  esac
  shift
done

if [[ -n "$KWFILE" ]]; then
  [[ ! -f "$KWFILE" ]] && { echo -e "${RED}File not found: $KWFILE${RESET}" >&2; exit 1; }
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    KEYWORDS+=("$line")
  done < "$KWFILE"
fi

[[ ${#KEYWORDS[@]} -eq 0 ]] && { echo -e "${RED}No keywords.${RESET}" >&2; usage; exit 1; }
[[ ! -d "$WORKSPACE" ]]     && { echo -e "${RED}Not a directory: $WORKSPACE${RESET}" >&2; exit 1; }

# ── Resolve -p paths into rg positional args and extra --glob flags ───────────
# Sets globals: RG_FILE_ARGS (array) and RG_GLOB_FLAGS (array)
resolve_targets() {
  RG_FILE_ARGS=()
  RG_GLOB_FLAGS=()
  if [[ ${#TARGET_PATHS[@]} -gt 0 ]]; then
    for p in "${TARGET_PATHS[@]}"; do
      if [[ "$p" == *'*'* || "$p" == *'?'* ]]; then
        # Glob: pass as --glob to rg, search from workspace root
        RG_GLOB_FLAGS+=("--glob" "$p")
      else
        # Literal path: resolve relative to workspace
        local abs
        if [[ "${p:0:1}" == "/" ]]; then abs="$p"
        else abs="$WORKSPACE/$p"; fi
        RG_FILE_ARGS+=("$abs")
      fi
    done
  fi
  # If no file args and no globs, default target is workspace dir
  if [[ ${#RG_FILE_ARGS[@]} -eq 0 && ${#RG_GLOB_FLAGS[@]} -eq 0 ]]; then
    RG_FILE_ARGS=("$WORKSPACE")
  elif [[ ${#RG_FILE_ARGS[@]} -eq 0 && ${#RG_GLOB_FLAGS[@]} -gt 0 ]]; then
    # Globs need a root directory to search from
    RG_FILE_ARGS=("$WORKSPACE")
  fi
}

resolve_targets

# ── Shared rg flag builder ─────────────────────────────────────────────────────
rg_common_flags() {
  local flags=("-H")   # always show filename, even for single-file targets
  $REGEX || flags+=("--fixed-strings")
  $ICASE  && flags+=("-i")
  $WWORD  && flags+=("-w")
  [[ -n "$FTYPE" ]] && flags+=("-t" "$FTYPE")
  [[ -n "$IGLOB" ]] && flags+=("--glob" "$IGLOB")
  [[ -n "$XGLOB" ]] && flags+=("--glob" "!$XGLOB")
  # Apply skip dirs only when searching a directory (not explicit files)
  if [[ ${#RG_FILE_ARGS[@]} -gt 0 && -d "${RG_FILE_ARGS[0]}" ]]; then
    flags+=(--glob '!node_modules/**' --glob '!.git/**' --glob '!dist/**'
            --glob '!build/**' --glob '!.next/**' --glob '!__pycache__/**')
  fi
  flags+=("${RG_GLOB_FLAGS[@]}")
  printf '%s\n' "${flags[@]}"
}

# ── Compact line refs for -L table: "AuthService.ts:8,9  routes.ts:7" ─────────
compact_refs() {
  local raw="$1"
  echo "$raw" | grep -v '^--$' | grep -v '^$' | \
  awk -F: -v ws="$WORKSPACE/" '
    NF >= 3 && $2+0 > 0 {
      p=$1; lnum=$2
      sub(ws,"",p)
      n=split(p,a,"/"); fname=a[n]
      if (fname in L) L[fname]=L[fname]","lnum
      else { L[fname]=lnum; O[++c]=fname }
    }
    END {
      for(i=1;i<=c;i++) { f=O[i]; printf "%s%s:%s",(i>1?"  ":""),f,L[f] }
      print ""
    }
  '
}

# ── Single keyword: full coloured output ──────────────────────────────────────
run_single() {
  local kw="$1"
  local mode="literal"; $REGEX && mode="regex"

  local cflags=(); while IFS= read -r f; do [[ -n "$f" ]] && cflags+=("$f"); done < <(rg_common_flags)

  echo
  echo -e "${BOLD}${BLUE}  ws_search${RESET}  ${DIM}${WORKSPACE}${RESET}"
  echo -e "${DIM}  ──────────────────────────────────────────────${RESET}"
  printf "${DIM}  %-12s${RESET} ${CYAN}%s${RESET}\n" "pattern" "$kw"
  printf "${DIM}  %-12s${RESET} %s" "mode" "$mode"
  $ICASE && printf "  ${DIM}case-insensitive${RESET}"
  $WWORD && printf "  ${DIM}whole-word${RESET}"
  echo
  [[ ${#TARGET_PATHS[@]} -gt 0 ]] && \
    printf "${DIM}  %-12s${RESET} %s\n" "files" "${TARGET_PATHS[*]}"
  echo -e "${DIM}  ──────────────────────────────────────────────${RESET}"
  echo

  local out
  out=$(rg --heading --color=always -n -C "$CONTEXT" \
    "${cflags[@]}" -- "$kw" "${RG_FILE_ARGS[@]}" 2>/dev/null || true)

  if [[ -z "$out" ]]; then echo -e "  ${YELLOW}No matches.${RESET}\n"; return; fi
  echo "$out"; echo

  local mc fc
  mc=$(rg --count-matches --color=never "${cflags[@]}" \
    -- "$kw" "${RG_FILE_ARGS[@]}" 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}')
  fc=$(rg -l --color=never "${cflags[@]}" \
    -- "$kw" "${RG_FILE_ARGS[@]}" 2>/dev/null | wc -l | tr -d ' ')
  echo -e "${DIM}  ──────────────────────────────────────────────${RESET}"
  echo -e "  ${GREEN}${BOLD}${mc}${RESET}${GREEN} matches${RESET} in ${BOLD}${fc}${RESET} files"
  echo
}

# ── Per-keyword worker (runs as background job) ────────────────────────────────
search_one() {
  local kw="$1" outfile="$2"
  local cflags=(); while IFS= read -r f; do [[ -n "$f" ]] && cflags+=("$f"); done < <(rg_common_flags)

  local raw
  raw=$(rg -n --no-heading --color=never "${cflags[@]}" -C "$CONTEXT" \
    --max-count "$MAX" -- "$kw" "${RG_FILE_ARGS[@]}" 2>/dev/null || true)

  local mc=0 fc=0
  if [[ -n "$raw" ]]; then
    mc=$(echo "$raw" | awk -F: 'NF>=3 && $2+0>0 {c++} END{print c+0}')
    fc=$(echo "$raw" | awk -F: 'NF>=3 && $2+0>0 {print $1}' | sort -u | wc -l | tr -d ' ')
  fi
  { printf "%s\t%s\t%s\n" "$kw" "$mc" "$fc"; echo "$raw"; } > "$outfile"
}

# ── Multi keyword: parallel summary table ─────────────────────────────────────
run_multi() {
  local tmpd; tmpd=$(mktemp -d); trap "rm -rf '$tmpd'" RETURN
  local t0; t0=$(date +%s%N 2>/dev/null || echo 0)

  if ! $JSON; then
    echo
    echo -e "${BOLD}${BLUE}  ws_search${RESET}  ${DIM}${WORKSPACE}${RESET}"
    if [[ ${#TARGET_PATHS[@]} -gt 0 ]]; then
      printf "${DIM}  files:${RESET}"
      for p in "${TARGET_PATHS[@]}"; do printf " ${CYAN}%s${RESET}" "$p"; done; echo
    fi
    local info=""; $REGEX && info+=" regex"; $ICASE && info+=" -i"; $WWORD && info+=" -w"
    [[ -n "$FTYPE" ]] && info+=" .$FTYPE"
    echo -e "${DIM}  ${#KEYWORDS[@]} keywords · ${JOBS} parallel jobs${info}${RESET}"
    echo -e "${DIM}  ──────────────────────────────────────────────${RESET}"
    echo
  fi

  # Launch background jobs (throttled to $JOBS)
  local idx=0
  for kw in "${KEYWORDS[@]}"; do
    while [[ $(jobs -rp | wc -l) -ge $JOBS ]]; do sleep 0.02; done
    search_one "$kw" "$tmpd/$idx.result" &
    (( idx++ )) || true
  done
  wait

  # Collect results preserving original keyword order
  local total_m=0 total_f=0 hit=0
  declare -A KM KF KD   # matches, files, detail raw text

  local i=0
  for kw in "${KEYWORDS[@]}"; do
    local rf="$tmpd/$i.result"
    local mc=0 fc=0
    if [[ -f "$rf" ]]; then
      IFS=$'\t' read -r _ mc fc <<< "$(head -1 "$rf")" || true
      mc="${mc:-0}"; fc="${fc:-0}"
    fi
    KM["$kw"]="$mc"; KF["$kw"]="$fc"
    KD["$kw"]="$(tail -n +2 "$rf" 2>/dev/null || true)"
    total_m=$(( total_m + mc ))
    [[ "$mc" -gt 0 ]] && (( total_f += fc, hit++ )) || true
    (( i++ )) || true
  done

  local t1; t1=$(date +%s%N 2>/dev/null || echo 0)
  local elapsed="0.000"
  [[ "$t0" != "0" ]] && elapsed=$(awk "BEGIN{printf \"%.3f\",($t1-$t0)/1000000000}")

  # ── JSON ──────────────────────────────────────────────────────────────────
  if $JSON; then
    echo "["
    local first=true
    for kw in "${KEYWORDS[@]}"; do
      $first || echo "  ,"
      first=false
      local mc="${KM[$kw]:-0}" fc="${KF[$kw]:-0}" raw="${KD[$kw]:-}"
      local kw_json; kw_json=$(printf '%s' "$kw" | \
        python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
      printf '  {"keyword": %s, "matches": %s, "files": %s, "hits": [' \
        "$kw_json" "$mc" "$fc"
      local hfirst=true
      while IFS= read -r line; do
        [[ -z "$line" || "$line" == "--" ]] && continue
        local path="${line%%:*}" rest="${line#*:}"
        local lnum="${rest%%:*}" text="${rest#*:}"
        [[ "$lnum" =~ ^[0-9]+$ ]] || continue
        local rpath="${path#$WORKSPACE/}"
        local tj; tj=$(printf '%s' "$text" | \
          python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip()))')
        $hfirst || printf ","
        hfirst=false
        printf '\n    {"file":"%s","line":%s,"text":%s}' "$rpath" "$lnum" "$tj"
      done <<< "$raw"
      printf "\n  ]}"
    done
    printf "\n]\n"
    return
  fi

  # ── Table with -L (inline line refs) ──────────────────────────────────────
  if $SHOW_LINES; then
    printf "  ${BOLD}%-24s %5s  %4s  %s${RESET}\n" "KEYWORD" "HITS" "FILES" "LINE REFS"
    printf "  ${DIM}%s${RESET}\n" \
      "─────────────────────────────────────────────────────────────────────────"
    for kw in "${KEYWORDS[@]}"; do
      local mc="${KM[$kw]:-0}" fc="${KF[$kw]:-0}"
      if [[ "$mc" -gt 0 ]]; then
        local refs; refs=$(compact_refs "${KD[$kw]:-}")
        printf "  ${CYAN}%-24s${RESET} ${GREEN}%5s  %4s${RESET}  ${DIM}%s${RESET}\n" \
          "$kw" "$mc" "$fc" "$refs"
      else
        printf "  ${DIM}%-24s %5s  %4s${RESET}\n" "$kw" "—" "—"
      fi
    done
    printf "  ${DIM}%s${RESET}\n" \
      "─────────────────────────────────────────────────────────────────────────"
    printf "  ${DIM}%-24s${RESET} ${BOLD}%5s  %4s${RESET}  ${DIM}(%ss · %s jobs)${RESET}\n" \
      "TOTAL  (${hit}/${#KEYWORDS[@]} hit)" "$total_m" "$total_f" "$elapsed" "$JOBS"

  # ── Table without -L ──────────────────────────────────────────────────────
  else
    printf "  ${BOLD}%-28s %7s  %5s${RESET}\n" "KEYWORD" "MATCHES" "FILES"
    printf "  ${DIM}%s${RESET}\n" "──────────────────────────────────────────────"
    for kw in "${KEYWORDS[@]}"; do
      local mc="${KM[$kw]:-0}" fc="${KF[$kw]:-0}"
      if [[ "$mc" -gt 0 ]]; then
        printf "  ${CYAN}%-28s${RESET} ${GREEN}%7s  %5s${RESET}\n" "$kw" "$mc" "$fc"
      else
        printf "  ${DIM}%-28s %7s  %5s${RESET}\n" "$kw" "—" "—"
      fi
    done
    printf "  ${DIM}%s${RESET}\n" "──────────────────────────────────────────────"
    printf "  ${DIM}%-28s${RESET} ${BOLD}%7s  %5s${RESET}  ${DIM}(%ss · %s jobs)${RESET}\n" \
      "TOTAL  (${hit}/${#KEYWORDS[@]} hit)" "$total_m" "$total_f" "$elapsed" "$JOBS"
  fi
  echo

  # ── Detail block (-D) ────────────────────────────────────────────────────
  if $DETAIL; then
    echo -e "${DIM}  ──────────────────────────────────────────────${RESET}"
    for kw in "${KEYWORDS[@]}"; do
      [[ "${KM[$kw]:-0}" -eq 0 ]] && continue
      echo
      echo -e "  ${BOLD}${CYAN}${kw}${RESET}"
      echo "${KD[$kw]}" | sed "s|${WORKSPACE}/||g" | \
        awk -F: '
          /^--$/ || /^$/ { next }
          NF>=3 && $2+0>0 { printf "    \033[2m%s\033[0m\033[33m:%s:\033[0m  %s\n", $1,$2,substr($0,index($0,$3)) }
          NF<3  || $2+0==0 { printf "    %s\n",$0 }
        '
    done
    echo
  fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
if [[ ${#KEYWORDS[@]} -eq 1 ]] && ! $JSON; then
  run_single "${KEYWORDS[0]}"
else
  run_multi
fi
