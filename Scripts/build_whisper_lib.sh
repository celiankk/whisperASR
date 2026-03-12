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
echo ""
echo "Collecting headers..."
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$WHISPER_DIR/include/whisper.h" "$HEADERS_DIR/"
cp "$WHISPER_DIR/ggml/include/ggml.h" "$HEADERS_DIR/"
cp "$WHISPER_DIR/ggml/include/ggml-cpu.h" "$HEADERS_DIR/"
cp "$WHISPER_DIR/ggml/include/ggml-backend.h" "$HEADERS_DIR/"
cp "$WHISPER_DIR/ggml/include/ggml-alloc.h" "$HEADERS_DIR/"
cp "$WHISPER_DIR/ggml/include/ggml-metal.h" "$HEADERS_DIR/"
cp "$WHISPER_DIR/ggml/include/ggml-opt.h" "$HEADERS_DIR/"
cp "$WHISPER_DIR/ggml/include/ggml-cpp.h" "$HEADERS_DIR/"
cp "$WHISPER_DIR/ggml/include/gguf.h" "$HEADERS_DIR/"

# Create module map
cat > "$HEADERS_DIR/module.modulemap" << 'EOF'
module CWhisper {
    header "whisper.h"
    header "ggml.h"
    export *
}
EOF

# Create xcframework
echo ""
echo "Creating xcframework..."
rm -rf "$XCF_DIR"
xcodebuild -create-xcframework \
    -library "$MERGED_LIB" \
    -headers "$HEADERS_DIR" \
    -output "$XCF_DIR"

echo ""
echo "=== Build complete ==="
echo "XCFramework: $XCF_DIR"
echo ""
echo "Metal GPU acceleration is enabled."
