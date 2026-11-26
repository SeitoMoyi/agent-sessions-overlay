#!/bin/bash
# Installs or updates `mo` with `mo sessions` from this repo's latest GitHub
# release (upstream Mole source + this overlay), using Mole's own installer (it asks for your password when the
# launcher lives in a root-owned folder such as /usr/local/bin).
#
#   ./update-mole.sh           install or update now
#   FORCE=1 ./update-mole.sh   reinstall even if already up to date
#
# Use this instead of `mo update`: `mo update` installs the official Mole,
# which has no `mo sessions`. Your sessions trash is kept either way.
set -euo pipefail

REPO="${MOLE_SESSIONS_REPO:-SeitoMoyi/agent-sessions-overlay}"
CONFIG_DIR="${MOLE_CONFIG_DIR:-$HOME/.config/mole}"
STAMP="$CONFIG_DIR/.sessions-release"

say() { printf '%s\n' "$*"; }
fail() { say "error: $*" >&2; exit 1; }

[ "$EUID" -ne 0 ] || fail "run without sudo; Mole's installer asks for it when needed"

say "$(date '+%F %T') checking $REPO"
latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
  || fail "cannot reach github.com/$REPO"
tag=${latest##*/}
[[ "$tag" =~ ^V[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$REPO has no release yet"

have=$(cat "$STAMP" 2>/dev/null || true)
if [ "$have" = "$tag" ] && [ -f "$CONFIG_DIR/bin/sessions.sh" ] && [ "${FORCE:-0}" != 1 ]; then
  say "$tag with mo sessions is up to date."
  exit 0
fi
say "Installing $tag with mo sessions (have: ${have:-official Mole or none})"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
base="https://github.com/$REPO/releases/download/$tag"
asset="agent-sessions-overlay-$tag.tar.gz"
curl -fsSL --retry 2 "$base/$asset" -o "$stage/$asset"
curl -fsSL --retry 2 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
(cd "$stage" && shasum -a 256 -c SHA256SUMS) || fail "checksum mismatch; not installing"
tar -xzf "$stage/$asset" -C "$stage"
src="$stage/agent-sessions-overlay-$tag"
[ -f "$src/install.sh" ] && [ -f "$src/bin/sessions.sh" ] || fail "the download has no Mole source"

# Mole's installer installs from the folder it runs in and fetches the official
# analyze/status binaries for the same version.
/bin/bash "$src/install.sh" --config "$CONFIG_DIR"

mkdir -p "$CONFIG_DIR"
printf '%s\n' "$tag" > "$STAMP"
command -v mo >/dev/null 2>&1 && mo --help | grep -q 'mo sessions' \
  && say "Installed $tag. Run: mo sessions" \
  || say "Installed $tag, but 'mo sessions' is not on your PATH yet; open a new terminal."
