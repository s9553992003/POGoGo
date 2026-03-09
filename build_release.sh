#!/usr/bin/env bash
# POGoGo 發佈打包腳本
# 產出：dist/POGoGo-<version>.dmg
#
# 用法：
#   ./build_release.sh                 # 無簽名 build（右鍵開啟）
#   IDENTITY="Developer ID: ..." ./build_release.sh  # 含簽名（需 Apple Developer）
#
set -eo pipefail

APP_NAME="POGoGo"
SCHEME="POGoGo"
PROJECT="POGoGo.xcodeproj"
ENTITLEMENTS="Sources/POGoGo/POGoGo.entitlements"
VERSION=$(defaults read "$(pwd)/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Yu Wen Chen (9DS7WYNF42)}"
NOTARIZE="${NOTARIZE_PROFILE:-}"       # 可選：notarytool 憑證 profile 名稱

DIST="$(pwd)/dist"
ARCHIVE="$DIST/$APP_NAME.xcarchive"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"

# ── 顏色輸出 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}▶ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
error()   { echo -e "${RED}✗ $*${NC}"; exit 1; }

# ── 1. 前置檢查 ───────────────────────────────────────────────────────────────
info "POGoGo $VERSION 打包開始"
[ -f "$PROJECT/project.pbxproj" ] || error "找不到 $PROJECT，請先在專案根目錄執行"

mkdir -p "$DIST"
rm -rf "$ARCHIVE" "$APP" "$DMG"

# ── 2. Build（Archive）────────────────────────────────────────────────────────
info "編譯 Release..."

if [ -n "$IDENTITY" ]; then
    CODE_SIGN_ARGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$IDENTITY"
        DEVELOPMENT_TEAM=""
    )
    warn "使用簽名：$IDENTITY"
else
    CODE_SIGN_ARGS=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="-"          # ad-hoc 簽名
        CODE_SIGNING_REQUIRED=NO
        DEVELOPMENT_TEAM=""
    )
    warn "未設定 SIGNING_IDENTITY，使用 ad-hoc 簽名（用戶需右鍵開啟）"
fi

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    "${CODE_SIGN_ARGS[@]}" \
    archive \
    | grep -E "error:|warning:|Build succeeded|Build FAILED" || true

# ── 3. 從 Archive 取出 .app ───────────────────────────────────────────────────
info "取出 .app..."
ARCHIVE_APP=$(find "$ARCHIVE/Products" -name "*.app" -maxdepth 3 | head -1)
[ -n "$ARCHIVE_APP" ] || error "找不到編譯產物，請確認 xcodebuild 成功"
cp -R "$ARCHIVE_APP" "$APP"
success "產出：$APP"

# ── 4. 簽名（ad-hoc 或正式）──────────────────────────────────────────────────
info "簽名..."
[ -f "$ENTITLEMENTS" ] || error "找不到 $ENTITLEMENTS"

if [ -n "$IDENTITY" ]; then
    # Developer ID 正式簽名：逐層簽名（避免 --deep 覆蓋子元件的簽名）
    # 用 process substitution 避免 pipefail 在 find 找不到目錄時中斷
    while IFS= read -r lib; do
        codesign --force --sign "$IDENTITY" --options runtime \
                 --entitlements "$ENTITLEMENTS" "$lib" 2>/dev/null || true
    done < <(find "$APP/Contents/Frameworks" -name "*.dylib" -o -name "*.framework" 2>/dev/null)
    codesign --force --sign "$IDENTITY" \
             --options runtime \
             --entitlements "$ENTITLEMENTS" \
             --timestamp \
             "$APP"
    success "Developer ID 簽名完成"
else
    # Ad-hoc 簽名
    codesign --force --deep \
             --sign "-" \
             --options runtime \
             --entitlements "$ENTITLEMENTS" \
             "$APP" 2>/dev/null && success "Ad-hoc 簽名完成" || warn "簽名失敗（可略過）"
fi

# ── 5. 建立 DMG ───────────────────────────────────────────────────────────────
info "製作 DMG..."

STAGING="$DIST/.staging_$$"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG" \
    > /dev/null

rm -rf "$STAGING"

# DMG 本身也要簽名（notarization 必要）
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
    success "DMG 簽名完成"
fi

success "DMG 產出：$DMG（$(du -sh "$DMG" | cut -f1)）"

# ── 6. Notarize（選用，需 Apple Developer）────────────────────────────────────
if [ -n "$NOTARIZE" ]; then
    [ -n "$IDENTITY" ] || error "Notarization 需要設定 SIGNING_IDENTITY（Developer ID Application: ...）"
    info "送出 notarization（需等 Apple 審核，通常 1-5 分鐘）..."
    xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARIZE" \
        --wait \
    && xcrun stapler staple "$DMG" \
    && success "Notarization 完成，已 staple ✓"
else
    warn "跳過 notarization（可設 NOTARIZE_PROFILE=<profile> 啟用）"
fi

# ── 完成 ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════${NC}"
echo -e "${GREEN}  打包完成！${NC}"
echo -e "${GREEN}  $DMG${NC}"
echo -e "${GREEN}══════════════════════════════════${NC}"

if [ -z "$IDENTITY" ]; then
    echo ""
    warn "此版本為 ad-hoc 簽名，用戶首次開啟需："
    echo "  右鍵（Control + 點擊）→「打開」→ 確認"
    echo ""
    echo "  或在終端執行："
    echo "  sudo xattr -rd com.apple.quarantine $DMG"
fi
