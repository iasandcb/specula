#!/bin/zsh
set -eu
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TASK_BUILD=/tmp/macremote-helper-build
TASK_APP="$PWD/Build/Mac Remote Display.app"
xcrun swift build --disable-sandbox -c release --product MacDisplayHelper --scratch-path "$TASK_BUILD"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BUILD/out/Products/Release/MacDisplayHelper" "$TASK_APP/Contents/MacOS/MacDisplayHelper"
cp Design/MacDisplayHelper.icns "$TASK_APP/Contents/Resources/AppIcon.icns"
cat > "$TASK_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.alex.MacRemote.Display</string>
<key>CFBundleName</key><string>Mac Remote Display</string>
<key>CFBundleDisplayName</key><string>Mac Remote Display</string>
<key>CFBundleExecutable</key><string>MacDisplayHelper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>아이폰에서 맥 화면 해상도를 변경하고 접속 종료 시 복원하기 위해 연결합니다.</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$TASK_APP"
printf 'Built: %s\n' "$TASK_APP"
