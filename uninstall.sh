#!/usr/bin/env bash
# Electron Shield — uninstall script
# Usage: curl -fsSL https://raw.githubusercontent.com/lleqsnoom/electron-shield/main/uninstall.sh | bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }

if [[ "$(id -u)" -eq 0 ]]; then
    TARGET_USER="${ELECTRON_SHIELD_TARGET_USER:-$(ls /home | head -1)}"
    if [[ -z "$TARGET_USER" ]]; then
        echo "No non-root users found in /home. Cannot proceed." >&2
        exit 1
    fi
else
    TARGET_USER="$(whoami)"
fi

HOME_DIR="/home/$TARGET_USER"
USER_SYSTEMD="$HOME_DIR/.config/systemd/user"
LOCAL_BIN="$HOME_DIR/.local/bin"
CONF_FILE="$HOME_DIR/.config/electron-shield.conf"

info "Uninstalling Electron Shield for user: $TARGET_USER"

# Stop & disable service
systemctl --user stop electron-shield 2>/dev/null && ok "Service stopped" || true
systemctl --user disable electron-shield 2>/dev/null && ok "Service disabled" || true
systemctl --user daemon-reload 2>/dev/null && ok "Daemon reloaded" || true

# Remove files
[[ -f "$USER_SYSTEMD/electron-shield.service" ]] && rm -f "$USER_SYSTEMD/electron-shield.service" && ok "Removed service file"
[[ -f "$LOCAL_BIN/electron-bucket.sh" ]]        && rm -f "$LOCAL_BIN/electron-bucket.sh"        && ok "Removed daemon script"

# Remove config (optional — user might want to keep it)
if [[ -f "$CONF_FILE" ]]; then
    read -r -p "Remove config file at $CONF_FILE? [Y/n] " resp || resp="y"
    if [[ "${resp,,}" != "n" ]]; then
        rm -f "$CONF_FILE" && ok "Removed config"
    else
        info "Keeping config: $CONF_FILE"
    fi
fi

# Clean up cgroup (requires root)
CGROUP="/sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield"
if [[ -d "$CGROUP" ]]; then
    if [[ "$(id -u)" -eq 0 ]] || sudo -n true 2>/dev/null; then
        sudo rm -rf "$CGROUP" && ok "Removed cgroup"
    else
        warn "Cgroup still at $CGROUP — remove manually with: sudo rm -rf '$CGROUP'"
    fi
fi

echo ""
info "Electron Shield has been uninstalled."
info "If you want to reinstall later: curl -fsSL https://raw.githubusercontent.com/lleqsnoom/electron-shield/main/install.sh | bash"
