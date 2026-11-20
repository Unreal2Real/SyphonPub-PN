#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
scripts/build-local.zsh --sdk-only
out=build/probes
mkdir -p "$out"
cat SyphonCapture/FramePublisher.swift SyphonCapture/CaptureManager.swift \
    Tests/Integration/CaptureStatus.swift.inc > "$out/CaptureStatus.swift"
xcrun swiftc -O -parse-as-library -swift-version 5 -default-isolation MainActor \
    -target arm64-apple-macosx14.6 -module-cache-path "$out/swift-cache" -F build/SDK \
    -Xlinker -rpath -Xlinker @loader_path/../../Vendor/SyphonSDK \
    SyphonCapture/PowerPointShowLocator.swift SyphonCapture/ShowDetection.swift SyphonCapture/ShowAutomationAuthorizer.swift SyphonCapture/KeynoteShowLocator.swift SyphonCapture/PresentationFollowSession.swift "$out/CaptureStatus.swift" -o "$out/capture-status"
"$out/capture-status"
