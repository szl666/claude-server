#!/usr/bin/env bash
#
# Launch Claude Code with remote execution and filesystem
# Usage: claude-remote [claude-args...]
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

# === WRAPS-NOT-ACTIVATES: seed mode=off on first launch ===
# If no global mode file exists yet, write "off" so that a fresh environment
# is passthrough-local by default.  If the user has already toggled on via
# /claude-remote on, the session file is present and takes precedence.
_CR_STATE_DIR="${CLAUDE_REMOTE_STATE_DIR:-$HOME/.claude-remote}"
if [[ ! -f "$_CR_STATE_DIR/mode" ]]; then
    mkdir -p "$_CR_STATE_DIR"
    printf 'off\n' > "$_CR_STATE_DIR/mode"
fi

# Always use CWD
WORK_PATH="$(pwd -P)"

# Ensure mutagen sync is running for this directory
"$SCRIPT_DIR/sync-start.sh" "$WORK_PATH"

# === FIX 4d: Reap zombie sync sessions before launching ===
"$SCRIPT_DIR/sync-reap.sh"

# Check remote shell connection
echo "Remote shell connection:"
"$SCRIPT_DIR/remote-shell.sh" -c "uname -a"

# === Tell Claude it is running in remote-offload mode (appended to system prompt) ===
# Uses REMOTE_HOST from config.sh so it always matches the configured box.
CR_SYSPROMPT="You are running in claude-remote 'remote offload' mode.
- Your Bash/shell commands are routed to and executed on the remote host ${REMOTE_HOST} (NOT this local machine), automatically via a shell wrapper whenever remote mode is on (the default here). Just run commands normally — never manually 'ssh' to the remote to run things.
- The current working directory is bidirectionally file-synced (Mutagen) with the remote. Your native Read/Edit/Grep/Glob/file-search tools operate on local mirror files that are identical to the remote copy — use them as usual for searching and reading. Do NOT shell out to the remote (ssh/grep/cat) to inspect files; the local mirror is authoritative and faster.
- NOT synced (they live only on the remote where commands run): node_modules, .venv, dist, build, target, __pycache__ and other caches. So after installs/builds those won't appear locally — that is expected, not an error.
- Remote toolchain available: node (nvm, default version), pnpm, python3/pip (linuxbrew), uv, docker, git.
- If a command unexpectedly seems to run locally, the mode file ~/.claude-remote/mode may be 'off'."

# Launch Claude with remote shell
SHELL="$SCRIPT_DIR/zsh" exec claude --dangerously-skip-permissions --append-system-prompt "$CR_SYSPROMPT" "$@"
