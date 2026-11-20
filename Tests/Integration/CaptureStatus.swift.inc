
// Compiled in the same file as the unmodified production classes so the fixture
// can exercise the private SCStream delegate and inspect its serialized cache.
private extension FramePublisher {
    func checkFollowing(_ id: UUID?, hasFrame: Bool) {
        worker.sync {
            precondition(admission.withLock { sourceID == id })
            precondition(hasSourceFrame == hasFrame)
        }
    }

    func checkState(width: Int?, retired expectedRetired: Bool = false) {
        worker.sync {
            precondition(latest?.texture.width == width, "Wrong cached image")
            precondition((timer != nil) == (width != nil), "Wrong clock state")
            precondition(retired == expectedRetired, "Wrong retirement state")
        }
    }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

// Scope the substitute to this test file. No window list is read or requested.
@MainActor private struct SCShareableContent {
    let windows: [SCWindow] = []
    let displays: [SCDisplay] = []
    static var enumerationError: NSError?
    static func excludingDesktopWindows(_ excluded: Bool, onScreenWindowsOnly: Bool) async throws -> Self {
        if let enumerationError { throw enumerationError }
        return Self()
    }
}

private extension CaptureManager {
    func simulateInterruptedManualSource() {
        retryManualSelection = (.window(123), 456)
    }
}

@main
private enum CaptureStatusFixture {
    nonisolated static func sample(_ status: SCFrameStatus, width: Int) -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let props = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                     kCVPixelBufferMetalCompatibilityKey as String: true] as [String: Any]
        precondition(CVPixelBufferCreate(nil, width, 16, kCVPixelFormatType_32BGRA,
                                         props as CFDictionary, &buffer) == kCVReturnSuccess)
        let image = buffer!
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image)!, Int32(width), CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        let format = try! CMVideoFormatDescription(imageBuffer: image)
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        let frame = try! CMSampleBuffer(imageBuffer: image, formatDescription: format, sampleTiming: timing)
        let key = CMSampleBuffer.PerSampleAttachmentsDictionary.Key(rawValue: SCStreamFrameInfo.status.rawValue as CFString)
        frame.sampleAttachments[0][key] = NSNumber(value: status.rawValue)
        return frame
    }

    static func followSwitch(device: MTLDevice, terminal: SCFrameStatus, detachFirst: Bool) {
        let streamA = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let streamB = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let idA = UUID(), idB = UUID()
        let ready = Counter(), ended = Counter()
        let name = "SyphonPub-QA-follow-status-" + UUID().uuidString
        let directory = SyphonServerDirectory.shared()
        let publisher = FramePublisher(device: device, serverName: name, frameRate: 30, continuous: true,
                                       previewLayer: nil, onFirstFrame: { preconditionFailure("False ready") })!
        func directoryIDs() -> [String] {
            directory.servers(matchingName: name, appName: nil).compactMap {
                $0[SyphonServerDescriptionUUIDKey] as? String
            }
        }
        func waitForAdvertisement(_ present: Bool) -> [String] {
            let timeout = Date().addingTimeInterval(3)
            while Date() < timeout {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                let ids = directoryIDs()
                if present ? ids.count == 1 : ids.isEmpty { return ids }
            }
            preconditionFailure("Unexpected advertised UUIDs: "+String(describing: directoryIDs()))
        }

        let outputA = CaptureOutput(publisher: publisher, followSource: idA,
                                    onWaitingFrameFailure: { preconditionFailure("Black A failed") },
                                    onEnd: { _ in ended.increment() })
        let outputB = CaptureOutput(publisher: publisher, followSource: idB,
                                    onWaitingFrameFailure: { preconditionFailure("Black B failed") },
                                    onEnd: { _ in ended.increment() })
        precondition(publisher.showWaitingFrame())
        let serverIDs = waitForAdvertisement(true)
        precondition(publisher.beginSource(idA, previewLayer: nil, onFirstFrame: { ready.increment() }))
        outputA.stream(streamA, didOutputSampleBuffer: sample(.started, width: 16), of: .screen)
        publisher.checkState(width: 16)
        publisher.checkFollowing(idA, hasFrame: true)
        if detachFirst {
            // Simulates the discovery loop detaching A before its delegate terminates.
            precondition(publisher.showWaitingFrame(after: idA))
        } else {
            outputA.stream(streamA, didOutputSampleBuffer: sample(terminal, width: 96), of: .screen)
        }
        publisher.checkState(width: 16)
        publisher.checkFollowing(nil, hasFrame: false)
        precondition(ready.count == 1)
        precondition(publisher.beginSource(idB, previewLayer: nil, onFirstFrame: { ready.increment() }))
        outputB.stream(streamB, didOutputSampleBuffer: sample(.complete, width: 32), of: .screen)
        publisher.checkState(width: 32)

        DispatchQueue.concurrentPerform(iterations: 64) { i in
            switch i % 3 {
            case 0: outputA.stream(streamA, didOutputSampleBuffer: sample(.complete, width: 128), of: .screen)
            case 1: outputA.stream(streamA, didOutputSampleBuffer: sample(terminal, width: 64), of: .screen)
            default: outputA.streamDidBecomeInactive(streamA)
            }
        }
        publisher.checkState(width: 32)
        publisher.checkFollowing(idB, hasFrame: true)
        precondition(ready.count == 2 && ended.count == 1 && directoryIDs() == serverIDs)
        publisher.stop()
        outputB.stream(streamB, didStopWithError: NSError(domain: "test", code: -1))
        outputB.stream(streamB, didOutputSampleBuffer: sample(.complete, width: 256), of: .screen)
        outputA.streamDidBecomeInactive(streamA)
        precondition(ready.count == 2 && ended.count == 2)
        publisher.checkState(width: nil, retired: true)
        precondition(!publisher.beginSource(UUID(), previewLayer: nil, onFirstFrame: {}))
        precondition(waitForAdvertisement(false).isEmpty)
        print("PASS follow status=\(terminal.rawValue) detachFirst=\(detachFirst) A -> black -> B, 64 late callbacks, same UUID, user stop retired")
    }

    static func keynoteResume(device: MTLDevice) {
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let id = UUID(), next = UUID()
        let pauses = Counter(), ready = Counter(), ends = Counter()
        let publisher = FramePublisher(device: device, serverName: "SyphonPub-QA-pause-" + UUID().uuidString,
                                       frameRate: 30, continuous: true, previewLayer: nil, onFirstFrame: {})!
        precondition(publisher.showWaitingFrame())
        precondition(publisher.beginSource(id, previewLayer: nil, onFirstFrame: { ready.increment() }))
        let output = CaptureOutput(publisher: publisher, followSource: id,
                                   onWaitingFrameFailure: { preconditionFailure("failed to publish black") },
                                   onTemporaryPause: { pauses.increment() }, onEnd: { _ in ends.increment() })
        func deliver(_ status: SCFrameStatus, _ width: Int = 32) {
            output.stream(stream, didOutputSampleBuffer: sample(status, width: width), of: .screen)
        }
        deliver(.suspended)
        precondition(!publisher.sourceHasFrame(id) && pauses.count == 0)
        deliver(.complete)
        deliver(.idle)
        precondition(publisher.sourceHasFrame(id) && ready.count == 1 && pauses.count == 0)
        deliver(.suspended)
        deliver(.blank)
        deliver(.idle)
        publisher.checkFollowing(id, hasFrame: false)
        precondition(pauses.count == 1 && ends.count == 0)
        deliver(.complete, 64)
        publisher.checkState(width: 64)
        precondition(publisher.sourceHasFrame(id) && ready.count == 2)
        deliver(.blank)
        deliver(.started, 16)
        publisher.checkState(width: 16)
        precondition(publisher.sourceHasFrame(id) && ready.count == 3 && pauses.count == 2)
        output.streamDidBecomeInactive(stream)
        publisher.checkFollowing(nil, hasFrame: false)
        precondition(ends.count == 1 && !publisher.sourceHasFrame(id))
        precondition(publisher.beginSource(next, previewLayer: nil, onFirstFrame: { ready.increment() }))
        publisher.submit(sample(.complete, width: 96), source: next)
        deliver(.suspended)
        deliver(.complete)
        deliver(.stopped)
        publisher.checkState(width: 96)
        precondition(publisher.sourceHasFrame(next) && ready.count == 4 && pauses.count == 2 && ends.count == 1)
        publisher.stop()
        print("PASS Keynote idle, suspended/blank, bounded pause callbacks, resume on same token, close, stale events after handover")
    }

    static func main() async {
        let domain = SCStreamError.errorDomain
        let manager = CaptureManager()
        manager.automaticallyFollowsShows = false
        for (errorDomain, code, denied) in [
            (domain, SCStreamError.Code.userDeclined.rawValue, true),
            (domain, SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue, false),
            (domain, SCStreamError.Code.noWindowList.rawValue, false),
            (NSCocoaErrorDomain, SCStreamError.Code.userDeclined.rawValue, false)
        ] {
            SCShareableContent.enumerationError = NSError(domain: errorDomain, code: code)
            await manager.refreshSources()
            precondition(manager.permissionDenied == denied)
            precondition(manager.lastError?.contains(errorDomain) == true && manager.lastError?.contains(String(code)) == true)
        }
        SCShareableContent.enumerationError = nil
        manager.simulateInterruptedManualSource()
        await manager.retryCaptureAccess()
        precondition(!manager.isCapturing && !manager.permissionDenied && manager.selectedSource == nil &&
                     manager.lastError?.contains("重新选择") == true)
        print("PASS retry dropped a missing manual source instead of capturing a stale window")
        print("PASS explicit ScreenCaptureKit denial is distinct from interruption, missing windows and foreign error domains")
        checkGPUCallbacks()
    }

    static func checkGPUCallbacks() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("No Metal device available\n", stderr)
            exit(69)
        }
        _ = NSApplication.shared
        // Empty filter; never attach an output or start this stream.
        let stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        let cases: [(SCFrameStatus, Bool)] = [(.blank, false), (.suspended, false),
                                              (.stopped, false), (.stopped, true)]
        for (terminal, raceFirstStop) in cases {
            let first = Counter()
            let ends = Counter()
            let publisher = FramePublisher(device: device, serverName: "SyphonPub-QA-status-" + UUID().uuidString,
                                           frameRate: 30, continuous: true, previewLayer: nil,
                                           onFirstFrame: { first.increment() })!
            let output = CaptureOutput(publisher: publisher, onEnd: { _ in ends.increment() })
            let started = sample(.started, width: 16)
            let complete = sample(.complete, width: 32)
            let idle = sample(.idle, width: 64)
            let end = sample(terminal, width: 96)
            output.stream(stream, didOutputSampleBuffer: idle, of: .screen)
            publisher.checkState(width: nil)
            output.stream(stream, didOutputSampleBuffer: started, of: .screen)
            publisher.checkState(width: 16)
            output.stream(stream, didOutputSampleBuffer: complete, of: .screen)
            publisher.checkState(width: 32)
            output.stream(stream, didOutputSampleBuffer: idle, of: .screen)
            publisher.checkState(width: 32)
            precondition(first.count == 1 && ends.count == 0)

            if !raceFirstStop {
                output.stream(stream, didOutputSampleBuffer: end, of: .screen)
                publisher.checkState(width: nil, retired: true)
                precondition(ends.count == 1)
            }
            DispatchQueue.concurrentPerform(iterations: 64) { i in
                switch i % 4 {
                case 0: output.stream(stream, didOutputSampleBuffer: sample(.complete, width: 128), of: .screen)
                case 1: output.stream(stream, didOutputSampleBuffer: sample(terminal, width: 96), of: .screen)
                case 2: output.stream(stream, didStopWithError: NSError(domain: "test", code: -1))
                default: publisher.stop()
                }
            }
            publisher.checkState(width: nil, retired: true)
            precondition(first.count == 1 && ends.count == 1)
            print("PASS status=\(terminal.rawValue) raceFirstStop=\(raceFirstStop) + 64 concurrent callbacks and stops")
        }
        followSwitch(device: device, terminal: .stopped, detachFirst: false)
        followSwitch(device: device, terminal: .blank, detachFirst: false)
        followSwitch(device: device, terminal: .stopped, detachFirst: true)
        keynoteResume(device: device)
    }
}
