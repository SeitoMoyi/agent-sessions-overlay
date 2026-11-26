#!/bin/bash
# Mole - Sessions command
# Manage Claude Code / Codex / Antigravity agent sessions (Codeg aware).
#
#   mo sessions [-a AGENT] [-n] [--purge]  pick sessions to remove (Space select, Enter confirm)
#   mo sessions list [-a AGENT] [-q KEYWORD] [-n COUNT]
#   mo sessions show <SEL>
#   mo sessions rm <SEL...> [-y] [-n] [--purge] [--force]
#   mo sessions prune --days N [-a AGENT] [-y] [-n] [--purge]
#   mo sessions orphans [-y] [-n] [--purge]  clean sessions deleted in Codeg UI whose files remain
#   mo sessions trash                      list the session trash
#   mo sessions restore <BATCH|ENTRY>      restore from the session trash
#   mo sessions empty-trash [-y]
#
# <SEL>: number from the last `list` (3), a range (3-7), or a session-ID prefix (>=4 chars)
# AGENT: claude | codex | antigravity (aliases: cc / cx / ag)
# -n/--dry-run previews without changing anything (MOLE_DRY_RUN=1 works too).
# Deletions go to a trash dir (files + SQL backup of DB rows); --purge deletes permanently.
set -uo pipefail

# User state must never be touched with inherited root privileges.
if [[ "$EUID" -eq 0 ]]; then
  printf '%s\n' 'Run Mole without sudo; mo sessions only changes your own agent sessions.' >&2
  exit 1
fi
export MOLE_CURRENT_COMMAND="${MOLE_CURRENT_COMMAND:-sessions}"
export LC_ALL="${AGENT_SESSIONS_LOCALE:-en_US.UTF-8}"

# shellcheck disable=SC2154
declare MOLE_SELECTION_RESULT   # set by paginated_multi_select
_SESSIONS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SESSIONS_BIN/../lib/core/common.sh"
source "$_SESSIONS_BIN/../lib/ui/menu_paginated.sh"
set +e   # the libraries turn on errexit; this script checks its statuses itself

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
AG_DIR="${ANTIGRAVITY_DIR:-$HOME/.gemini/antigravity-acp}"
CODEG_DB="${CODEG_DB:-$HOME/Library/Application Support/app.codeg/codeg.db}"
TRASH_DIR="${AGENT_SESSIONS_TRASH:-$HOME/.agent-sessions-trash}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-sessions"
LAST="$CACHE_DIR/last.tsv"
TAB=$'\t'

command -v sqlite3 >/dev/null || { echo "sqlite3 is required" >&2; exit 1; }
mkdir -p "$CACHE_DIR"
TMP=$(mktemp -d)
cleanup() { show_cursor 2>/dev/null; rm -rf "$TMP"; }  # SAFE: private mktemp -d scratch dir
trap cleanup EXIT; trap 'exit 130' INT TERM

# Short aliases for Mole's colours (empty under NO_COLOR or when piped).
R=$RED G=$GREEN Y=$YELLOW C=$CYAN D=$GRAY N=$NC B=${NC:+$'\e[1m'}

die()  { echo "${R}error:${N} $*" >&2; exit 1; }
warn() { echo "${Y}warning:${N} $*" >&2; }
sq()   { sqlite3 -cmd ".timeout 5000" "$@"; }
# BSD stat/date by absolute path: GNU coreutils earlier in PATH misreads -f / -r.
STAT_BSD="${STAT_BSD:-/usr/bin/stat}"; DATE_BSD="${DATE_BSD:-/bin/date}"
fdate(){ "$DATE_BSD" -r "$1" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "-"; }
human_to() { printf -v "$1" '%s' "$(bytes_to_human "${2:-0}")"; }   # var bytes, Mole's units
# Removals go to Mole's operations.log, so `mo history` lists them.
oplog() { log_operation "$MOLE_CURRENT_COMMAND" "$@"; }   # action path [detail]
fit_to() {  # var text width → text cut and padded to a display width (CJK aware)
  local _fit; _fit=$(truncate_by_display_width "$(mole_terminal_safe_text "$2")" "$3")   # _fit: must not shadow the caller's var
  printf -v "$1" '%s%*s' "$_fit" $(($3 - $(get_display_width "$_fit"))) ""
}
plural() { [ "$1" = 1 ] && echo "$1 $2" || echo "$1 ${2}s"; }
# Mole's confirm: Enter confirms, anything else cancels; -y skips it.
confirm_enter() {  # prompt
  [ "${YES:-0}" = 1 ] && return 0
  local k
  echo -ne "${PURPLE}${ICON_ARROW}${NC} $1  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "
  if ! { IFS= read -r -s -n1 k </dev/tty; } 2>/dev/null; then
    echo; echo "No terminal to confirm in; pass -y to run unattended." >&2; return 1
  fi
  echo
  [ -z "$k" ]
}
valid_id(){ [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
norm_agent(){
  case "${1:-}" in
    ""|all) echo all ;; claude|cc|claude_code) echo claude ;;
    codex|cx) echo codex ;; antigravity|ag|gemini) echo antigravity ;;
    *) die "unknown agent: $1" ;;
  esac
}

