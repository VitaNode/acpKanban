#!/bin/bash
# MyBot Relay - 远程安装脚本（在目标服务器上执行）
# 前置条件: 所有文件已放置在 $INSTALL_DIR 目录下
# 此脚本由 install_relay.sh 通过 SSH 调用

set -e

INSTALL_DIR="/opt/mybot-relay"
VENV_DIR="$INSTALL_DIR/.venv"

echo "========================================"
echo "   MyBot Relay - Remote Installer      "
echo "========================================"

# --- 1. 检查 Python ---
echo "[*] Checking Python3..."
if ! command -v python3 &> /dev/null; then
    echo "[!] Python3 not found. Attempting to install..."
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y -qq python3 python3-pip python3-venv
    elif command -v yum &> /dev/null; then
        yum install -y -q python3 python3-pip
    else
        echo "[✗] Cannot install python3 automatically. Please install it manually."
        exit 1
    fi
fi
echo "[✓] $(python3 --version)"

# --- 2. 创建目录 ---
echo "[*] Setting up $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

# --- 3. 复制文件（来自 tar 解压的目录）---
# 安装脚本所在目录即为源文件目录
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "[*] Copying files from $SRC_DIR to $INSTALL_DIR ..."
cp "$SRC_DIR/relay_server.py" "$INSTALL_DIR/relay_server.py"
cp "$SRC_DIR/.env" "$INSTALL_DIR/.env"
cp "$SRC_DIR/relay_requirements.txt" "$INSTALL_DIR/relay_requirements.txt"
cp "$SRC_DIR/start_relay.sh" "$INSTALL_DIR/start_relay.sh"
chmod +x "$INSTALL_DIR/start_relay.sh"

# --- 4. 创建虚拟环境并安装依赖 ---
echo "[*] Creating Python virtual environment..."
python3 -m venv "$VENV_DIR"
echo "[*] Installing dependencies..."
"$VENV_DIR/bin/pip" install --quiet --upgrade pip
"$VENV_DIR/bin/pip" install --quiet -r "$INSTALL_DIR/relay_requirements.txt"
echo "[✓] Dependencies installed"

# --- 5. 启动方式 ---
USE_SYSTEMD="${1:-}"
if [ "$USE_SYSTEMD" = "yes" ]; then
    echo "[*] Installing systemd service..."

    cp "$SRC_DIR/mybot-relay.service" /etc/systemd/system/mybot-relay.service
    chmod 644 /etc/systemd/system/mybot-relay.service

    # 创建专用用户（安全考量）
    if ! id -u mybot-relay &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin mybot-relay
    fi
    chown -R mybot-relay:nogroup "$INSTALL_DIR"
    chmod 750 "$INSTALL_DIR"

    # 修改 service 文件中的 User
    sed -i 's/User=nobody/User=mybot-relay/' /etc/systemd/system/mybot-relay.service
    sed -i 's/Group=nogroup/Group=nogroup/' /etc/systemd/system/mybot-relay.service

    systemctl daemon-reload
    systemctl enable mybot-relay
    systemctl restart mybot-relay

    sleep 2
    if systemctl is-active --quiet mybot-relay; then
        echo "[✓] Systemd service started successfully"
        systemctl status mybot-relay --no-pager -l | head -10
    else
        echo "[✗] Service failed to start. Check: journalctl -u mybot-relay -n 30"
        journalctl -u mybot-relay -n 20 --no-pager
        exit 1
    fi

elif [ "$USE_SYSTEMD" = "no" ]; then
    echo "[*] Starting relay with nohup (no systemd)..."
    # 如果已有运行中的实例，先停掉
    if [ -f "$INSTALL_DIR/relay.pid" ]; then
        OLD_PID=$(cat "$INSTALL_DIR/relay.pid")
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    cd "$INSTALL_DIR"
    nohup "$VENV_DIR/bin/python3" relay_server.py >> "$INSTALL_DIR/relay.log" 2>&1 &
    RELAY_PID=$!
    echo "$RELAY_PID" > "$INSTALL_DIR/relay.pid"
    sleep 2
    if kill -0 "$RELAY_PID" 2>/dev/null; then
        echo "[✓] Relay started with PID: $RELAY_PID"
        echo "    Logs: $INSTALL_DIR/relay.log"
        echo "    To stop: kill $RELAY_PID"
    else
        echo "[✗] Relay failed to start. Check logs: $INSTALL_DIR/relay.log"
        tail -10 "$INSTALL_DIR/relay.log"
        exit 1
    fi
else
    echo "[!] Unknown startup mode: $USE_SYSTEMD"
    echo "    Skipping service start, files are at $INSTALL_DIR"
    echo "    Run manually: cd $INSTALL_DIR && bash start_relay.sh"
fi

# --- 6. 打印关键信息 ---
echo ""
echo "========================================"
echo "   Installation Complete!              "
echo "========================================"
echo "Install dir: $INSTALL_DIR"
echo "Config:      $INSTALL_DIR/.env"
echo ""
# 读取端口信息
PORT=$(grep -oP 'RELAY_PORT=\K.*' "$INSTALL_DIR/.env" 2>/dev/null || echo "8766")
HOST=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
echo "Relay URL:   ws://$HOST:$PORT/relay/{mac|app}/{user_id}"
echo ""
echo "Remember to update your Bridge's config.json:"
echo '  "relay": {'
echo '    "url":   "ws://'$HOST':'$PORT'/relay",'
echo '    "token": "<see config.json>"'
echo '  }'