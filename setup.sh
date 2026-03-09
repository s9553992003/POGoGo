#!/bin/zsh
# POGoGo 環境設定腳本
set -e

echo "=============================="
echo "  POGoGo 環境設定"
echo "=============================="

# 1. 檢查 Xcode 15+（devicectl 需要 Xcode 15+）
if xcrun --find devicectl &> /dev/null; then
    echo "✅ Xcode devicectl 可用：$(xcrun --find devicectl)"
else
    echo "❌ 未找到 devicectl，請安裝 Xcode 15+："
    echo "   https://developer.apple.com/xcode/"
    echo "   安裝後執行 'sudo xcode-select --switch /Applications/Xcode.app'"
    exit 1
fi

# 2. 檢查 Homebrew（XcodeGen 需要）
if ! command -v brew &> /dev/null; then
    echo "❌ 未安裝 Homebrew（用於安裝 XcodeGen），請先安裝："
    echo "   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
fi
echo "✅ Homebrew 已安裝"

# 3. 安裝 XcodeGen
echo ""
echo "📦 安裝 XcodeGen..."
if brew list xcodegen &>/dev/null; then
    echo "   XcodeGen 已安裝"
else
    brew install xcodegen
fi
echo "✅ XcodeGen 已安裝"

# 4. 產生 Xcode 專案
echo ""
echo "🔨 產生 Xcode 專案..."
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR"
xcodegen generate
echo "✅ Xcode 專案已產生：POGoGo.xcodeproj"

# 5. 說明
echo ""
echo "=============================="
echo "  設定完成！"
echo "=============================="
echo ""
echo "接下來："
echo "  1. 以 Lightning/USB-C 連接 iPhone"
echo "  2. iPhone 需開啟「開發者模式」"
echo "     設定 → 隱私與安全性 → 開發者模式"
echo "  3. 在 Xcode → 視窗 → 裝置與模擬器 確認裝置已信任"
echo "  4. 開啟 POGoGo.xcodeproj 並執行"
echo ""
echo "注意：此工具僅供學習研究使用"
echo "      使用位置偽造可能違反 Niantic 服務條款"
echo ""
