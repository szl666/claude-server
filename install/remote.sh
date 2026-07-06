#!/usr/bin/env bash
#
# claude-server — REMOTE machine setup. Run this ON the remote server.
#
# It: enables the SSH server (at boot), installs the local machine's public key,
# and adds your toolchain to ~/.profile (the wrapper sources ~/.profile ONLY,
# not ~/.bashrc, on every remote command).
#
# Usage:   bash remote.sh '<local-public-key-string>'
#   or:    curl -fsSL https://raw.githubusercontent.com/szl666/claude-server/main/install/remote.sh | bash -s -- '<pubkey>'
#

set -euo pipefail

PUBKEY="${1:-}"

c_say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
c_ok(){ printf '\033[1;32m✓\033[0m  %s\n' "$*"; }
c_warn(){ printf '\033[1;33m!\033[0m  %s\n' "$*"; }

echo "======================================"
echo " claude-server — remote setup ($(hostname))"
echo "======================================"

# --- 1. SSH server on + enabled at boot ---------------------------------------
if command -v systemctl >/dev/null 2>&1; then
    c_say "Enabling SSH server (and at boot)..."
    if sudo -n true 2>/dev/null || [ -t 0 ]; then
        sudo systemctl enable --now ssh 2>/dev/null \
          || sudo systemctl enable --now sshd 2>/dev/null \
          || c_warn "could not enable ssh via systemctl (may already be socket-activated)"
    else
        c_warn "no sudo — ensure the SSH server is running yourself"
    fi
fi
# report what's listening
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -qE ':(22|2[0-9]{3}) ' \
    && c_ok "SSH is listening" || c_warn "no SSH listener detected — start it before connecting"

# --- 2. authorized_keys -------------------------------------------------------
if [ -n "$PUBKEY" ]; then
    c_say "Installing the local machine's public key..."
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
    if grep -qF "$PUBKEY" "$HOME/.ssh/authorized_keys"; then
        c_ok "key already present"
    else
        echo "$PUBKEY" >> "$HOME/.ssh/authorized_keys"; c_ok "key added"
    fi
    # a too-open private key elsewhere can block auth; tidy perms
    chmod 600 "$HOME"/.ssh/id_* 2>/dev/null || true
else
    c_warn "no public key passed — pass it as the first argument to enable key auth"
fi

# --- 3. ~/.profile toolchain PATH ---------------------------------------------
# The wrapper runs 'source ~/.profile' (non-interactively) before each command,
# and does NOT read ~/.bashrc. Put your PATH here so node/pnpm/python resolve.
if grep -q 'claude-server: PATH' "$HOME/.profile" 2>/dev/null; then
    c_ok "~/.profile already has the claude-server PATH block"
else
    c_say "Adding toolchain PATH to ~/.profile..."
    cat >> "$HOME/.profile" <<'PEOF'

# --- claude-server: PATH (sourced non-interactively on every remote command) ---
# auto-detect nvm's default Node (no hardcoded version)
if [ -d "$HOME/.nvm/versions/node" ]; then
    _n=""
    if [ -f "$HOME/.nvm/alias/default" ]; then
        _d="$(cat "$HOME/.nvm/alias/default")"
        for _c in "$_d" "v$_d"; do
            [ -d "$HOME/.nvm/versions/node/$_c/bin" ] && _n="$HOME/.nvm/versions/node/$_c/bin" && break
        done
    fi
    [ -z "$_n" ] && _n="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -n1)"
    [ -n "$_n" ] && PATH="$_n:$PATH"; unset _n _d _c
fi
# common tool dirs (add/remove to taste)
[ -d "/home/linuxbrew/.linuxbrew/bin" ] && PATH="/home/linuxbrew/.linuxbrew/bin:$PATH"
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
export PATH
PEOF
    c_ok "PATH block added"
fi

# --- 4. optional Tailscale (pass '--tailscale' as 2nd arg, or CS_TAILSCALE=1) --
if [ "${2:-}" = "--tailscale" ] || [ "${CS_TAILSCALE:-}" = "1" ]; then
    c_say "Setting up Tailscale on this remote..."
    command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
    command -v systemctl >/dev/null 2>&1 && sudo systemctl enable --now tailscaled 2>/dev/null || true
    c_say "Joining tailnet — open the login URL and approve with your account:"
    sudo tailscale up --accept-dns=false --hostname="$(hostname)"
    c_ok "Remote tailnet IPv4: $(tailscale ip -4 2>/dev/null | head -1) — use this as REMOTE_HOST on the local machine"
fi

echo
c_ok "Remote setup done on $(hostname)."
echo "    Verify your toolchain resolves non-interactively:"
echo "      bash -lc 'source ~/.profile && which node pnpm python3'"
echo "    If some tool is missing, add its bin dir to the block in ~/.profile."
