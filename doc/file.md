# File Documentation

## Project Files

| File | Description |
|------|-------------|
| `pb.sh` | PocketBase management shell script (install, setup, start, stop, status, logs, backup, update, uninstall) |

## Runtime Directories (~/.pocketbase/)

| Directory | Description |
|-----------|-------------|
| `src/` | Cloned PocketBase source code from GitHub |
| `bin/` | Compiled PocketBase binary |
| `data/` | PocketBase runtime data (pb_data) |
| `backups/` | Timestamped backup archives |
| `logs/` | PocketBase log files |
| `pb.conf` | Configuration file (repo, port, host, paths) |

## Service Files

| Platform | File | Description |
|----------|------|-------------|
| macOS | `~/Library/LaunchAgents/com.pocketbase.server.plist` | launchd service definition |
| Linux | `~/.config/systemd/user/pocketbase.service` | systemd user service unit |