# ---------------------------------------------------------------- scanning
# index fields: agent id mtime size cwd title path flags
# Scanners emit only what the session files themselves say; scan() then joins
# titles/cwds from Codeg and Codex metadata in one awk pass instead of one
# lookup process per session.
CODEG_TITLED=" "   # IDs Codeg already has a title for (skip the costly Claude title grep)
codeg_map() {
  : > "$TMP/codeg"; CODEG_TITLED=" "
  [ -f "$CODEG_DB" ] || return 0
  sq -readonly -separator "$TAB" "$CODEG_DB" \
    "select external_id, replace(replace(coalesce(title,''),char(9),' '),char(10),' '),
            case when deleted_at is null then '' else 'D' end
       from conversation where external_id is not null" > "$TMP/codeg" 2>/dev/null || true
  CODEG_TITLED=" $(awk -F'\t' '$2!=""{printf "%s ", $1}' "$TMP/codeg")"
}
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }

claude_title() {
  local f=$1 t
  t=$(grep -oE '"(customTitle|aiTitle|summary)":"([^"\\]|\\.)*"' "$f" 2>/dev/null | tail -1 | sed -E 's/^"[a-zA-Z]+":"//; s/"$//')
  [ -n "$t" ] && { printf '%s' "$t"; return; }
  grep '"type":"user"' "$f" 2>/dev/null | grep -v '"tool_result"' | grep -v '"isMeta":true' | grep -v '<command-' \
    | head -1 | grep -oE '"(text|content)":"([^"\\]|\\.)*"' | head -1 | sed -E 's/^"(text|content)":"//; s/"$//'
}

