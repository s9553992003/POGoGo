#!/usr/bin/env bash
# POGoGo Notarization 設定精靈
# 執行一次即可將 Apple ID 憑證存入 Keychain，之後 build_release.sh 自動使用。
#
# 前置需求：
#   1. Apple Developer Program 帳號（$99/年）
#   2. 在 appleid.apple.com 產生「App 專屬密碼」
#   3. 在 Xcode → Settings → Accounts 加入 Apple ID
#
set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
error()   { echo -e "${RED}✗ $*${NC}"; exit 1; }

echo ""
echo -e "${BLUE}══════════════════════════════════${NC}"
echo -e "${BLUE}  POGoGo Notarization 設定精靈${NC}"
echo -e "${BLUE}══════════════════════════════════${NC}"
echo ""

# ── 1. 確認 Xcode Command Line Tools ─────────────────────────────────────────
xcrun notarytool --version &>/dev/null || error "需要 Xcode 14+，請先安裝"
success "notarytool 可用"

# ── 2. 列出可用的 Developer ID 憑證 ──────────────────────────────────────────
info "偵測 Keychain 中的 Developer ID 憑證..."
CERTS=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)

if [ -z "$CERTS" ]; then
    warn "找不到 Developer ID Application 憑證"
    echo ""
    echo "請先在 Xcode 完成憑證安裝："
    echo "  Xcode → Settings → Accounts → 選擇 Apple ID → Manage Certificates"
    echo "  點「+」→ Developer ID Application"
    echo ""
    exit 1
fi

echo ""
echo "找到以下憑證："
echo "$CERTS"
echo ""

# 自動取第一個 Developer ID Application 憑證
IDENTITY=$(echo "$CERTS" | head -1 | sed 's/.*) //' | sed 's/ (.*//')
info "將使用：$IDENTITY"

# ── 3. 取得 Team ID ────────────────────────────────────────────────────────────
TEAM_ID=$(echo "$CERTS" | head -1 | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()')
if [ -z "$TEAM_ID" ]; then
    echo ""
    echo -n "請手動輸入 Team ID（10 位英數字，可在 developer.apple.com/account 查詢）："
    read -r TEAM_ID
fi
success "Team ID：$TEAM_ID"

# ── 4. 輸入 Apple ID 與 App 專屬密碼 ─────────────────────────────────────────
echo ""
info "需要 Apple ID 與 App 專屬密碼（App-Specific Password）"
echo ""
echo "產生 App 專屬密碼步驟："
echo "  1. 前往 https://appleid.apple.com"
echo "  2. 登入 → 安全性 → App 專屬密碼 → 產生"
echo "  3. 輸入名稱（如：POGoGo Notarize）→ 複製產生的密碼"
echo ""
echo -n "Apple ID（Email）："
read -r APPLE_ID
echo -n "App 專屬密碼（xxxx-xxxx-xxxx-xxxx）："
read -rs APP_PASSWORD
echo ""

# ── 5. Profile 名稱 ───────────────────────────────────────────────────────────
PROFILE_NAME="pogogo-notarize"
echo ""
info "Keychain profile 名稱：$PROFILE_NAME"
echo "（build_release.sh 將以 NOTARIZE_PROFILE=$PROFILE_NAME 使用）"

# ── 6. 儲存憑證到 Keychain ────────────────────────────────────────────────────
echo ""
info "儲存到 Keychain..."
xcrun notarytool store-credentials "$PROFILE_NAME" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD"

success "憑證已儲存：Keychain profile = $PROFILE_NAME"

# ── 7. 驗證憑證 ───────────────────────────────────────────────────────────────
info "驗證憑證..."
xcrun notarytool history --keychain-profile "$PROFILE_NAME" --output-format json &>/dev/null \
    && success "憑證驗證通過 ✓" \
    || warn "憑證驗證失敗，請確認 Apple ID / 密碼 / Team ID 是否正確"

# ── 8. 輸出使用方式 ───────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════${NC}"
echo -e "${GREEN}  設定完成！${NC}"
echo -e "${GREEN}══════════════════════════════════${NC}"
echo ""
echo "之後執行 build_release.sh 時加上以下環境變數："
echo ""
echo -e "  ${YELLOW}SIGNING_IDENTITY=\"$IDENTITY\" \\${NC}"
echo -e "  ${YELLOW}NOTARIZE_PROFILE=\"$PROFILE_NAME\" \\${NC}"
echo -e "  ${YELLOW}./build_release.sh${NC}"
echo ""
echo "或設定一次後永久生效："
echo ""
echo "  echo 'export SIGNING_IDENTITY=\"$IDENTITY\"' >> ~/.zshrc"
echo "  echo 'export NOTARIZE_PROFILE=\"$PROFILE_NAME\"' >> ~/.zshrc"
echo ""
