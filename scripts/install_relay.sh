#!/bin/bash
# MyBot Relay - 一键远程安装脚本
# 使用方式: ./scripts/install_relay.sh
#
# 功能:
#   1. 读取本地 config.json 中的 relay.token
#   2. 询问远程服务器信息
#   3. 打包 relay 源文件并上传
#   4. 远程安装依赖并启动服务（systemd / nohup）
#
# 前置依赖: sshpass（会自动检测并提示安装）

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RELAY_DIR="$SCRIPT_DIR/relay"

# ──────────────────────────────────────────────
#  颜色定义
# ──────────────────────────────────────────────
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

# ──────────────────────────────────────────────
#  1. 检查 sshpass
# ──────────────────────────────────────────────
check_sshpass() {
    if command -v sshpass &>/dev/null; then
        return 0
    fi

    warn "sshpass is required for SSH password authentication."
    echo ""
    echo "  Install it manually:"
    echo "    macOS:  brew install hudochenkov/sshpass/sshpass"
    echo "    Ubuntu: sudo apt install sshpass"
    echo "    CentOS: sudo yum install sshpass"
    echo ""
    echo "  Alternatively, set up SSH key-based auth and re-run this script."
    echo ""

    read -rp "Press Enter to exit and install sshpass first, or 'c' to continue without password auth... " CHOICE
    if [ "$CHOICE" = "c" ]; then
        warn "Continuing without sshpass. Make sure passwordless SSH is configured."
        return 1
    fi
    err "Please install sshpass and try again."
    exit 1
}

# ──────────────────────────────────────────────
#  2. 读取 config.json 中的 relay token
# ──────────────────────────────────────────────
read_token() {
    local config_file="$PROJECT_DIR/config.json"
    local token=""

    if [ -f "$config_file" ]; then
        token=$(python3 -c "
import json
with open('$config_file') as f:
    cfg = json.load(f)
print(cfg.get('relay', {}).get('token', ''))
" 2>/dev/null || echo "")
    fi

    if [ -n "$token" ]; then
        echo "$token"
        return 0
    fi

    # Fallback: 尝试从 acp_config.json 读取
    local old_config="$PROJECT_DIR/acp_config.json"
    if [ -f "$old_config" ]; then
        token=$(python3 -c "
import json
with open('$old_config') as f:
    cfg = json.load(f)
print(cfg.get('relay_token', ''))
" 2>/dev/null || echo "")
    fi

    echo "$token"
}

# ──────────────────────────────────────────────
#  3. 交互式信息收集
# ──────────────────────────────────────────────
gather_info() {
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   MyBot Relay - 远程安装向导          ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    # ---- Server IP ----
    while [ -z "${SERVER_IP:-}" ]; do
        read -rp "Server IP: " SERVER_IP
    done

    # ---- SSH Port ----
    read -rp "SSH Port [22]: " SSH_PORT_INPUT
    SSH_PORT="${SSH_PORT_INPUT:-22}"

    # ---- Relay Port ----
    read -rp "Relay Port [8766]: " RELAY_PORT_INPUT
    RELAY_PORT="${RELAY_PORT_INPUT:-8766}"

    # ---- Relay Token（自动读取 + 可手动修改）----
    AUTO_TOKEN=$(read_token)
    if [ -n "$AUTO_TOKEN" ]; then
        echo ""
        info "Auto-detected relay token from config.json"
        read -rp "Relay Token [$AUTO_TOKEN]: " TOKEN_INPUT
        RELAY_TOKEN="${TOKEN_INPUT:-$AUTO_TOKEN}"
    else
        echo ""
        warn "No relay token found in config.json"
        while [ -z "${RELAY_TOKEN:-}" ]; do
            read -rp "Relay Token (required): " RELAY_TOKEN
        done
    fi

    # ---- SSH Password ----
    echo ""
    info "Enter SSH password for $SERVER_IP (input hidden)"
    read -rsp "SSH Password: " SSH_PASS
    echo ""

    # ---- Systemd ----
    echo ""
    echo "How should the relay run on the remote server?"
    echo "  1) systemd service (recommended) - auto-restart, persistent"
    echo "  2) nohup background - simple, manual management"
    read -rp "Choose [1/2]: " SYS_CHOICE
    case "$SYS_CHOICE" in
        2) USE_SYSTEMD="no" ;;
        *) USE_SYSTEMD="yes" ;;
    esac

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Summary${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  Server:      $SERVER_IP:$SSH_PORT"
    echo "  Relay port:  $RELAY_PORT"
    echo "  Token:       ${RELAY_TOKEN:0:12}...${RELAY_TOKEN: -4}"
    echo "  Start mode:  $([ "$USE_SYSTEMD" = "yes" ] && echo "systemd" || echo "nohup")"
    echo ""
    read -rp "Proceed with installation? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
        err "Installation cancelled."
        exit 0
    fi
}

# ──────────────────────────────────────────────
#  4. 打包 relay 源文件
# ──────────────────────────────────────────────
build_package() {
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/mybot-relay-XXXXXX)

    info "Building relay package..."

    # 创建目录结构
    mkdir -p "$tmp_dir/src/transport"

    # 复制 relay 服务端代码
    cp "$PROJECT_DIR/src/transport/relay_server.py" "$tmp_dir/src/transport/relay_server.py"
    cp "$PROJECT_DIR/src/logger.py"               "$tmp_dir/src/logger.py"

    # 创建包标记文件（空也行，但 Relay 需要导入路径）
    cp "$PROJECT_DIR/src/__init__.py"              "$tmp_dir/src/__init__.py" 2>/dev/null || touch "$tmp_dir/src/__init__.py"
    touch "$tmp_dir/src/transport/__init__.py"

    # 生成 .env
    cat > "$tmp_dir/.env" <<EOF
# MyBot Relay Configuration
# Auto-generated by install_relay.sh on $(date '+%Y-%m-%d %H:%M:%S')
RELAY_TOKEN=${RELAY_TOKEN}
RELAY_PORT=${RELAY_PORT}
RELAY_HOST=0.0.0.0
EOF

    # 复制辅助脚本和配置
    cp "$RELAY_DIR/relay_requirements.txt" "$tmp_dir/relay_requirements.txt"
    cp "$RELAY_DIR/mybot-relay.service"    "$tmp_dir/mybot-relay.service"
    cp "$RELAY_DIR/start_relay.sh"         "$tmp_dir/start_relay.sh"
    cp "$RELAY_DIR/_remote_install.sh"     "$tmp_dir/_remote_install.sh"

    # 打包
    local tarball="/tmp/mybot-relay-package.tar.gz"
    tar czf "$tarball" -C "$tmp_dir" .

    rm -rf "$tmp_dir"
    echo "$tarball"
}

