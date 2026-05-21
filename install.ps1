# acpKanban One-Click Remote Installer for Windows
# Usage: irm https://raw.githubusercontent.com/VitaNode/acpKanban/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

$repoUrl = "https://github.com/VitaNode/acpKanban.git"
$installDir = "acpKanban"

Write-Host "========================================" -ForegroundColor Blue
Write-Host "     acpKanban Installer v0.1.0        " -ForegroundColor Blue
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

# 3. Check Python
if (!(Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[✗] Python is not installed. Please install Python 3.10+ (https://www.python.org/) first." -ForegroundColor Red
    exit 1
}

$pythonVersion = python --version
Write-Host "[*] Using $pythonVersion" -ForegroundColor Blue

# 4. Create Virtual Environment
if (!(Test-Path ".venv")) {
    Write-Host "[*] Creating virtual environment..." -ForegroundColor Blue
    python -m venv .venv
}

# 5. Install Dependencies
Write-Host "[*] Installing dependencies (this may take a while)..." -ForegroundColor Blue
& ".\.venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
& ".\.venv\Scripts\pip.exe" install --quiet -r requirements.txt

# 6. Initialize Config
Write-Host "[*] Initializing system configuration..." -ForegroundColor Blue
$env:PYTHONPATH = "."
& ".\.venv\Scripts\python.exe" -c "from src.config.manager import config"
Write-Host "[✓] Configuration saved to config.json" -ForegroundColor Green

# 7. Create Runner Scripts
Write-Host "[*] Generating runner scripts..." -ForegroundColor Blue

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

Write-Host "[✓] start.bat and start_api.bat created" -ForegroundColor Green

# 8. Success Message
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Setup Completed Successfully!       ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Standard:    .\start.bat" -ForegroundColor Blue
Write-Host "  API Only:    .\start_api.bat" -ForegroundColor Blue
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
