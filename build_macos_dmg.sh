#!/usr/bin/env bash
#
# build_macos_dmg.sh — build mod3_solitaire on macOS and package it as
# Mod3_Solitaire.dmg containing a proper Mod3_Solitaire.app bundle.
#
# Must be run ON a Mac (V cannot cross-compile for macOS from Linux).
# Requires: Xcode command line tools, V (brew install vlang).
#
# Usage:
#   ./build_macos_dmg.sh                 # compile with V, then package
#   ./build_macos_dmg.sh --package-only  # skip compiling, package ./mod3
#
set -euo pipefail
cd "$(dirname "$0")"

PACKAGE_ONLY=0
if [ "${1:-}" = "--package-only" ]; then PACKAGE_ONLY=1; fi

# --- 1. Compile with V (native macOS target; sokol uses Cocoa automatically) ---
if [ "$PACKAGE_ONLY" -eq 0 ]; then
  if ! command -v v >/dev/null 2>&1; then
    echo "V compiler not found. Install it with:  brew install vlang" >&2
    exit 1
  fi
  echo "==> Compiling mod3.v with V ($(v version))..."
  # NOTE: -d sokol_wayland is Linux-only; on macOS sokol uses Cocoa/Metal.
  v mod3.v
fi
[ -x ./mod3 ] || { echo "ERROR: ./mod3 binary not found" >&2; exit 1; }

# --- 2. Assemble Mod3_Solitaire.app ---
APP="Mod3_Solitaire.app"
echo "==> Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp ./mod3 "$APP/Contents/MacOS/Mod3_Solitaire"
chmod +x "$APP/Contents/MacOS/Mod3_Solitaire"

# Bundle the Boehm GC dylib if the binary links against libgc, so the .app
# is self-contained (no need for DYLD_LIBRARY_PATH on other machines).
if otool -L ./mod3 2>/dev/null | grep -q "libgc"; then
  echo "==> Bundling libgc dylib..."
  V_BIN="$(which v)"
  V_RESOLVED="$(readlink -f "$V_BIN" 2>/dev/null || readlink "$V_BIN" 2>/dev/null || echo "$V_BIN")"
  V_ROOT="$(cd "$(dirname "$V_RESOLVED")/.." && pwd -P)"
  LIBGC_SRC=""
  for p in "$V_ROOT/thirdparty/tcc/lib/libgc.dylib" \
           /opt/homebrew/lib/libgc.dylib \
           /usr/local/lib/libgc.dylib; do
    if [ -f "$p" ]; then LIBGC_SRC="$p"; break; fi
  done
  if [ -n "$LIBGC_SRC" ]; then
    cp "$LIBGC_SRC" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
      "$APP/Contents/MacOS/Mod3_Solitaire" 2>/dev/null || true
    echo "    bundled $(basename "$LIBGC_SRC")"
  else
    echo "    WARNING: libgc dylib not found; the .app may need bdw-gc installed" >&2
  fi
fi

# App icon (generated from mod3_solitaire.png)
if [ -f mod3_solitaire.png ]; then
  echo "==> Generating .icns icon..."
  ICONSET_DIR="$(mktemp -d)/icon.iconset"
  mkdir -p "$ICONSET_DIR"
  for sz in 16 32 64 128 256 512; do
    sips -z "$sz" "$sz" mod3_solitaire.png \
      --out "$ICONSET_DIR/icon_${sz}x${sz}.png" >/dev/null
    sips -z "$((sz * 2))" "$((sz * 2))" mod3_solitaire.png \
      --out "$ICONSET_DIR/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/mod3_solitaire.icns"
  rm -rf "$(dirname "$ICONSET_DIR")"
fi

# Info.plist
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Mod3 Solitaire</string>
  <key>CFBundleDisplayName</key>
  <string>Mod3 Solitaire</string>
  <key>CFBundleIdentifier</key>
  <string>com.jeffsauer.mod3solitaire</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>Mod3_Solitaire</string>
  <key>CFBundleIconFile</key>
  <string>mod3_solitaire</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

# Ad-hoc code signature so Gatekeeper lets it run when distributed
echo "==> Ad-hoc code signing..."
codesign --deep --force --sign - "$APP" 2>/dev/null \
  || echo "    (codesign unavailable, skipping)"

# --- 3. Create the .dmg ---
DMG="Mod3_Solitaire.dmg"
echo "==> Creating $DMG..."
rm -f "$DMG"
hdiutil create -volname "Mod3 Solitaire" -srcfolder "$APP" \
  -ov -format UDZO "$DMG" >/dev/null

echo "Done: $(pwd)/$DMG"
