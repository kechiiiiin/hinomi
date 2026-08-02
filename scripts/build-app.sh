#!/usr/bin/env bash
# hinomi.app を組み立てる（Xcode プロジェクト不要）。
#   swift build -c release → .app バンドル生成 → ad-hoc 署名
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.1.0"
BUNDLE_ID="app.hinomi.hinomi"
APP="$ROOT/build/hinomi.app"

cd "$ROOT"
echo "==> swift build -c release"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> .app を組み立て: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/hinomi" "$APP/Contents/MacOS/hinomi"
cp "$BIN_DIR/hinomi-hook" "$APP/Contents/MacOS/hinomi-hook"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>ja</string>
	<key>CFBundleExecutable</key>
	<string>hinomi</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>hinomi</string>
	<key>CFBundleDisplayName</key>
	<string>hinomi</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 署名"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/hinomi-hook"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> 完成: $APP"
echo "    起動:        open \"$APP\""
echo "    hooks 導入:  \"$APP/Contents/MacOS/hinomi\" install-hooks"
