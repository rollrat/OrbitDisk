#!/bin/zsh
set -eu
ORBIT_ROOT="$(cd "$(dirname "$0")" && pwd)"
ORBIT_CACHE="${ORBIT_CACHE:-$ORBIT_ROOT/.build/ModuleCache}"
if [[ -z "${ORBIT_SDK:-}" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    ORBIT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  else
    ORBIT_SDK="$(xcrun --show-sdk-path)"
  fi
fi
mkdir -p "$ORBIT_ROOT/.build" "$ORBIT_CACHE"
cat "$ORBIT_ROOT/Sources/OrbitDisk.swift" "$ORBIT_ROOT/Tests/OrbitDiskChecks.swift" > "$ORBIT_ROOT/.build/Checks.swift"
CLANG_MODULE_CACHE_PATH="$ORBIT_CACHE" SWIFT_MODULE_CACHE_PATH="$ORBIT_CACHE" \
  xcrun swiftc -D TESTING -sdk "$ORBIT_SDK" -target "$(uname -m)-apple-macosx13.0" \
  -parse-as-library -swift-version 5 -O "$ORBIT_ROOT/.build/Checks.swift" \
  -framework SwiftUI -framework AppKit -o "$ORBIT_ROOT/.build/checks"
cd "$ORBIT_ROOT"
.build/checks
