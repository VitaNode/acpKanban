#!/bin/bash
# acpKanban Relay - 手动启动脚本（无 systemd 时的 fallback）
# 用法: ./start_relay.sh

cd "$(dirname "$0")" || exit 1

PID_FILE="relay.pid"
LOG_FILE="relay.log"

# 检查是否已经在运行
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[!] Relay is already running (PID: $OLD_PID)"
        echo "    To stop: kill $OLD_PID"
        exit 1
    else
        echo "[*] Removing stale PID file..."
        rm -f "$PID_FILE"
    fi
fi

# 启动 relay（nohup 后台运行）
echo "[*] Starting acpKanban Relay Server..."
nohup ./.venv/bin/python3 -m src.transport.relay_server >> "$LOG_FILE" 2>&1 &
RELAY_PID=$!
echo "$RELAY_PID" > "$PID_FILE"

sleep 2
# 验证启动成功
if kill -0 "$RELAY_PID" 2>/dev/null; then
    echo "[✓] Relay started (PID: $RELAY_PID)"
    echo "    Logs: $(pwd)/$LOG_FILE"
    echo "    To stop: kill $RELAY_PID"
else
    echo "[✗] Relay failed to start. Check logs: $(pwd)/$LOG_FILE"
    tail -5 "$LOG_FILE"
    exit 1
fi