#!/bin/bash
# Claude Code for Home Assistant - Setup / survive-updates script
# https://github.com/danbuhler/claude-code-ha
#
# This installs dependencies + CLI tools AND makes Claude Code survive HA Core /
# Supervisor / add-on updates (which rebuild the add-on container and wipe /root
# and /usr/local).
#
# Survival strategy:
#   - The `claude` binary lives in /usr/local (wiped on rebuild) -> reinstalled
#     here, but only when actually missing (fast on normal restarts).
#   - Login + memory live in ~/.claude + ~/.claude.json (in /root, wiped on
#     rebuild). We SYMLINK those to the persistent HA config partition (/config),
#     so the login and memory survive no matter how `claude` is launched.
#
# This script is idempotent and safe to run on every add-on start. Wire it into
# the add-on's `init_commands` so it runs automatically (see README).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Claude Code for Home Assistant Setup ==="
echo ""

# Detect OS / package manager
if command -v apk &> /dev/null; then
    PKG_MANAGER="apk"
    INSTALL_CMD="apk add --quiet"
elif command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt-get install -y"
elif command -v brew &> /dev/null; then
    PKG_MANAGER="brew"
    INSTALL_CMD="brew install"
else
    echo "Warning: Unknown package manager. Please install dependencies manually:"
    echo "  python3, pip, curl, jq, nodejs, npm"
    PKG_MANAGER="unknown"
fi

# Install system dependencies only if something is missing (fast on restarts).
need_pkgs=false
for c in python3 node npm curl jq; do
    command -v "$c" &> /dev/null || need_pkgs=true
done
if [ "$need_pkgs" = true ] && [ "$PKG_MANAGER" != "unknown" ]; then
    echo "Installing system packages (some were missing)..."
    case "$PKG_MANAGER" in
        apk)  $INSTALL_CMD python3 py3-pip npm nodejs curl jq ;;
        apt)  sudo $INSTALL_CMD python3 python3-pip curl jq nodejs npm ;;
        brew) $INSTALL_CMD python3 curl jq node ;;
    esac
else
    echo "System packages present, skipping."
fi

# Python websockets (needed by ha-ws) - install only if missing.
if ! python3 -c "import websockets" &> /dev/null; then
    echo "Installing Python websockets..."
    if command -v pip3 &> /dev/null; then
        pip3 install websockets --break-system-packages --quiet 2>/dev/null || pip3 install websockets --quiet
    elif command -v pip &> /dev/null; then
        pip install websockets --quiet
    fi
else
    echo "Python websockets present, skipping."
fi

# Claude Code CLI - reinstall only if the binary is gone (i.e. after a rebuild).
if ! command -v claude &> /dev/null; then
    echo "Installing Claude Code (binary missing - likely after an update)..."
    if command -v npm &> /dev/null; then
        npm install -g @anthropic-ai/claude-code --silent 2>/dev/null || npm install -g @anthropic-ai/claude-code
    else
        echo "Warning: npm not found. Install Claude Code manually: npm install -g @anthropic-ai/claude-code"
    fi
else
    echo "Claude Code present, skipping reinstall."
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR/bin/"* 2>/dev/null || true

# Determine HA config directory (persistent across updates).
if [ -d "/config" ]; then
    HA_CONFIG="/config"
elif [ -d "/homeassistant" ]; then
    HA_CONFIG="/homeassistant"
else
    HA_CONFIG="$HOME"
fi

# ---------------------------------------------------------------------------
# Persist Claude login + memory across container rebuilds via symlinks.
#
# We point ~/.claude and ~/.claude.json at the persistent HA config partition.
# This runs at add-on start (before any interactive session), so replacing a
# real dir with a symlink is safe. On the very first run it migrates whatever is
# currently in /root into /config, then symlinks.
# ---------------------------------------------------------------------------
persist_into_config() {
    local name="$1"                 # e.g. ".claude" or ".claude.json"
    local home_path="$HOME/$name"
    local store_path="$HA_CONFIG/$name"

    # Already correctly symlinked? nothing to do.
    if [ -L "$home_path" ] && [ "$(readlink -f "$home_path" 2>/dev/null)" = "$(readlink -f "$store_path" 2>/dev/null)" ]; then
        echo "  [ok] ~/$name already -> $store_path"
        return
    fi

    # Seed the persistent store from /root if the store doesn't exist yet.
    if [ ! -e "$store_path" ] && [ -e "$home_path" ] && [ ! -L "$home_path" ]; then
        mkdir -p "$(dirname "$store_path")"
        cp -a "$home_path" "$store_path"
        echo "  [migrate] ~/$name -> $store_path"
    fi

    # Ensure a directory store exists so the symlink target is valid.
    if [ "$name" = ".claude" ] && [ ! -e "$store_path" ]; then
        mkdir -p "$store_path"
    fi

    # Replace whatever is at ~/$name with a symlink to the persistent store.
    # (Safe at startup: no live claude session holds it open yet.)
    if [ -e "$store_path" ]; then
        rm -rf "$home_path"
        ln -sfn "$store_path" "$home_path"
        echo "  [symlink] ~/$name -> $store_path"
    fi
}

