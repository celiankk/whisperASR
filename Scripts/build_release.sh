#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# 工具链选择（Xcode 优先；不可用时回退 CLT + 显式宏插件路径）
# ---------------------------------------------------------------------------
# 为什么需要：项目用 SwiftUI 宏（`@State` 等），这些宏的实现只随 Xcode 提供
# （`libSwiftUIMacros.dylib` 位于 Xcode 各 Platform 目录）。系统默认工具链若是
# CommandLineTools（`xcode-select -p` 指向 CLT），编译期会报
# "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"。
#
# 两条可用路径：
#   A) `DEVELOPER_DIR=<Xcode>/Contents/Developer`：完整 Xcode 工具链自带宏插件；
#   B) 保持 CLT 工具链，用 `-Xswiftc -plugin-path -Xswiftc <插件目录>` 把 Xcode 的
#      宏插件目录**额外**加进 swiftc 搜索路径（-plugin-path 是叠加语义，不改工具链）。
#      插件只是加载 dylib，不触发 Xcode 的许可校验，所以 Xcode 因
#      "You have not agreed to the Xcode license agreements" 不可用时仍能构建。
#
# 因此回退后**必须探测可用性**：Xcode.app 存在 ≠ 可用。本机实测两个独立失败
# 信号——许可未接受时 `xcrun --find swiftc` 直接失败（exit 69，
# "You have not agreed to the Xcode license agreements"）。不探测的话构建会在
# 后面以晦涩的宏/许可错误失败，用户看不出该做什么。
#
# 可用环境变量覆盖：
#   XCODE_DEVELOPER_DIR   非默认安装路径的 Xcode Developer 目录
#   DEVELOPER_DIR         显式指定工具链（不可用时同样回退，并打印警告）
XCODE_DEVELOPER_DIR="${XCODE_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# 某工具链的 SwiftUI 宏插件目录（Xcode 专属；CLT 下该目录不存在）。
macro_plugin_dir_for() {
    echo "$1/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
}
XCODE_MACRO_PLUGIN_DIR="$(macro_plugin_dir_for "$XCODE_DEVELOPER_DIR")"
# 宏插件存在性判据：SwiftUI 宏实现本体（缺它编译期必报
# "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"）。
XCODE_SWIFTUI_MACRO_DYLIB="$XCODE_MACRO_PLUGIN_DIR/libSwiftUIMacros.dylib"

# 工具链可用性探测（两条都过才算可用）：
#   1) xcrun 能解析出 swiftc —— 构建实际走的分发入口，许可未接受 / 工具链损坏
#      在此暴露；
#   2) SwiftUI 宏插件文件存在 —— 决定能否编译本项目的 SwiftUI 宏。
toolchain_usable() {
    local dev_dir="$1"
    [ -d "$dev_dir" ] || return 1
    DEVELOPER_DIR="$dev_dir" /usr/bin/xcrun --find swiftc >/dev/null 2>&1 || return 1
    [ -f "$(macro_plugin_dir_for "$dev_dir")/libSwiftUIMacros.dylib" ] || return 1
    return 0
}

# 回退路径：CLT 工具链 + 显式 Xcode 宏插件路径；插件缺失则给出可操作错误后退出。
use_clt_with_xcode_macro_plugins() {
    if [ ! -f "$XCODE_SWIFTUI_MACRO_DYLIB" ]; then
        cat >&2 <<EOF
ERROR: 找不到 SwiftUI 宏插件，无法构建。

原因：项目使用 SwiftUI 宏（@State 等），其实现只随完整 Xcode 提供；
      当前工具链（DEVELOPER_DIR=${DEVELOPER_DIR:-未设置（系统默认，通常是 CommandLineTools）}）
      不自带这些插件，且未发现 Xcode 的宏插件目录：
        $XCODE_MACRO_PLUGIN_DIR

解决（任选其一）：
  1) 安装完整 Xcode，然后：sudo xcode-select -s $XCODE_DEVELOPER_DIR
  2) Xcode 已装但许可未接受：sudo xcodebuild -license accept
  3) Xcode 装在别处：XCODE_DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer bash $0
EOF
        exit 1
    fi
    echo "==> [警告] 工具链不可直接用于本项目（Xcode 许可未接受 / 工具链损坏 / 缺宏插件）。"
    echo "    改用系统默认工具链（通常是 CommandLineTools）+ 显式宏插件路径："
    echo "      $XCODE_MACRO_PLUGIN_DIR"
    echo "    彻底修复：sudo xcodebuild -license accept"
    # 摘掉可能指向坏 Xcode 的 DEVELOPER_DIR，让系统默认工具链（CLT）生效；
    # 插件目录以 -plugin-path 追加，不改工具链本身。
    unset DEVELOPER_DIR || true
    SWIFT_EXTRA_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$XCODE_MACRO_PLUGIN_DIR")
}

SWIFT_EXTRA_ARGS=()

if [ -n "${DEVELOPER_DIR:-}" ] && ! toolchain_usable "$DEVELOPER_DIR"; then
    use_clt_with_xcode_macro_plugins
