#!/bin/bash
# acpKanban Relay - 服务器本地一键安装脚本
# 使用方式:
#   curl -fsSL https://raw.githubusercontent.com/VitaNode/acpKanban/main/install_relay.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/VitaNode/acpKanban/main/install_relay.sh | bash -s -- --token mytoken
#   bash install_relay.sh --token mytoken
#
# 适用场景: 仅支持 Web 终端（如服务器管理后台），无法 SSH 直连的环境
# 功能:
#   1. 从 GitHub 克隆 relay 源码
#   2. 安装 Python 依赖（隔离在 venv 中，不影响系统环境）
#   3. 生成 .env 配置文件（token 通过 --token 参数或交互式输入）
#   4. 安装 systemd 服务 或 配置 nohup 启动

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }

INSTALL_DIR="/opt/acpkanban-relay"
VENV_DIR="$INSTALL_DIR/.venv"
REPO_URL="https://github.com/VitaNode/acpKanban.git"
TMP_DIR=$(mktemp -d /tmp/acpkanban-relay-XXXXXX)

RELAY_PORT=""
RELAY_TOKEN=""
SERVICE_MODE=""
ENABLE_AUTO_START=""

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# ──────────────────────────────────────────────
# 工具函数：根据发行版安装包
# ──────────────────────────────────────────────
pkg_install() {
    local pkg_apt="$1" pkg_yum="$2" pkg_apk="$3" pkg_zypper="$4" pkg_pacman="$5"
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkg_apt
    elif command -v yum &>/dev/null; then
        yum install -y -q $pkg_yum
    elif command -v apk &>/dev/null; then
        apk add --no-cache $pkg_apk
    elif command -v zypper &>/dev/null; then
        zypper install -y $pkg_zypper
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm $pkg_pacman
    else
        return 1
    fi
    return 0
}

pkg_update() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
    elif command -v apk &>/dev/null; then
        apk update --quiet
    elif command -v zypper &>/dev/null; then
        zypper refresh
    fi
}