echo ""
echo "Persisting Claude login + memory to $HA_CONFIG ..."
persist_into_config ".claude"
persist_into_config ".claude.json"

# Restore memory from backup if the memory dir is empty (e.g. fresh store).
MEMORY_DIR="$HA_CONFIG/.claude/projects/-homeassistant/memory"
MEMORY_BACKUP="$HA_CONFIG/.claude-memory-backup"
if [ -d "$MEMORY_BACKUP" ]; then
    mkdir -p "$MEMORY_DIR"
    if [ -z "$(ls -A "$MEMORY_DIR" 2>/dev/null)" ]; then
        echo "Restoring memory from backup..."
        for f in "$MEMORY_BACKUP"/*.md; do
            [ -f "$f" ] && cp "$f" "$MEMORY_DIR/"
        done
        echo "  [restored] $(ls "$MEMORY_DIR" | wc -l) memory file(s)"
    fi
fi

# SSH connection reuse for HA -> other hosts on your network. If HA's SSH to
# your servers is routed through a router with an IPS, the IPS may block SSH
# from HA to a host for minutes after a burst of new connections. Reusing one
# connection per host avoids that. Written only if no ControlMaster block
# exists yet, so local edits to ~/.ssh/config survive.
# PLACEHOLDERS: replace SERVER_SUBNET and ROUTER_IP below with your own
# (e.g. a subnet pattern like 10.0.0.* and your router's address).
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if ! grep -q "ControlMaster" "$HOME/.ssh/config" 2>/dev/null; then
    cat >> "$HOME/.ssh/config" << 'EOF'
# Reuse one TCP connection per host (see install.sh: router IPS blocks SSH bursts).
Host SERVER_SUBNET.* ROUTER_IP
    ControlMaster auto
    ControlPath /tmp/ssh-cm-%r@%h-%p
    ControlPersist 15m
    ServerAliveInterval 30
EOF
    chmod 600 "$HOME/.ssh/config"
    echo "  [written] ~/.ssh/config (SSH connection reuse)"
fi

# Determine bin install location
if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    BIN_DIR="/usr/local/bin"
else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
fi

# Create symlinks for tools (wiped on rebuild, safe to recreate every run)
echo ""
echo "Creating symlinks in $BIN_DIR..."
for script in ha-api ha-ws lovelace-sync; do
    if [ -f "$SCRIPT_DIR/bin/$script" ]; then
        ln -sf "$SCRIPT_DIR/bin/$script" "$BIN_DIR/$script"
        echo "  [symlink] $script -> $SCRIPT_DIR/bin/$script"
    fi
done

# Copy CLAUDE.md to HA config (only if absent - won't overwrite customizations)
echo ""
if [ -f "$HA_CONFIG/CLAUDE.md" ]; then
    echo "  [skipped] CLAUDE.md already exists"
else
    cp "$SCRIPT_DIR/CLAUDE.md" "$HA_CONFIG/CLAUDE.md"
    echo "  [copied] CLAUDE.md -> $HA_CONFIG/CLAUDE.md"
fi

# Copy .env.example if .env doesn't exist
if [ ! -f "$HA_CONFIG/.env" ] && [ -f "$SCRIPT_DIR/.env.example" ]; then
    cp "$SCRIPT_DIR/.env.example" "$HA_CONFIG/.env"
    echo "  [copied] .env.example -> $HA_CONFIG/.env (edit this with your token!)"
fi

# Add tools to PATH for login shells. (Login + memory are handled by the
# symlinks above, so we no longer rely on CLAUDE_CONFIG_DIR.)
if [ -d "/etc/profile.d" ] && [ -w "/etc/profile.d" ]; then
    PROFILE_FILE="/etc/profile.d/claude-ha.sh"
    cat > "$PROFILE_FILE" << EOF
# Claude Code for Home Assistant
export PATH="\$PATH:$BIN_DIR:$SCRIPT_DIR/bin"
EOF
    chmod +x "$PROFILE_FILE"
fi

# Disable HA banner (HA OS specific)
if [ -f "/etc/profile.d/homeassistant.sh" ]; then
    sed -i 's/^ha banner/# ha banner/' /etc/profile.d/homeassistant.sh 2>/dev/null || true
fi

echo ""
echo "=== Setup Complete ==="
echo "Claude login + memory persist at $HA_CONFIG/.claude (symlinked from ~)."
echo "Run 'source /etc/profile.d/claude-ha.sh' or open a new shell to use the tools."
