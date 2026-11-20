#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
out=build/probes/powerpoint-locator
mkdir -p "$out"
cat SyphonCapture/PowerPointShowLocator.swift Tests/Integration/PowerPointLocatorProbe.swift.inc > "$out/LocatorProbe.swift"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -module-cache-path build/ModuleCache -target arm64-apple-macosx14.6 \
    SyphonCapture/ShowDetection.swift "$out/LocatorProbe.swift" -o "$out/locator-probe"
"$out/locator-probe" "$@"
