#!/usr/bin/env bash
# pb.sh - PocketBase management script
# Supports macOS (launchd) and Linux (systemd)
# Usage: ./pb.sh <command> [options]

set -euo pipefail

# ─── Constants ───────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.0.0"
readonly PB_HOME="${PB_HOME:-$HOME/.pocketbase}"
readonly PB_CONF="$PB_HOME/pb.conf"
readonly SERVICE_NAME="com.pocketbase.server"
readonly SYSTEMD_UNIT="pocketbase.service"
readonly MIN_GO_VERSION="1.25"

# ─── OS Detection ───────────────────────────────────────────────────────────

detect_os() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Darwin) OS="darwin" ;;
        Linux)  OS="linux" ;;
        *)
            echo "Error: unsupported OS '$OS'. Only macOS and Linux are supported."
            exit 1
            ;;
    esac

    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *)
            echo "Error: unsupported architecture '$ARCH'."
            exit 1
            ;;
    esac
}

# ─── Configuration ──────────────────────────────────────────────────────────

load_config() {
    # Defaults
    PB_REPO="https://github.com/leoleoaabbcc/pocketbase.git"
    PB_BRANCH="master"
    PB_PORT=8090
    PB_HOST="127.0.0.1"
    PB_DATA_DIR="$PB_HOME/data"
    PB_LOG_DIR="$PB_HOME/logs"
    PB_SRC_DIR="$PB_HOME/src"
    PB_BIN_DIR="$PB_HOME/bin"
    PB_BACKUP_DIR="$PB_HOME/backups"
    PB_BINARY="$PB_BIN_DIR/pocketbase"

    # Override from config file if exists
    if [[ -f "$PB_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$PB_CONF"
    fi
}

save_config() {
    cat > "$PB_CONF" << EOF
# PocketBase configuration
PB_REPO="$PB_REPO"
PB_BRANCH="$PB_BRANCH"
PB_PORT=$PB_PORT
PB_HOST="$PB_HOST"
PB_DATA_DIR="$PB_DATA_DIR"
PB_LOG_DIR="$PB_LOG_DIR"
EOF
}

# ─── Helpers ────────────────────────────────────────────────────────────────

log_info() {
    echo "[INFO] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_success() {
    echo "[OK] $*"
}

# Check if a command exists
require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        log_error "'$1' is required but not installed."
        return 1
    fi
}

# Compare semver: returns 0 if $1 >= $2
version_gte() {
    local IFS=.
    local i v1=($1) v2=($2)
    for ((i = 0; i < ${#v2[@]}; i++)); do
        local a="${v1[i]:-0}"
        local b="${v2[i]:-0}"
        if ((a > b)); then return 0; fi
        if ((a < b)); then return 1; fi
    done
    return 0
}

check_go_version() {
    require_cmd go || return 1
    local go_ver
    go_ver="$(go version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    if ! version_gte "$go_ver" "$MIN_GO_VERSION"; then
        log_error "Go >= $MIN_GO_VERSION required, found $go_ver"
        return 1
    fi
    log_info "Go $go_ver detected"
}

# ─── Service Management ────────────────────────────────────────────────────

get_launchd_plist_path() {
    echo "$HOME/Library/LaunchAgents/${SERVICE_NAME}.plist"
}

get_systemd_unit_path() {
    echo "$HOME/.config/systemd/user/${SYSTEMD_UNIT}"
}

write_launchd_plist() {
    local plist_path
    plist_path="$(get_launchd_plist_path)"
    mkdir -p "$(dirname "$plist_path")"

    cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PB_BINARY}</string>
        <string>serve</string>
        <string>--http</string>
        <string>${PB_HOST}:${PB_PORT}</string>
        <string>--dir</string>
        <string>${PB_DATA_DIR}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${PB_HOME}</string>
    <key>StandardOutPath</key>
    <string>${PB_LOG_DIR}/pocketbase.log</string>
    <key>StandardErrorPath</key>
    <string>${PB_LOG_DIR}/pocketbase.error.log</string>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
    log_info "launchd plist written to $plist_path"
}

write_systemd_unit() {
    local unit_path
    unit_path="$(get_systemd_unit_path)"
    mkdir -p "$(dirname "$unit_path")"

    cat > "$unit_path" << EOF
[Unit]
Description=PocketBase Server
After=network.target

[Service]
Type=simple
ExecStart=${PB_BINARY} serve --http ${PB_HOST}:${PB_PORT} --dir ${PB_DATA_DIR}
WorkingDirectory=${PB_HOME}
Restart=on-failure
RestartSec=5
StandardOutput=append:${PB_LOG_DIR}/pocketbase.log
StandardError=append:${PB_LOG_DIR}/pocketbase.error.log

[Install]
WantedBy=default.target
EOF
    log_info "systemd unit written to $unit_path"
}

service_register() {
    if [[ "$OS" == "darwin" ]]; then
        write_launchd_plist
        launchctl load "$(get_launchd_plist_path)" 2>/dev/null || true
    else
        write_systemd_unit
        systemctl --user daemon-reload
        systemctl --user enable "$SYSTEMD_UNIT"
    fi
    log_success "Service registered"
}

service_unregister() {
    if [[ "$OS" == "darwin" ]]; then
        local plist_path
        plist_path="$(get_launchd_plist_path)"
        if [[ -f "$plist_path" ]]; then
            launchctl unload "$plist_path" 2>/dev/null || true
            rm -f "$plist_path"
        fi
    else
        systemctl --user disable "$SYSTEMD_UNIT" 2>/dev/null || true
        systemctl --user stop "$SYSTEMD_UNIT" 2>/dev/null || true
        rm -f "$(get_systemd_unit_path)"
        systemctl --user daemon-reload
    fi
    log_success "Service unregistered"
}

service_start() {
    if [[ "$OS" == "darwin" ]]; then
        launchctl start "$SERVICE_NAME"
    else
        systemctl --user start "$SYSTEMD_UNIT"
    fi
}

service_stop() {
    if [[ "$OS" == "darwin" ]]; then
        launchctl stop "$SERVICE_NAME" 2>/dev/null || true
    else
        systemctl --user stop "$SYSTEMD_UNIT" 2>/dev/null || true
    fi
}

service_is_running() {
    if [[ "$OS" == "darwin" ]]; then
        launchctl list "$SERVICE_NAME" &>/dev/null
    else
        systemctl --user is-active --quiet "$SYSTEMD_UNIT" 2>/dev/null
    fi
}

# ─── Commands ───────────────────────────────────────────────────────────────

cmd_install() {
    log_info "Checking prerequisites..."
    require_cmd git
    check_go_version

    mkdir -p "$PB_BIN_DIR"

    # Clone source
    if [[ -d "$PB_SRC_DIR/.git" ]]; then
        log_info "Source already cloned, pulling latest..."
        cd "$PB_SRC_DIR"
        git pull
    else
        log_info "Cloning $PB_REPO (branch: $PB_BRANCH)..."
        git clone -b "$PB_BRANCH" "$PB_REPO" "$PB_SRC_DIR"
        cd "$PB_SRC_DIR"
    fi

    # Build
    log_info "Compiling PocketBase..."
    cd "$PB_SRC_DIR/examples/base"
    CGO_ENABLED=0 go build -o "$PB_BINARY" .

    # Verify
    if [[ -x "$PB_BINARY" ]]; then
        local version
        version="$("$PB_BINARY" --version 2>/dev/null || echo 'unknown')"
        log_success "PocketBase compiled: $version"
        log_info "Binary: $PB_BINARY"
    else
        log_error "Build failed - binary not found"
        exit 1
    fi
}

cmd_setup() {
    log_info "Setting up PocketBase..."

    # Create directories
    mkdir -p "$PB_DATA_DIR" "$PB_LOG_DIR" "$PB_BACKUP_DIR" "$PB_BIN_DIR"

    # Save config
    if [[ ! -f "$PB_CONF" ]]; then
        save_config
        log_info "Config saved to $PB_CONF"
    else
        log_info "Config already exists at $PB_CONF"
    fi

    # Check binary
    if [[ ! -x "$PB_BINARY" ]]; then
        log_error "PocketBase binary not found. Run './pb.sh install' first."
        exit 1
    fi

    # Register service
    service_register

    log_success "Setup complete"
    echo ""
    echo "  PB_HOME:  $PB_HOME"
    echo "  Data:     $PB_DATA_DIR"
    echo "  Logs:     $PB_LOG_DIR"
    echo "  Backups:  $PB_BACKUP_DIR"
    echo "  Address:  http://$PB_HOST:$PB_PORT"
    echo ""
    echo "  Run './pb.sh start' to start PocketBase"
}

cmd_start() {
    if service_is_running; then
        log_info "PocketBase is already running"
        return 0
    fi

    if [[ ! -x "$PB_BINARY" ]]; then
        log_error "PocketBase binary not found. Run './pb.sh install' first."
        exit 1
    fi

    log_info "Starting PocketBase..."
    service_start
    sleep 2

    if service_is_running; then
        log_success "PocketBase started at http://$PB_HOST:$PB_PORT"
        log_info "Admin UI: http://$PB_HOST:$PB_PORT/_/"
    else
        log_error "Failed to start PocketBase. Check logs: ./pb.sh logs"
        exit 1
    fi
}

cmd_stop() {
    if ! service_is_running; then
        log_info "PocketBase is not running"
        return 0
    fi

    log_info "Stopping PocketBase..."
    service_stop
    sleep 1
    log_success "PocketBase stopped"
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    echo "=== PocketBase Status ==="
    echo ""
    echo "  PB_HOME:  $PB_HOME"
    echo "  Binary:   $PB_BINARY"
    echo "  Address:  http://$PB_HOST:$PB_PORT"
    echo ""

    # Binary check
    if [[ -x "$PB_BINARY" ]]; then
        local version
        version="$("$PB_BINARY" --version 2>/dev/null || echo 'unknown')"
        echo "  Version:  $version"
    else
        echo "  Version:  (not installed)"
    fi

    # Service state
    if service_is_running; then
        echo "  Status:   RUNNING"

        # Get PID
        local pid=""
        if [[ "$OS" == "darwin" ]]; then
            pid="$(launchctl list "$SERVICE_NAME" 2>/dev/null | grep PID | awk '{print $NF}' || true)"
            if [[ -z "$pid" ]]; then
                pid="$(pgrep -f "$PB_BINARY" 2>/dev/null | head -1 || true)"
            fi
        else
            pid="$(systemctl --user show -p MainPID "$SYSTEMD_UNIT" 2>/dev/null | cut -d= -f2 || true)"
        fi
        [[ -n "$pid" && "$pid" != "0" ]] && echo "  PID:      $pid"

        # Health check
        local health
        health="$(curl -s --connect-timeout 3 "http://$PB_HOST:$PB_PORT/api/health" 2>/dev/null || true)"
        if [[ -n "$health" ]]; then
            echo "  Health:   OK"
        else
            echo "  Health:   UNREACHABLE"
        fi
    else
        echo "  Status:   STOPPED"
    fi

    # Data dir size
    if [[ -d "$PB_DATA_DIR" ]]; then
        local data_size
        data_size="$(du -sh "$PB_DATA_DIR" 2>/dev/null | awk '{print $1}')"
        echo "  Data:     $data_size"
    fi

    # Backup count
    if [[ -d "$PB_BACKUP_DIR" ]]; then
        local backup_count
        backup_count="$(find "$PB_BACKUP_DIR" -name "*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')"
        echo "  Backups:  $backup_count"
    fi

    echo ""
}

cmd_logs() {
    local log_file="$PB_LOG_DIR/pocketbase.log"
    local tail_lines=""
    local follow=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tail|-n)
                tail_lines="$2"
                follow=false
                shift 2
                ;;
            --error|-e)
                log_file="$PB_LOG_DIR/pocketbase.error.log"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ ! -f "$log_file" ]]; then
        log_info "No log file found at $log_file"
        return 0
    fi

    if [[ -n "$tail_lines" ]]; then
        tail -n "$tail_lines" "$log_file"
    elif [[ "$follow" == true ]]; then
        log_info "Following $log_file (Ctrl+C to stop)"
        tail -f "$log_file"
    fi
}

