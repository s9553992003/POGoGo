#!/bin/bash
# POGoGo 內建工具建構腳本
# 使用 PyInstaller 將 pymobiledevice3 編譯成獨立二進位，不再依賴使用者 Python 環境
# 建構策略：分別建構 arm64 和 x86_64，再用 lipo 合併成 universal2 binary
#
# 使用方式：
#   bash scripts/build_bundled_tools.sh
#
# 前置需求：
#   - macOS with Rosetta 2（用於 x86_64 建構）
#   - python.org universal2 Python 3.10+（用於兩種架構）
#   - 或使用 pogogo venv Python（arm64）和 Rosetta x86_64 Python

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESOURCES_DIR="$PROJECT_ROOT/Resources"
BINARY_NAME="pogogo"

DIST_DIR="$SCRIPT_DIR/dist"
BUILD_DIR="$SCRIPT_DIR/build_pyinstaller"

echo "▶ 尋找 Python 3.10+..."

# 優先：python.org universal2 Python（同時支援兩種架構模式）
UNIVERSAL2_PY=""
for PY in \
    /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.11/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.10/bin/python3; do
    if [ -f "$PY" ]; then
        ARCHS=$(lipo -archs "$PY" 2>/dev/null || echo "")
        if echo "$ARCHS" | grep -q "x86_64" && echo "$ARCHS" | grep -q "arm64"; then
            MINOR=$("$PY" -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo "0")
            if [ "$MINOR" -ge 10 ] 2>/dev/null; then
                UNIVERSAL2_PY="$PY"
                break
            fi
        fi
    fi
done

# Fallback arm64 Python（venv 或 Homebrew）
ARM64_PY=""
for PY in \
    "$HOME/.pogogo/venv/bin/python3" \
    /opt/homebrew/bin/python3.13 \
    /opt/homebrew/bin/python3.12 \
    /opt/homebrew/bin/python3.11 \
    /opt/homebrew/bin/python3.10; do
    if [ -f "$PY" ] || command -v "$PY" &>/dev/null; then
        MINOR=$("$PY" -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo "0")
        if [ "$MINOR" -ge 10 ] 2>/dev/null; then
            ARM64_PY="$PY"
            break
        fi
    fi
done

if [ -n "$UNIVERSAL2_PY" ]; then
    ARM64_PY="$UNIVERSAL2_PY"
    X86_PY="$UNIVERSAL2_PY"
    echo "  使用 universal2 Python：$UNIVERSAL2_PY ($($UNIVERSAL2_PY --version))"
elif [ -n "$ARM64_PY" ]; then
    X86_PY="$ARM64_PY"  # 之後用 arch -x86_64 執行
    echo "  使用 Python：$ARM64_PY ($($ARM64_PY --version))"
else
    echo "❌ 找不到 Python 3.10+，請先安裝："
    echo "   建議：從 https://www.python.org/downloads/macos/ 下載 universal2 安裝包"
    exit 1
fi

