// Test-only deterministic injection point immediately after screen capture.
// Input changes ONLY when a command is received. No desktop or user data is captured.
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Metal

private func page(width: Int, height: Int, alternate: Bool) -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey: true
    ]
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                     attrs as CFDictionary, &buffer) == kCVReturnSuccess)
    let image = buffer!
    CVPixelBufferLockBaseAddress(image, [])
    let base = CVPixelBufferGetBaseAddress(image)!
    for y in 0..<height {
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(image))
        let color: UInt32 = alternate ? (y < height/2 ? 0xff0000ff : 0xffff00ff)
                                      : (y < height/2 ? 0xffff0000 : 0xff00ff00)
        row.assumingMemoryBound(to: UInt32.self).initialize(repeating: color, count: width)
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    var format: CMVideoFormatDescription?
    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                             formatDescriptionOut: &format) == noErr)
    var t = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                               presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                               decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
                                                         formatDescription: format!, sampleTiming: &t,
                                                         sampleBufferOut: &sample) == noErr)
    return sample!
}

private final class ReadyCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() { lock.withLock { count += 1 } }
    func expect(_ expected: Int) { precondition(lock.withLock { count } == expected) }
}

@main
struct Sender {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("SyphonPub-QA-"),
              let device = MTLCreateSystemDefaultDevice() else {
            fputs("Metal device unavailable or invalid QA name\n", stderr)
            exit(69)
        }
        _ = NSApplication.shared
        let name = CommandLine.arguments[1]
        #if BASELINE
        let output = OriginalFixture(name: name)
        #else
        let sourceA = UUID(), sourceB = UUID()
        let ready = ReadyCount()
        guard let output = FramePublisher(device: device, serverName: name, frameRate: 30, continuous: true,
                                          previewLayer: AVSampleBufferDisplayLayer(), onFirstFrame: { ready.record() }) else { exit(70) }
        #endif
        let stdinQueue = DispatchQueue(label: "test.input")
        stdinQueue.async {
            while let line = readLine() {
                DispatchQueue.main.async {
                    switch line {
                    case "page": output.submit(page(width: 1280, height: 720, alternate: false))
                    case "resized": output.submit(page(width: 960, height: 540, alternate: true))
                    #if !BASELINE
                    case "wait":
                        precondition(output.showWaitingFrame())
                        ready.expect(0)
                    case "attachA":
                        precondition(output.beginSource(sourceA, previewLayer: AVSampleBufferDisplayLayer(),
                                                        onFirstFrame: { ready.record() }))
                    case "pageA", "lateA":
                        output.submit(page(width: 1280, height: 720, alternate: false), source: sourceA)
                    case "endA":
                        precondition(output.showWaitingFrame(after: sourceA))
                    case "attachB":
                        precondition(output.beginSource(sourceB, previewLayer: AVSampleBufferDisplayLayer(),
                                                        onFirstFrame: { ready.record() }))
                        ready.expect(1)
                    case "pageB":
                        output.submit(page(width: 960, height: 540, alternate: true), source: sourceB)
                    case "endB":
                        precondition(output.showWaitingFrame(after: sourceB))
                    case "verifyB":
                        ready.expect(2)
                    case "60": output.configure(frameRate: 60, continuous: true)
                    case "off": output.configure(frameRate: 30, continuous: false)
                    case "on": output.configure(frameRate: 30, continuous: true)
                    #endif
                    case "stop": output.stop()
                    case "quit": output.stop(); exit(0)
                    default: exit(64)
                    }
                    print("OK " + line)
                    fflush(stdout)
                }
            }
            DispatchQueue.main.async { output.stop(); exit(0) }
        }
        print("READY")
        fflush(stdout)
        RunLoop.main.run()
    }
}
