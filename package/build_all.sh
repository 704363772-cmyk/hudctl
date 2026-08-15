#!/bin/bash
# ============================================================
# HUDControl JB 直连版 一键构建（macOS / GitHub Actions macos-latest）
#   1. swiftc 交叉编译 app (arm64 iOS)
#   2. ldid 伪签（带 no-sandbox entitlements，越狱直连）
#   3. 组 deb（/Applications/HUDControl.app + postinst(uicache)）
#   产物: pkg/hudcontrol_jb.deb
# ============================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
cd "$ROOT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TGT="arm64-apple-ios15.0"

rm -rf dist
mkdir -p dist/Applications/HUDControl.app

echo "==> [1/4] compiling app (swiftc -> arm64 iOS)"
xcrun --sdk iphoneos swiftc -target "$TGT" -sdk "$SDK" -O \
    app/main.swift -o dist/Applications/HUDControl.app/HUDControl

cp app/Info.plist dist/Applications/HUDControl.app/Info.plist
printf 'APPL????' > dist/Applications/HUDControl.app/PkgInfo
plutil -lint dist/Applications/HUDControl.app/Info.plist

echo "==> [2/4] ldid sign with no-sandbox entitlements"
if command -v ldid >/dev/null 2>&1; then
    ldid -S app/entitlements.plist dist/Applications/HUDControl.app/HUDControl
    echo "    ldid: done"
else
    echo "    ERROR: ldid not found (brew install ldid)"
    exit 1
fi

echo "==> [3/4] pack deb (app + postinst)"
mkdir -p pkg
python3 package/pack_deb.py

echo "==> [4/4] done: pkg/hudcontrol_jb.deb"