# ── 建構 helper function ──────────────────────────────────────────────────────
build_arch() {
    local ARCH="$1"   # arm64 或 x86_64
    local PY="$2"
    local VENV_DIR="/tmp/pogogo_build_${ARCH}_venv"
    local OUT_NAME="${BINARY_NAME}_${ARCH}"

    echo ""
    echo "▶ 建構 ${ARCH} binary..."

    # 建立或重用獨立 venv
    if [ ! -d "$VENV_DIR" ]; then
        echo "  建立 ${ARCH} venv..."
        if [ "$ARCH" = "x86_64" ]; then
            arch -x86_64 "$PY" -m venv "$VENV_DIR"
        else
            "$PY" -m venv "$VENV_DIR"
        fi
    fi

    local VENV_PY="$VENV_DIR/bin/python3"

    # 安裝依賴
    local PIP_CMD="$VENV_PY -m pip install --quiet"
    if [ "$ARCH" = "x86_64" ]; then
        PIP_CMD="arch -x86_64 $VENV_PY -m pip install --quiet"
    fi

    if ! "$VENV_DIR/bin/python3" -c "import pymobiledevice3" 2>/dev/null; then
        echo "  [${ARCH}] 安裝 pymobiledevice3..."
        if [ "$ARCH" = "x86_64" ]; then
            arch -x86_64 "$VENV_PY" -m pip install pymobiledevice3 pyinstaller --quiet
        else
            "$VENV_PY" -m pip install pymobiledevice3 pyinstaller --quiet
        fi
    fi

    PYMD3_VER=$("$VENV_PY" -c "import pymobiledevice3; print(pymobiledevice3.__version__)" 2>/dev/null || echo "unknown")
    echo "  [${ARCH}] pymobiledevice3 ${PYMD3_VER}"

    # 建構
    if [ "$ARCH" = "x86_64" ]; then
        arch -x86_64 "$VENV_PY" -m PyInstaller \
            --onefile \
            --name "$OUT_NAME" \
            --distpath "$DIST_DIR" \
            --workpath "${BUILD_DIR}_${ARCH}" \
            --specpath "$SCRIPT_DIR" \
            --collect-all pymobiledevice3 \
            --collect-all cryptography \
            --collect-all certifi \
            --collect-all readchar \
            --collect-all inquirer3 \
            --hidden-import requests \
            --hidden-import click \
            --hidden-import asyncio \
            --noconfirm \
            --clean \
            --target-arch x86_64 \
            "$SCRIPT_DIR/pogogo_tools.py"
    else
        "$VENV_PY" -m PyInstaller \
            --onefile \
            --name "$OUT_NAME" \
            --distpath "$DIST_DIR" \
            --workpath "${BUILD_DIR}_${ARCH}" \
            --specpath "$SCRIPT_DIR" \
            --collect-all pymobiledevice3 \
            --collect-all cryptography \
            --collect-all certifi \
            --collect-all readchar \
            --collect-all inquirer3 \
            --hidden-import requests \
            --hidden-import click \
            --hidden-import asyncio \
            --noconfirm \
            --clean \
            --target-arch arm64 \
            "$SCRIPT_DIR/pogogo_tools.py"
    fi

    if [ ! -f "$DIST_DIR/$OUT_NAME" ]; then
        echo "❌ [${ARCH}] 建構失敗"
        exit 1
    fi

    local SZ=$(ls -lh "$DIST_DIR/$OUT_NAME" | awk '{print $5}')
    local ARCHS=$(lipo -archs "$DIST_DIR/$OUT_NAME" 2>/dev/null || echo "unknown")
    echo "  [${ARCH}] 完成 ($SZ, archs: $ARCHS)"
}

# ── 建構兩種架構 ───────────────────────────────────────────────────────────────
mkdir -p "$DIST_DIR"

build_arch arm64  "$ARM64_PY"
build_arch x86_64 "$X86_PY"

# ── lipo 合併 ─────────────────────────────────────────────────────────────────
echo ""
echo "▶ lipo 合併成 universal2..."
lipo -create \
    "$DIST_DIR/${BINARY_NAME}_arm64" \
    "$DIST_DIR/${BINARY_NAME}_x86_64" \
    -output "$DIST_DIR/$BINARY_NAME"

BINARY_SIZE=$(ls -lh "$DIST_DIR/$BINARY_NAME" | awk '{print $5}')
BINARY_ARCHS=$(lipo -archs "$DIST_DIR/$BINARY_NAME" 2>/dev/null || echo "unknown")
echo "  合併成功 ($BINARY_SIZE, archs: $BINARY_ARCHS)"

echo "▶ 部署到 Resources/..."
mkdir -p "$RESOURCES_DIR"
for ARCH in arm64 x86_64; do
    SRC="$DIST_DIR/${BINARY_NAME}_${ARCH}"
    DST="$RESOURCES_DIR/${BINARY_NAME}_${ARCH}"
    cp "$SRC" "$DST"
    chmod +x "$DST"
    SZ=$(ls -lh "$DST" | awk '{print $5}')
    echo "  ${BINARY_NAME}_${ARCH} ($SZ) → $DST"
done
echo "✅ 完成：兩個 binary 已部署到 $RESOURCES_DIR"
echo ""
echo "下一步："
echo "  1. 重新產生 Xcode 專案：xcodegen generate"
echo "  2. 開啟並建構：open POGoGo.xcodeproj"
echo "  3. 打包發行：bash scripts/notarize.sh"