scan_claude() {
  local f j id cwd title fl pid sid active=" "
  for j in "$CLAUDE_DIR"/sessions/*.json; do      # live Claude processes
    [ -f "$j" ] || continue
    pid=$(grep -o '"pid":[0-9]*' "$j" | head -1 | cut -d: -f2)
    sid=$(grep -o '"sessionId":"[^"]*"' "$j" | head -1 | cut -d'"' -f4)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && active="$active$sid "
  done
  for f in "$CLAUDE_DIR"/projects/*/*.jsonl; do
    [ -f "$f" ] || continue
    id=${f##*/}; id=${id%.jsonl}
    cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" | cut -d'"' -f4)
    title=""; [[ "$CODEG_TITLED" == *" $id "* ]] || title=$(claude_title "$f")
    fl=""; [[ "$active" == *" $id "* ]] && fl="*"
    row claude "$id" "" "" "$cwd" "$title" "$f" "$fl"      # mtime/size: batch stat in finish_index
  done
}

scan_codex() {
  local f db id cwd fl
  for db in "$CODEX_DIR"/state_*.sqlite; do       # title/cwd metadata, joined in scan()
    [ -f "$db" ] && sq -readonly -separator "$TAB" "$db" \
      "select id, cwd, replace(replace(coalesce(nullif(name,''),nullif(title,''),first_user_message,''),char(9),' '),char(10),' ')
         from threads" >> "$TMP/meta" 2>/dev/null
  done
  [ -f "$CODEX_DIR/session_index.jsonl" ] && sed -nE 's/.*"id":"([^"]+)".*"thread_name":"(([^"\\]|\\.)*)".*/\1\t\t\2/p' \
      "$CODEX_DIR/session_index.jsonl" >> "$TMP/meta"
  find "$CODEX_DIR/sessions" "$CODEX_DIR/archived_sessions" -name 'rollout-*.jsonl' 2>/dev/null | while read -r f; do
    [[ "$f" =~ ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$ ]] || continue
    id=${BASH_REMATCH[1]}
    cwd=$(head -1 "$f" | grep -o '"cwd":"[^"]*"' | head -1 | cut -d'"' -f4)
    fl=""; [[ "$f" == */archived_sessions/* ]] && fl="A"
    row codex "$id" "" "" "$cwd" "" "$f" "$fl"
  done
}

scan_antigravity() {
  local d="$AG_DIR/conversations" id f cwd main mz
  [ -d "$d" ] || return 0
  for f in "$d"/*.db "$d"/*.meta; do [ -e "$f" ] && basename "$f" | sed -E 's/\.(db|meta)$//'; done | sort -u | while read -r id; do
    # total size of all companions; newest mtime ignoring -shm (readers touch it too)
    mz=$("$STAT_BSD" -f '%m%t%z%t%N' "$d/$id".* 2>/dev/null |
      awk -F'\t' '{s+=$2} $3 !~ /-shm$/ && $1>m {m=$1} END{printf "%d\t%d", m, s}')
    cwd=$(grep -o '"cwd": *"[^"]*"' "$d/$id.meta" 2>/dev/null | sed -E 's/.*: *"//; s/"$//')
    main="$d/$id.db"; [ -e "$main" ] || main="$d/$id.meta"
    row antigravity "$id" "${mz%%$TAB*}" "${mz#*$TAB}" "$cwd" "" "$main" ""
  done
}

# Join metadata, drop unsafe IDs, mark sessions held open by a running agent
# (lsof; Claude uses its own pid files), fill empty fields with "-".
finish_index() {  # raw index file → stdout
  local raw=$1 paths
  paths=$(awk -F'\t' '$1!="claude"{print $7}' "$raw")
  if [ -n "$paths" ] && command -v lsof >/dev/null; then
    printf '%s\n' "$paths" | tr '\n' '\0' | xargs -0 lsof -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u > "$TMP/open"
  else : > "$TMP/open"; fi
  # one stat for every single-file session (Antigravity rows already carry totals)
  awk -F'\t' '$3==""{print $7}' "$raw" | tr '\n' '\0' | xargs -0 "$STAT_BSD" -f '%m%t%z%t%N' 2>/dev/null > "$TMP/stat"
  awk -F'\t' -v OFS='\t' '
    function tidy(t) { gsub(/\\[nt]/, " ", t); gsub(/\\"/, "\"", t); gsub(/[\t\r\n ]+/, " ", t); sub(/^ /, "", t); return t }
    FILENAME==ARGV[1] { if ($2 != "") ct[$1]=$2; if ($3 != "") del[$1]=1; next }
    FILENAME==ARGV[2] { if ($2 != "" && !($1 in mc)) mc[$1]=$2; if ($3 != "" && !($1 in mt)) mt[$1]=$3; next }
    FILENAME==ARGV[3] { open[$0]=1; next }
    FILENAME==ARGV[4] { p=$0; sub(/^[^\t]*\t[^\t]*\t/, "", p); smt[p]=$1; ssz[p]=$2; next }
    $2 !~ /^[A-Za-z0-9_-]+$/ { next }
    {
      if ($3 == "") { $3=smt[$7]+0; $4=ssz[$7]+0 }
      if ($2 in ct) $6=ct[$2]; else if ($6 == "" && ($2 in mt)) $6=mt[$2]
      if ($2 in mc) $5=mc[$2]
      if ($6 == "" && $1 == "antigravity") $6="(untitled)"
      $6=tidy($6)
      if (($7 in open) && $8 !~ /\*/) $8="*" $8
      if ($2 in del) $8=$8 "D"
      for (i=1; i<=7; i++) if ($i == "") $i="-"
      print
    }' "$TMP/codeg" "$TMP/meta" "$TMP/open" "$TMP/stat" "$raw"
}

scan() {  # $1 = agent filter
  local a; a=$(norm_agent "${1:-all}")
  codeg_map; : > "$TMP/meta"
  { [ "$a" = all ] || [ "$a" = claude ]      && scan_claude
    [ "$a" = all ] || [ "$a" = codex ]       && scan_codex
    [ "$a" = all ] || [ "$a" = antigravity ] && scan_antigravity
  } > "$TMP/raw"
  finish_index "$TMP/raw" | sort -t"$TAB" -k3,3nr
}

# ---------------------------------------------------------------- display
proj_to() {  # var cwd → short project label
  local _p
  case "$2" in
    *app.codeg/chat-sessions*) _p="(codeg chat)";; ""|-) _p="-";;
    "$HOME") _p="~";; *) _p=${2%/}; _p=${_p##*/};;
  esac
  printf -v "$1" '%s' "$_p"
}
print_table() {  # stdin: index; also writes LAST
  local n=0 agent id mt size cwd title path fl proj hs col
  cat > "$LAST"
  printf "${B}%-4s %-3s %-12s %-9s %-16s %7s  %-20s %s${N}\n" "#" "" AGENT ID UPDATED SIZE PROJECT TITLE
  while IFS="$TAB" read -r agent id mt size cwd title path fl; do
    n=$((n+1))
    proj_to proj "$cwd"; human_to hs "$size"
    case $agent in claude) col=$C;; codex) col=$G;; *) col=$Y;; esac
    printf "%-4s ${R}%-3s${N} ${col}%-12s${N} %-9s %-16s %7s  %-20s %s\n" \
      "$n" "$fl" "$agent" "${id:0:8}" "$(fdate "$mt")" "$hs" "${proj:0:20}" "${title:0:60}"
  done < "$LAST"
  [ "$n" -eq 0 ] && echo "${D}(no sessions)${N}"
  echo "${D}flags: * running (protected)  D deleted in Codeg UI  A Codex archived${N}"
}

