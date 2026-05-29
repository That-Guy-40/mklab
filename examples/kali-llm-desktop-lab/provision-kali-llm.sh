#!/usr/bin/env bash
# provision-kali-llm.sh — Provision the FULL Kali local-LLM stack INSIDE a Kali
#                         VM (Tier 2-full of the Kali Ollama+5ire blog).
#
#   RUN THIS INSIDE THE KALI VM, AS ROOT — not on your host:
#     scp -P <ssh_port> provision-kali-llm.sh kali@127.0.0.1:/tmp/
#     phase2-qemu-vm/lab-vm.sh ssh kali-llm-desktop -- 'sudo bash /tmp/provision-kali-llm.sh'
#
# Installs, faithfully to https://www.kali.org/blog/kali-llm-ollama-5ire/ :
#   1. Ollama          (LLM runtime + systemd service)         → pulls a model
#   2. mcp-kali-server (nmap/sqlmap/metasploit/… as MCP tools)  → apt
#   3. 5ire            (desktop GUI / MCP client AppImage)      → /opt/5ire
#   4. TigerVNC + XFCE (so you can reach the 5ire GUI over an SSH-tunnelled VNC)
#
# Env knobs:
#   MODEL=llama3.2:1b   model to pull (default; the blog used 3b/4b/8b on a GPU)
#   FIVEIRE_VER=0.15.3  5ire AppImage version (the blog's version)
#   LITE=1              skip the heaviest tools (metasploit-framework, wordlists)
#   VNC_PASS=kali       VNC password for the desktop session (CHANGE THIS)
#   DESKTOP_USER=kali   the unprivileged desktop user the GUI runs as
#
# ⚠️  SECURITY: this gives a local LLM the ability to run real offensive tools
#     (Tier 3). Keep this VM on an isolated network and only ever target hosts
#     you are authorized to test (the blog uses scanme.nmap.org). See README.

set -euo pipefail

MODEL="${MODEL:-llama3.2:1b}"
FIVEIRE_VER="${FIVEIRE_VER:-0.15.3}"
LITE="${LITE:-}"
VNC_PASS="${VNC_PASS:-kali}"
DESKTOP_USER="${DESKTOP_USER:-kali}"

