#!/bin/bash
# Installs or updates `mo` with `mo sessions`: the latest release of this repo
# (upstream Mole source + the sessions overlay), installed by Mole's own
# installer. It asks for your password when the launcher lives in a root-owned
# folder such as /usr/local/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/SeitoMoyi/agent-sessions-overlay/main/install.sh | bash
#   ./install.sh               same, from a clone
#   FORCE=1 ./install.sh       reinstall even if already up to date
#
# Run it again to update. `mo update` would install the official Mole, which
# has no `mo sessions`. Your session trash is kept either way.
#
# Everything runs inside main(), called on the last line, so a download cut
# short when piped from curl never runs half a script.
set -euo pipefail

STAGE=""   # global: the EXIT trap runs after main() has returned
main() {
  local repo="${MOLE_SESSIONS_REPO:-SeitoMoyi/agent-sessions-overlay}"
  local config_dir="${MOLE_CONFIG_DIR:-$HOME/.config/mole}"
  local stamp="$config_dir/.sessions-release"
  local latest tag have base asset src tty=/dev/null

  say() { printf '%s\n' "$*"; }
  fail() { say "error: $*" >&2; exit 1; }

  [ "$(uname -s)" = Darwin ] || fail "this is for macOS"
  [ "$EUID" -ne 0 ] || fail "run without sudo; Mole's installer asks for it when needed"
  command -v curl >/dev/null || fail "curl is required"
  command -v sqlite3 >/dev/null || fail "sqlite3 is required (it ships with macOS)"

  latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") \
    || fail "cannot reach github.com/$repo"
  tag=${latest##*/}
  [[ "$tag" =~ ^V[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$repo has no release yet"

  have=$(cat "$stamp" 2>/dev/null || true)
  if [ "$have" = "$tag" ] && [ -f "$config_dir/bin/sessions.sh" ] && [ "${FORCE:-0}" != 1 ]; then
    say "$tag with mo sessions is already installed."
    return 0
  fi
  say "Installing $tag with mo sessions (have: ${have:-official Mole or none})"

  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  local stage=$STAGE
  base="https://github.com/$repo/releases/download/$tag"
  asset="agent-sessions-overlay-$tag.tar.gz"
  curl -fsSL --retry 2 "$base/$asset" -o "$stage/$asset"
  curl -fsSL --retry 2 "$base/SHA256SUMS" -o "$stage/SHA256SUMS"
  (cd "$stage" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "checksum mismatch; not installing"
  tar -xzf "$stage/$asset" -C "$stage"
  src="$stage/agent-sessions-overlay-$tag"
  [ -f "$src/install.sh" ] && [ -f "$src/bin/sessions.sh" ] || fail "the download has no Mole source"

  # Mole's installer installs from the folder it runs in and fetches the
  # official analyze/status binaries for the same version. When this script
  # is piped from curl, stdin is the script itself: give the installer the
  # terminal instead, so it never reads the rest of this file.
  { : < /dev/tty; } 2>/dev/null && tty=/dev/tty
  /bin/bash "$src/install.sh" --config "$config_dir" < "$tty"

  mkdir -p "$config_dir"
  printf '%s\n' "$tag" > "$stamp"
  if command -v mo >/dev/null 2>&1 && mo --help 2>/dev/null | grep -q 'mo sessions'; then
    say "Installed $tag. Run: mo sessions"
  else
    say "Installed $tag. Open a new terminal, then run: mo sessions"
  fi
}

main "$@"
