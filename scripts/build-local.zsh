#!/bin/zsh
# Build the Apple silicon distribution with Apple's Command Line Tools.
set -euo pipefail
cd "${0:A:h:h}"
name="SyphonPub PN"
version="1.4.4"
revision="31"
archive="SyphonPub-PN-$version-macOS-arm64.zip"
vendor=Vendor/SyphonSDK
runtime="$PWD/$vendor/Syphon.framework"
sdkfw=build/SDK/Syphon.framework

if [[ $# -gt 1 || ( $# == 1 && $1 != --sdk-only ) ]]; then
    print -u2 -- "Usage: scripts/build-local.zsh [--sdk-only]"
    exit 2
fi

# The distribution runtime must stay sealed. Expose its public headers to
# swiftc in a separate framework layout, then embed the original runtime.
(cd "$vendor" && shasum -a 256 --quiet -c SHA256SUMS)
codesign --verify --strict --deep "$runtime"
mkdir -p "$sdkfw/Headers" "$sdkfw/Modules" build/ModuleCache
ln -sfn "$runtime/Syphon" "$sdkfw/Syphon"
cp "$vendor"/Headers/*.h "$sdkfw/Headers/"
cp "$vendor/Syphon.modulemap" "$sdkfw/Modules/module.modulemap"
[[ ${1:-} != --sdk-only ]] || exit 0

# Sign outside iCloud Documents, whose File Provider may add FinderInfo to new
# bundles between creation and signing. Keep the source application read-only.
stage=$(mktemp -d "${TMPDIR:-/private/tmp}/syphon-package.XXXXXX")
trap 'rm -r -- "$stage"' EXIT
bundle="$stage/$name.app/Contents"
mkdir -p "$bundle/MacOS" "$bundle/Frameworks" "$bundle/Resources"
ditto --noextattr --norsrc "$runtime" "$bundle/Frameworks/Syphon.framework"
cp -X "$vendor/Resources/AppIcon.icns" "$vendor/Resources/Assets.car" LICENSE Licenses/Syphon-Framework.txt "$bundle/Resources/"
# Swift 5 language mode with the same default main-actor isolation as the Xcode target.
xcrun --sdk macosx swiftc -swift-version 5 -default-isolation MainActor \
    -target arm64-apple-macosx14.6 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -module-name SyphonPubPN -module-cache-path "$PWD/build/ModuleCache" \
    -parse-as-library -whole-module-optimization -O -F "$PWD/build/SDK" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    MenuBarMenuView.swift SyphonCapture/*.swift -o "$bundle/MacOS/$name"

cat > "$bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIdentifier</key><string>local.syphonpub.show-follow-test</string>
    <key>CFBundleDisplayName</key><string>$name</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundleVersion</key><string>$revision</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSAppleEventsUsageDescription</key><string>自动跟随放映时，读取 PowerPoint 和 Keynote 的放映状态，识别观众画面并输出到 QLab。</string>
    <key>LSMinimumSystemVersion</key><string>14.6</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none --entitlements SyphonCapture/SyphonCapture.entitlements "${bundle:h}"
codesign --verify --strict --deep "${bundle:h}"
# The archive also supports installation from iCloud without provider metadata.
ditto -c -k --keepParent --norsrc "${bundle:h}" "$stage/$name.zip"
mkdir "$stage/check"
ditto -x -k "$stage/$name.zip" "$stage/check"
codesign --verify --strict --deep "$stage/check/$name.app"
mv -f -- "$stage/$name.zip" "build/$archive"
print -- "$PWD/build/$archive"
