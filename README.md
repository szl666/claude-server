# claude-server

**One seamless experience in both directions.** The Claude Code UI always runs locally and stays fast, while the real work happens on the server — whichever way your project points:

- **Work on the server as if it were local.** Your project lives **on the server** (too big to copy down); Claude Code drives it locally with zero-friction file access and remote execution. → **Mode B (SSHFS)**: mounted at the identical path, files stay remote (near-zero local disk), commands run remotely.
- **Work locally as if you were on the server.** Your project lives **on your machine**, but every command executes on a powerful remote box. → **Mode A (Mutagen sync)**: files sync both ways, commands run on the server — borrow its CPU (compilation, tests) with a snappy local UI.

Both modes coexist — pick per project. Commands are transparently routed to the server by swapping Claude Code's `$SHELL` for a wrapper; no code changes to your project.

> This is a fork of [langwatch/claude-remote](https://github.com/langwatch/claude-remote) with **Linux-local support, an SSHFS "direct" mode, Tailscale-friendly connectivity, per-session system-prompt injection, permanent SSH connection reuse, and fixes for zsh remote login shells**. See [What's different from upstream](#whats-different-from-upstream).

---

## Quick install (one script per machine)

Two scripts automate the whole setup — one per machine. Both offer an optional
**Tailscale** step (handled by `install/tailscale.sh`) for remotes behind NAT /
CGNAT / IPv6-only — see [Connectivity](#connectivity) for the details it automates.

**1 — On your LOCAL machine** (installs deps, offers Tailscale, generates an SSH key, writes `config.sh` + `~/.ssh/config`, creates the command symlinks, and prompts for the remote host):

```bash
git clone https://github.com/szl666/claude-server.git ~/Projects/claude-server
cd ~/Projects/claude-server
bash install/local.sh
```

It then pauses and prints a one-liner (containing your new public key) to run on the remote.

**2 — On the REMOTE server** (enables the SSH server, installs the key, adds your toolchain to `~/.profile`):

```bash
curl -fsSL https://raw.githubusercontent.com/szl666/claude-server/main/install/remote.sh | bash -s -- '<pubkey that local.sh printed>'
# add --tailscale to also install Tailscale on the remote:
#   ... | bash -s -- '<pubkey>' --tailscale
```

> If the remote can't reach GitHub (e.g. a proxy is in the way), copy `install/remote.sh` to the box and run `bash remote.sh '<pubkey>'` instead.

Back on the local machine, press Enter so `local.sh` verifies SSH and pre-installs the Mutagen agent. Done — then:

```bash
cd <local-project> && claude-remote     # Mode A: local project, runs on the server
crfs /home/you/big-remote-project       # Mode B: server-side project, no local copy
printf 'on\n' > ~/.claude-remote/mode   # turn remote routing on
```

The sections below document the same steps **manually** and explain each piece.

---

## Architecture

```
                LOCAL (macOS or Linux)                         REMOTE (Linux)
  ┌───────────────────────────────────────┐        ┌──────────────────────────────┐
  │ Claude Code (UI/TUI)                   │        │ SSH server                   │
  │   └─ $SHELL = remote-shell.sh ─────────┼──SSH──▶│ commands run here            │
  │                                        │        │ (node/pnpm/python/docker…)   │
  │ Mode A: local files ◀─ Mutagen sync ──▶│◀──────▶│ REMOTE_MIRROR_ROOT/<abs>/    │
  │ Mode B: SSHFS mount  ◀─ live, no copy ─┼──────▶ │ /home/you/<project>/         │
  └───────────────────────────────────────┘        └──────────────────────────────┘
        one persistent SSH master (ControlMaster) shared by ssh + mutagen + sshfs
```

`remote-shell.sh` decides **per directory** how to map paths:

- Directories under a registered **SSHFS mount** (`~/.claude-remote/sshfs-mounts`) → **identity mapping** (local path == remote path), no Mutagen.
- Everything else → **mirror mapping** under `REMOTE_MIRROR_ROOT` (Mutagen).

So Mode A and Mode B run side by side without a global switch.

---

## Requirements

- **Local:** macOS *or* Linux, [Claude Code](https://claude.ai/code), OpenSSH client, [Mutagen](https://mutagen.io/) (Mode A), `sshfs` + FUSE (Mode B only).
- **Remote:** Linux with an SSH server and key-based auth. Nothing else needs installing (Mutagen deploys its agent over SSH; see the zsh caveat below).
- **Network:** direct SSH reachability. If the remote is behind NAT / CGNAT / has only IPv6, [Tailscale](https://tailscale.com/) is the easy path (see [Connectivity](#connectivity)).

---

## Install (local)

```bash
# 1. Install Mutagen
#    macOS:
brew install mutagen-io/mutagen/mutagen
#    Linux (no brew): grab the release tarball and put BOTH files on your PATH
TAG=$(curl -fsSL https://api.github.com/repos/mutagen-io/mutagen/releases/latest | grep -m1 tag_name | cut -d'"' -f4)
curl -fsSL "https://github.com/mutagen-io/mutagen/releases/download/${TAG}/mutagen_linux_amd64_${TAG}.tar.gz" | tar -xz -C /tmp
install -m755 /tmp/mutagen ~/.local/bin/mutagen
cp /tmp/mutagen-agents.tar.gz ~/.local/bin/     # MUST sit next to the mutagen binary

# 2. Clone + run setup
git clone https://github.com/szl666/claude-server.git ~/Projects/claude-server
cd ~/Projects/claude-server
cp config.example.sh config.sh   # then edit it (see Configuration)
./setup.sh                        # symlinks commands into ~/bin, tests SSH

# 3. Make sure ~/bin is on your PATH
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc   # or ~/.zshrc
```

`setup.sh` symlinks: `claude-remote`, `crfs`, `sync-start/stop/status/reap`, `remote-status`, `install-mutagen-agent`.

---

## Configuration

`config.sh` (copy from `config.example.sh`, git-ignored):

```bash
REMOTE_HOST="you@remote-or-tailscale-ip"             # user@host — ssh + mutagen + sshfs all use this
REMOTE_MIRROR_ROOT="/home/you/claude-remote-mirror"  # Mode A mirror root (Mode B ignores it)
PATH_IDENTITY="false"                                # leave false; Mode B does identity per-mount automatically
```

Put the SSH key (and non-standard port, if any) in `~/.ssh/config` so **ssh, mutagen and sshfs all share one persistent connection**:

```
Host remote-or-tailscale-ip
    HostName remote-or-tailscale-ip
    User you
    IdentityFile ~/.ssh/your_key
    IdentitiesOnly yes
    # permanent, shared master — big latency win
    ControlMaster auto
    ControlPath /tmp/ssh-claude-%r@%h:%p
    ControlPersist yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
    TCPKeepAlive yes
```

---

## Connectivity

Any SSH-reachable host works — `REMOTE_HOST` can be a public IP, a LAN address, anything. If the remote is behind NAT/CGNAT or only has IPv6 (a typical home box), **Tailscale** is the easiest way to get a stable, direct, encrypted path between the two machines.

### Tailscale setup (recommended for home / NAT'd remotes)

Both machines join the same tailnet; you then use the remote's `100.x` Tailscale IP as `REMOTE_HOST`.

1. **Install Tailscale** on each machine not already on the tailnet (needs `/dev/net/tun`):
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo systemctl enable --now tailscaled       # start + enable at boot
   ```
2. **Join the tailnet** — on each machine:
   ```bash
   sudo tailscale up --accept-dns=false --hostname=<a-name>
   ```
   It prints a `https://login.tailscale.com/a/...` URL. Open it in a browser, sign in with the **same account on both**, approve the device. `--accept-dns=false` stops Tailscale from touching the box's DNS resolver.
3. **Get addresses & confirm reachability:**
   ```bash
   tailscale ip -4            # this machine's 100.x address
   tailscale status          # list peers; confirm the remote is online
   tailscale ping 100.x.y.z  # "pong ... via <ip>" with no "DERP" = DIRECT (fastest)
   ```
   Put the remote's `100.x` into `config.sh` (`REMOTE_HOST="you@100.x.y.z"`) and `~/.ssh/config`.

### Keep always-on nodes from expiring (tags)

Tailscale node keys expire (~180 days) by default, forcing re-auth. **Tagged devices never expire** — the proper fix for servers:

1. Admin console → **Access Controls** (a HuJSON policy file) → add a tag owner, keeping your existing `grants`/`acls`:
   ```json
   "tagOwners": {
       "tag:box": ["autogroup:admin"]
   },
   ```
   Save. The default allow-all grant (`{"src":["*"],"dst":["*"],"ip":["*"]}`) already lets tagged devices reach everything.
2. Re-run `up` with the tag on each server (it must be able to reach the control plane — see the proxy note):
   ```bash
   sudo tailscale up --advertise-tags=tag:box --accept-dns=false
   ```
3. Verify: `tailscale status --json | grep -A2 Tags` shows `tag:box`; the admin console shows **Expiry: Disabled**.

### ⚠️ Fake-ip proxies (Clash / Mihomo) break Tailscale

A "fake-ip" proxy hands out `198.18.x` placeholder addresses and hijacks DNS. It makes `*.tailscale.com` resolve to `198.18.x`, so **tailscaled can't reach the control plane**: `tailscale up` hangs with no login URL, tagging silently fails, and after a `--reset` the node can drop **fully offline**.

Check with `getent hosts controlplane.tailscale.com` — a `198.18.x` answer means it's being hijacked. Fix, either:

- **Temporary** (just to run `tailscale up`/tagging): use a real resolver first — `echo 'nameserver 223.5.5.5' | sudo tee /etc/resolv.conf` (or briefly stop the proxy) — then restore.
- **Permanent** — whitelist tailscale in the proxy (Clash/Mihomo):
  ```yaml
  rules:
    - DOMAIN-SUFFIX,tailscale.com,DIRECT
    - DOMAIN-SUFFIX,tailscale.io,DIRECT
  dns:
    fake-ip-filter:
      - '+.tailscale.com'
      - '+.tailscale.io'
  ```
  If Tailscale's control plane is blocked on your network, route those domains through a working proxy node instead of `DIRECT`.

### Reverse SSH (remote → local), optional

To SSH from the remote **back into** the local machine over the tailnet: enable sshd locally (`sudo systemctl enable --now ssh`), add the remote's public key to the local `~/.ssh/authorized_keys`, then from the remote run `ssh <localuser>@<local-100.x>`.

---

## Mode A — Offload (local project → remote CPU)

```bash
cd ~/my-local-project
claude-remote          # (alias: cr) syncs THIS dir, launches Claude routing commands to the remote
```

- Only the launch directory is synced (one Mutagen session per directory). `node_modules`, `.venv`, `dist`, `build`, caches, etc. are **not** synced — they live only on the remote where commands run.
- Source, lockfiles and build artifacts sync **both ways** and appear locally.

Helpers: `sync-start [dir]`, `sync-stop`, `sync-status`, `sync-reap` (clear zombie sessions).

## Mode B — Direct (remote project → no local disk)

```bash
crfs /home/you/big-remote-project
```

`crfs` (**c**laude-**r**emote **f**ile**s**ystem) mounts the remote path via SSHFS at the **same absolute path** locally, registers it for identity mapping, and launches Claude. Files stream on demand (near-zero local disk); your native Read/Edit/Write tools edit remote files directly; commands run on the remote at native speed.

- **Search large trees with `rg`/`grep` via Bash** (runs on the remote, fast). Avoid the native Grep/Glob tools on huge dirs — they walk the SSHFS mount over the network.
- Unmount when done: `fusermount -u /home/you/big-remote-project`. `crfs` reuses an existing mount and re-mounts after reboot.

---

## Remote preparation

The remote shell wrapper sources **`~/.profile` only** (not `.bashrc`). Put your toolchain PATH there. To avoid hardcoding a Node version, auto-detect nvm's default:

```sh
# ~/.profile on the remote
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
# add any other tool dirs, e.g. linuxbrew / uv:
export PATH="/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin:$PATH"
```

Verify: `ssh you@remote 'source ~/.profile && which node pnpm python3'`.

**If the remote's login shell is zsh/fish**, pre-install the Mutagen agent once (avoids a "permission denied" agent-install failure):

```bash
install-mutagen-agent            # uses REMOTE_HOST from config.sh
```

Enable the SSH server at boot on both ends as needed: `sudo systemctl enable --now ssh`.

---

## System prompt injection

So you never have to explain the setup at the start of a session ("run this on the remote", "the files are synced", …), each launcher **appends a system prompt** to the Claude session with `claude --append-system-prompt "…"`. The two modes inject **different, mode-appropriate** text, built from your `config.sh` (so `REMOTE_HOST` is filled in automatically):

- **`claude-remote` (Mode A)** tells the session: Bash runs on the remote host; the working dir is Mutagen-synced both ways; use native Read/Edit/Grep/Glob on the local mirror (don't `ssh` to grep); `node_modules`/caches won't appear locally because they stay on the remote.
- **`crfs` (Mode B)** tells the session: the dir is an SSHFS mount of the remote at the identical path; native Read/Edit/Write edit remote files live (no sync step); **search large trees with `rg`/`grep` via Bash** (native remote speed) rather than the native Grep tool over the mount.

To customize the wording, edit `CR_SYSPROMPT` near the bottom of `scripts/claude-remote.sh` or `scripts/crfs.sh`. Because these are launch-time flags, they apply **only** to sessions started via `claude-remote`/`crfs` — a plain `claude` session is unaffected.

## Command routing toggle

Routing is file-backed and re-read on every command (env vars don't survive Claude's per-call `$SHELL` re-exec):

```
~/.claude-remote/mode                 # global on|off
~/.claude-remote/session/<id>         # per-session override (highest precedence)
~/.claude-remote/sshfs-mounts         # registered SSHFS mounts → identity mapping
```

Anything other than exactly `on` routes **locally** (fail-safe). Set a persistent default with `printf 'on\n' > ~/.claude-remote/mode`.

---

## Performance

- **One persistent SSH master** (`ControlPersist yes`) shared by ssh + mutagen + sshfs eliminates per-command handshake/auth (~2× faster bare round-trips).
- The floor on per-command latency is your network RTT to the remote; a **direct** connection is optimal — relays (DERP/peer-relay) only add hops. Confirm directness with `tailscale ping <ip>`.
- Mode A flushes sync before/after each command for consistency; Mode B has no sync step (SSHFS is live).

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| Commands return **empty output** | A fragile `~/.bashrc` sourced under a zsh remote shell aborted the command. This fork **removed** that; ensure PATH is in `~/.profile`. |
| Mutagen: `permission denied: ./.mutagen-agent…` | zsh/fish login shell left the agent non-executable. Run `install-mutagen-agent`. |
| `node`/`pnpm` "command not found" on remote | PATH not in `~/.profile` (wrapper doesn't read `.bashrc`). See [Remote preparation](#remote-preparation). |
| SSHFS search slow | Use `rg`/`grep` via Bash (runs on remote); avoid native Grep on huge mounts. |
| Commands hang after network change | Stale SSH control socket: `rm /tmp/ssh-claude-*` (wrapper also auto-detects). |
| Tailscale peer `node key has expired` | Re-auth: `tailscale up`. Permanent fix: tag the node (tagged devices don't expire). |
| Tailscale can't reach control plane / hangs with no login URL | A fake-ip proxy (`198.18.x`) is hijacking `*.tailscale.com`. Use real DNS / whitelist those domains, then retry. |

### Survives reboot
- Enabled at boot: `tailscaled`, `ssh` (both ends). Tailscale login persists.
- On-demand (re-established on next launch, by design): Mutagen daemon + sync sessions (`claude-remote` restarts them), SSHFS mounts (`crfs` re-mounts).

---

## What's different from upstream

Versus [langwatch/claude-remote](https://github.com/langwatch/claude-remote):

- **Linux local machine support** (Mutagen via release tarball; macOS-only notifications degrade gracefully).
- **Mode B / `crfs`**: SSHFS "direct" mode for large remote projects (near-zero local disk), coexisting with Mutagen mirror mode via per-directory path mapping (`_is_identity_path` + `~/.claude-remote/sshfs-mounts`).
- **System-prompt injection** per launcher (`--append-system-prompt`) so each session knows its execution model.
- **Permanent, shared SSH master** (`ControlPersist=yes` + keepalives) across ssh/mutagen/sshfs.
- **Removed** the `source <(sed … ~/.bashrc)` step that yielded empty output under zsh remote login shells.
- **`install-mutagen-agent`** helper for zsh/fish remotes.
- Docs for **Tailscale** connectivity, node-key expiry via tags, and fake-ip proxy pitfalls.

---

## License

MIT — same as the upstream project. See [LICENSE](LICENSE). Original work © the langwatch/claude-remote authors; modifications © this fork's authors.
