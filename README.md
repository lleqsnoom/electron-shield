# Electron Shield

**A solution for Electron apps that freeze Linux due to excessive resource usage.**

Resource limits for Electron apps — a lightweight systemd user service that auto-detects Electron processes and cgroups them with CPU, memory, and PID limits. No root required.

## Why?

Electron apps (VS Code, Slack, Discord, Spotify, etc.) are notorious resource hogs. A single app can eat 2+ GB of RAM and spike CPU indefinitely. This tool caps each Electron instance at sane defaults so one misbehaving app can't starve the rest of your system.

## Features

- **Zero config** — works out of the box with sensible defaults
- **Auto-detection** — catches all running Electron processes (main + renderer threads) across 12 categories (~160 apps)
- **Cgroup v2** — kernel-native resource enforcement, no per-app daemon overhead
- **User-level** — runs as a `systemd --user` service, no sudo needed
- **Configurable** — tweak CPU %, memory cap, PID limit via env file or `systemctl set-environment`
- **Persistent** — enabled by default; survives reboots

## Install

One-liner (curl pipe to bash):

```bash
curl -fsSL https://raw.githubusercontent.com/lleqsnoom/electron-shield/main/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/lleqsnoom/electron-shield.git
cd electron-shield
bash install.sh
```

The installer:
1. Drops `electron-shield.service` into your systemd user dir
2. Installs the daemon script to `~/.local/bin/`
3. Creates a config file at `~/.config/electron-shield.conf`
4. Enables and starts the service

## Configuration

Edit `~/.config/electron-shield.conf`:

```ini
# CPU limit per cgroup (supports percentage or ms/period ratio)
ELECTRON_CPU_MAX=50%

# Memory limit per cgroup
ELECTRON_MEM_MAX=1G

# Maximum PIDs in the electron-shield cgroup
ELECTRON_PIDS_MAX=64

# Detection loop interval (seconds)
ELECTRON_INTERVAL=5

# Custom cgroup name (internal — default: electron-shield)
# ELECTRON_CGROUP_NAME=electron-shield
```

Or set live via systemd:

```bash
systemctl --user set-environment ELECTRON_CPU_MAX=30%
systemctl --user set-environment ELECTRON_MEM_MAX=512M
systemctl --user daemon-reload
systemctl --user restart electron-shield
```

## App categories & detection

Electron Shield auto-detects Electron apps via two methods:

1. **Binary name** — `/proc/<pid>/exe` resolves to `electron` (catches all main processes)
2. **Cmdline match** — matches known app identifiers against renderer threads (e.g. `--type=renderer code`)

### Categorized app list (default)

| Category | Apps included |
|---|---|
| Messengers | Slack, Discord, Teams, Zoom, Element, Mattermost, Rocket.Chat, Signal, Telegram, Wavebox, Threema, Zulip, Caprine, Francium/X, Bluesky |
| Code editors | VS Code, VSCodium, Cursor, WindSurf, Zed, GoLand, RubyMine, Atom, Fleet |
| Design | Figma, Penpot, Excalidraw, Canva, Inkscape Web, Lunacy, Affinity Designer |
| Productivity | Notion, Evernote, Obsidian, Logseq, Joplin, Roam Research, Craft, Bear Notes |
| Office | LibreOffice, OnlyOffice, WPS Office, Google Docs Offline |
| Email | Thunderbird, Outlook, Tutanota, ProtonMail Bridge, BlueMail, Canary Mail |
| Media players | Spotify, VLC, Audacity, Plex, Roon, Tidal, Deezer, BandLab |
| File managers | Dropbox, MegaSync, Syncthing Tray, Nextcloud Desktop, PCloud Drive |
| Dev tools | Postman, Insomnia, TablePlus, DBeaver, Hoppscotch, Beekeeper Studio |
| Browsers | Brave, Vivaldi, Arc, Opera GX, Waterfox, Pale Moon |
| Task managers | Todoist, Sunsama, Reclaim.ai, Motion AI, Google Calendar |
| Utilities | BalenaEtcher, NordVPN, Docker Desktop helper, ExpressVPN |

To add a custom app identifier, append to any category variable in `~/.local/bin/electron-bucket.sh`:

```bash
# Before the declare -A TRACKED line:
MY_APPS="my-custom-app|another-tool"
```

Then update the combined pattern loop (around the `for cg_var in ...` block) to include your new variable.

## Usage

### Status & logs

```bash
systemctl --user status electron-shield
journalctl --user -u electron-shield -f          # live tail
journalctl --user -u electron-shield --since today  # today's entries
```

### Check applied limits

```bash
cat /sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/cpu.max
cat /sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/memory.max
cat /sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/pids.max
```

### List managed processes

```bash
ls /sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/ | grep -E '^user-'
# Each sub-cgroup entry corresponds to a process moved into the cgroup.
ps --no-headers -o pid,comm -p $(cat /sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/cgroup.procs 2>/dev/null | tr '\n' ' ')
```

### Temporarily pause (disable service)

```bash
systemctl --user stop electron-shield
systemctl --user disable electron-shield   # optional: prevent restart on boot
```

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/lleqsnoom/electron-shield/main/uninstall.sh | bash
```

Or manually:

```bash
systemctl --user stop electron-shield
systemctl --user disable electron-shield
rm ~/.config/systemd/user/electron-shield.service
rm ~/.local/bin/electron-bucket.sh
rm ~/.config/electron-shield.conf
systemctl --user daemon-reload
# Clean up cgroup: sudo rm -rf /sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield
```

## How it works

1. The systemd user service launches `electron-bucket.sh` in a loop every 5 seconds
2. On each iteration, the script scans `/proc/[pid]/exe` for Electron binaries and matches renderer threads against known app identifiers
3. Detected processes are moved into a cgroup at `/sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/`
4. The cgroup's `cpu.max`, `memory.max`, and `pids.max` enforce hard limits via cgroup v2 kernel controllers
5. User-level systemd services automatically get `subtree_control` rights, so no root is needed

## Requirements

- Linux with **cgroup v2** (most distros since ~2019)
- **systemd** user session running
- Bash 4+ (for associative arrays and extglob)

## Limitations

- Only works in cgroup v2 systems (not v1 without `systemd-cgtop` conversion)
- Limits apply to the *cgroup*, not individual apps — all Electron processes share the pool
- Some Electron forks (e.g. custom Chromium-based apps) may not match detection patterns — add manually via the category variables
- PID limit is shared across all managed Electron processes, not per-app

## Troubleshooting

**Service won't start:** Check `systemctl --user status electron-shield` and `journalctl --user -u electron-shield`. Common cause: cgroup v2 not mounted (`cat /proc/filesystems | grep cgroup2`).

**Processes not being caught:** Verify your Electron apps appear in `/sys/fs/cgroup/user-1000.slice/user@1000.service/electron-shield/cgroup.procs` after the daemon starts. If missing, check `journalctl --user -u electron-shield -f` for detection logs.

**Permission denied writing cgroup:** Ensure you're running a systemd user session (`systemctl --user status` should work). User services get subtree_control automatically — if not, your distro may need `UserAllowArchitecture=auto` in `/etc/systemd/system.conf`.

## License

MIT
