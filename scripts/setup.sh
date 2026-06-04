#!/bin/bash
#
# acpKanban Setup Script
# Targets: macOS (Darwin) and Linux
# Usage:   bash scripts/setup.sh
#
# This script must run from the project root (acpkanban/).
# It will create .venv, install deps, and generate start.sh / start_dev.sh.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   acpKanban Setup v1.2     ${NC}"
echo -e "${BLUE}========================================${NC}"

# ──────────────────────────────────────────────
#  1. OS Detection & Prerequisites
# ──────────────────────────────────────────────
OS="$(uname)"
info "Detected OS: ${OS}"

case "$OS" in
    Darwin)
        if ! xcode-select -p &>/dev/null; then
            warn "Xcode Command Line Tools not found."
            echo "  Run: xcode-select --install"
            echo "  Then re-run this script."
            exit 1
        fi
        if ! command -v python3 &>/dev/null; then
            warn "Python 3 not found. Install via:"
            echo "  brew install python"
            echo "  Or download from https://www.python.org/downloads/"
            exit 1
        fi
        ;;
    Linux)
        if command -v apt-get &>/dev/null; then
            if ! dpkg -l python3-venv &>/dev/null 2>&1; then
                info "Installing python3-venv (required for virtual environment)..."
                if sudo -n true 2>/dev/null; then
                    sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv
                else
                    warn "sudo requires a terminal. Install python3-venv manually:"
                    warn "  sudo apt-get install python3-venv"
                fi
            fi
        fi
        ;;
    *)
        warn "Untested OS: ${OS}. Proceed with caution."
        ;;
esac

# ──────────────────────────────────────────────
#  2. Python Check (3.10+)
# ──────────────────────────────────────────────
PYTHON_CMD="python3"

check_python_version() {
    command -v "$1" &>/dev/null || return 1
    local minor
    minor=$("$1" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null)
    [ "$minor" -ge 10 ] 2>/dev/null
}

if ! check_python_version "$PYTHON_CMD"; then
    warn "Python 3.10+ required, found: $(python3 --version 2>/dev/null || echo 'none')"

    if [ "$OS" = "Darwin" ] && command -v brew &>/dev/null; then
        info "Attempting to install Python 3.12 via Homebrew..."
        brew install python@3.12
        BREW_PREFIX="$(brew --prefix python@3.12)"
        if [ -x "${BREW_PREFIX}/bin/python3.12" ]; then
            PYTHON_CMD="${BREW_PREFIX}/bin/python3.12"
        elif [ -x "${BREW_PREFIX}/libexec/bin/python3" ]; then
            PYTHON_CMD="${BREW_PREFIX}/libexec/bin/python3"
        else
            PYTHON_CMD="python3.12"   # fallback: 依赖 PATH
        fi
    fi

    if ! check_python_version "$PYTHON_CMD"; then
        err "Could not find or install Python 3.10+."
        echo ""
        echo "  Please install manually:"
        echo "    brew install python@3.12"
        echo "    Or: https://www.python.org/downloads/"
        echo ""
        echo "  Then re-run: bash scripts/setup.sh"
        exit 1
    fi

    ok "Using $(${PYTHON_CMD} --version)"
fi

# ──────────────────────────────────────────────
#  3. Virtual Environment
# ──────────────────────────────────────────────
if [ ! -d ".venv" ]; then
    info "Creating virtual environment..."
    $PYTHON_CMD -m venv .venv
else
    info "Virtual environment already exists."
fi

# ──────────────────────────────────────────────
#  4. Install Dependencies
# ──────────────────────────────────────────────
info "Installing dependencies (this may take a while)..."
./.venv/bin/pip install --quiet --upgrade pip
./.venv/bin/pip install --quiet -r requirements.txt

# 验证 tree-sitter / sqlite-vec 原生编译是否成功
./.venv/bin/python3 -c "import tree_sitter; print('tree_sitter: ok')" 2>/dev/null || \
    warn "tree_sitter native build may have failed (some features limited)"
./.venv/bin/python3 -c "import sqlite_vec; print('sqlite-vec: ok')" 2>/dev/null || \
    warn "sqlite-vec native build may have failed (vector search disabled)"

