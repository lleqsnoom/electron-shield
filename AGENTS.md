# AGENTS.md — Electron Shield Development Guide

## Project Overview

A pure Bash shell project: a `systemd --user` service daemon that auto-detects Electron processes on Linux and cgroups them with CPU, memory, and PID limits via cgroup v2. No build system, no tests, no package manager — just shell scripts and an `.service` file.

## File Layout

```
electron-bucket.sh    # Core daemon: detection loop + cgroup management
install.sh            # One-shot installer (curl | bash or local)
uninstall.sh          # Cleanup script
electron-shield.service  # systemd user service unit
README.md             # User-facing docs
AGENTS.md             # This file
```

## Architecture

The daemon (`electron-bucket.sh`) runs as a `systemd --user` service in an infinite loop:

1. **Detection** — scans `/proc/[pid]/exe` for `electron` binaries, and cmdline for known app identifiers via regex alternation (2 methods)
2. **Cgroup management** — applies limits to the cgroup at `/sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/`
3. **Tracking** — uses a Bash associative array `TRACKED` to avoid re-processing already-captured PIDs

The detection list is organized into 12 category variables (e.g. `COMMUNICATORS`, `CODE_EDITORS`) that are concatenated with `|` at runtime for matching.

## Commands

There is no build/test/lint command — this repo has none. Key operational commands:

```bash
# Install / uninstall (run as the target user)
bash install.sh
bash uninstall.sh

# Manage the service (systemd --user)
systemctl --user status electron-shield
systemctl --user start|stop|restart electron-shield
journalctl --user -u electron-shield -f    # live tail

# Check applied cgroup limits
cat /sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/cpu.max
```

## Conventions

- **Shell strictness**: All scripts use `set -euo pipefail`
- **Shebangs**: `#!/bin/bash` for the daemon, `#!/usr/bin/env bash` for install/uninstall
- **Color helpers**: install.sh and uninstall.sh define ANSI color codes (`RED`, `GREEN`, etc.) with helper functions (`info()`, `ok()`, `warn()`, `err()`) — reuse this pattern if adding new scripts
- **Configuration**: Read via `EnvironmentFile` in the `.service` file, overridden by per-environment variables. Defaults are set as fallbacks in both the service unit and the daemon script itself — keep them in sync when changing defaults
- **Variable naming**: UPPERCASE for config values (`ELECTRON_CPU_MAX`, etc.), UPPER_SNAKE_CASE for constants/arrays

## Gotchas

- **cgroup v2 only** — does not work on cgroup v1 systems without conversion
- **PID namespace** — the service file uses `%h` (home dir) but cgroup paths are hardcoded to `user-1000.slice/user@1000.service/` in the daemon. If a user has UID != 1000, the daemon will fail silently. This is not yet fixed.
- **Detect loop race condition** — between detection (`get_electron_pids`) and moving to cgroup (`move_to_cgroup`), a process may exit. The script handles this by returning `1` from `move_to_cgroup`, but does NOT log it currently (line 138).
- **SIGTERM handling**: The daemon uses `sleep X & wait $!` instead of plain `sleep X` so that signals can interrupt the sleep. This is intentional and must be preserved when changing the loop interval.
- **Associative array tracking**: `TRACKED` persists across iterations. Stale entries are cleaned up at the bottom of each loop, but only if `/proc/$pid` still exists — a process that was killed between detection and cleanup won't be removed from `TRACKED` until the next iteration.
- **Memory unit parsing** (line 120-125): The daemon parses `G`/`M` suffixes but falls back to raw bytes for other values. It does NOT handle `K` or `T` suffixes — only the service file defaults use valid formats.
- **Combined regex performance**: Building the combined alternation from all 12 category variables on every PID scan (line 93-96) is O(PIDs × categories). For systems with many Electron apps this could be slow; consider caching if adding more apps.

## Adding a New App

To add support for a new Electron app, append its identifier to the appropriate category variable in `electron-bucket.sh` (around line 23-56), using regex-safe lowercase identifiers separated by `|`. No other code changes needed — categories are auto-included via the `for cg_var in ...` loop at line 94.

## Modifying Detection Logic

The two detection methods are:
1. `/proc/<pid>/exe` resolves to a binary named `electron` (line 85)
2. cmdline contains `--type=renderer <app_identifier>` matching category regexes (line 97)

Both produce PIDs that feed into the same cgroup move path. To add new detection patterns, extend either method before the loop or add new category variables.

## Testing Changes

No automated tests exist. Manual testing workflow:
1. Make changes to `electron-bucket.sh`
2. Install (or copy) to `~/.local/bin/` and run directly: `bash electron-bucket.sh`
3. Check detection via `journalctl --user -u electron-shield -f` or direct execution output
4. Verify cgroup limits with the commands in README.md

When testing interactively, the daemon will loop forever — use Ctrl+C (SIGINT is trapped and logs shutdown).
