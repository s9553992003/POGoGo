@echo off
setlocal enabledelayedexpansion

echo ============================================================
echo  POGoGo Windows Build Script
echo ============================================================

:: ── 1. Check Python ──────────────────────────────────────────
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python 3.10+ not found.
    echo        Download: https://python.org/downloads/
    pause & exit /b 1
)

:: ── 2. Install dependencies ──────────────────────────────────
echo [1/4] Installing Python dependencies...
pip install -r requirements.txt pyinstaller --quiet --upgrade
if errorlevel 1 (
    echo ERROR: pip install failed
    pause & exit /b 1
)

:: ── 3. Build exe ─────────────────────────────────────────────
echo [2/4] Building POGoGo.exe...
if exist dist\POGoGo rmdir /s /q dist\POGoGo
if exist build\POGoGo rmdir /s /q build\POGoGo

pyinstaller ^
    --name POGoGo ^
    --onedir ^
    --windowed ^
    --icon resources\icon.ico ^
    --add-data "src\map.html;." ^
    --paths src ^
    --collect-all pymobiledevice3 ^
    --collect-all readchar ^
    --collect-all inquirer3 ^
    --collect-all pytun_pmd3 ^
    --hidden-import requests ^
    --hidden-import asyncio ^
    --hidden-import cryptography ^
    --hidden-import certifi ^
    --noconfirm ^
    src\main.py

if errorlevel 1 (
    echo ERROR: PyInstaller build failed
    pause & exit /b 1
)

:: Copy map.html next to exe
copy /y src\map.html dist\POGoGo\map.html >nul
if exist resources\icon.ico copy /y resources\icon.ico dist\POGoGo\icon.ico >nul
echo        dist\POGoGo\POGoGo.exe  OK

:: ── 4. Build installer ───────────────────────────────────────
echo [3/4] Looking for Inno Setup...
set "ISCC="
for %%P in (
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    "C:\Program Files\Inno Setup 6\ISCC.exe"
) do if exist %%P set "ISCC=%%P"

if not defined ISCC (
    echo [3/4] Inno Setup not found — auto-downloading...
    powershell -Command ^
        "Invoke-WebRequest -Uri 'https://files.jrsoftware.org/is/6/innosetup-6.3.3.exe' -OutFile '%TEMP%\issetup.exe' -UseBasicParsing" ^
        && "%TEMP%\issetup.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
        && set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
)

if defined ISCC (
    echo [4/4] Building POGoGo-Setup.exe...
    if not exist output mkdir output
    %ISCC% installer.iss
    if errorlevel 1 ( echo ERROR: Inno Setup failed & pause & exit /b 1 )
) else (
    echo [4/4] Skipping installer (Inno Setup unavailable)
)

:: ── Done ─────────────────────────────────────────────────────
echo.
echo ============================================================
echo  Build complete!
echo.
echo  Run directly:  dist\POGoGo\POGoGo.exe
if exist output\POGoGo-Setup.exe (
    echo  Installer:     output\POGoGo-Setup.exe
)
echo ============================================================
pause
