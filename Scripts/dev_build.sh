#!/bin/bash
# 开发构建 / 测试入口（Lead 审阅后新增）
#
# 背景：项目使用 SwiftUI 宏（`@State` 等）。宏实现 `libSwiftUIMacros.dylib`
# 只随 Xcode 提供（位于 Xcode 各 Platform 目录下的
# `usr/lib/swift/host/plugins/`），CommandLineTools 里没有。因此当
# `xcode-select -p` 指向 CLT 时，直接 `swift build` 会在编译期报：
#   external macro implementation type 'SwiftUIMacros.StateMacro'
#   could not be found for macro 'State()'
#
# 注意 `-load-plugin-executable` 不可用：它把 dylib 当可执行文件启动，
# 报 "cannot execute binary file" → "produced malformed response"。
# 必须用 `-plugin-path` 让编译器自行发现并进程内加载。
#
# 本脚本把该路径固化，使 CLT 环境也能构建与跑测试：
#   bash Scripts/dev_build.sh          # 构建
#   bash Scripts/dev_build.sh test     # 构建并跑测试
#   bash Scripts/dev_build.sh run      # 构建并启动 App

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# 优先用 Xcode 工具链（完整、无需额外插件路径）；不可用时回落 CLT +
# 显式宏插件路径。Xcode 存在但许可未接受的情况必须显式提示——否则会在
# 后面以晦涩错误失败（实测：回退后立刻报 "You have not agreed to the
# Xcode license agreements"）。
SWIFT_ARGS=()
TOOLCHAIN_NOTE=""

try_xcode() {
    local dev="/Applications/Xcode.app/Contents/Developer"
    [ -d "$dev" ] || return 1
    # 许可未接受时 xcodebuild/swift 会直接失败，提前探测避免误判可用。
    if ! DEVELOPER_DIR="$dev" "$dev/usr/bin/swiftc" --version >/dev/null 2>&1; then
        echo "警告：检测到 ${dev}，但该工具链不可用（通常是 Xcode 许可未接受）。"
        echo "      请执行 'sudo xcodebuild -license accept'，或改用 CLT + 宏插件路径（本脚本自动回落）。"
        return 1
    fi
    export DEVELOPER_DIR="$dev"
    TOOLCHAIN_NOTE="Xcode 工具链（${dev}）"
    return 0
}

try_clt_with_macro_plugin() {
    # 宏插件可能在任一 Platform 目录下；MacOSX 优先。
    local candidates=(
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
        "/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
    )
    local plugins=""
    for p in "${candidates[@]}"; do
        if [ -f "$p/libSwiftUIMacros.dylib" ]; then plugins="$p"; break; fi
    done
    if [ -z "$plugins" ]; then
        echo "错误：找不到 SwiftUI 宏插件（libSwiftUIMacros.dylib）。" >&2
        echo "      项目使用 SwiftUI 宏，必须由 Xcode 提供该插件；仅安装 CommandLineTools 无法构建。" >&2
        echo "      请安装 Xcode，或执行 'sudo xcodebuild -license accept' 后重试。" >&2
        return 1
    fi
    SWIFT_ARGS+=(-Xswiftc -plugin-path -Xswiftc "$plugins")
    TOOLCHAIN_NOTE="CommandLineTools + 宏插件（${plugins}）"
    return 0
}

if ! try_xcode; then
    try_clt_with_macro_plugin
fi

echo "==> 工具链：$TOOLCHAIN_NOTE"

ACTION="${1:-build}"
case "$ACTION" in
    build)
        swift build "${SWIFT_ARGS[@]}"
        ;;
    test)
        # XCTest 随 Xcode 提供（CLT 无）。CLT 路径下需要三组额外参数，
        # 缺一不可（逐项实测得出）：
        #   1) -I <platform>/Developer/usr/lib —— XCTest 的 Swift 模块接口
        #      （XCTest.swiftmodule 在这里；XCTest.framework/Modules 下只有
        #      module.modulemap，没有 swiftmodule）
        #   2) -framework XCTest + -F/-rpath <platform>/Developer/Library/Frameworks
        #      —— SPM 在 CLT 环境下不会自动补 -framework XCTest
        #   3) -lXCTestSwiftSupport —— XCTAssert* 等 Swift overlay 符号在
        #      libXCTestSwiftSupport.dylib 里，只链 XCTest.framework 会报
        #      "Undefined symbols: XCTest.XCTAssertNil/..."（全是 XCTest
        #      自身的 Swift 符号，不是项目代码问题）
        XC_PLATFORM="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer"
        TEST_ARGS=("${SWIFT_ARGS[@]}")
        if [ -d "$XC_PLATFORM/usr/lib" ]; then
            TEST_ARGS+=(-Xswiftc -I -Xswiftc "$XC_PLATFORM/usr/lib")
            TEST_ARGS+=(-Xswiftc -F -Xswiftc "$XC_PLATFORM/Library/Frameworks")
            TEST_ARGS+=(-Xlinker -F -Xlinker "$XC_PLATFORM/Library/Frameworks")
            TEST_ARGS+=(-Xlinker -rpath -Xlinker "$XC_PLATFORM/Library/Frameworks")
            TEST_ARGS+=(-Xlinker -framework -Xlinker XCTest)
            TEST_ARGS+=(-Xlinker -L -Xlinker "$XC_PLATFORM/usr/lib")
            TEST_ARGS+=(-Xlinker -lXCTestSwiftSupport)
            TEST_ARGS+=(-Xlinker -rpath -Xlinker "$XC_PLATFORM/usr/lib")
        fi
        swift build --build-tests "${TEST_ARGS[@]}"
        # 运行：`swift test` 在本环境只发现 swift-testing（0 用例）而漏掉
        # XCTest，故直接用 xctest 运行器跑已构建的 .xctest 包。
        if [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest" ]; then
            BIN_PATH="$(swift build --show-bin-path "${SWIFT_ARGS[@]}")"
            export DYLD_FRAMEWORK_PATH="$XC_PLATFORM/Library/Frameworks:$XC_PLATFORM/usr/lib"
            /Applications/Xcode.app/Contents/Developer/usr/bin/xctest "$BIN_PATH/WhisperASRTests.xctest"
        else
            swift test "${TEST_ARGS[@]}"
        fi
        ;;
    run)
        swift run "${SWIFT_ARGS[@]}"
        ;;
    *)
        echo "用法：bash Scripts/dev_build.sh [build|test|run]" >&2
        exit 2
        ;;
esac