cmd_list() {
  local agent=all q="" lim=0
  while [ $# -gt 0 ]; do case $1 in
    -a|--agent) agent=$2; shift;; -q|--query) q=$2; shift;; -n) lim=$2; shift;;
    claude|cc|codex|cx|antigravity|ag) agent=$1;;
    *) die "list: unknown argument $1";; esac; shift; done
  [[ "$lim" =~ ^[0-9]+$ ]] || die "list: -n needs a number"
  scan "$agent" > "$TMP/idx"
  if [ -n "$q" ]; then grep -iF -- "$q" "$TMP/idx" > "$TMP/f" || true; mv "$TMP/f" "$TMP/idx"; fi
  [ "$lim" -gt 0 ] && { head -n "$lim" "$TMP/idx" > "$TMP/f"; mv "$TMP/f" "$TMP/idx"; }
  print_table < "$TMP/idx"
}

# resolve selectors to index rows (stdout)
resolve() {
  local tok a b i
  for tok in "$@"; do
    # a number is a row of the last listing; past its end, a >=4-digit token is an ID prefix
    if [[ "$tok" =~ ^[0-9]+$ ]] && { [ ${#tok} -lt 4 ] || [ "$tok" -le "$(wc -l < "$LAST" 2>/dev/null || echo 0)" ]; }; then
      [ -s "$LAST" ] || die "no previous listing — run list first"
      sed -n "${tok}p" "$LAST" | grep . || die "no item #$tok"
    elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      [ -s "$LAST" ] || die "no previous listing — run list first"
      a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
      sed -n "${a},${b}p" "$LAST"
    elif [ ${#tok} -ge 4 ] && valid_id "$tok"; then
      [ -s "$TMP/all" ] || scan all > "$TMP/all"
      local m; m=$(awk -F'\t' -v p="$tok" 'index($2,p)==1' "$TMP/all")
      [ -n "$m" ] || die "no session matches ID prefix $tok"
      [ "$(printf '%s\n' "$m" | wc -l)" -gt 1 ] && die "ID prefix $tok is ambiguous"
      printf '%s\n' "$m"
    else die "unrecognized selector: $tok"; fi
  done | awk '!seen[$1 FS $2]++'
}

cmd_show() {
  [ $# -ge 1 ] || die "usage: show <SEL>"
  resolve "$@" > "$TMP/show" || exit 1
  show_rows < "$TMP/show"
}
show_rows() {
  while IFS="$TAB" read -r agent id mt size cwd title path fl; do
    echo "${B}$agent${N}  $id  ${R}$fl${N}"
    echo "  Title:   $title"
    echo "  Dir:     ${cwd:--}"
    echo "  Updated: $(fdate "$mt")   Size: $(bytes_to_human "$size")"
    echo "  Files:"; related_files "$agent" "$id" "$path" | sed 's/^/    /'
    if [ -f "$CODEG_DB" ]; then
      sq -readonly "$CODEG_DB" "select '  Codeg: #'||id||' '||coalesce(title,'')||' ['||status||']'||case when deleted_at is null then '' else ' (deleted)' end from conversation where external_id='$id'" 2>/dev/null
    fi
    if [ "$agent" != antigravity ]; then
      echo "  First user messages:"
      if [ "$agent" = claude ]; then
        grep '"type":"user"' "$path" | grep -v '"tool_result"' | grep -v '"isMeta":true' \
          | grep -oE '"(text|content)":"([^"\\]|\\.)*"' | sed -E 's/^"(text|content)":"//; s/"$//'
      else
        grep '"type":"user_message"' "$path" | grep -oE '"message":"([^"\\]|\\.)*"' | sed -E 's/^"message":"//; s/"$//'
      fi | head -5 | tidy_lines | cut -c1-120 | sed 's/^/    › /'
    fi
    echo
  done
}
tidy_lines(){ sed -E 's/\\[nt]/ /g; s/\\"/"/g; s/[[:space:]]+/ /g; s/^ //' | grep .; }   # JSON escapes → one clean line

# ---------------------------------------------------------------- deletion
related_files() {  # agent id mainpath → files/dirs to remove
  local agent=$1 id=$2 path=$3
  case $agent in
    claude)
      echo "$path"
      local p
      for p in "$(dirname "$path")/$id" "$CLAUDE_DIR/session-env/$id" "$CLAUDE_DIR/file-history/$id" \
               "$CLAUDE_DIR/tasks/$id" "$CLAUDE_DIR/debug/$id.txt" "$CLAUDE_DIR"/todos/"$id"*.json; do
        [ -e "$p" ] && echo "$p"
      done ;;
    codex) echo "$path" ;;
    antigravity) find "$AG_DIR" -maxdepth 3 -name "*$id*" 2>/dev/null ;;
  esac
}

ENTRY=""; SEQ=0; PURGE=0; DRY_RUN=0; [ "${MOLE_DRY_RUN:-0}" = 1 ] && DRY_RUN=1
rec() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ENTRY/manifest.tsv"; }

rm_path() {
  [ -e "$1" ] || return 0
  if [ $PURGE = 1 ]; then rm -rf -- "$1" && oplog REMOVED "$1" "purged"  # SAFE: path comes from related_files for a validated session ID under the agent's own config dir
  else SEQ=$((SEQ+1)); mv -- "$1" "$ENTRY/f$SEQ" && rec file "f$SEQ" "$1" && oplog REMOVED "$1" "session trash $(basename "$BATCH")"; fi
}

rm_lines() {  # file pattern(fixed)
  local f=$1 p=$2
  [ -f "$f" ] && grep -qF -- "$p" "$f" || return 0
  if [ $PURGE = 0 ]; then SEQ=$((SEQ+1)); grep -F -- "$p" "$f" > "$ENTRY/l$SEQ"; rec lines "l$SEQ" "$f"; fi
  grep -vF -- "$p" "$f" > "$TMP/lines" ; cat "$TMP/lines" > "$f"
}

rm_rows() {  # db table where
  local db=$1 t=$2 w=$3 n
  n=$(sq "$db" "select count(*) from \"$t\" where $w" 2>/dev/null) || return 0
  [ "${n:-0}" -gt 0 ] || return 0
  if [ $PURGE = 0 ]; then
    SEQ=$((SEQ+1))
    sq "$db" ".mode insert \"$t\"" "select * from \"$t\" where $w" | sed 's/^INSERT INTO/INSERT OR REPLACE INTO/' > "$ENTRY/s$SEQ"
    rec sql "s$SEQ" "$db"
  fi
  sq "$db" "PRAGMA foreign_keys=ON; delete from \"$t\" where $w;"
}

delete_one() {  # agent id path
  local agent=$1 id=$2 path=$3 db t col
  valid_id "$id" || { warn "skipping invalid ID: $id"; return; }
  local cids=""
  [ -f "$CODEG_DB" ] && cids=$(sq "$CODEG_DB" "select group_concat(id) from conversation where external_id='$id'")
  [ -n "$cids" ] && rm_rows "$CODEG_DB" conversation "id in ($cids)"

  case $agent in
    claude)
      while read -r p; do rm_path "$p"; done < <(related_files claude "$id" "$path")
      rm_lines "$CLAUDE_DIR/history.jsonl" "\"sessionId\":\"$id\"" ;;
    codex)
      rm_path "$path"
      rm_lines "$CODEX_DIR/session_index.jsonl" "\"id\":\"$id\""
      rm_lines "$CODEX_DIR/history.jsonl" "\"session_id\":\"$id\""
      for db in "$CODEX_DIR"/*.sqlite; do
        [ -f "$db" ] || continue
        sq "$db" "select m.name||'$TAB'||p.name from sqlite_master m, pragma_table_info(m.name) p
                  where m.type='table' and (p.name like '%thread_id' or (m.name='threads' and p.name='id'))" 2>/dev/null > "$TMP/cols"
        while IFS="$TAB" read -r t col; do rm_rows "$db" "$t" "\"$col\"='$id'"; done < "$TMP/cols"
      done ;;
    antigravity)
      while read -r p; do rm_path "$p"; done < <(related_files antigravity "$id" "$path") ;;
  esac
}

# back up rows that ON DELETE CASCADE will remove along with the conversation
backup_codeg_cascade() {  # id
  [ $PURGE = 0 ] && [ -f "$CODEG_DB" ] || return 0
  local cids t col; cids=$(sq "$CODEG_DB" "select group_concat(id) from conversation where external_id='$1'")
  [ -n "$cids" ] || return 0
  sq "$CODEG_DB" "select m.name||'$TAB'||f.\"from\" from sqlite_master m, pragma_foreign_key_list(m.name) f
                  where m.type='table' and f.\"table\"='conversation' and f.on_delete='CASCADE'" > "$TMP/fk"
  while IFS="$TAB" read -r t col; do
    local n; n=$(sq "$CODEG_DB" "select count(*) from \"$t\" where \"$col\" in ($cids)")
    [ "${n:-0}" -gt 0 ] || continue
    SEQ=$((SEQ+1))
    sq "$CODEG_DB" ".mode insert \"$t\"" "select * from \"$t\" where \"$col\" in ($cids)" | sed 's/^INSERT INTO/INSERT OR REPLACE INTO/' > "$ENTRY/c$SEQ"
    printf 'sql\tc%s\t%s\n' "$SEQ" "$CODEG_DB" >> "$ENTRY/manifest.tsv.after"
  done < "$TMP/fk"
}


session_label() {  # agent id title → "claude  9800d6b8  Title…"
  local t; fit_to t "$3" 56
  printf '%-11s %s  %s' "$1" "${2:0:8}" "${t%"${t##*[! ]}"}"
}

do_delete() {  # stdin: index rows
  cat > "$TMP/sel"
  [ -s "$TMP/sel" ] || { echo "No sessions to remove"; return 0; }
  local prot n total agent id mt size cwd title path fl done=0
  prot=$(awk -F'\t' '$8 ~ /\*/' "$TMP/sel")
  if [ -n "$prot" ] && [ "${FORCE:-0}" != 1 ]; then
    echo -e "${YELLOW}${ICON_WARNING}${NC} Skipping $(plural "$(printf '%s\n' "$prot" | wc -l | tr -d ' ')" "running session"), quit the agent or pass --force:"
    while IFS="$TAB" read -r agent id mt size cwd title path fl; do
      echo -e "  ${GRAY}${ICON_LIST} $(session_label "$agent" "$id" "$title")${NC}"
    done <<< "$prot"
    awk -F'\t' '$8 !~ /\*/' "$TMP/sel" > "$TMP/sel2"; mv "$TMP/sel2" "$TMP/sel"
    [ -s "$TMP/sel" ] || return 0
  fi
  n=$(wc -l < "$TMP/sel" | tr -d ' ')
  total=$(awk -F'\t' '{s+=$4} END{printf "%d", s}' "$TMP/sel")

  echo -e "\n${PURPLE_BOLD}Sessions to remove:${NC}"
  while IFS="$TAB" read -r agent id mt size cwd title path fl; do
    echo -e "${BLUE}${ICON_CONFIRM}${NC} $(session_label "$agent" "$id" "$title") ${GRAY}· $(bytes_to_human "$size")${NC}"
  done < "$TMP/sel"
  echo
  if [ $PURGE = 1 ]; then echo -e "${RED}--purge removes them permanently, this cannot be undone.${NC}"
  else echo -e "${GRAY}They move to the session trash, mo sessions restore brings them back.${NC}"; fi
  if [ "${DRY_RUN:-0}" = 1 ]; then
    print_summary_block "Dry run complete - no changes made" "Would remove $(plural "$n" session), $(bytes_to_human "$total")"
    return 0
  fi
  confirm_enter "Remove $(plural "$n" session), $(bytes_to_human "$total")" || { echo "Cancelled"; return 0; }

  pgrep -qf '/codeg.app/Contents/MacOS/codeg$' 2>/dev/null &&
    echo -e "${GRAY}${ICON_REVIEW} Codeg is running, refresh or restart it to see the change${NC}"
  BATCH="$TRASH_DIR/$(date +%Y%m%d-%H%M%S)"
  [ $PURGE = 0 ] && mkdir -p "$BATCH"
  log_operation_session_start "$MOLE_CURRENT_COMMAND"
  while IFS="$TAB" read -r agent id mt size cwd title path fl; do
    if [ $PURGE = 0 ]; then
      ENTRY="$BATCH/$agent-$id"; mkdir -p "$ENTRY"; SEQ=100
      printf '%s\t%s\t%s\n' "$agent" "$id" "$title" > "$ENTRY/info.tsv"
      backup_codeg_cascade "$id"
    fi
    delete_one "$agent" "$id" "$path" </dev/null
    [ -f "$ENTRY/manifest.tsv.after" ] && { cat "$ENTRY/manifest.tsv.after" >> "$ENTRY/manifest.tsv"; rm "$ENTRY/manifest.tsv.after"; }
    done=$((done + 1))
    echo -e "${GREEN}${ICON_SUCCESS}${NC} $(session_label "$agent" "$id" "$title") ${GRAY}· $(bytes_to_human "$size")${NC}"
  done < "$TMP/sel"
  log_operation_session_end "$MOLE_CURRENT_COMMAND" "$done" "$((total / 1024))"

  local -a details=("Removed $(plural "$done" session), ${GREEN}$(bytes_to_human "$total")${NC}")
  if [ $PURGE = 0 ]; then details+=("${GRAY}${ICON_REVIEW} Undo with mo sessions restore $(basename "$BATCH")${NC}")
  else details+=("${GRAY}${ICON_REVIEW} Removed permanently${NC}"); fi
  print_summary_block "Sessions removed" "${details[@]}"
  rm -f "$LAST"
}

parse_del_flags() {  # leftover args → ARGS
  ARGS=()
  while [ $# -gt 0 ]; do case $1 in
    -y|--yes) YES=1;; --purge) PURGE=1;; -f|--force) FORCE=1;; -n|--dry-run) DRY_RUN=1;;
    *) ARGS+=("$1");; esac; shift; done
}

