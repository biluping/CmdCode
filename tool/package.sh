#!/bin/bash
# 打包 CmdCode：Release 构建 → 本地临时签名（ad-hoc）→ 生成 DMG。
# 只在自己的 Mac 上使用，不做 Developer ID 签名和公证。
#
# 用法：
#   tool/package.sh            生成 build/dist/CmdCode-<版本>.dmg
#   tool/package.sh --install  另外把 CmdCode.app 安装到 /Applications（会先退出正在运行的 CmdCode）
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DERIVED="$ROOT/build/DerivedData"
DIST="$ROOT/build/dist"
APP="$DERIVED/Build/Products/Release/CmdCode.app"

echo "==> 运行核心库测试"
TEST_OUTPUT=$(cd CmdCodeCore && swift test 2>&1 || true)
echo "$TEST_OUTPUT" | grep -E '✘|Test run with|error:' || true
if ! echo "$TEST_OUTPUT" | grep -q '✔ Test run with'; then
    echo "测试未通过，停止打包" >&2
    exit 1
fi

echo "==> Release 构建"
xcodebuild -project CmdCode.xcodeproj -scheme CmdCode -configuration Release \
    -derivedDataPath "$DERIVED" -skipPackagePluginValidation clean build 2>&1 | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
[ -d "$APP" ] || { echo "构建失败，找不到 $APP" >&2; exit 1; }

echo "==> 检查签名"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Signature|flags'

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$DIST/CmdCode-$VERSION.dmg"

echo "==> 生成 DMG"
rm -rf "$DIST"
mkdir -p "$DIST/staging"
cp -R "$APP" "$DIST/staging/"
ln -s /Applications "$DIST/staging/Applications"
hdiutil create -quiet -volname "CmdCode" -srcfolder "$DIST/staging" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$DIST/staging"

echo
echo "App 大小：$(du -sh "$APP" | cut -f1)"
echo "DMG 大小：$(du -sh "$DMG" | cut -f1)  →  $DMG"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> 安装到 /Applications"
    osascript -e 'quit app "CmdCode"' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/CmdCode.app
    cp -R "$APP" /Applications/
    echo "已安装：/Applications/CmdCode.app"
fi
