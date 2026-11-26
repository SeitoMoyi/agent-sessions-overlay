#!/bin/bash
# Tests `mo sessions` inside a patched Mole source tree, against fake
# Claude Code / Codex / Antigravity sessions in a throwaway HOME. Nothing
# outside that temp dir is read or written.
#
#   scripts/smoke_test.sh <patched-mole-source-dir>
set -euo pipefail

SRC=$(cd "${1:?usage: smoke_test.sh <patched-mole-source-dir>}" && pwd)
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT  # SAFE: private mktemp -d sandbox

fails=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf '::error::FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
has()  { grep -qF -- "$2" <<< "$1"; }

# --- fake sessions
mkdir -p "$T/home/.claude/projects/p" "$T/home/.codex/sessions/2026" "$T/home/.gemini/antigravity-acp/conversations"
for i in 1 2 3; do
  printf '{"type":"user","cwd":"/tmp/proj%s","message":{"content":"claude task %s 中文标题"}}\n' "$i" "$i" \
    > "$T/home/.claude/projects/p/aaaa000$i-0000-0000-0000-000000000001.jsonl"
  touch -t "2026010${i}0000" "$T/home/.claude/projects/p/aaaa000$i-0000-0000-0000-000000000001.jsonl"
done
printf '{"cwd":"/tmp/cx"}\n' > "$T/home/.codex/sessions/2026/rollout-x-bbbb0001-0000-0000-0000-000000000002.jsonl"
touch -t 202501010000 "$T/home/.codex/sessions/2026/rollout-x-bbbb0001-0000-0000-0000-000000000002.jsonl"
printf '{"cwd": "/tmp/ag"}' > "$T/home/.gemini/antigravity-acp/conversations/cccc0001.meta"
printf 'x' > "$T/home/.gemini/antigravity-acp/conversations/cccc0001.db"
sqlite3 "$T/codeg.db" "create table conversation(id integer primary key, external_id text, title text,
  status text, deleted_at text, agent_type text);
  insert into conversation(external_id,title,status,deleted_at) values('cccc0001','ag from codeg','ok','2026');"

export HOME="$T/home" XDG_CACHE_HOME="$T/cache" CODEG_DB="$T/codeg.db" TERM=xterm-256color
unset CLAUDE_CONFIG_DIR CODEX_HOME ANTIGRAVITY_DIR AGENT_SESSIONS_TRASH MOLE_DRY_RUN NO_COLOR
mo() { "$SRC/mole" "$@" < /dev/null; }
files() { find "$HOME/.claude/projects" "$HOME/.codex/sessions" "$HOME/.gemini" -type f | wc -l | tr -d ' '; }

# --- wiring into Mole
out=$(mo --help); check "mo --help lists sessions" has "$out" "mo sessions"
out=$(mo sessions --help); check "mo sessions --help" has "$out" "mo sessions list"
out=$("$SRC/bin/completion.sh" bash); check "bash completion has sessions" has "$out" "sessions)"
check "bash completion parses" bash -n <<< "$out"
out=$("$SRC/bin/completion.sh" fish); check "fish completion has sessions" has "$out" "subcommand_from sessions"

# --- scripted commands
out=$(mo sessions list)
check "list shows 5 sessions" test "$(grep -cE '^[0-9]+ ' <<< "$out")" = 5
check "list reads the Codeg title and deleted flag" has "$out" "ag from codeg"
check "list keeps CJK titles" has "$out" "中文标题"
out=$(mo sessions prune --days 30 -n)
check "prune --dry-run previews" has "$out" "Dry run complete"
check "prune --dry-run changes nothing" test "$(files)" = 6
out=$(mo sessions rm aaaa0001 2>&1 || true)
check "rm without a terminal or -y refuses" has "$out" "pass -y"
check "refused rm changes nothing" test "$(files)" = 6
out=$(mo sessions rm aaaa0001 bbbb0001 -y)
check "rm -y removes" has "$out" "Removed 2 sessions"
check "rm -y moved the files" test "$(files)" = 4
out=$(mo sessions orphans -y)
check "orphans removes the session deleted in Codeg" has "$out" "Removed 1 session"
check "Codeg row removed" test "$(sqlite3 "$CODEG_DB" 'select count(*) from conversation')" = 0
check "operations.log records the removals" grep -q '\[sessions' "$HOME/Library/Logs/mole/operations.log"
for b in "$HOME"/.agent-sessions-trash/*/; do mo sessions restore "$(basename "$b")" > /dev/null; done
check "restore brings every file back" test "$(files)" = 6
check "restore brings the Codeg row back" test "$(sqlite3 "$CODEG_DB" 'select count(*) from conversation')" = 1

# --- interactive picker (Mole's shared menu) through a pseudo-terminal
if python3 -I "$HERE/picker_pty.py" "$SRC/mole"; then ok "picker: select oldest, confirm, remove"
else bad "picker: select oldest, confirm, remove"; fi
check "picker removed exactly the oldest session" test ! -e "$HOME/.codex/sessions/2026/rollout-x-bbbb0001-0000-0000-0000-000000000002.jsonl"
check "picker left the rest" test "$(files)" = 5

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