elif [ -z "${DEVELOPER_DIR:-}" ]; then
    if toolchain_usable "$XCODE_DEVELOPER_DIR"; then
        export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
    else
        use_clt_with_xcode_macro_plugins
    fi
fi

# 品牌参数（可经环境变量注入；默认「声记 SonicScribe」，与仓库内
# SonicScribe.app / CI 工作流 / 应用显示名保持一致）。
# 改名时只需覆盖这些变量，Swift 侧不再硬编码品牌名——URL scheme 判定
# 从本脚本写出的 Info.plist 读取（见 AppDelegate.acceptedURLSchemes）。
APP_NAME="${APP_NAME:-SonicScribe}"                # bundle 与可执行文件名
DISPLAY_NAME="${DISPLAY_NAME:-声记 SonicScribe}"    # 访达/程序坞显示名
BUNDLE_ID="${BUNDLE_ID:-com.sonicscribe.app}"
# 兼容旧 scheme：升级安装的用户可能仍持有 whisperasr:// 快捷方式，
# 双写进 Info.plist（AppDelegate 两者都接受）。
LEGACY_URL_SCHEMES="${LEGACY_URL_SCHEMES:-whisperasr}"
URL_SCHEME="${URL_SCHEME:-$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]')}"
BINARY_NAME="${BINARY_NAME:-WhisperASR}"          # SwiftPM 产物名（模块名未改）
# 多架构：ARCHS="arm64 x86_64" → 交叉编译通用二进制（SwiftPM 产物在
# .build/apple/Products/Release）；未设置时保持本机架构旧行为。
#
# 切片探测（本地脚本兜底，CI 侧另有门禁）：仓库三个预编译 xcframework
# （CWhisper / CTranscribe / SherpaONNX）当前只发布 `macos-arm64` 切片。
# ARCHS 里出现非 arm64 架构时，swift build 会在链接阶段以晦涩的
# "building for 'macOS', but linking in object file built for ..." 之类错误失败。
# 这里先读 xcframework 的 Info.plist 探测，明确报错；确需降级时设
# ALLOW_ARCH_DEGRADE=1 自动退回 arm64 并警告。
xcframework_supported_archs() {
    local info="$1/Info.plist"
    [ -f "$info" ] || return 0
    # `|| true`：plist 里没有该键时 grep 无匹配会返回 1，在 `set -e -o pipefail`
    # 下会让调用处的命令替换（fw_archs=$(...)）直接终止脚本。
    sed -n '/<key>SupportedArchitectures<\/key>/,/<\/array>/p' "$info" \
        | grep -oE '<string>[^<]+</string>' \
        | sed -E 's/<\/?string>//g' \
        | sort -u || true
    return 0
}

