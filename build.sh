#!/bin/zsh
set -eu
ORBIT_ROOT="$(cd "$(dirname "$0")" && pwd)"
ORBIT_OUTPUT="${1:-$ORBIT_ROOT/build}"
ORBIT_APP="$ORBIT_OUTPUT/OrbitDisk.app"
ORBIT_CACHE="${ORBIT_CACHE:-$ORBIT_ROOT/.build/ModuleCache}"
if [[ -z "${ORBIT_SDK:-}" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    ORBIT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    ORBIT_SDK="$(xcrun --show-sdk-path)"
  fi
fi
mkdir -p "$ORBIT_APP/Contents/MacOS" "$ORBIT_APP/Contents/Resources" "$ORBIT_CACHE"
CLANG_MODULE_CACHE_PATH="$ORBIT_CACHE" SWIFT_MODULE_CACHE_PATH="$ORBIT_CACHE" \
  xcrun swiftc -sdk "$ORBIT_SDK" -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -swift-version 5 -O "$ORBIT_ROOT/Sources/OrbitDisk.swift" \
  -framework SwiftUI -framework AppKit -o "$ORBIT_APP/Contents/MacOS/OrbitDisk"
cp "$ORBIT_ROOT/Resources/Info.plist" "$ORBIT_APP/Contents/Info.plist"
cp "$ORBIT_ROOT/Resources/OrbitDisk.icns" "$ORBIT_APP/Contents/Resources/OrbitDisk.icns"
codesign --force --sign - "$ORBIT_APP"
printf 'Built: %s\n' "$ORBIT_APP"
