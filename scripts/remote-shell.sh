#!/usr/bin/env bash
#
# Remote shell wrapper for Claude Code
# Intercepts shell commands and executes them on the remote machine
# Falls back to local execution if remote is unavailable
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

if [[ -z "$REMOTE_MIRROR_ROOT" ]]; then
    echo "Error: REMOTE_MIRROR_ROOT not set in config.sh" >&2
    exit 1
fi

# === MODE TOGGLE (file-backed, per-call) ===
# Precedence (session > project-local > global > env seed > default "on").
# Fail-safe: ANYTHING other than exactly "on" or "off" defaults to LOCAL and
# emits a warning.  A corrupt toggle must NEVER silently SSH to a box.
# Logic lives in lib-mode.sh; sourced here so the gate and the CLI share one copy.
STATE_DIR="${CLAUDE_REMOTE_STATE_DIR:-$HOME/.claude-remote}"
source "$SCRIPT_DIR/lib-mode.sh" || {
    echo "[claude-remote] ERROR: lib-mode.sh not found — cannot resolve mode" >&2
    exit 1
}

_RESOLVED_MODE="$(_resolve_mode)"

# Apply mode — fail-safe: anything that is not exactly "on" routes local
FORCE_LOCAL=0
case "$_RESOLVED_MODE" in
    on)
        : # fall through to normal remote-availability check
        ;;
    off)
        FORCE_LOCAL=1
        ;;
    *)
        FORCE_LOCAL=1
        echo "[claude-remote] WARNING: unrecognized mode '${_RESOLVED_MODE}' — defaulting to local (off)" >&2
        ;;
esac

# === URL OVERRIDE (file-backed) ===
# _resolve_url returns the url-file value (trimmed) when present and non-empty,
# otherwise the config.sh REMOTE_HOST.  Assign unconditionally — it is safe
# because the fallback value IS the current REMOTE_HOST.
# AC11: empty/whitespace url file → _resolve_url returns config.sh value → no change.
REMOTE_HOST="$(_resolve_url)"

SSH_OPTS="-o ControlMaster=auto -o ControlPath=/tmp/ssh-claude-%r@%h:%p -o ControlPersist=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes"
STATE_FILE="/tmp/claude-remote-state"
NOTIFY_COOLDOWN=300  # 5 minutes

# Indirection so tests can inject a stub without touching PATH.
# Production default is /usr/bin/ssh; tests set CLAUDE_REMOTE_SSH=$STUB_BIN/ssh.
SSH_BIN="${CLAUDE_REMOTE_SSH:-/usr/bin/ssh}"

