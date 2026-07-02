#!/bin/bash
# 构建脚本 - 编译并运行 MacSystemMonitor

set -euo pipefail

cd "$(dirname "$0")"

echo "🔨 正在编译 MacSystemMonitor..."

if ! swift build -c release; then
    cat <<EOF
❌ 编译失败。

当前 xcode-select:
   $(xcode-select -p)

如果错误里出现 SwiftUIMacros，请安装完整 Xcode，或切换到完整 Xcode 工具链:
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

EOF
    exit 1
fi

BIN_PATH="$(swift build -c release --show-bin-path)/MacSystemMonitor"
cp "$BIN_PATH" ./MacSystemMonitor

APP_DIR="./MacSystemMonitor.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/MacSystemMonitor"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>系统监视器</string>
    <key>CFBundleExecutable</key>
    <string>MacSystemMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>local.MacSystemMonitor</string>
    <key>CFBundleName</key>
    <string>MacSystemMonitor</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "✅ 编译完成"
echo ""
echo "运行: ./MacSystemMonitor"
echo "应用: open MacSystemMonitor.app"
echo ""

# 如果传入 run 参数则直接运行
if [ "${1:-}" = "run" ]; then
    open -n "$APP_DIR"
fi