cmd_rm() {
  parse_del_flags "$@"
  [ ${#ARGS[@]} -ge 1 ] || die "usage: rm <SEL...> [-y] [--purge]"
  resolve "${ARGS[@]}" > "$TMP/r" || exit 1
  do_delete < "$TMP/r"
}

cmd_prune() {
  local days="" agent=all
  parse_del_flags "$@"; set -- ${ARGS[@]+"${ARGS[@]}"}
  while [ $# -gt 0 ]; do case $1 in
    --days|-d) days=$2; shift;; -a|--agent) agent=$2; shift;; *) die "prune: unknown argument $1";; esac; shift; done
  [[ "$days" =~ ^[0-9]+$ ]] || die "usage: prune --days N"
  local cut=$(( $(date +%s) - days*86400 ))
  scan "$agent" | awk -F'\t' -v c="$cut" '$3 < c' | do_delete
}

cmd_orphans() {
  parse_del_flags "$@"
  scan all | awk -F'\t' '$8 ~ /D/' > "$TMP/o"
  if [ -s "$TMP/o" ]; then echo "Sessions deleted in Codeg whose files still exist:"; do_delete < "$TMP/o"
  else echo "No leftover deleted sessions ✓"; fi
  # Codeg rows whose source files no longer exist
  [ -f "$CODEG_DB" ] || return 0
  scan all | cut -f2 | sort -u > "$TMP/ids"
  sq -readonly -separator "$TAB" "$CODEG_DB" "select id, external_id, agent_type, coalesce(title,'') from conversation where external_id is not null and deleted_at is null" \
    | awk -F'\t' 'FILENAME==ARGV[1]{h[$1]=1;next} !($2 in h)' "$TMP/ids" - > "$TMP/dangling"
  if [ -s "$TMP/dangling" ]; then
    echo; echo "These Codeg conversations have no source files anymore (info only; delete them in Codeg):"
    awk -F'\t' '{printf "  #%-4s %-12s %s  %s\n",$1,$3,substr($2,1,8),$4}' "$TMP/dangling"
  fi
}