cmd_backup() {
    local backup_name="${1:-pb_backup_$(date +%Y%m%d_%H%M%S)}"
    local backup_file="$PB_BACKUP_DIR/${backup_name}.tar.gz"
    local was_running=false

    mkdir -p "$PB_BACKUP_DIR"

    if [[ ! -d "$PB_DATA_DIR" ]]; then
        log_error "Data directory not found: $PB_DATA_DIR"
        exit 1
    fi

    # Stop if running (for consistent backup)
    if service_is_running; then
        was_running=true
        log_info "Stopping PocketBase for consistent backup..."
        service_stop
        sleep 1
    fi

    log_info "Creating backup..."
    tar -czf "$backup_file" -C "$(dirname "$PB_DATA_DIR")" "$(basename "$PB_DATA_DIR")"

    # Restart if was running
    if [[ "$was_running" == true ]]; then
        log_info "Restarting PocketBase..."
        service_start
        sleep 1
    fi

    local backup_size
    backup_size="$(du -sh "$backup_file" | awk '{print $1}')"
    log_success "Backup created: $backup_file ($backup_size)"
}

cmd_update() {
    if [[ ! -d "$PB_SRC_DIR/.git" ]]; then
        log_error "Source not found. Run './pb.sh install' first."
        exit 1
    fi

    local was_running=false
    if service_is_running; then
        was_running=true
    fi

    log_info "Pulling latest code..."
    cd "$PB_SRC_DIR"
    git pull

    log_info "Recompiling..."
    cd "$PB_SRC_DIR/examples/base"
    CGO_ENABLED=0 go build -o "$PB_BINARY" .

    local version
    version="$("$PB_BINARY" --version 2>/dev/null || echo 'unknown')"
    log_success "Updated to: $version"

    # Re-register service (binary path may be same but config could change)
    service_register

    if [[ "$was_running" == true ]]; then
        log_info "Restarting PocketBase..."
        cmd_restart
    fi
}

