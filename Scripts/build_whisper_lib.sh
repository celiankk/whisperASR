#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WHISPER_DIR="$PROJECT_DIR/.whisper.cpp"
OUTPUT_DIR="$PROJECT_DIR/Frameworks"
HEADERS_DIR="$OUTPUT_DIR/headers"
XCF_DIR="$OUTPUT_DIR/CWhisper.xcframework"

echo "=== Building whisper.cpp with Metal GPU acceleration ==="
echo ""

if [ ! -d "$WHISPER_DIR" ]; then
    echo "Cloning whisper.cpp..."
    git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER_DIR"
fi

# Build with cmake — Metal + embedded shader library
echo "Building with Metal support..."
cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_ACCELERATE=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)"

cmake --build "$WHISPER_DIR/build" --config Release -j "$(sysctl -n hw.ncpu)"

# Collect all static libraries
echo ""
echo "Merging static libraries..."
LIBS=()
for lib in \
    "$WHISPER_DIR/build/src/libwhisper.a" \
    "$WHISPER_DIR/build/ggml/src/libggml.a" \
    "$WHISPER_DIR/build/ggml/src/ggml-cpu/libggml-cpu.a" \
    "$WHISPER_DIR/build/ggml/src/ggml-metal/libggml-metal.a" \
    "$WHISPER_DIR/build/ggml/src/libggml-base.a"; do
    if [ -f "$lib" ]; then
        LIBS+=("$lib")
        echo "  Found: $(basename "$lib")"
    fi
done

MERGED_LIB="$WHISPER_DIR/build/libwhisper_all.a"
libtool -static -o "$MERGED_LIB" "${LIBS[@]}"
echo "  Merged into: libwhisper_all.a"

# Prepare headers
#
# 头文件放在 `Headers/CWhisper/` 子目录（而非 `Headers/` 根下）：SwiftPM 的
# swiftbuild 构建引擎会把每个 binaryTarget 的 Headers 内容摊平复制到同一个
# `Products/<Config>/include/`，多个 target 各自带根级 module.modulemap 时
# 会报 "Multiple commands produce .../include/module.modulemap"。
# 放进同名子目录后路径不再冲突（SherpaONNX.xcframework 同样布局）。
echo ""
echo "Collecting headers..."
# 头文件放在 `Headers/CWhisper/` 子目录（而非 `Headers/` 根下）：SwiftPM 的
# swiftbuild 构建引擎把各 binaryTarget 的 Headers 内容摊平复制到同一个
# `Products/<Config>/include/`，多个 target 各带根级 module.modulemap 时会报
# "Multiple commands produce .../include/module.modulemap"。放进同名子目录即
# 不再冲突（SherpaONNX.xcframework 同样布局）。
#
# 注意 `xcodebuild -headers` 复制的是**该目录的内容**，所以这里把模块子目录建在
# `$HEADERS_DIR` 之下、并把 `$HEADERS_DIR` 本身传给 -headers，产物才是
# `Headers/CWhisper/*`；若直接传子目录会被摊平回根级。
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR/CWhisper"
HDR_SRC="$HEADERS_DIR/CWhisper"
cp "$WHISPER_DIR/include/whisper.h" "$HDR_SRC/"
cp "$WHISPER_DIR/ggml/include/ggml.h" "$HDR_SRC/"
cp "$WHISPER_DIR/ggml/include/ggml-cpu.h" "$HDR_SRC/"
cp "$WHISPER_DIR/ggml/include/ggml-backend.h" "$HDR_SRC/"
cp "$WHISPER_DIR/ggml/include/ggml-alloc.h" "$HDR_SRC/"
cp "$WHISPER_DIR/ggml/include/ggml-metal.h" "$HDR_SRC/"
cp "$WHISPER_DIR/ggml/include/ggml-opt.h" "$HDR_SRC/"
cp "$WHISPER_DIR/ggml/include/ggml-cpp.h" "$HDR_SRC/"
cp "$WHISPER_DIR/ggml/include/gguf.h" "$HDR_SRC/"

# Create module map
cat > "$HDR_SRC/module.modulemap" << 'EOF'
module CWhisper {
    header "whisper.h"
    header "ggml.h"
    export *
}
EOF

# Create xcframework（xcodebuild 需要完整 Xcode；CLT 下会报
# "xcodebuild requires Xcode"）。
echo ""
echo "Creating xcframework..."
rm -rf "$XCF_DIR"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcodebuild -create-xcframework \
    -library "$MERGED_LIB" \
    -headers "$HEADERS_DIR" \
    -output "$XCF_DIR"

echo ""
echo "=== Build complete ==="
echo "XCFramework: $XCF_DIR"

# 收尾清理中间头文件目录：`Frameworks/headers/` 只是喂给 `xcodebuild
# -create-xcframework -headers` 的输入，真身在 xcframework 内
# （`macos-arm64/Headers/CWhisper/`）。留在仓库里会形成双份事实源——
# 改了 xcframework 内头文件却忘了这份，SwiftPM 编译期会用到过期头。
# 目录已在 .gitignore 中；此处只清构建中间产物，不动已入库的 xcframework。
rm -rf "$HEADERS_DIR"
echo ""
echo "Metal GPU acceleration is enabled."
