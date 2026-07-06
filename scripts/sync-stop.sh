#!/usr/bin/env bash
#
# Stop Mutagen sync session
#

# Resolve symlinks to find the real script directory
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

if mutagen sync list 2>/dev/null | grep -q "claude-remote"; then
    echo "Stopping sync session..."
    mutagen sync terminate --label-selector=name=claude-remote
    echo "✓ Sync session stopped"
else
    echo "○ No sync session running"
fi
