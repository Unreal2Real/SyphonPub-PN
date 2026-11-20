#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=build/probes
sdk=build/SDK
vendor_rpath='@loader_path/../../Vendor/SyphonSDK'
client_rpath="$vendor_rpath"
baseline=false

for option in "$@"; do
    case "$option" in
        --qlab-receiver)
            client_rpath=/Applications/QLab.app/Contents/Frameworks
            if [[ ! -f "$client_rpath/Syphon.framework/Syphon" ]]; then
                echo "QLab's Syphon.framework was not found in /Applications/QLab.app" >&2
                exit 1
            fi
            ;;
        --with-baseline)
            if ! git cat-file -e 'v1.2:SyphonCapture/CaptureManager.swift' 2>/dev/null; then
                echo "The optional baseline requires the upstream SyphonPub v1.2 tag." >&2
                exit 1
            fi
            baseline=true
            ;;
        *)
            echo "Usage: Tests/Integration/build-probes.sh [--qlab-receiver] [--with-baseline]" >&2
            exit 2
            ;;
    esac
done

scripts/build-local.zsh --sdk-only
mkdir -p "$out"
# Always compile against the shipped headers. QLab interoperability can be
# tested by loading its framework in the independent receiver process only.
client=(-fobjc-arc -mmacosx-version-min=14.6 -F "$sdk"
        -framework AppKit -framework Metal -framework Syphon "-Wl,-rpath,$client_rpath")
xcrun clang "${client[@]}" Tests/Integration/Receiver.m -o "$out/receiver"
xcrun clang "${client[@]}" Tests/Integration/ObserveAudience.m -o "$out/observe-audience"
xcrun clang "${client[@]}" -framework ScreenCaptureKit -framework CoreGraphics -framework CoreVideo \
    -framework CoreMedia Tests/Integration/KeynoteFixturePixels.m -o "$out/keynote-fixture-pixels"

common=(-O -swift-version 5 -parse-as-library -module-cache-path "$out/swift-cache"
        -target arm64-apple-macosx14.6 -F "$sdk" -Xlinker -rpath -Xlinker "$vendor_rpath")
xcrun swiftc "${common[@]}" SyphonCapture/FramePublisher.swift Tests/Integration/Sender.swift -o "$out/continuous"
if [[ "$baseline" == true ]]; then
    git show v1.2:SyphonCapture/CaptureManager.swift > "$out/Original.swift"
    cat Tests/Integration/Baseline.swift.inc >> "$out/Original.swift"
    xcrun swiftc "${common[@]}" -DBASELINE "$out/Original.swift" Tests/Integration/Sender.swift -o "$out/original"
fi
