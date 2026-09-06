#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# build.sh — build ISO9660.pcxplugin, and optionally the .pcplug package around it.
#
#   ./build.sh                 build into ~/Library/Application Support/PeachCommander/plugins
#   ./build.sh dist            build into ./dist
#   ./build.sh dist --package  …and wrap it in dist/ISO9660-<version>.pcplug
#
# SwiftPM is not used for this. The output has to be a bare dylib inside a bundle directory with a
# specific name, and both architectures have to be in it — none of which is a SwiftPM product. The
# invocation below is the whole of what a Swift plugin needs, and it is deliberately short enough
# to read.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

DEFAULT_DIR="$HOME/Library/Application Support/PeachCommander/plugins"
OUT_DIR="${1:-$DEFAULT_DIR}"
PACKAGE="${2:-}"
NAME="ISO9660"
BUNDLE="$OUT_DIR/$NAME.pcxplugin"

# The SDK: a checkout beside this one while developing, or resolved by SwiftPM.
SDK_INCLUDE=""
for candidate in \
    "$ROOT/../PeachCommanderPluginSDK/Sources/CPeachCommanderPlugin/include" \
    "$ROOT/.build/checkouts/PeachCommanderPluginSDK/Sources/CPeachCommanderPlugin/include"; do
    if [ -d "$candidate" ]; then SDK_INCLUDE="$candidate"; break; fi
done
[ -n "$SDK_INCLUDE" ] || {
    echo "error: the plugin SDK headers were not found." >&2
    echo "       Run 'swift package resolve', or check out PeachCommanderPluginSDK beside this repo." >&2
    exit 1
}

# Universal (arm64 + x86_64). A single-slice plugin cannot be loaded at all by the universal app on
# the other architecture, and nothing about it looks wrong until somebody there reports that the
# plugin does not exist.
# shellcheck source=Tools/pc-universal.sh
source "$ROOT/Tools/pc-universal.sh"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$ROOT/Plugin/Info.plist" "$BUNDLE/Contents/Info.plist"

pc_swiftc -emit-library -O \
  -module-name "$NAME" \
  -Xcc -I"$SDK_INCLUDE" \
  -Xcc -fmodule-map-file="$SDK_INCLUDE/module.modulemap" \
  -I"$SDK_INCLUDE" \
  -o "$BUNDLE/Contents/MacOS/$NAME" \
  "$ROOT"/Sources/ISOPlugin/*.swift

if [ -d "$ROOT/Resources" ]; then
  mkdir -p "$BUNDLE/Contents/Resources"
  cp -R "$ROOT/Resources/." "$BUNDLE/Contents/Resources/"
fi

echo "Built $BUNDLE"

if [ "$PACKAGE" = "--package" ]; then
  for candidate in \
      "$ROOT/../PeachCommanderPluginSDK/Tools/make-pcplug.sh" \
      "$ROOT/.build/checkouts/PeachCommanderPluginSDK/Tools/make-pcplug.sh"; do
      if [ -x "$candidate" ]; then "$candidate" "$BUNDLE" "$OUT_DIR"; exit 0; fi
  done
  echo "error: make-pcplug.sh not found in the SDK checkout" >&2
  exit 1
fi