log() { printf '\033[36m[provision]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[provision] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root inside the Kali VM (sudo bash $0)"
command -v apt-get >/dev/null || die "not a Debian/Kali apt system — is this the Kali VM?"
id "$DESKTOP_USER" >/dev/null 2>&1 || die "desktop user '$DESKTOP_USER' does not exist"

export DEBIAN_FRONTEND=noninteractive

# ── 1. Ollama ────────────────────────────────────────────────────────────────
# The blog extracts the tarball + writes a systemd unit by hand; the official
# installer does exactly that (tarball → /usr/bin/ollama + an `ollama` user +
# `ollama.service`) and is the maintained path, so we use it.
if ! command -v ollama >/dev/null; then
    log "installing Ollama (official installer)…"
    curl -fsSL https://ollama.com/install.sh | sh
else
    log "Ollama already installed: $(ollama --version 2>/dev/null || echo '?')"
fi
systemctl enable --now ollama 2>/dev/null || true
# Wait for the API, then pull the model.
log "waiting for the Ollama API (:11434)…"
for _ in $(seq 1 30); do
    curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
    sleep 1
done
log "pulling model: ${MODEL}  (the blog used llama3.2:3b / qwen3:4b / llama3.1:8b on a GPU)"
ollama pull "$MODEL" || die "ollama pull ${MODEL} failed (network? bad tag?)"

# ── 2. mcp-kali-server + the offensive tool set (the blog's apt line) ────────
log "apt update + installing MCP server and tools…"
apt-get update -y
declare -a TOOLS=(mcp-kali-server dirb gobuster nikto nmap enum4linux-ng hydra john sqlmap wpscan)
if [[ -z "$LITE" ]]; then
    TOOLS+=(metasploit-framework wordlists)   # large; LITE=1 skips these
else
    log "LITE=1 → skipping metasploit-framework + wordlists"
fi
apt-get install -y --no-install-recommends "${TOOLS[@]}" \
    || die "apt install failed (is 'mcp-kali-server' in your Kali mirror? it's a recent package)"
command -v mcp-server >/dev/null \
    && log "MCP server present: $(command -v mcp-server)" \
    || log "WARNING: /usr/bin/mcp-server not found — check the mcp-kali-server package"

# ── 3. 5ire desktop GUI / MCP client (AppImage, per the blog) ────────────────
log "installing 5ire ${FIVEIRE_VER} AppImage…"
apt-get install -y --no-install-recommends libfuse2 || true   # AppImages need FUSE
install -d /opt/5ire
appimg="/opt/5ire/5ire-x86_64.AppImage"
if [[ ! -x "$appimg" ]]; then
    curl -fL "https://github.com/nanbingxyz/5ire/releases/download/v${FIVEIRE_VER}/5ire-${FIVEIRE_VER}-x86_64.AppImage" \
        -o "$appimg" || die "5ire download failed (version ${FIVEIRE_VER} still published?)"
    chmod 0755 "$appimg"
fi
# A .desktop launcher so it shows up in the XFCE menu.
cat > /usr/share/applications/5ire.desktop <<EOF
[Desktop Entry]
Name=5ire (AI assistant / MCP client)
Exec=${appimg} %U
Icon=utilities-terminal
Type=Application
Categories=Utility;
EOF
log "5ire installed at ${appimg}"

# ── 4. TigerVNC + XFCE — the GUI, reached over an SSH-tunnelled VNC ──────────
log "installing XFCE + TigerVNC…"
apt-get install -y --no-install-recommends \
    kali-desktop-xfce xfce4 xfce4-terminal dbus-x11 \
    tigervnc-standalone-server tigervnc-common || \
apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal dbus-x11 tigervnc-standalone-server tigervnc-common \
    || die "desktop/VNC install failed"

# Resolve the TigerVNC binaries — Debian/Kali ship them as either `vncserver`/
# `vncpasswd` or the `tigervnc`-prefixed names depending on the release.
VNCSERVER="$(command -v vncserver || command -v tigervncserver)" \
    || die "no vncserver/tigervncserver found after install"
VNCPASSWD="$(command -v vncpasswd || command -v tigervncpasswd)" \
    || die "no vncpasswd/tigervncpasswd found after install"

# Configure the VNC session for the desktop user (NOT root).
home="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
install -d -o "$DESKTOP_USER" -g "$DESKTOP_USER" "$home/.vnc"
# Password file (CHANGE VNC_PASS for anything but a throwaway lab).
printf '%s\n%s\nn\n' "$VNC_PASS" "$VNC_PASS" | runuser -u "$DESKTOP_USER" -- "$VNCPASSWD" >/dev/null 2>&1 || \
    { printf '%s' "$VNC_PASS" | runuser -u "$DESKTOP_USER" -- "$VNCPASSWD" -f > "$home/.vnc/passwd"; \
      chown "$DESKTOP_USER:$DESKTOP_USER" "$home/.vnc/passwd"; chmod 600 "$home/.vnc/passwd"; }
cat > "$home/.vnc/xstartup" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chown "$DESKTOP_USER:$DESKTOP_USER" "$home/.vnc/xstartup"
chmod 0755 "$home/.vnc/xstartup"
# Start the VNC server on :1 (port 5901), LOOPBACK ONLY — reach it via SSH-forward.
runuser -u "$DESKTOP_USER" -- "$VNCSERVER" -kill :1 >/dev/null 2>&1 || true
runuser -u "$DESKTOP_USER" -- "$VNCSERVER" :1 -localhost yes -geometry 1440x900 >/dev/null 2>&1 \
    || die "vncserver failed to start"
log "VNC desktop running on :1 (127.0.0.1:5901), session = XFCE, user = ${DESKTOP_USER}"

# ── Done — next steps ─────────────────────────────────────────────────────────
log "DONE — the full Kali LLM stack is installed in this VM."
cat <<EOF

Reach the desktop from the lab host (the VM's SSH is hostfwd'd to 127.0.0.1:<ssh_port>):

    ssh -p <ssh_port> -L 5901:localhost:5901 ${DESKTOP_USER}@127.0.0.1
    # then point a VNC viewer at  localhost:5901   (VNC password: ${VNC_PASS})

In the XFCE desktop, launch 5ire and configure it (the blog's steps):
  • Workspace → Providers → Ollama → enable; enable model '${MODEL}' (toggle Tools + Enabled).
  • Tools → Local → Name: mcp-kali-server, Command: /usr/bin/mcp-server → enable.
  • New Chat → Ollama → e.g. "port-scan scanme.nmap.org"  → the model runs nmap via MCP.

⚠️  The MCP tools (nmap/sqlmap/metasploit/…) run for real. Keep this VM on an
    isolated network and only target hosts you are authorized to test.
EOF