cmd_uninstall() {
    echo "This will stop PocketBase and remove the service registration."
    echo ""
    read -rp "Remove all data in $PB_HOME? [y/N] " confirm

    # Stop and unregister
    if service_is_running; then
        service_stop
        sleep 1
    fi
    service_unregister

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$PB_HOME"
        log_success "PocketBase fully removed ($PB_HOME deleted)"
    else
        log_success "Service removed. Data preserved at $PB_HOME"
    fi
}

cmd_help() {
    cat << EOF
pb.sh v${SCRIPT_VERSION} - PocketBase Management Script

Usage: ./pb.sh <command> [options]

Commands:
  install       Clone repo and compile PocketBase from source
  setup         Initialize directories and register system service
  start         Start PocketBase service
  stop          Stop PocketBase service
  restart       Restart PocketBase service
  status        Show PocketBase status and health
  logs          View PocketBase logs (default: follow mode)
    --tail N      Show last N lines
    --error       Show error log
  backup [name] Create a backup of PocketBase data
  update        Pull latest code, recompile, and restart
  uninstall     Stop service and optionally remove all data
  help          Show this help message

Environment:
  PB_HOME       Base directory (default: ~/.pocketbase)

Platform: macOS (launchd) / Linux (systemd)
EOF
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    detect_os
    load_config

    local command="${1:-help}"
    shift || true

    case "$command" in
        install)    cmd_install "$@" ;;
        setup)      cmd_setup "$@" ;;
        start)      cmd_start "$@" ;;
        stop)       cmd_stop "$@" ;;
        restart)    cmd_restart "$@" ;;
        status)     cmd_status "$@" ;;
        logs)       cmd_logs "$@" ;;
        backup)     cmd_backup "$@" ;;
        update)     cmd_update "$@" ;;
        uninstall)  cmd_uninstall "$@" ;;
        help|--help|-h) cmd_help ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
