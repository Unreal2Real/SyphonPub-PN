#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
out=build/probes/automation-consent
mkdir -p "$out"
cat SyphonCapture/ShowAutomationAuthorizer.swift Tests/Integration/AutomationConsentProbe.swift.inc > "$out/ConsentProbe.swift"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -module-cache-path build/ModuleCache -target arm64-apple-macosx14.6 \
    SyphonCapture/ShowDetection.swift "$out/ConsentProbe.swift" -o "$out/probe"
"$out/probe"
