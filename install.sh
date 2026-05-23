#!/bin/bash
#
# acpKanban One-Click Remote Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/VitaNode/acpKanban/main/install.sh | bash
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }

REPO_URL="https://github.com/VitaNode/acpKanban.git"
INSTALL_DIR="acpKanban"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}     acpKanban Installer v0.2.0        ${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. Check Git
if ! command -v git &> /dev/null; then
    err "Git is not installed. Please install Git first."
    exit 1
fi

# 2. Clone Repository
if [ -d "$INSTALL_DIR" ]; then
    info "Directory '$INSTALL_DIR' already exists."
    read -rp "Pull latest changes and re-install? [y/N]: " REINSTALL_CHOICE </dev/tty
    if [[ ! "$REINSTALL_CHOICE" =~ ^[Yy] ]]; then
        info "Aborting installation."
        exit 0
    fi
    cd "$INSTALL_DIR"
    info "Updating repository..."
    git pull
else
    info "Cloning acpKanban repository..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 3. Run Setup Script
if [ -f "scripts/setup.sh" ]; then
    bash scripts/setup.sh
else
    err "scripts/setup.sh not found. Repository might be corrupted."
    exit 1
fi
