#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
out=build/probes/keynote-locator
mkdir -p "$out"
cat SyphonCapture/KeynoteShowLocator.swift Tests/Integration/KeynoteLocatorProbe.swift.inc > "$out/LocatorProbe.swift"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -module-cache-path build/ModuleCache -target arm64-apple-macosx14.6 \
    SyphonCapture/ShowDetection.swift "$out/LocatorProbe.swift" -o "$out/locator-probe"
"$out/locator-probe" "$@"