# ──────────────────────────────────────────────
#  5. 上传 + 远程安装
# ──────────────────────────────────────────────
do_install() {
    local tarball="$1"

    # 构建 SSH 前缀
    local SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p $SSH_PORT"
    local SSH_TARGET="root@$SERVER_IP"  # 默认用 root，也可考虑让用户输入用户名

    info "Step 1/4: Uploading relay package to $SERVER_IP ..."

    # 上传 package
    if [ -n "$SSH_PASS" ]; then
        sshpass -p "$SSH_PASS" scp $SSH_OPTS "$tarball" "$SSH_TARGET:/tmp/mybot-relay-package.tar.gz"
    else
        scp $SSH_OPTS "$tarball" "$SSH_TARGET:/tmp/mybot-relay-package.tar.gz"
    fi
    ok "Upload complete"

    info "Step 2/4: Extracting package on remote server..."
    local REMOTE_CMD="
set -e
INSTALL_DIR='/opt/mybot-relay'
mkdir -p \"\$INSTALL_DIR\"
cd \"\$INSTALL_DIR\"
tar xzf /tmp/mybot-relay-package.tar.gz
rm -f /tmp/mybot-relay-package.tar.gz
chmod +x \$INSTALL_DIR/_remote_install.sh
"
    if [ -n "$SSH_PASS" ]; then
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "$SSH_TARGET" "$REMOTE_CMD"
    else
        ssh $SSH_OPTS "$SSH_TARGET" "$REMOTE_CMD"
    fi
    ok "Package extracted"

    info "Step 3/4: Installing dependencies and starting relay..."
    local INSTALL_CMD="cd /opt/mybot-relay && bash _remote_install.sh $USE_SYSTEMD"
    if [ -n "$SSH_PASS" ]; then
        sshpass -p "$SSH_PASS" ssh $SSH_OPTS "$SSH_TARGET" "$INSTALL_CMD"
    else
        ssh $SSH_OPTS "$SSH_TARGET" "$INSTALL_CMD"
    fi
    ok "Remote installation finished"
}

# ──────────────────────────────────────────────
#  6. 清理
# ──────────────────────────────────────────────
cleanup() {
    local tarball="/tmp/mybot-relay-package.tar.gz"
    rm -f "$tarball"
}

# ──────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     MyBot Relay Installer v1.0       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""

    check_sshpass
    gather_info

    local tarball
    tarball=$(build_package)
    ok "Package built: $tarball"

    do_install "$tarball"
    cleanup

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Installation Complete!              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "  Relay URL: ws://$SERVER_IP:$RELAY_PORT/relay/{mac|app}/{user_id}"
    echo "  Token:     $RELAY_TOKEN"
    echo ""
    echo "  Update your Bridge config.json:"
    echo '    "relay": {'
    echo "      \"url\":   \"ws://$SERVER_IP:$RELAY_PORT/relay\","
    echo '      "token": "'"$RELAY_TOKEN"'",'
    echo '      "user_id": "user_xxxxxx"'
    echo '    }'
    echo ""
    echo "  Note: user_id is auto-generated by Bridge on first run."
    echo "  It will be printed when you start the Bridge: ./start.sh"
    echo ""
}

main "$@"