# === PATH IDENTITY (mirror mode vs identity mode) ===
# Identity mode = local path == remote path (no translation). It applies when:
#   - PATH_IDENTITY=true in config.sh (global), OR
#   - the path lives under a registered SSHFS mount, listed one-per-line in
#     $STATE_DIR/sshfs-mounts. This lets the `crfs` (SSHFS) launcher coexist
#     with Mutagen mirror mode without a global config switch — the mapping is
#     chosen per-command based on where you are.
# Otherwise mirror mode: prepend/strip REMOTE_MIRROR_ROOT.
_is_identity_path() {
    [[ "${PATH_IDENTITY:-false}" == "true" ]] && return 0
    local p="$1" root
    if [[ -f "$STATE_DIR/sshfs-mounts" ]]; then
        while IFS= read -r root; do
            [[ -n "$root" && ( "$p" == "$root" || "$p" == "$root"/* ) ]] && return 0
        done < "$STATE_DIR/sshfs-mounts"
    fi
    return 1
}

# Map local path to remote path
local_to_remote() {
    if _is_identity_path "$1"; then
        echo "$1"
    else
        echo "${REMOTE_MIRROR_ROOT}${1}"
    fi
}

# Map remote path to local path
remote_to_local() {
    if _is_identity_path "$1"; then
        echo "$1"
    else
        echo "${1#$REMOTE_MIRROR_ROOT}"
    fi
}

# Send macOS notification with rate limiting
notify() {
    local message="$1"
    local state="$2"  # "offline" or "online"
    local now=$(date +%s)
    local last_state=""
    local last_notify=0

    if [[ -f "$STATE_FILE" ]]; then
        last_state=$(head -1 "$STATE_FILE")
        last_notify=$(tail -1 "$STATE_FILE")
    fi

    # Only notify if state changed, or still offline after cooldown
    if [[ "$state" != "$last_state" ]] || { [[ "$state" == "offline" ]] && [[ $((now - last_notify)) -ge $NOTIFY_COOLDOWN ]]; }; then
        osascript -e "display notification \"$message\" with title \"Claude Remote\"" 2>/dev/null
        echo -e "$state\n$now" > "$STATE_FILE"
    fi
}

# Pick a usable timeout binary (macOS lacks `timeout` by default).
# If neither exists, run the command without a wrapper — SSH's own
# ConnectTimeout still bounds it.
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN=gtimeout
else
    TIMEOUT_BIN=""
fi
_timeout() {
    local secs="$1"; shift
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" "$secs" "$@"
    else
        "$@"
    fi
}

# Check if remote is reachable (fast check with hard timeout)
is_remote_available() {
    # First check if control socket exists but is stale
    local socket="/tmp/ssh-claude-${REMOTE_HOST}:22"
    if [[ -S "$socket" ]]; then
        # Test if socket is alive, remove if stale
        if ! _timeout 1 "$SSH_BIN" -o ControlPath="$socket" -O check "$REMOTE_HOST" 2>/dev/null; then
            /bin/rm -f "$socket" 2>/dev/null
        fi
    fi
    # Plain SSH check without ControlMaster (ControlMaster=auto can hang when creating socket)
    _timeout 5 "$SSH_BIN" -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_HOST" "exit 0" 2>/dev/null
}

# _session_name_for is imported from lib-mode.sh (already sourced above).
# Used to scope mutagen flush to this repo only.

# Parse flags - Claude Code sends: -c -l "command"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c) shift ;;
        -l|-i) shift ;;
        *) cmd="$1"; break ;;
    esac
done

if [[ -n "$cmd" ]]; then
    # Extract pwd file if present
    pwd_file=""
    if [[ "$cmd" =~ (.*)(\&\&\ pwd\ -P\ \>\|\ ([^[:space:]]+))$ ]]; then
        cmd="${BASH_REMATCH[1]}"
        pwd_file="${BASH_REMATCH[3]}"
    fi

    LOCAL_CWD="$(pwd -P)"

    # Session name scoped to this directory
    SESSION_NAME="$(_session_name_for "$LOCAL_CWD")"

    # Check remote availability — skip if mode=off
    if [[ "$FORCE_LOCAL" -eq 0 ]] && is_remote_available; then
        # === REMOTE EXECUTION ===
        notify "Remote instance available" "online"

        REMOTE_CWD="$(local_to_remote "$LOCAL_CWD")"

        # === FIX 3: Flush only this repo's sync session before command ===
        # Skip for identity/SSHFS paths — no Mutagen session exists there.
        _is_identity_path "$LOCAL_CWD" || mutagen sync flush "$SESSION_NAME" >/dev/null 2>&1

        # === FIX 1: .git rewrite block — only needed in legacy (non-identity) mode ===
        if ! _is_identity_path "$LOCAL_CWD"; then
            "$SSH_BIN" $SSH_OPTS "$REMOTE_HOST" "
                if [ -f '$REMOTE_CWD/.git' ] && grep -q 'gitdir:' '$REMOTE_CWD/.git'; then
                    if ! grep -q 'gitdir: ${REMOTE_MIRROR_ROOT}' '$REMOTE_CWD/.git'; then
                        sed -i 's|gitdir: /|gitdir: ${REMOTE_MIRROR_ROOT}/|' '$REMOTE_CWD/.git'
                    fi
                fi
            " 2>/dev/null || true
        fi

        # Build remote command
        # Source .profile and .bashrc (with non-interactive guard disabled)
        MARKER="__CLAUDE_REMOTE_PWD__"
        # NOTE: dropped the `source <(sed ... ~/.bashrc)` step — under a zsh remote
        # login shell it aborted the whole command line, yielding empty output.
        # ~/.profile already carries the full PATH (nvm/linuxbrew/uv), so it suffices.
        remote_cmd="source ~/.profile 2>/dev/null; cd '$REMOTE_CWD'; /bin/bash -c $(printf '%q' "$cmd"); echo $MARKER; pwd -P"

        # Run and capture output
        remote_output=$("$SSH_BIN" $SSH_OPTS "$REMOTE_HOST" "$remote_cmd")
        exit_code=$?

        # === FIX 3: Flush only this repo's sync session after command ===
        _is_identity_path "$LOCAL_CWD" || mutagen sync flush "$SESSION_NAME" >/dev/null 2>&1

        # Split output and handle pwd
        if [[ "$remote_output" == *"$MARKER"* ]]; then
            cmd_output="${remote_output%$MARKER*}"
            remote_pwd="${remote_output##*$MARKER}"
            remote_pwd=$(echo "$remote_pwd" | tr -d '\n')
            printf "%s" "$cmd_output"
            if [[ -n "$pwd_file" ]]; then
                echo "$(remote_to_local "$remote_pwd")" > "$pwd_file"
            fi
        else
            echo "$remote_output"
            [[ -n "$pwd_file" ]] && echo "$LOCAL_CWD" > "$pwd_file"
        fi
    else
        # === LOCAL EXECUTION (mode=off or remote unavailable) ===
        # === FIX 4b: Loud stderr marker so Claude sees the fallback ===
        if [[ "$FORCE_LOCAL" -eq 1 ]]; then
            echo "[claude-remote] LOCAL EXECUTION — MODE=off, running on Mac" >&2
        else
            notify "Remote unavailable - using local execution" "offline"
            echo "[claude-remote] LOCAL FALLBACK — remote $REMOTE_HOST unreachable, running on Mac" >&2
        fi

        # Run locally
        MARKER="__CLAUDE_LOCAL_PWD__"
        local_output=$(/bin/bash -c "$cmd; echo $MARKER; pwd -P" 2>&1)
        exit_code=$?

        # Split output and handle pwd
        if [[ "$local_output" == *"$MARKER"* ]]; then
            cmd_output="${local_output%$MARKER*}"
            local_pwd="${local_output##*$MARKER}"
            local_pwd=$(echo "$local_pwd" | tr -d '\n')
            printf "%s" "$cmd_output"
            [[ -n "$pwd_file" ]] && echo "$local_pwd" > "$pwd_file"
        else
            echo "$local_output"
            [[ -n "$pwd_file" ]] && echo "$LOCAL_CWD" > "$pwd_file"
        fi
    fi

    exit $exit_code
else
    # Interactive shell
    if [[ "$FORCE_LOCAL" -eq 0 ]] && is_remote_available; then
        notify "Remote instance available" "online"
        REMOTE_CWD="$(local_to_remote "$(pwd -P)")"
        "$SSH_BIN" $SSH_OPTS -t "$REMOTE_HOST" "cd '$REMOTE_CWD'; /bin/bash -l"
    else
        if [[ "$FORCE_LOCAL" -eq 1 ]]; then
            echo "[claude-remote] LOCAL EXECUTION — MODE=off, running on Mac" >&2
        else
            notify "Remote unavailable - using local shell" "offline"
        fi
        /bin/bash -l
    fi
fi
