# acpKanban One-Click Remote Installer for Windows
# Usage: irm https://raw.githubusercontent.com/VitaNode/acpKanban/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$repoUrl = "https://github.com/VitaNode/acpKanban.git"
$installDir = "acpKanban"

Write-Host "========================================" -ForegroundColor Blue
Write-Host "     acpKanban Installer v0.2.0        " -ForegroundColor Blue
Write-Host "========================================" -ForegroundColor Blue

# 1. Check Git
if (!(Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[✗] Git is not installed. Please install Git (https://git-scm.com/) first." -ForegroundColor Red
    exit 1
}

# 2. Clone Repository
if (Test-Path $installDir) {
    Write-Host "[*] Directory '$installDir' already exists." -ForegroundColor Blue
    $choice = Read-Host "Pull latest changes and re-install? [y/N]"
    if ($choice -notmatch "[yY]") {
        Write-Host "[*] Aborting installation." -ForegroundColor Blue
        exit 0
    }
    Set-Location $installDir
    Write-Host "[*] Updating repository..." -ForegroundColor Blue
    git pull
} else {
    Write-Host "[*] Cloning acpKanban repository..." -ForegroundColor Blue
    git clone $repoUrl $installDir
    Set-Location $installDir
}

# 3. Check Python (3.10+)
$pythonCmd = if (Get-Command py -ErrorAction SilentlyContinue) { "py" } else { "python" }
try {
    $pyVersion = & $pythonCmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
} catch {
    Write-Host "[✗] Python 3 is not installed. Please install Python 3.10+ (https://www.python.org/) first." -ForegroundColor Red
    exit 1
}
if ([version]$pyVersion -lt [version]"3.10") {
    Write-Host "[✗] Python 3.10+ required, found $pyVersion" -ForegroundColor Red
    exit 1
}
$pythonVersion = & $pythonCmd --version
Write-Host "[*] Using $pythonVersion" -ForegroundColor Blue

# 4. Create Virtual Environment
if (!(Test-Path ".venv")) {
    Write-Host "[*] Creating virtual environment..." -ForegroundColor Blue
    & $pythonCmd -m venv .venv
}

# 5. Install Dependencies
Write-Host "[*] Installing dependencies (this may take a while)..." -ForegroundColor Blue
& ".\.venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
& ".\.venv\Scripts\python.exe" -m pip install --quiet -r requirements.txt

# 6. Initialize Config & Database
Write-Host "[*] Initializing system configuration..." -ForegroundColor Blue
$env:PYTHONPATH = "."
& ".\.venv\Scripts\python.exe" -c "from src.config.manager import config"
Write-Host "[✓] Configuration saved to config.json" -ForegroundColor Green

Write-Host "[*] Initializing database..." -ForegroundColor Blue
& ".\.venv\Scripts\python.exe" -c "
from src.persistence.database import KanbanDB
db = KanbanDB()
db.init_db()
"
Write-Host "[✓] Database initialized" -ForegroundColor Green

# 7. Create Runner Scripts
Write-Host "[*] Generating runner scripts..." -ForegroundColor Blue

$overwriteAll = $true
if ((Test-Path "start.bat") -or (Test-Path "start_api.bat") -or (Test-Path "start_dev.bat")) {
    $choice = Read-Host "Runner scripts already exist. Overwrite? [y/N]"
    if ($choice -notmatch "[yY]") {
        $overwriteAll = $false
        Write-Host "[*] Keeping existing runner scripts" -ForegroundColor Blue
    }
}

if ($overwriteAll) {
    $startAll = @"
@echo off
set PYTHONPATH=.
echo [*] Starting acpKanban All-in-One Service...
.\.venv\Scripts\python.exe run_all.py
pause
"@
    $startAll | Out-File -FilePath "start.bat" -Encoding ascii

    $startApi = @"
@echo off
set PYTHONPATH=.
echo [*] Starting acpKanban API Server...
.\.venv\Scripts\python.exe -m uvicorn api.main:app --host 127.0.0.1 --port 8000
pause
"@
    $startApi | Out-File -FilePath "start_api.bat" -Encoding ascii

    $startDev = @"
@echo off
set PYTHONPATH=.
echo [*] Starting acpKanban API Server (dev mode)...
.\.venv\Scripts\python.exe -m uvicorn api.main:app --host 127.0.0.1 --port 8000 --reload
pause
"@
    $startDev | Out-File -FilePath "start_dev.bat" -Encoding ascii

    Write-Host "[✓] start.bat, start_api.bat, start_dev.bat created" -ForegroundColor Green
}

# 8. Post-Install Verification
Write-Host "[*] Verifying installation..." -ForegroundColor Blue
try {
    & ".\.venv\Scripts\python.exe" -c "import tree_sitter"
    Write-Host "[✓] tree_sitter native module: ok" -ForegroundColor Green
} catch {
    Write-Host "[!] tree_sitter native build may have failed (some features limited)" -ForegroundColor Yellow
}
try {
    & ".\.venv\Scripts\python.exe" -c "import sqlite_vec"
    Write-Host "[✓] sqlite-vec native module: ok" -ForegroundColor Green
} catch {
    Write-Host "[!] sqlite-vec native build may have failed (vector search disabled)" -ForegroundColor Yellow
}

# 9. Success Message
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Setup Completed Successfully!       ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Standard:    .\start.bat" -ForegroundColor Blue
Write-Host "  API Only:    .\start_api.bat" -ForegroundColor Blue
Write-Host "  Dev Mode:    .\start_dev.bat" -ForegroundColor Blue
Write-Host ""
Write-Host "  Server runs at:  http://localhost:8000" -ForegroundColor Blue
Write-Host ""
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host "  Connection Credentials (config.json):"
& ".\.venv\Scripts\python.exe" -c "from src.config.manager import config; print(f'    USER_ID:     {config.user_id}'); print(f'    RELAY_TOKEN: {config.relay_token}'); print(f'    API_TOKEN:   {config.api_token}')"
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
Write-Host ""
Write-Host "  Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Run .\start.bat"
Write-Host "  2. Enter credentials into the Mobile App."
Write-Host ""
