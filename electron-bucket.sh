#!/bin/bash
# electron-bucket — Electron Shield daemon
# Auto-cgroups all Electron processes under user slice with CPU / memory / PID limits.
# Designed to run as a systemd --user service; cgroup writes use the scope's subtree_control.

set -euo pipefail

CGROUP_ROOT="/sys/fs/cgroup"
USER_SLICE="${ELECTRON_CGROUP_NAME:-electron-shield}"
USER_SLICE_PATH="user-1000.slice/user@1000.service/${USER_SLICE}"

CPU_MAX="${ELECTRON_CPU_MAX:-50%}"
MEM_MAX="${ELECTRON_MEM_MAX:-1G}"
PIDS_MAX="${ELECTRON_PIDS_MAX:-64}"
INTERVAL="${ELECTRON_INTERVAL:-5}"

# ── Electron app detection lists ────────────────────────────────
# Each variable is a regex alternation of lowercase identifiers used
# to match the process cmdline (e.g. "--type=renderer code", "slack").
# Add or remove apps freely — they are joined with | at runtime.

# Messengers / video calls / team communication
COMMUNICATORS="slack|discord|teams|element|mattermost|mattermos\w*|rocketchat|zulip|caprine"

# IDEs / code editors / terminals
CODE_EDITORS="code|vscodium|cursor"

# Design / graphics / whiteboards
DESIGN=""

# Productivity / notes / knowledge bases
PRODUCTIVITY="notion|evernote|roam-research|craft-notes|joplin|logseq|remnote|obsidian|standard-notes|simplenote"

# Office suites / documents
OFFICE=""

# Email clients
EMAIL_CLIENTS="tutanota"

# Media players / music / video
MEDIA_PLAYERS=""

# File managers / cloud storage
FILE_MANAGERS=""

# Databases / API tools / dev utilities
DEV_TOOLS="postman|insomnia|beekeeper-studio|bruno-api-client|httpie-desktop|lm-studio"

# Browsers / web wrappers
BROWSERS=""

# Task managers / scheduling / calendar
TASK_MANAGERS="todoist-desktop|motion-ai"

# Misc utility apps
MISC_UTILS="balenaetcher|docker-desktop-helper|electron-fiddle"

# Build combined app identifier alternation once (skip empty category variables)
COMBINED_APPS=""
for cg_var in COMMUNICATORS CODE_EDITORS DESIGN PRODUCTIVITY OFFICE EMAIL_CLIENTS MEDIA_PLAYERS FILE_MANAGERS DEV_TOOLS BROWSERS TASK_MANAGERS MISC_UTILS; do
    [[ -n "${!cg_var}" ]] && { [[ -n "$COMBINED_APPS" ]] && COMBINED_APPS+="|"; COMBINED_APPS+="${!cg_var}"; }
done

declare -A TRACKED

