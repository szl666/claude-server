#!/usr/bin/env bash
#
# claude-server — optional Tailscale connectivity.
#
# Run on EITHER machine that isn't on your tailnet yet. Installs Tailscale,
# joins the tailnet (prints a browser login URL), and reports this machine's
# 100.x address to use as the SSH target.
#
# Usage:
#   bash tailscale.sh [hostname] [--tag tag:box]
#     hostname    name to show in the tailnet (default: this host's name)
#     --tag NAME  advertise a tag so the node key never expires (needs a
#                 matching tagOwner in the Tailscale admin Access Controls first)
#

set -euo pipefail

NAME="${1:-$(hostname)}"
TAG=""
[ "${2:-}" = "--tag" ] && TAG="${3:-tag:box}"

c_say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
c_ok(){ printf '\033[1;32m✓\033[0m  %s\n' "$*"; }
c_warn(){ printf '\033[1;33m!\033[0m  %s\n' "$*"; }

# --- install ------------------------------------------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
    c_say "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi
if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now tailscaled 2>/dev/null || c_warn "start tailscaled yourself if needed"
fi

# --- join ---------------------------------------------------------------------
UP=(sudo tailscale up --accept-dns=false --hostname="$NAME")
[ -n "$TAG" ] && UP+=(--advertise-tags="$TAG")
c_say "Joining the tailnet — open the login URL it prints and approve with your account:"
"${UP[@]}"

IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
c_ok "On the tailnet as '$NAME' — IPv4: ${IP:-unknown}"
tailscale status 2>/dev/null | head -6 || true

echo
echo "Use this machine's 100.x address where you need to reach it (e.g. REMOTE_HOST)."
if [ -z "$TAG" ]; then
cat <<'TIP'

Tip — node keys expire (~180 days). To make an always-on server NEVER expire,
tag it: add a tagOwner in the Tailscale admin Access Controls (HuJSON):
    "tagOwners": { "tag:box": ["autogroup:admin"] }
then re-run:   bash tailscale.sh <name> --tag tag:box
NOTE: tagging needs the box to reach controlplane.tailscale.com. A fake-ip proxy
(Clash/Mihomo) that maps *.tailscale.com to 198.18.x will block it — whitelist
those domains (real DNS + DIRECT/working node) first.
TIP
else
    c_ok "Tagged with '$TAG' — this node will not expire (verify Expiry=Disabled in the admin console)."
fi
