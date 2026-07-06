#!/usr/bin/env bash
#
# crfs — "claude-remote fs": work directly on a REMOTE project via SSHFS,
# with commands executed on the remote server. No Mutagen, near-zero local disk.
# Coexists with the Mutagen-based `claude-remote` (mirror mode).
#
# Usage: crfs [remote-abs-path]
#   remote-abs-path  absolute path on the remote box to work in
#                    (default: the remote user's home, /home/<remote-user>)
# The remote path is SSHFS-mounted at the IDENTICAL local path, so local==remote.
#

set -e

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

STATE_DIR="${CLAUDE_REMOTE_STATE_DIR:-$HOME/.claude-remote}"
mkdir -p "$STATE_DIR"

REMOTE_USER="${REMOTE_HOST%@*}"
REMOTE_PATH="${1:-/home/$REMOTE_USER}"
# Strip any trailing slash (but keep root "/")
[[ "$REMOTE_PATH" != "/" ]] && REMOTE_PATH="${REMOTE_PATH%/}"
LOCAL_MOUNT="$REMOTE_PATH"   # identity mount: same absolute path locally

# --- ensure the SSHFS mount ---
if mountpoint -q "$LOCAL_MOUNT" 2>/dev/null; then
    echo "✓ already mounted: $LOCAL_MOUNT"
else
    mkdir -p "$LOCAL_MOUNT"
    echo "Mounting $REMOTE_HOST:$REMOTE_PATH -> $LOCAL_MOUNT (SSHFS)..."
    sshfs "$REMOTE_HOST:$REMOTE_PATH" "$LOCAL_MOUNT" \
        -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks
    echo "✓ mounted (files stay on the remote; streamed on demand)"
fi

# --- register this mount so remote-shell.sh uses identity path mapping under it ---
grep -qxF "$LOCAL_MOUNT" "$STATE_DIR/sshfs-mounts" 2>/dev/null \
    || echo "$LOCAL_MOUNT" >> "$STATE_DIR/sshfs-mounts"

# --- ensure remote command routing is on ---
[[ -f "$STATE_DIR/mode" ]] || printf 'on\n' > "$STATE_DIR/mode"

cd "$LOCAL_MOUNT"

# --- system prompt describing SSHFS-direct mode (only for this launcher) ---
CR_SYSPROMPT="You are running in claude-remote 'SSHFS direct' mode.
- This project lives on the remote host ${REMOTE_HOST}. The current directory is an SSHFS mount of the remote path, at the identical absolute path (local path == remote path). Files are NOT copied to local disk — reads/writes stream to the remote on demand, so this works for large projects without filling local disk.
- Your native Read/Edit/Write tools operate directly on these files and changes land on the remote IMMEDIATELY (there is no sync step).
- Your Bash/shell commands execute ON the remote host at the same path — just run them normally; never manually 'ssh' to the remote.
- IMPORTANT for speed: to SEARCH or traverse large trees, run ripgrep/grep/find via Bash (they execute on the remote at native speed). Do NOT rely on the native Grep/Glob tools for large directories — those walk the SSHFS mount over the network and are slow. For opening/editing a specific known file, the native Read/Edit tools are fine and fast.
- Not present locally as real files: build outputs live wherever the remote build puts them; there is no separate local copy. Remote toolchain: node (nvm), pnpm, python3/pip (linuxbrew), uv, docker, git."

# --- launch Claude with the remote shell wrapper ---
SHELL="$SCRIPT_DIR/zsh" exec claude --permission-mode auto --append-system-prompt "$CR_SYSPROMPT" "$@"
