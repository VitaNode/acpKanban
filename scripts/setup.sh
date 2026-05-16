#!/bin/bash

# MyBot (Agent Kanban) Setup Script
# Targets: macOS (Darwin) and Linux

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}   MyBot (Agent Kanban) Setup v1.0     ${NC}"
echo -e "${BLUE}=======================================${NC}"

# 1. OS Detection
OS="$(uname)"
echo -e "[*] Detected OS: ${OS}"

# 2. Python Check
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}[!] Python 3 is not installed. Please install it first.${NC}"
    exit 1
fi

PYTHON_VERSION=$(python3 --version)
echo -e "[*] Using ${PYTHON_VERSION}"

# 3. Virtual Environment
if [ ! -d ".venv" ]; then
    echo -e "[*] Creating virtual environment..."
    python3 -m venv .venv
else
    echo -e "[*] Virtual environment already exists."
fi

# 4. Install Dependencies
echo -e "[*] Installing dependencies..."
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install -r requirements.txt

# 5. Initialize Database & Config
echo -e "[*] Initializing system configuration..."
export PYTHONPATH=$PYTHONPATH:.
./.venv/bin/python3 -c "from src.config.manager import config"

# 6. Create Runner Script
echo -e "[*] Creating start.sh..."
cat <<EOF > start.sh
#!/bin/bash
export PYTHONPATH=\$PYTHONPATH:.
echo "[*] Starting MyBot API Server..."
./.venv/bin/uvicorn api.main:app --host 0.0.0.0 --port 8000
EOF
chmod +x start.sh

echo -e "${GREEN}=======================================${NC}"
echo -e "${GREEN}   Setup Completed Successfully!       ${NC}"
echo -e "${GREEN}=======================================${NC}"
echo -e ""
echo -e "To start the server, run: ${BLUE}./start.sh${NC}"
echo -e ""
echo -e "Your credentials (saved in config.json):"
./.venv/bin/python3 -c "from src.config.manager import config; print(f'USER_ID: {config.user_id}'); print(f'RELAY_TOKEN: {config.relay_token}')"
echo -e ""
echo -e "Please copy these credentials and enter them into the mobile app's Connection Settings."
echo -e "If you are using Tailscale, use your Tailscale IP and the port 8000 in the mobile app."
