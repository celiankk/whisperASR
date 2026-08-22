#!/bin/bash
# FunASR/SenseVoice runtime 冒烟：加载模型 + 正弦波推理。
# 用法：bash Scripts/funasr-smoke.sh [模型目录（默认 SenseVoice catalog 路径）]
FW="$(dirname "$0")/../Frameworks/SherpaONNX.xcframework/macos-arm64"
swiftc "$(dirname "$0")/funasr-smoke.swift" -I "$FW/Headers/SherpaONNX" -L "$FW" -lSherpaONNX -lc++ -o /tmp/funasr-smoke
exec /tmp/funasr-smoke "$@"