# ---------------------------------------------------------------- trash
cmd_trash() {
  [ -d "$TRASH_DIR" ] || { echo "trash is empty"; return; }
  local b e
  for b in "$TRASH_DIR"/*/; do
    [ -d "$b" ] || continue
    echo "${B}$(basename "$b")${N}  $(du -sh "$b" | cut -f1)"
    for e in "$b"*/; do
      [ -f "$e/info.tsv" ] && awk -F'\t' -v e="$(basename "$e")" '{printf "  %-50s %s\n", e, $3}' "$e/info.tsv" | cut -c1-104
    done
  done
}

restore_entry() {
  local e=$1 kind name target
  [ -f "$e/manifest.tsv" ] || { warn "$e has no manifest"; return; }
  # order: files, lines, main rows (s*), then cascade rows (c*)
  sort -t"$TAB" -k2,2 "$e/manifest.tsv" | awk -F'\t' '{k=substr($2,1,1); o=(k=="f"?0:k=="l"?1:k=="s"?2:3); print o"\t"$0}' | sort -n -k1,1 -s | cut -f2- |
  while IFS="$TAB" read -r kind name target; do
    case $kind in
      file)  if [ -e "$target" ]; then warn "already exists, skipping: $target"
             else mkdir -p "$(dirname "$target")" && mv "$e/$name" "$target"; fi ;;
      lines) cat "$e/$name" >> "$target" ;;
      sql)   sq "$target" < "$e/$name" || warn "SQL restore failed: $e/$name" ;;
    esac
  done
  echo "  ${G}✓${N} restored $(basename "$e")"
  rm -rf "$e"  # SAFE: emptied trash entry after its items were restored
}

