#!/bin/zsh
#
# Builds "Sonarr Radarr Updater.app" from main.swift, bundles a copy of
# update-servarr.sh into it, and ad-hoc signs the result.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
APP_NAME="Sonarr Radarr Updater"
DEST="$SCRIPT_DIR/$APP_NAME.app"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "Compiling..."
swiftc -O -o "$BUILD_DIR/UpdateServarrUI" "$SCRIPT_DIR/main.swift"

echo "Assembling app bundle..."
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BUILD_DIR/UpdateServarrUI" "$DEST/Contents/MacOS/UpdateServarrUI"
chmod +x "$DEST/Contents/MacOS/UpdateServarrUI"
cp "$SCRIPT_DIR/update-servarr.sh" "$DEST/Contents/Resources/update-servarr.sh"
chmod +x "$DEST/Contents/Resources/update-servarr.sh"

cat > "$DEST/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>UpdateServarrUI</string>
	<key>CFBundleIdentifier</key>
	<string>local.sonarr-radarr-updater</string>
	<key>CFBundleName</key>
	<string>Sonarr Radarr Updater</string>
	<key>CFBundleDisplayName</key>
	<string>Sonarr Radarr Updater</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.1</string>
	<key>CFBundleVersion</key>
	<string>2</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

echo -n "APPL????" > "$DEST/Contents/PkgInfo"

echo "Signing..."
codesign --force --deep -s - "$DEST"
xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Built: $DEST"
