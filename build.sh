#!/bin/bash
# 构建脚本 - 编译并运行 Mac-TaskManager

set -euo pipefail

cd "$(dirname "$0")"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/swift-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-/tmp/swift-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

APP_NAME="Mac-TaskManager"
TARGET_NAME="MacTaskManager"
FAN_HELPER_NAME="MacFanHelper"
FAN_HELPER_SERVICE="local.Mac-TaskManager.FanHelper"
APP_VERSION="${APP_VERSION:-1.0.0}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-4}"
BETA_TAG="${BETA_TAG:-beta.2}"
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

build_app_bundle() {
    local target_arch="${1:-arm64}"
    local app_dir="${2:-./$APP_NAME.app}"

    echo "🔨 正在编译 $APP_NAME ($target_arch)..."

    if ! swift build -c release --arch "$target_arch" --product "$APP_NAME" ||
       ! swift build -c release --arch "$target_arch" --product "$FAN_HELPER_NAME"; then
        cat <<EOF
❌ 编译失败。

当前 xcode-select:
   $(xcode-select -p)

如果错误里出现 SwiftUIMacros，请安装完整 Xcode，或切换到完整 Xcode 工具链:
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

EOF
        exit 1
    fi

    local bin_path
    local helper_path
    bin_path="$(swift build -c release --arch "$target_arch" --show-bin-path)/$APP_NAME"
    helper_path="$(swift build -c release --arch "$target_arch" --show-bin-path)/$FAN_HELPER_NAME"
    cp "$bin_path" "./$APP_NAME"

    rm -rf "$app_dir"
    mkdir -p \
        "$app_dir/Contents/MacOS" \
        "$app_dir/Contents/Resources" \
        "$app_dir/Contents/Library/LaunchDaemons"
    cp "$bin_path" "$app_dir/Contents/MacOS/$APP_NAME"
    # SMAppService LaunchDaemons resolve BundleProgram relative to the app bundle.
    # Keep the helper in Resources, matching Apple's documented bundle layout and
    # avoiding stale registrations that point at an earlier helper location.
    cp "$helper_path" "$app_dir/Contents/Resources/$FAN_HELPER_NAME"
    chmod 755 "$app_dir/Contents/Resources/$FAN_HELPER_NAME"
    cp assets/app-icon.svg "$app_dir/Contents/Resources/app-icon.svg"
    cp assets/app-icon.png "$app_dir/Contents/Resources/app-icon.png"
    cp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"

    cat > "$app_dir/Contents/Info.plist" <<EOF
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

    cat > "$app_dir/Contents/Library/LaunchDaemons/$FAN_HELPER_SERVICE.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$FAN_HELPER_SERVICE</string>
    <key>BundleProgram</key>
    <string>Contents/Resources/$FAN_HELPER_NAME</string>
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

    plutil -lint "$app_dir/Contents/Info.plist"
    plutil -lint "$app_dir/Contents/Library/LaunchDaemons/$FAN_HELPER_SERVICE.plist"

    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$app_dir/Contents/Resources/$FAN_HELPER_NAME"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$app_dir"

    echo "✅ [$target_arch] 编译与签名完成: $app_dir"
}

create_dmg_package() {
    local app_dir="$1"
    local dmg_path="$2"

    local dist_dir
    dist_dir="$(dirname "$dmg_path")"
    mkdir -p "$dist_dir"

    local dmg_root="$dist_dir/dmg-root"
    rm -rf "$dmg_root"
    mkdir -p "$dmg_root"
    cp -R "$app_dir" "$dmg_root/"
    ln -s /Applications "$dmg_root/Applications"

    rm -f "$dmg_path"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$dmg_root" \
        -ov \
        -format UDZO \
        "$dmg_path"
    rm -rf "$dmg_root"

    codesign \
        --force \
        --timestamp \
        --sign "$CODESIGN_IDENTITY" \
        "$dmg_path"

    if [ -n "$NOTARY_PROFILE" ]; then
        xcrun notarytool submit \
            "$dmg_path" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait
        xcrun stapler staple "$dmg_path"
        xcrun stapler validate "$dmg_path"
        spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
        echo "✅ Apple 公证与票据装订完成"
    else
        echo "⚠️ 未设置 NOTARY_PROFILE：当前 DMG 仅适合本地测试，不应直接对外发布。"
    fi

    echo "💿 DMG: $dmg_path"
}

rm -rf ./MacSystemMonitor ./MacSystemMonitor.app ./MacTaskManager ./MacTaskManager.app

if [ "${1:-}" = "dmg" ]; then
    ARCH_TARGET="${2:-all}"
    DIST_DIR="./dist"
    mkdir -p "$DIST_DIR"

    if [ "$ARCH_TARGET" = "all" ] || [ "$ARCH_TARGET" = "arm64" ]; then
        build_app_bundle "arm64" "./$APP_NAME.app"
        VERSIONED_ARM64="$DIST_DIR/$APP_NAME-v$APP_VERSION-$BETA_TAG-arm64.dmg"
        PLAIN_ARM64="$DIST_DIR/$APP_NAME-arm64.dmg"
        create_dmg_package "./$APP_NAME.app" "$VERSIONED_ARM64"
        cp -f "$VERSIONED_ARM64" "$PLAIN_ARM64"
        cp -f "$VERSIONED_ARM64" "$DIST_DIR/$APP_NAME.dmg"
    fi

    if [ "$ARCH_TARGET" = "all" ] || [ "$ARCH_TARGET" = "x64" ] || [ "$ARCH_TARGET" = "x86_64" ]; then
        X64_APP_DIR="./$APP_NAME-x64.app"
        build_app_bundle "x86_64" "$X64_APP_DIR"
        VERSIONED_X64="$DIST_DIR/$APP_NAME-v$APP_VERSION-$BETA_TAG-x64.dmg"
        PLAIN_X64="$DIST_DIR/$APP_NAME-x64.dmg"
        create_dmg_package "$X64_APP_DIR" "$VERSIONED_X64"
        cp -f "$VERSIONED_X64" "$PLAIN_X64"
        rm -rf "$X64_APP_DIR"
    fi

    echo ""
    echo "🎉 所有指定架构 DMG 打包完成！输出文件如下："
    ls -lh "$DIST_DIR"/*.dmg
    exit 0
fi

# 默认构建本机架构
build_app_bundle "arm64" "./$APP_NAME.app"

echo "✅ 编译完成"
echo ""
echo "运行: ./$APP_NAME"
echo "应用: open $APP_NAME.app"
echo ""

if [ "${1:-}" = "run" ]; then
    # Reuse the existing application instance. `open -n` launches multiple
    # copies of the same bundle, which creates competing status-bar items.
    open "./$APP_NAME.app"
fi