cleanup() {
    echo "electron-shield: shutting down" >&2
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# Find Electron process PIDs (main + renderer threads).
# Matches processes whose /proc/<pid>/exe resolves to an 'electron' binary,
# or processes whose cmdline matches known Electron app names.
get_electron_pids() {
    local pid exe comm

    # Method 1: exe is literally 'electron' (most common)
    for pid in /proc/[0-9]*/exe; do
        [[ "$pid" =~ ^/proc/([0-9]+)/exe$ ]] || continue
        pid="${BASH_REMATCH[1]}"

        # Skip if already tracked or dead
        [[ -n "${TRACKED[$pid]:-}" ]] && continue
        [[ -d "/proc/$pid/cgroup" ]] || continue

        # Fast pre-filter: skip non-Electron executables without spawning subprocesses
        comm=$(<"/proc/$pid/comm") 2>/dev/null || continue
        [[ "$comm" == "electron" ]] || continue

        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
        if [[ "$(basename "$exe")" == "electron" ]]; then
            echo "$pid"
            continue
        fi
    done

    # Method 2: cmdline matches known Electron app identifiers (--type=renderer flag)
    for pid in /proc/[0-9]*/exe; do
        [[ "$pid" =~ ^/proc/([0-9]+)/exe$ ]] || continue
        pid="${BASH_REMATCH[1]}"

        # Skip if already tracked or dead
        [[ -n "${TRACKED[$pid]:-}" ]] && continue

        # Fast pre-filter: only check cmdline for processes likely to be Electron-related
        local comm
        comm=$(<"/proc/$pid/comm") 2>/dev/null || continue
        # Chrome-based apps use chrome/slack/discord/etc. as comm name; skip obvious non-Electron procs
        case "$comm" in
            bash|sh|systemd|sshd|dbus-daemon|Xorg|wayland|hyprland|sway|i3|kwin_wayland|\
            Xwayland|xinit|login|sudo|su|top|htop|ps|grep|vi|vim|nano|cat|echo|head) continue ;;
        esac

        local cmdline
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || continue
        if [[ -n "$COMBINED_APPS" ]] && [[ "$cmdline" =~ (--type=renderer).*\b(${COMBINED_APPS})\b ]]; then
            echo "$pid"
        fi
    done
}

apply_limits() {
    local cg="$CGROUP_ROOT/$USER_SLICE_PATH"

    [[ -d "$cg" ]] || mkdir -p "$cg" 2>/dev/null || return 1

    # Ensure cpu and memory controllers are enabled for subtree propagation
    echo "cpu memory pids" > "$cg/cgroup.subtree_control" 2>/dev/null || true

    if [[ "$CPU_MAX" == *"%"* ]]; then
        echo "${CPU_MAX}" > "$cg/cpu.max" 2>/dev/null || return 1
    else
        local period=100000
        local quota=$(( CPU_MAX * period / 100 ))
        echo "${quota} ${period}" > "$cg/cpu.max" 2>/dev/null || return 1
    fi

    # Convert human-readable memory to bytes for cgroup v2 (which accepts both)
    local mem_bytes
    case "$MEM_MAX" in
        *[Gg]) mem_bytes=$(( ${MEM_MAX%[Gg]*} * 1073741824 )) ;;
        *[Mm]) mem_bytes=$(( ${MEM_MAX%[Mm]*} * 1048576 )) ;;
        *)     mem_bytes="$MEM_MAX" ;;
    esac
    echo "$mem_bytes" > "$cg/memory.max" 2>/dev/null || return 1

    echo "$PIDS_MAX" > "$cg/pids.max" 2>/dev/null || true
}

move_to_cgroup() {
    local pid="$1"
    local cg_path="$CGROUP_ROOT/$USER_SLICE_PATH"

    [[ -d "$cg_path" ]] || return 0

    echo "$pid" > "$cg_path/cgroup.procs" 2>/dev/null && return 0
    # Process may have died between detection and move — ignore silently
    return 1
}

# ── Main loop ────────────────────────────────────────────────────

echo "electron-shield: starting (CPU=$CPU_MAX, MEM=$MEM_MAX, PIDS=$PIDS_MAX, interval=${INTERVAL}s, cgroup='${USER_SLICE_PATH}')" >&2

while true; do
    # Ensure cgroup exists and limits are applied
    apply_limits || { echo "electron-shield: failed to apply limits, retrying next cycle" >&2; }

    pids_found=0
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        pids_found=$((pids_found + 1))
        if [[ -z "${TRACKED[$pid]:-}" ]]; then
            move_to_cgroup "$pid" && TRACKED["$pid"]=1
        fi
    done < <(get_electron_pids)

    # Clean up stale pids no longer running
    for pid in "${!TRACKED[@]}"; do
        [[ -d "/proc/$pid" ]] || unset "TRACKED[$pid]"
    done

    sleep "$INTERVAL" &
    wait $! 2>/dev/null || break
done