# ──────────────────────────────────────────────
#  5. Initialize Database & Config
# ──────────────────────────────────────────────
info "Initializing system configuration..."
export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}."
./.venv/bin/python3 -c "from src.config.manager import config"
ok "Configuration saved to config.json"

# ──────────────────────────────────────────────
#  6. Create Runner Scripts
# ──────────────────────────────────────────────

# 如果 start.sh 已存在，询问是否覆盖
OVERWRITE_START="yes"
if [ -f "start.sh" ]; then
    echo ""
    warn "start.sh already exists."
    read -rp "Overwrite? [y/N]: " OVERWRITE_CHOICE </dev/tty
    if [[ ! "$OVERWRITE_CHOICE" =~ ^[Yy] ]]; then
        OVERWRITE_START="no"
        info "Keeping existing start.sh"
    fi
fi

if [ "$OVERWRITE_START" = "yes" ]; then
    info "Generating start.sh (All-in-One: API + Local Relay + Bridge)..."
    cat > start.sh <<'RUNTIME_EOF'
#!/bin/bash
export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}."
echo "[*] Starting acpKanban All-in-One Service..."
exec ./.venv/bin/python3 run_all.py
RUNTIME_EOF
    chmod +x start.sh
    ok "start.sh created"

    info "Generating start_api.sh (API Server Only)..."
    cat > start_api.sh <<'RUNTIME_EOF'
#!/bin/bash
export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}."
echo "[*] Starting acpKanban API Server..."
exec ./.venv/bin/uvicorn api.main:app --host 127.0.0.1 --port 8000
RUNTIME_EOF
    chmod +x start_api.sh
    ok "start_api.sh created"
fi

# 开发模式脚本（始终生成，不会覆盖重要文件）
info "Generating start_dev.sh (development, with --reload)..."
cat > start_dev.sh <<'RUNTIME_EOF'
#!/bin/bash
export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}."
echo "[*] Starting acpKanban API Server (dev mode)..."
exec ./.venv/bin/uvicorn api.main:app --host 127.0.0.1 --port 8000 --reload
RUNTIME_EOF
chmod +x start_dev.sh
ok "start_dev.sh created"


# ──────────────────────────────────────────────
#  7. Post-Install Verification
# ──────────────────────────────────────────────
info "Verifying installation..."
VERIFY_PASS=true

./.venv/bin/python3 -c "
from api.main import app
print('✓ API module loaded successfully')
from src.persistence.database import KanbanDB
db = KanbanDB()
db.init_db()
print('✓ Database initialized successfully')
" 2>/dev/null || VERIFY_PASS=false

if [ "$VERIFY_PASS" = false ]; then
    warn "Post-install verification found issues. Check the error messages above."
    warn "The server may still work; run it and check logs."
else
    ok "Installation verified successfully"
fi

# ──────────────────────────────────────────────
#  Done
# ──────────────────────────────────────────────
echo -e ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Setup Completed Successfully!       ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo -e ""
echo -e "  Standard:    ${BLUE}./start.sh${NC} (API + Bridge + Local Relay)"
echo -e "  API Only:    ${BLUE}./start_api.sh${NC}"
echo -e "  Dev mode:    ${BLUE}./start_dev.sh${NC}"
echo -e ""
echo -e "  Server runs at:  ${BLUE}http://localhost:8000${NC}"
echo -e "  API docs:        ${BLUE}http://localhost:8000/docs${NC}"
echo -e ""
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Connection Credentials (config.json):"
./.venv/bin/python3 -c "
from src.config.manager import config
print(f'    USER_ID:     {config.user_id}')
print(f'    RELAY_TOKEN: {config.relay_token}')
print(f'    API_TOKEN:   {config.api_token}')
"
echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e ""
echo -e "  ${YELLOW}Next Steps:${NC}"
echo -e "  1. Run ${BLUE}./start.sh${NC}"
echo -e "  2. Enter the credentials above into the Mobile App's settings."
echo -e "  3. Use your Mac's LAN IP as the server address."
echo -e ""
echo -e "  ${YELLOW}Tip:${NC} For cloud relay deployment, use: ${BLUE}./scripts/install_relay.sh${NC}"
echo -e ""
