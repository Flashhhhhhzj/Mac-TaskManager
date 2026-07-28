#!/bin/bash
# 构建脚本 - 编译并运行 Mac-TaskManager

set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Mac-TaskManager"
TARGET_NAME="MacTaskManager"
FAN_HELPER_NAME="MacFanHelper"
FAN_HELPER_SERVICE="local.Mac-TaskManager.FanHelper"
APP_VERSION="${APP_VERSION:-1.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-2}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

if [ -z "$CODESIGN_IDENTITY" ]; then
    CODESIGN_IDENTITY="$(
        security find-identity -v -p codesigning |
            sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' |
            head -n 1
    )"
fi

if [ -z "$CODESIGN_IDENTITY" ]; then
    echo "❌ 未找到 Developer ID Application 签名。"
    echo "   持久化特权 Helper 必须使用可信开发者签名，不能使用临时 ad-hoc 签名。"
    exit 1
fi

echo "🔨 正在编译 $APP_NAME..."

if ! swift build -c release --product "$APP_NAME" ||
   ! swift build -c release --product "$FAN_HELPER_NAME"; then
    cat <<EOF
❌ 编译失败。

当前 xcode-select:
   $(xcode-select -p)

如果错误里出现 SwiftUIMacros，请安装完整 Xcode，或切换到完整 Xcode 工具链:
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

EOF
    exit 1
fi

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
FAN_HELPER_PATH="$(swift build -c release --show-bin-path)/$FAN_HELPER_NAME"
cp "$BIN_PATH" "./$APP_NAME"

APP_DIR="./$APP_NAME.app"
rm -rf ./MacSystemMonitor ./MacSystemMonitor.app ./MacTaskManager ./MacTaskManager.app
rm -rf "$APP_DIR"
mkdir -p \
    "$APP_DIR/Contents/MacOS" \
    "$APP_DIR/Contents/Resources" \
    "$APP_DIR/Contents/Library/LaunchDaemons"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$FAN_HELPER_PATH" "$APP_DIR/Contents/MacOS/$FAN_HELPER_NAME"
chmod 755 "$APP_DIR/Contents/MacOS/$FAN_HELPER_NAME"
cp assets/app-icon.svg "$APP_DIR/Contents/Resources/app-icon.svg"
cp assets/app-icon.png "$APP_DIR/Contents/Resources/app-icon.png"
cp THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Mac-TaskManager</string>
    <key>CFBundleExecutable</key>
    <string>Mac-TaskManager</string>
    <key>CFBundleIconFile</key>
    <string>app-icon.png</string>
    <key>CFBundleIdentifier</key>
    <string>local.Mac-TaskManager</string>
    <key>CFBundleName</key>
    <string>Mac-TaskManager</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

cat > "$APP_DIR/Contents/Library/LaunchDaemons/$FAN_HELPER_SERVICE.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$FAN_HELPER_SERVICE</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/$FAN_HELPER_NAME</string>
    <key>MachServices</key>
    <dict>
        <key>$FAN_HELPER_SERVICE</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>local.Mac-TaskManager</string>
    </array>
</dict>
</plist>
EOF

plutil -lint "$APP_DIR/Contents/Info.plist"
plutil -lint "$APP_DIR/Contents/Library/LaunchDaemons/$FAN_HELPER_SERVICE.plist"

codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR/Contents/MacOS/$FAN_HELPER_NAME"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR"

echo "✅ 编译完成"
echo ""
echo "运行: ./$APP_NAME"
echo "应用: open $APP_NAME.app"
echo ""

if [ "${1:-}" = "dmg" ]; then
    DIST_DIR="./dist"
    DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
    DMG_ROOT="$DIST_DIR/dmg-root"

    rm -rf "$DMG_ROOT"
    mkdir -p "$DMG_ROOT" "$DIST_DIR"
    cp -R "$APP_DIR" "$DMG_ROOT/"
    ln -s /Applications "$DMG_ROOT/Applications"

    rm -f "$DMG_PATH"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$DMG_ROOT" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
    rm -rf "$DMG_ROOT"

    codesign \
        --force \
        --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$DMG_PATH"

    if [ -n "$NOTARY_PROFILE" ]; then
        xcrun notarytool submit \
            "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
        xcrun stapler staple "$DMG_PATH"
        xcrun stapler validate "$DMG_PATH"
        spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
        echo "✅ Apple 公证与票据装订完成"
    else
        echo "⚠️ 未设置 NOTARY_PROFILE：当前 DMG 仅适合本地测试，不应直接对外发布。"
    fi

    echo "💿 DMG: $DMG_PATH"
fi

if [ "${1:-}" = "run" ]; then
    open -n "$APP_DIR"
fi
