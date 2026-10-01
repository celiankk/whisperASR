#!/bin/bash
set -euo pipefail

# Build transcribe.cpp (ggml + Metal) into Frameworks/CTranscribe.xcframework,
# mirroring Scripts/build_whisper_lib.sh. Runtime for Qwen3-ASR GGUF models.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TRANSCRIBE_DIR="$PROJECT_DIR/.transcribe.cpp"
OUTPUT_DIR="$PROJECT_DIR/Frameworks"
HEADERS_DIR="$OUTPUT_DIR/transcribe-headers"
XCF_DIR="$OUTPUT_DIR/CTranscribe.xcframework"

echo "=== Building transcribe.cpp with Metal GPU acceleration ==="

if [ ! -d "$TRANSCRIBE_DIR" ]; then
    echo "Cloning transcribe.cpp..."
    git clone --depth 1 https://github.com/handy-computer/transcribe.cpp.git "$TRANSCRIBE_DIR"
fi

cmake -S "$TRANSCRIBE_DIR" -B "$TRANSCRIBE_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DTRANSCRIBE_METAL=ON \
    -DTRANSCRIBE_BUILD_TESTS=OFF \
    -DTRANSCRIBE_BUILD_EXAMPLES=ON \
    -DTRANSCRIBE_BUILD_TOOLS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES="$(uname -m)"

cmake --build "$TRANSCRIBE_DIR/build" --config Release -j "$(sysctl -n hw.ncpu)"

echo ""
echo "Merging static libraries..."
LIBS=()
for lib in \
    "$TRANSCRIBE_DIR/build/src/libtranscribe.a" \
    "$TRANSCRIBE_DIR"/build/ggml/src/libggml*.a \
    "$TRANSCRIBE_DIR"/build/ggml/src/ggml-cpu/libggml-cpu.a \
    "$TRANSCRIBE_DIR"/build/ggml/src/ggml-metal/libggml-metal.a \
    "$TRANSCRIBE_DIR"/build/ggml/src/libggml-base.a; do
    if [ -f "$lib" ]; then
        LIBS+=("$lib")
        echo "  Found: $(basename "$lib")"
    fi
done

MERGED_LIB="$TRANSCRIBE_DIR/build/libtranscribe_all.a"
libtool -static -o "$MERGED_LIB" "${LIBS[@]}"
echo "  Merged into: libtranscribe_all.a"

echo ""
echo "Building Swift bridging shim..."
SHIM_DIR="$TRANSCRIBE_DIR/build/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/transcribe_shim.h" << 'EOF'
#ifndef TRANSCRIBE_SHIM_H
#define TRANSCRIBE_SHIM_H

#include "transcribe.h"

/* Opaque session pointer as a concrete typedef, so Swift imports it as
 * OpaquePointer instead of an incomplete struct type. */
typedef struct transcribe_session * transcribe_session_ref;

transcribe_status transcribe_open_swift(const char * path, transcribe_session_ref * out_session);
transcribe_status transcribe_run_swift(transcribe_session_ref session, const float * pcm, int n_samples);
const char * transcribe_full_text_swift(transcribe_session_ref session);
void transcribe_close_swift(transcribe_session_ref session);

#endif
EOF

cat > "$SHIM_DIR/transcribe_shim.c" << 'EOF'
#include "transcribe_shim.h"

transcribe_status transcribe_open_swift(const char * path, transcribe_session_ref * out_session) {
    return transcribe_open(path, NULL, NULL, out_session);
}

transcribe_status transcribe_run_swift(transcribe_session_ref session, const float * pcm, int n_samples) {
    return transcribe_run(session, pcm, n_samples, NULL);
}

const char * transcribe_full_text_swift(transcribe_session_ref session) {
    return transcribe_full_text(session);
}

void transcribe_close_swift(transcribe_session_ref session) {
    transcribe_close(session);
}
EOF

cc -O2 -I"$TRANSCRIBE_DIR/include" -I"$SHIM_DIR" -c "$SHIM_DIR/transcribe_shim.c" -o "$SHIM_DIR/transcribe_shim.o"
libtool -static -o "$MERGED_LIB" "${LIBS[@]}" "$SHIM_DIR/transcribe_shim.o"
echo "  Shim merged into: libtranscribe_all.a"

echo ""
echo "Collecting headers..."
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$TRANSCRIBE_DIR/include/transcribe.h" "$HEADERS_DIR/"
cp "$SHIM_DIR/transcribe_shim.h" "$HEADERS_DIR/"

cat > "$HEADERS_DIR/module.modulemap" << 'EOF'
module CTranscribe {
    header "transcribe.h"
    header "transcribe_shim.h"
    export *
}
EOF

echo ""
echo "Creating xcframework..."
# 头文件放进 `Headers/CTranscribe/` 子目录：swiftbuild 引擎把各 binaryTarget 的
# Headers 摊平到同一个 `Products/<Config>/include/`，多个 target 各带根级
# module.modulemap 时会报 "Multiple commands produce .../module.modulemap"。
rm -rf "$XCF_DIR"
mkdir -p "$XCF_DIR/macos-arm64/Headers/CTranscribe"
cp "$MERGED_LIB" "$XCF_DIR/macos-arm64/libtranscribe_all.a"
cp "$HEADERS_DIR/transcribe.h" "$XCF_DIR/macos-arm64/Headers/CTranscribe/"
cp "$HEADERS_DIR/transcribe_shim.h" "$XCF_DIR/macos-arm64/Headers/CTranscribe/"
cp "$HEADERS_DIR/module.modulemap" "$XCF_DIR/macos-arm64/Headers/CTranscribe/"
cat > "$XCF_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libtranscribe_all.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>libtranscribe_all.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

echo ""
echo "=== Build complete ==="
echo "XCFramework: $XCF_DIR"

# 收尾清理中间头文件目录：`Frameworks/transcribe-headers/` 只是本脚本组装
# xcframework 时的暂存目录，真身是 `macos-arm64/Headers/CTranscribe/`。
# 留在仓库里会形成双份事实源（改了 xcframework 内头文件却忘了这份，
# SwiftPM 编译期会用到过期头）。目录已在 .gitignore 中；此处只清构建中间
# 产物，不动已入库的 xcframework 文件。
rm -rf "$HEADERS_DIR"
echo "Metal GPU acceleration is enabled."