cmd_restore() {
  [ $# -ge 1 ] || { cmd_trash; echo; die "usage: restore <BATCH|BATCH/ENTRY>"; }
  local t="$TRASH_DIR/$1" e
  [ -d "$t" ] || die "not found: $t"
  if [ -f "$t/manifest.tsv" ] || [ -f "$t/info.tsv" ]; then restore_entry "$t"
  else for e in "$t"/*/; do [ -d "$e" ] && restore_entry "${e%/}"; done; rmdir "$t" 2>/dev/null; fi
}

cmd_empty_trash() {
  parse_del_flags "$@"
  [ -d "$TRASH_DIR" ] || { echo "trash is empty"; return; }
  confirm_enter "Permanently empty the session trash, $(du -sh "$TRASH_DIR" | cut -f1 | tr -d ' ')B" && rm -rf "$TRASH_DIR" && oplog REMOVED "$TRASH_DIR" "session trash emptied" && echo "emptied"  # SAFE: fixed session-trash dir owned by this command
}

# ---------------------------------------------------------------- picker
# Mole's shared multi-select (lib/ui/menu_paginated.sh): Space select, A all,
# Enter confirm, Q cancel, S/O sort, / search. Running sessions are left out.
cmd_interactive() {
  local agent=all
  parse_del_flags "$@"; set -- ${ARGS[@]+"${ARGS[@]}"}
  while [ $# -gt 0 ]; do case $1 in
    -a|--agent) agent=$2; shift;; claude|cc|codex|cx|antigravity|ag) agent=$1;;
    *) die "unknown argument $1 (see mo sessions --help)";; esac; shift; done
  { [ -t 0 ] && [ -t 1 ]; } || { cmd_list -a "$agent"; return; }

  start_inline_spinner "Scanning agent sessions..."
  scan "$agent" > "$TMP/idx"
  stop_inline_spinner
  awk -F'\t' '$8 !~ /\*/' "$TMP/idx" > "$TMP/pickable"
  local running; running=$(awk -F'\t' '$8 ~ /\*/' "$TMP/idx" | wc -l | tr -d ' ')
  if [ ! -s "$TMP/pickable" ]; then
    echo "No sessions to remove$([ "$running" -gt 0 ] && echo ", $(plural "$running" "running session") left alone")"
    return 0
  fi

  local cols tw agent_ id mt size cwd title path fl proj hs line
  local -a rows=() epochs=() sizes=() names=()
  cols=$(tput cols 2>/dev/null || echo 100); [[ "$cols" =~ ^[0-9]+$ ]] || cols=100
  tw=$((cols - 72)); [ $tw -lt 12 ] && tw=12   # "➤ ● " + fixed columns take 72
  while IFS="$TAB" read -r agent_ id mt size cwd title path fl; do
    proj_to proj "$cwd"; fit_to proj "$proj" 16; fit_to line "$title" "$tw"; line=${line%"${line##*[! ]}"}; human_to hs "$size"
    rows+=("$(printf '%-11s %s  %s  %s  %7s  %s %s' "$agent_" "${id:0:8}" "$(fdate "$mt")" "$proj" "$hs" "${R}${fl:- }${N}" "$line")")
    epochs+=("$mt"); sizes+=("$((size / 1024))"); names+=("$title $proj $agent_ $id")
  done < "$TMP/pickable"

  local title_text="Select sessions to remove"
  [ "$running" -gt 0 ] && title_text+=" (${running} running hidden)"
  MOLE_MENU_META_EPOCHS=$(IFS=','; printf '%s' "${epochs[*]}")
  MOLE_MENU_META_SIZEKB=$(IFS=','; printf '%s' "${sizes[*]}")
  MOLE_MENU_FILTER_NAMES=$(printf '%s\n' "${names[@]}")
  export MOLE_MENU_META_EPOCHS MOLE_MENU_META_SIZEKB MOLE_MENU_FILTER_NAMES
  export MOLE_MENU_SORT_MODE=date MOLE_MENU_SORT_REVERSE=false   # oldest first
  MOLE_SELECTION_RESULT=""
  local rc=0
  hide_cursor
  _MOLE_MENU_SELECT_ALL=true paginated_multi_select "$title_text" "${rows[@]}" || rc=$?
  show_cursor
  unset MOLE_MENU_META_EPOCHS MOLE_MENU_META_SIZEKB MOLE_MENU_FILTER_NAMES
  [ $rc -eq 0 ] && [ -n "$MOLE_SELECTION_RESULT" ] || return 0

  local i; : > "$TMP/pick"
  for i in ${MOLE_SELECTION_RESULT//,/ }; do sed -n "$((i + 1))p" "$TMP/pickable" >> "$TMP/pick"; done
  do_delete < "$TMP/pick"
}

usage() { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; }

case "${1:-}" in
  -h|--help|help) usage ;;
  ""|-*|claude|cc|codex|cx|antigravity|ag) cmd_interactive "$@" ;;
  list|ls|l)     shift; cmd_list "$@" ;;
  show|s)        shift; cmd_show "$@" ;;
  rm|delete|del) shift; cmd_rm "$@" ;;
  prune)         shift; cmd_prune "$@" ;;
  orphans)       shift; cmd_orphans "$@" ;;
  trash)         shift; cmd_trash ;;
  restore)       shift; cmd_restore "$@" ;;
  empty-trash)   shift; cmd_empty_trash "$@" ;;
  *) usage >&2; exit 1 ;;
esac
