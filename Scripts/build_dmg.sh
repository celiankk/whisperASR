#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 品牌参数与 build_release.sh / release.sh 同源默认值（三处必须一致，否则找不到
# 构建产物）。可经环境变量覆盖。
APP_NAME="${APP_NAME:-SonicScribe}"
DISPLAY_NAME="${DISPLAY_NAME:-声记 SonicScribe}"
# 可选：对 dmg 本身签名（不影响 app 内签名）。留空则产出未签名 dmg。
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "error: app bundle not found at $APP_BUNDLE" >&2
    echo "       run Scripts/build_release.sh first" >&2
    exit 1
fi

# 版本号取自构建产物而非硬编码，避免 Info.plist 与文件名漂移。
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_PATH="$PROJECT_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Packaging $APP_NAME $VERSION into DMG..."

# 暂存目录：应用本体 + 指向 /Applications 的软链，构成标准的「拖拽安装」布局。
# 用 mktemp -d 而非固定路径，避免上一次失败留下的残留污染本次产物。
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP_BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG_PATH"

# UDZO = zlib 压缩的只读镜像，是分发 macOS 应用的标准格式。
hdiutil create \
    -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

if [ -n "$CODESIGN_IDENTITY" ]; then
    echo "==> Signing disk image..."
    codesign --force --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

# 校验镜像可挂载，避免把损坏产物发出去。
hdiutil verify "$DMG_PATH" >/dev/null

echo "==> Done!"
echo "    DMG:  $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
shasum -a 256 "$DMG_PATH" | tee "$DMG_PATH.sha256"

if [ -z "$CODESIGN_IDENTITY" ]; then
    echo ""
    echo "    NOTE: app is not code-signed. Recipients must clear the quarantine"
    echo "          attribute or use right-click -> Open on first launch:"
    echo "            xattr -cr /Applications/$APP_NAME.app"
fi