if [ -n "${ARCHS:-}" ] && [ "$ARCHS" != "arm64" ]; then
    MISSING_SLICES=()
    for arch in $ARCHS; do
        for fw in "$PROJECT_DIR"/Frameworks/*.xcframework; do
            [ -d "$fw" ] || continue
            fw_archs=$(xcframework_supported_archs "$fw" | tr '\n' ' ')
            if ! xcframework_supported_archs "$fw" | grep -qx "$arch"; then
                # 变量一律用 ${} 包裹：紧跟全角字符时 bash 3.2 在非 UTF-8 locale
                # 下会把多字节首字节当成标识符字符，报 "unbound variable"。
                MISSING_SLICES+=("${arch}（$(basename "$fw") 只有：${fw_archs:-无声明}）")
            fi
        done
    done
    if [ ${#MISSING_SLICES[@]} -gt 0 ]; then
        echo "ERROR: ARCHS=\"$ARCHS\" 中部分架构在预编译 xcframework 中缺少切片：" >&2
        for item in "${MISSING_SLICES[@]}"; do echo "    - $item" >&2; done
        echo "  解决（任选其一）：" >&2
        echo "    1) 只构建可用架构：ARCHS=arm64 bash $0" >&2
        echo "    2) 先用 Scripts/build_whisper_lib.sh / build_transcribe_lib.sh 重新生成对应架构切片" >&2
        echo "    3) 允许自动降级：ALLOW_ARCH_DEGRADE=1 bash $0" >&2
        if [ "${ALLOW_ARCH_DEGRADE:-0}" = "1" ]; then
            echo "==> [警告] ALLOW_ARCH_DEGRADE=1：降级为 ARCHS=arm64 继续构建。" >&2
            ARCHS="arm64"
        else
            exit 1
        fi
    fi
fi

BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "==> Building release binary..."
cd "$PROJECT_DIR"
# SWIFTPM_EXTRA_ARGS 可选透传（例如 --disable-sandbox，用于被 sandbox-exec
# 嵌套拦截的环境）；默认空，行为不变。
# shellcheck disable=SC2086
if [ -n "${ARCHS:-}" ] && [ "$ARCHS" != "arm64" ]; then
    SWIFT_ARCH_ARGS=()
    for a in $ARCHS; do SWIFT_ARCH_ARGS+=(--arch "$a"); done
    swift build -c release ${SWIFT_ARCH_ARGS[@]+"${SWIFT_ARCH_ARGS[@]}"} \
        ${SWIFT_EXTRA_ARGS[@]+"${SWIFT_EXTRA_ARGS[@]}"} ${SWIFTPM_EXTRA_ARGS:-}
    BUILD_DIR="$PROJECT_DIR/.build/apple/Products/Release"
    # SwiftPM 产物名是 BINARY_NAME（模块名 WhisperASR），不是 APP_NAME。
    echo "==> Universal binary archs: $(lipo -archs "$BUILD_DIR/$BINARY_NAME")"
else
    swift build -c release \
        ${SWIFT_EXTRA_ARGS[@]+"${SWIFT_EXTRA_ARGS[@]}"} ${SWIFTPM_EXTRA_ARGS:-}
fi

echo "==> Generating app icon (SonicScribe soundwave)..."
ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
swift "$SCRIPT_DIR/generate_icon.swift" "$ICONSET_DIR"
ICNS_PATH="$PROJECT_DIR/.build/AppIcon.icns"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
rm -rf "$(dirname "$ICONSET_DIR")"
echo "==> Icon generated at $ICNS_PATH"

echo "==> Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary（SwiftPM 产物名 = BINARY_NAME；bundle 内可执行名 = APP_NAME）
cp "$BUILD_DIR/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy icon
cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# ---------------------------------------------------------------------------
# SwiftPM 资源 bundle（缺失 = 运行期 fatalError，不是可降级失败）
# ---------------------------------------------------------------------------
# Package.swift 声明了 `.copy("Pipeline/Subtitle/FloatingLetter/Metal")`，SwiftPM
# 把它打成 `<包名>_<target名>.bundle`（本仓库：WhisperASR_WhisperASR.bundle）。
# MetalSubtitleRenderer.swift:97 用 `Bundle.module` 取 .metal 着色器源，找不到
# bundle 时 SwiftPM 生成的 accessor 直接 `fatalError`。
#
# 放置位置由 SwiftPM 生成的 resource_bundle_accessor.swift 决定，实测其内容为：
#     Bundle.main.bundleURL.appendingPathComponent("WhisperASR_WhisperASR.bundle")
# 而 .app 内 `Bundle.main.bundleURL` == `<App>.app` **本身**（实测，
# resourceURL 才是 Contents/Resources）→ 必须放一份到 .app 根目录；
# 再按惯例在 Contents/Resources/ 放一份，兼容以 resourceURL 解析的调用方
# 与打包/公证工具的预期。
RESOURCE_BUNDLE_NAME="${RESOURCE_BUNDLE_NAME:-WhisperASR_WhisperASR.bundle}"
RESOURCE_BUNDLE_SRC="$BUILD_DIR/$RESOURCE_BUNDLE_NAME"
if [ ! -d "$RESOURCE_BUNDLE_SRC" ]; then
    cat >&2 <<EOF
ERROR: 未找到 SwiftPM 资源 bundle，无法组装可用的 app。

期望路径：$RESOURCE_BUNDLE_SRC
该 bundle 由 swift build 依据 Package.swift 的 resources 声明生成；
缺失时 Bundle.module 会在运行期 fatalError（Metal SDF 字幕渲染器必崩）。

排查：
    ls "$BUILD_DIR" | grep -i bundle        # 看实际产物名
若产物名不同，用 RESOURCE_BUNDLE_NAME=<名字> 重跑本脚本。
EOF
    exit 1
fi
echo "==> Copying SwiftPM resource bundle ($RESOURCE_BUNDLE_NAME)..."
cp -R "$RESOURCE_BUNDLE_SRC" "$APP_BUNDLE/$RESOURCE_BUNDLE_NAME"
cp -R "$RESOURCE_BUNDLE_SRC" "$APP_BUNDLE/Contents/Resources/$RESOURCE_BUNDLE_NAME"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>$DISPLAY_NAME needs microphone access to record audio for transcription.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>$DISPLAY_NAME needs speech recognition to transcribe audio with Apple Speech.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>$DISPLAY_NAME needs to control other applications for screen recording.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>$URL_SCHEME</string>
                <string>$LEGACY_URL_SCHEMES</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    # Create entitlements for hardened runtime
    ENTITLEMENTS=$(mktemp /tmp/entitlements.XXXXXX.plist)
    cat > "$ENTITLEMENTS" << 'ENTPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENTPLIST

    echo "==> Signing app bundle..."
    codesign --deep --force --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_BUNDLE"
    rm -f "$ENTITLEMENTS"
    echo "==> Verifying signature..."
    codesign --verify --deep --strict "$APP_BUNDLE"
    spctl --assess --type execute "$APP_BUNDLE" && echo "    Gatekeeper: OK" || echo "    Gatekeeper: not yet notarized (run notarytool to fix)"
else
    echo "==> Skipping code signing (set CODESIGN_IDENTITY to sign)"
fi

echo "==> Done! App bundle created at:"
echo "    $APP_BUNDLE"
echo ""
echo "    To run:  open $APP_BUNDLE"
echo "    To move: cp -r $APP_BUNDLE /Applications/"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    echo ""
    echo "    Signed with: $CODESIGN_IDENTITY"
fi
