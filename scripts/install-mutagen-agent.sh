#!/usr/bin/env bash
#
# install-mutagen-agent — pre-install the Mutagen agent on the remote box.
#
# Why: when the remote's login shell is zsh (or fish), Mutagen's automatic
# agent installation can leave the agent binary WITHOUT the execute bit, so the
# first sync fails with:
#     remote error: zsh:1: permission denied: ./.mutagen-agent<...>
# This script copies the correct agent binary to
#     ~/.mutagen/agents/<version>/mutagen-agent   (chmod +x)
# on the remote, so Mutagen finds it and skips the failing auto-install.
#
# Usage: install-mutagen-agent [user@host]      (default: REMOTE_HOST from config.sh)
#

set -e

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
source "$SCRIPT_DIR/../config.sh" 2>/dev/null || {
    echo "Error: config.sh not found. Run ./setup.sh first." >&2
    exit 1
}

REMOTE="${1:-$REMOTE_HOST}"
[[ -z "$REMOTE" ]] && { echo "Error: no remote host (set REMOTE_HOST in config.sh)"; exit 1; }

command -v mutagen >/dev/null || { echo "Error: mutagen not installed locally"; exit 1; }
VER="$(mutagen version)"

# Locate the agent bundle that ships next to the mutagen binary.
MUTAGEN_BIN="$(command -v mutagen)"
BUNDLE=""
for cand in \
    "$(dirname "$MUTAGEN_BIN")/mutagen-agents.tar.gz" \
    "$HOME/.local/bin/mutagen-agents.tar.gz" \
    "/usr/local/bin/mutagen-agents.tar.gz"; do
    [[ -f "$cand" ]] && { BUNDLE="$cand"; break; }
done
[[ -z "$BUNDLE" ]] && {
    echo "Error: mutagen-agents.tar.gz not found next to the mutagen binary."
    echo "  Put it alongside 'mutagen' (it ships in the same release tarball)."
    exit 1
}

# Pick the agent entry for the remote's architecture.
RARCH="$(ssh -o BatchMode=yes "$REMOTE" 'uname -m')"
case "$RARCH" in
    x86_64|amd64)   ENTRY=linux_amd64 ;;
    aarch64|arm64)  ENTRY=linux_arm64 ;;
    armv7l|armv7)   ENTRY=linux_arm ;;
    *) echo "Error: unsupported remote arch '$RARCH'"; exit 1 ;;
esac

echo "Pre-installing Mutagen agent $VER ($ENTRY) on $REMOTE ..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$BUNDLE" -C "$TMP" "$ENTRY"
chmod +x "$TMP/$ENTRY"

ssh -o BatchMode=yes "$REMOTE" "rm -f ~/.mutagen-agent* 2>/dev/null; mkdir -p ~/.mutagen/agents/$VER"
scp -q "$TMP/$ENTRY" "$REMOTE:.mutagen/agents/$VER/mutagen-agent"
ssh -o BatchMode=yes "$REMOTE" "chmod +x ~/.mutagen/agents/$VER/mutagen-agent && ~/.mutagen/agents/$VER/mutagen-agent version >/dev/null && echo '  agent OK'"

echo "✓ Mutagen agent $VER pre-installed on $REMOTE"