# ──────────────────────────────────────────────
# 1. 交互式配置收集
# ──────────────────────────────────────────────
gather_config() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  Configuration${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Relay Port
    while true; do
        read -rp "Relay Port [8766]: " PORT_INPUT
        RELAY_PORT="${PORT_INPUT:-8766}"
        if [[ "$RELAY_PORT" =~ ^[0-9]+$ ]] && [ "$RELAY_PORT" -ge 1 ] && [ "$RELAY_PORT" -le 65535 ]; then
            break
        fi
        err "Invalid port. Must be a number between 1 and 65535."
    done

    # Relay Token
    if [ -z "$RELAY_TOKEN" ]; then
        echo ""
        info "Enter the relay token (leave empty to fill in manually after install)"
        read -rp "Relay Token: " RELAY_TOKEN
    fi

    # Service mode
    echo ""
    echo "How should the relay run?"
    echo "  1) systemd service (recommended) - auto-restart, persistent"
    echo "  2) nohup background - simple, manual management"
    read -rp "Choose [1/2]: " MODE_CHOICE
    if [ "$MODE_CHOICE" = "2" ]; then
        SERVICE_MODE="nohup"
    else
        SERVICE_MODE="systemd"
    fi

    # Auto-start (only for systemd)
    if [ "$SERVICE_MODE" = "systemd" ]; then
        echo ""
        echo "Enable auto-start on boot?"
        read -rp "Enable auto-start? [Y/n]: " AUTO_CHOICE
        if [[ "$AUTO_CHOICE" =~ ^[Nn] ]]; then
            ENABLE_AUTO_START="no"
        else
            ENABLE_AUTO_START="yes"
        fi
    fi

    # Summary
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Summary${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  Port:        $RELAY_PORT"
    if [ -n "$RELAY_TOKEN" ]; then
        local masked
        masked=$(python3 -c "t='$RELAY_TOKEN'; print(t[:8]+'...'+t[-4:])" 2>/dev/null || echo "${RELAY_TOKEN:0:8}...${RELAY_TOKEN: -4}")
        echo "  Token:       $masked (configured)"
    else
        echo "  Token:       (will be prompted after install)"
    fi
    echo "  Start mode:  $SERVICE_MODE"
    if [ "$SERVICE_MODE" = "systemd" ]; then
        echo "  Auto-start:  $ENABLE_AUTO_START"
    fi
    echo ""
    read -rp "Proceed with installation? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
        err "Installation cancelled."
        exit 0
    fi
}

# ──────────────────────────────────────────────
# 2. 检查/安装前置依赖
# ──────────────────────────────────────────────
check_prereqs() {
    if ! command -v python3 &>/dev/null; then
        info "Installing python3..."
        pkg_update
        if ! pkg_install "python3 python3-pip python3-venv" "python3 python3-pip" "python3 py3-pip" "python3 python3-pip python3-venv" "python python-pip"; then
            err "Cannot install python3 automatically. Please install it manually."
            exit 1
        fi
    fi
    ok "$(python3 --version)"

    if ! command -v git &>/dev/null; then
        info "Installing git..."
        if ! pkg_install "git" "git" "git" "git" "git"; then
            err "Cannot install git automatically. Please install it manually."
            exit 1
        fi
    fi
    ok "Git: $(git --version)"
}

# ──────────────────────────────────────────────
# 3. 获取源码
# ──────────────────────────────────────────────
get_source() {
    info "Downloading relay source files..."
    if git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$TMP_DIR/acpKanban" 2>/dev/null; then
        git -C "$TMP_DIR/acpKanban" sparse-checkout set scripts/relay
    else
        git clone --depth 1 "$REPO_URL" "$TMP_DIR/acpKanban"
    fi
    ok "Source code downloaded"
}

# ──────────────────────────────────────────────
# 4. 部署文件到 INSTALL_DIR
# ──────────────────────────────────────────────
setup_files() {
    local src="$TMP_DIR/acpKanban/scripts/relay"

    mkdir -p "$INSTALL_DIR"

    cp "$src/relay_server.py"           "$INSTALL_DIR/relay_server.py"
    cp "$src/relay_requirements.txt"    "$INSTALL_DIR/relay_requirements.txt"

    # 生成适配 standalone 的 start_relay.sh
    cat > "$INSTALL_DIR/start_relay.sh" <<'SHELL'
#!/bin/bash
cd "$(dirname "$0")" || exit 1

PID_FILE="relay.pid"
LOG_FILE="relay.log"

if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[!] Relay is already running (PID: $OLD_PID)"
        echo "    To stop: kill $OLD_PID"
        exit 1
    else
        rm -f "$PID_FILE"
    fi
fi

echo "[*] Starting acpKanban Relay Server..."
nohup ./.venv/bin/python3 relay_server.py >> "$LOG_FILE" 2>&1 &
RELAY_PID=$!
echo "$RELAY_PID" > "$PID_FILE"

sleep 2
if kill -0 "$RELAY_PID" 2>/dev/null; then
    echo "[✓] Relay started (PID: $RELAY_PID)"
    echo "    Logs: $(pwd)/$LOG_FILE"
    echo "    To stop: kill $RELAY_PID"
else
    echo "[✗] Relay failed to start. Check logs: $(pwd)/$LOG_FILE"
    tail -5 "$LOG_FILE"
    exit 1
fi
SHELL
    chmod +x "$INSTALL_DIR/start_relay.sh"

    # 生成 .env
    local token_value="${RELAY_TOKEN:-YOUR_RELAY_TOKEN}"
    cat > "$INSTALL_DIR/.env" <<EOF
# acpKanban Relay Configuration
# Installed on $(date '+%Y-%m-%d %H:%M:%S')
RELAY_TOKEN=${token_value}
RELAY_PORT=${RELAY_PORT}
RELAY_HOST=0.0.0.0
EOF
    if [ -n "$RELAY_TOKEN" ]; then
        ok "Relay token has been written to .env"
    else
        warn "Edit relay token later: nano $INSTALL_DIR/.env"
    fi
    chmod 600 "$INSTALL_DIR/.env"

    ok "Files deployed to $INSTALL_DIR"
}

# ──────────────────────────────────────────────
# 5. 安装 Python 依赖（隔离在 venv 中）
# ──────────────────────────────────────────────
install_deps() {
    info "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip
    "$VENV_DIR/bin/pip" install --quiet -r "$INSTALL_DIR/relay_requirements.txt"
    ok "Python dependencies installed (isolated in venv)"
}

# ──────────────────────────────────────────────
# 6. 配置服务
# ──────────────────────────────────────────────
setup_service() {
    if [ "$SERVICE_MODE" = "nohup" ]; then
        warn "Skipping systemd setup."
        info "Start relay manually: bash $INSTALL_DIR/start_relay.sh"
        return
    fi

    if ! command -v systemctl &>/dev/null; then
        warn "systemctl not found. Falling back to nohup mode."
        info "Start relay manually: bash $INSTALL_DIR/start_relay.sh"
        return
    fi

    info "Installing systemd service..."

    if ! id -u acpkanban-relay &>/dev/null; then
        useradd --system --no-create-home --user-group --shell /usr/sbin/nologin acpkanban-relay
    fi
    local RELAY_GROUP
    RELAY_GROUP=$(id -gn acpkanban-relay 2>/dev/null || echo "nogroup")
    chown -R "acpkanban-relay:$RELAY_GROUP" "$INSTALL_DIR"
    chmod 750 "$INSTALL_DIR"

    cat > "$INSTALL_DIR/acpkanban-relay.service" <<UNIT
[Unit]
Description=acpKanban Relay Server
After=network.target

[Service]
Type=simple
User=acpkanban-relay
Group=${RELAY_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${VENV_DIR}/bin/python3 relay_server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
NoNewPrivileges=yes
PrivateDevices=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
UNIT

    cp "$INSTALL_DIR/acpkanban-relay.service" /etc/systemd/system/acpkanban-relay.service
    chmod 644 /etc/systemd/system/acpkanban-relay.service

    systemctl daemon-reload

    if [ "$ENABLE_AUTO_START" = "yes" ]; then
        systemctl enable acpkanban-relay
        ok "systemd service installed and auto-start enabled"
    else
        ok "systemd service installed (auto-start disabled)"
        info "Enable later: systemctl enable acpkanban-relay"
    fi

    if [ -n "$RELAY_TOKEN" ]; then
        echo ""
        read -rp "Start the relay now? [Y/n]: " START_NOW
        if [[ ! "$START_NOW" =~ ^[Nn] ]]; then
            systemctl start acpkanban-relay
            sleep 2
            if systemctl is-active --quiet acpkanban-relay; then
                ok "Relay started successfully"
            else
                err "Service failed to start. Check: journalctl -u acpkanban-relay -n 30"
            fi
        fi
    else
        echo ""
        warn "Set the relay token first, then start: systemctl start acpkanban-relay"
    fi

}

# ──────────────────────────────────────────────
# 命令行参数解析
# ──────────────────────────────────────────────
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --token)
                if [ -z "$2" ]; then
                    err "--token requires an argument"
                    exit 1
                fi
                RELAY_TOKEN="$2"
                shift 2
                ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  acpKanban Relay - Local Installer     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"
    gather_config
    check_prereqs
    get_source
    setup_files
    install_deps
    setup_service

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Installation Complete!              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "  Install dir: $INSTALL_DIR"
    echo "  Config:      $INSTALL_DIR/.env"
    echo ""
    echo "  ${YELLOW}Next steps:${NC}"
    if [ -z "$RELAY_TOKEN" ]; then
        echo "  1. Set relay token:  nano $INSTALL_DIR/.env"
        echo "  2. Start the relay:  systemctl start acpkanban-relay"
        echo "     (or nohup:        bash $INSTALL_DIR/start_relay.sh)"
    else
        echo "  1. Check status:     systemctl status acpkanban-relay"
        echo "  2. View logs:        journalctl -u acpkanban-relay -f"
    fi
    echo ""
}

main "$@"
