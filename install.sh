#!/usr/bin/env bash
# electron-shield installer — install Electron Shield as a systemd user service.
# Usage: curl -fsSL https://raw.githubusercontent.com/lleqsnoom/electron-shield/main/install.sh | bash
#    or: git clone ... && cd electron-shield && sudo -E bash install.sh  (rootless, no sudo needed)

set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()   { echo -e "  ${RED}✗${NC} $*"; }

ask_yn() {
    local prompt="$1" default="${2:-y}"
    local resp
    if [[ "${default,,}" == "y" ]]; then
        read -r -p "$prompt [Y/n] " resp || resp="y"
        [[ -z "$resp" ]] && return 0
        [[ "${resp,,}" != "n" ]] && return 0
    else
        read -r -p "$prompt [y/N] " resp || resp="n"
        [[ -z "$resp" ]] && return 1
        [[ "${resp,,}" == "y" ]] && return 0
    fi
    return 1
}

# ── Detect environment ───────────────────────────────────────────
if ! command -v systemctl &>/dev/null; then
    err "systemctl not found. Electron Shield requires systemd (user session)."
    exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
    warn "Running as root — installer will still use the first non-root user (UID $(ls /home | head -1) assumed). Run as your regular user for best results."
    TARGET_USER="${ELECTRON_SHIELD_TARGET_USER:-$(ls /home 2>/dev/null | head -1)}"
    if [[ -z "$TARGET_USER" ]]; then
        err "No non-root users found in /home. Cannot proceed."
        exit 1
    fi
else
    TARGET_USER="$(whoami)"
fi

HOME_DIR="/home/$TARGET_USER"
USER_SYSTEMD="$HOME_DIR/.config/systemd/user"
LOCAL_BIN="$HOME_DIR/.local/bin"
CONF_DIR="$HOME_DIR/.config"
CONF_FILE="$CONF_DIR/electron-shield.conf"

# ── Resolve script locations (script dir or GitHub) ───────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="$SCRIPT_DIR/electron-shield.service"
SH_SRC="$SCRIPT_DIR/electron-bucket.sh"

if [[ ! -f "$SERVICE_SRC" ]]; then
    info "Running in standalone mode — downloading from GitHub..."
    GITHUB_RAW="https://raw.githubusercontent.com/lleqsnoom/electron-shield/main/"
    curl -fsSL "${GITHUB_RAW}electron-shield.service" -o /tmp/es-service.tmp || { err "Failed to download service file"; exit 1; }
    SERVICE_SRC="/tmp/es-service.tmp"

    curl -fsSL "${GITHUB_RAW}electron-bucket.sh" -o /tmp/es-script.tmp || { err "Failed to download daemon script"; exit 1; }
    SH_SRC="/tmp/es-script.tmp"
fi

# ── Pre-flight checks ────────────────────────────────────────────
info "Installing Electron Shield for user: $TARGET_USER"
ok "systemd detected ($(systemctl --version | head -1))"

[[ -w "$USER_SYSTEMD" ]] || { err "$USER_SYSTEMD not writable. Check permissions."; exit 1; }
ok "$USER_SYSTEMD is writable"

mkdir -p "$LOCAL_BIN" && ok "$LOCAL_BIN ready"
mkdir -p "$CONF_DIR" && ok "$CONF_DIR ready"

# ── Handle existing installation ──────────────────────────────────
EXISTING_SERVICE="$USER_SYSTEMD/electron-shield.service"
if [[ -f "$EXISTING_SERVICE" ]]; then
    warn "electron-shield.service already exists at $EXISTING_SERVICE"
    if ask_yn "Overwrite existing service file?"; then
        cp "$SERVICE_SRC" "$EXISTING_SERVICE"
        ok "Service file updated"
    else
        info "Skipping service file (keeping existing)"
    fi
else
    cp "$SERVICE_SRC" "$EXISTING_SERVICE"
    ok "Service file installed to $USER_SYSTEMD/electron-shield.service"
fi

# ── Install daemon script ────────────────────────────────────────
if [[ -f "$LOCAL_BIN/electron-bucket.sh" ]]; then
    warn "electron-bucket.sh already exists — backing up and overwriting"
    cp "$LOCAL_BIN/electron-bucket.sh" "$LOCAL_BIN/electron-bucket.sh.bak.$(date +%s)" 2>/dev/null || true
fi
cp "$SH_SRC" "$LOCAL_BIN/electron-bucket.sh"
chmod +x "$LOCAL_BIN/electron-bucket.sh"
ok "Daemon script installed to $LOCAL_BIN/electron-bucket.sh"

# ── Create config file (only if doesn't exist) ───────────────────
if [[ -f "$CONF_FILE" ]]; then
    info "Config already exists at $CONF_FILE — leaving unchanged"
else
    cat > "$CONF_FILE" << 'CONF'
# Electron Shield configuration
# Override defaults here or via: systemctl --user set-environment ELECTRON_*=value

# CPU limit per cgroup (supports % or absolute ms/period ratio)
ELECTRON_CPU_MAX=50%

# Memory limit (human-readable: 256M, 1G, etc.)
ELECTRON_MEM_MAX=1G

# Maximum PIDs in the electron-shield cgroup
ELECTRON_PIDS_MAX=64

# Detection loop interval in seconds
ELECTRON_INTERVAL=5

# Cgroup name (internal — changing this requires manual migration)
# ELECTRON_CGROUP_NAME=electron-shield
CONF
    ok "Config created at $CONF_FILE"
fi

# ── Reload systemd and enable service ────────────────────────────
info "Reloading systemd user daemon..."
systemctl --user daemon-reload 2>/dev/null || true
ok "Daemon reloaded"

if systemctl --user is-enabled electron-shield.service &>/dev/null; then
    info "Service already enabled — skipping enable step"
else
    systemctl --user enable electron-shield.service 2>/dev/null || warn "Enable failed (may need login shell)"
fi
ok "Service enabled for auto-start"

# ── Start service ────────────────────────────────────────────────
if systemctl --user is-active electron-shield.service &>/dev/null; then
    info "Restarting service to apply changes..."
    systemctl --user restart electron-shield.service 2>/dev/null || warn "Restart failed — try: systemctl --user start electron-shield"
else
    systemctl --user start electron-shield.service 2>/dev/null || warn "Start failed — try manually: systemctl --user start electron-shield"
fi

# ── Summary ──────────────────────────────────────────────────────
echo ""
info "═══════════════════════════════════════════════════"
ok "Electron Shield installed successfully!"
echo ""
info "Installed files:"
echo "  Service:  $USER_SYSTEMD/electron-shield.service"
echo "  Script:   $LOCAL_BIN/electron-bucket.sh"
echo "  Config:   $CONF_FILE"
echo ""
info "Manage with:"
echo "  systemctl --user status electron-shield"
echo "  journalctl --user -u electron-shield -f"
echo "  systemctl --user restart electron-shield"
echo ""
info "Tune limits by editing $CONF_FILE or running:"
echo "  systemctl --user set-environment ELECTRON_CPU_MAX=30%"
echo "  systemctl --user set-environment ELECTRON_MEM_MAX=512M"
echo "  systemctl --user daemon-reload && systemctl --user restart electron-shield"
echo ""
info "Uninstall with: bash <(curl -fsSL https://raw.githubusercontent.com/lleqsnoom/electron-shield/main/uninstall.sh)"
echo "═══════════════════════════════════════════════════"

# Clean up temp files from standalone mode
[[ -f /tmp/es-service.tmp ]] && rm -f /tmp/es-service.tmp
[[ -f /tmp/es-script.tmp ]]   && rm -f /tmp/es-script.tmp
