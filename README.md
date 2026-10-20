# Claude Code for Home Assistant

CLI tools and configuration for using [Claude Code](https://claude.com/claude-code) with Home Assistant OS.

## What's Included

| File | Description |
|------|-------------|
| `bin/ha-api` | REST API CLI for quick state/service operations |
| `bin/ha-ws` | WebSocket CLI for registry management and detailed lookups |
| `bin/lovelace-sync` | Push dashboard changes to HA without restart |
| `install.sh` | Setup script for HA OS (re-run after updates) |
| `CLAUDE.md` | Instructions file that Claude Code reads automatically |

## Prerequisites

### SSH Add-on Setup

Install the **Advanced SSH & Web Terminal** add-on (community add-ons repository) — it is the one
whose `init_commands` keep Claude alive across updates (see *After Home Assistant OS Updates*).
The official "Terminal & SSH" add-on also works for a one-off install, but has no `init_commands`.
Configure it with the required packages:

1. Go to **Settings → Add-ons → Advanced SSH & Web Terminal → Configuration**
2. Add these packages to the configuration:

```yaml
apks:
  - gcompat
  - libstdc++
  - curl
  - procps
  - coreutils
  - tar
  - bash
  - python3
  - py3-pip
  - fzf
```

3. Save and restart the add-on

## Installation

### Getting a Long-Lived Access Token

1. Go to your Home Assistant profile (click your name in sidebar)
2. Switch to the **Security** tab
3. Scroll to "Long-Lived Access Tokens"
4. Click "Create Token"
5. Save the token for the next step

### On Home Assistant OS

```bash
# SSH into your HA OS instance
cd /config

# Clone this repo
git clone https://github.com/danbuhler/claude-code-ha.git

# Run setup (installs dependencies + Claude Code)
cd claude-code-ha
./install.sh

# Edit /config/.env and add your long-lived access token
nano /config/.env
```

### Manual Installation (what install.sh does for you)

```bash
# Install dependencies
apk add python3 py3-pip curl jq nodejs npm
pip3 install websockets --break-system-packages

# Install Claude Code
npm install -g @anthropic-ai/claude-code

# Link scripts into PATH (install.sh symlinks, so a git pull updates them)
chmod +x bin/*
ln -sf "$PWD"/bin/* /usr/local/bin/

# Copy CLAUDE.md and .env to your HA config directory
cp CLAUDE.md /config/
cp .env.example /config/.env
nano /config/.env  # Add your token
```

## Usage

### ha-api - REST API CLI

Fast lookups and service calls:

```bash
ha-api states                    # List all entities
ha-api states light              # Filter by domain
ha-api state light.kitchen       # Get specific entity state
ha-api attr sensor.temperature   # Show attributes
ha-api devices motion            # Find by device_class
ha-api search bedroom            # Search entity IDs
ha-api call light turn_on        # Call a service
ha-api call light turn_on '{"entity_id":"light.kitchen"}'  # ...with a JSON body
ha-api history sensor.temp 48    # Get 48h history
```

### ha-ws - WebSocket CLI

Registry management and detailed entity/device info:

```bash
# Entity operations
ha-ws entity list light          # List light entities
ha-ws entity get light.kitchen   # Full entity details + related items
ha-ws entity update light.old new_entity_id=light.new  # Rename

# Device operations
ha-ws device list                # List all devices
ha-ws device get <device_id>     # Device details + all entities

# Area management
ha-ws area list                  # List areas
ha-ws area create "Guest Room"   # Create area

# Area management (continued)
ha-ws area update kitchen icon=mdi:stove   # Update area
ha-ws area delete guest_room               # Delete area

# States and service calls
ha-ws state sensor.temperature
ha-ws states light               # Optional domain filter
ha-ws services light             # List services
ha-ws call light.turn_on entity_id=light.kitchen brightness=255

# Search & inspect
ha-ws search kitchen             # Search related entities
ha-ws related light.kitchen      # Automations/scenes/devices that use it

# System
ha-ws config                     # HA configuration
ha-ws info                       # HA core info

# Raw WebSocket
ha-ws raw config/entity_registry/list
ha-ws raw config/entity_registry/get entity_id=light.kitchen   # key=value params
ha-ws raw config_entries/ignore_flow '{"flow_id":"X","title":"Y"}'   # or a JSON object

# Batch: one command per line on stdin
printf 'entity get light.a\nentity get light.b\n' | ha-ws batch

# Options: --json (raw JSON output), --quiet (minimal output)
ha-ws --json entity get light.kitchen
```

### lovelace-sync - Dashboard Sync

Edit `.storage/lovelace` directly, then push to HA. Only the **default** dashboard
(`.storage/lovelace`) is pushed; extra dashboards (`.storage/lovelace.<name>`) need a
`lovelace/config/save` WebSocket call with their `url_path`.

```bash
# 1. Edit the lovelace file
# 2. Push changes (no restart needed)
lovelace-sync
# 3. Refresh browser to see changes
```

**Note:** Changes made in the HA web interface will overwrite any unpushed local edits. Always run `lovelace-sync` before making changes in the UI.

## Claude Code Integration

The `CLAUDE.md` file provides Claude Code with context about:
- These CLI tools and how to use them
- Home Assistant YAML configuration patterns
- Best practices for automation/template syntax

Copy `CLAUDE.md` to your HA config directory. Claude Code automatically reads it when working there.

### Example Session

```
> claude

You: "Turn on the kitchen lights"
Claude: *uses ha-api call light turn_on*

You: "What motion sensors do I have?"
Claude: *uses ha-api devices motion*

You: "Rename light.old_lamp to light.bedroom_lamp"
Claude: *uses ha-ws entity update*
```

## Configuration

### Environment Variables

The install script creates `/config/.env` from the template. Edit it with your token:

```bash
# /config/.env
HA_URL=https://172.30.32.1:8128   # Internal HA API URL (HA OS default)
HA_TOKEN=your_token_here          # Long-lived access token
```

The scripts search for `.env` in order:
1. `$HA_ENV_FILE` (if set)
2. `/config/.env` (standard location)
3. `/homeassistant/.env`
4. Current directory
5. `~/.ha-cli.env`

### For External Access

If running Claude Code from outside HA OS:

```bash
HA_URL=https://your-ha-domain.com:8123
HA_TOKEN=your_token_here
```

## After Home Assistant OS Updates

HA Core / Supervisor / add-on updates rebuild the add-on container, wiping the
root filesystem (`/root`, `/usr/local`) — so the `claude` binary and your login
are lost. This is now handled **automatically**: `install.sh` is wired into the
SSH add-on's `init_commands`, so it runs on every add-on start, *before* you open
a terminal.

To set that up (one time), add this to **Settings → Add-ons → Advanced SSH &
Web Terminal → Configuration → `init_commands`**:

```yaml
init_commands:
  - bash /config/claude-code-ha/install.sh >> /config/claude-code-ha/install.log 2>&1 || true
```

After an update you should *not* have to reinstall Claude or log in again.

### What install.sh Does (idempotent — safe to run every start)

| Item | Action |
|------|--------|
| System packages (python3, nodejs, etc.) | Installs via apk **only if missing** |
| Python websockets | pip install **only if missing** |
| Claude Code | `npm install -g` **only if the binary is gone** (after a rebuild) |
| `~/.claude` + `~/.claude.json` (login + memory) | **Symlinks** to `/config/.claude` so they persist; migrates existing data on first run |
| Memory | Restores `*.md` from `/config/.claude-memory-backup` into `~/.claude/projects/-homeassistant/memory` only if that dir is empty |
| `ha-api`, `ha-ws`, `lovelace-sync` | **Symlinks** to repo's `bin/` |
| `CLAUDE.md` / `.env` | **Copies** to `/config/` only if absent (preserves customizations) |
| PATH in `/etc/profile.d/` | Recreated |

### What Persists Across HA Updates

These survive in `/config` (the HA config partition, also in HA backups):
- The cloned repo itself
- **Your Claude login + memory** (`/config/.claude` + `/config/.claude.json`)
- Your `.env` file (with your token)
- Your customized `CLAUDE.md`

### What Does NOT Persist

Anything else under `/root` is wiped on every add-on rebuild (add-on, Supervisor or
Core update). Known cases:

- **`~/.tmux.conf`** — a plain file, not managed by `install.sh`. Contains the
  terminal add-on's defaults plus `set -g set-clipboard on` (added 2026-09-12 so
  tmux copies reach the system clipboard). Re-add that line after a rebuild, or move
  the file to `/config` and symlink it from `install.sh` if it keeps getting lost.
- **`~/.ssh/config`** — wiped like the rest, but `install.sh` re-creates the SSH
  connection-reuse block (ControlMaster for the hosts in its `Host` line — replace the
  `SERVER_SUBNET.*` / `ROUTER_IP` placeholders in `install.sh` with your own) when no
  ControlMaster block is present. Useful when a router's IPS blocks bursts of new
  SSH connections from HA to other hosts on your network.
- **`~/.zshrc`** — written by the add-on. It aliases `tmux` to the oh-my-zsh tmux
  plugin wrapper, which only exists in interactive shells; scripts and Claude's Bash
  tool must call `command tmux` or `/usr/bin/tmux`.

## Requirements

- Home Assistant (any installation with shell access)
- Python 3 with `websockets` package
- `curl` and `jq` for ha-api
- Node.js/npm for Claude Code

## License

MIT License - See [LICENSE](LICENSE)
