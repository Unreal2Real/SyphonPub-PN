import Foundation
import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo
import Metal
import Syphon

/// Owns one Syphon server. Automatic follow keeps it alive across capture
/// streams. The admission lock protects stream identity and the one-slot mailbox;
/// the serial worker owns output, preview, and all GPU resources.
nonisolated final class FramePublisher: @unchecked Sendable {
    private let worker = DispatchQueue(label: "local.syphonpub.frame-publisher",
                                       qos: .userInteractive, autoreleaseFrequency: .workItem)
    private let admission = NSLock()
    private var accepting = true
    private var sourceID: UUID?
    private var followsSources = false
    private var pending: CMSampleBuffer?
    private var drainScheduled = false

    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private let server: SyphonMetalServer
    private var previewLayer: AVSampleBufferDisplayLayer?
    private var onFirstFrame: (@Sendable () -> Void)?

    private var retired = false
    private var latest: Frame?
    private var hasSourceFrame = false
    private var timer: DispatchSourceTimer?
    private var frameRate: Int
    private var continuous: Bool
    private var previewPool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    private struct Frame {
        let texture: MTLTexture
        // Keep the owned buffer checked out of the pool as long as it is cached.
        let pixels: CVPixelBuffer?
    }

    init?(device: MTLDevice, serverName: String, frameRate: Int, continuous: Bool,
          previewLayer: AVSampleBufferDisplayLayer?, onFirstFrame: @escaping @Sendable () -> Void) {
        guard let commands = device.makeCommandQueue() else { return nil }
        // The ObjC header assumes nonnull, but documents a failable initializer.
        let candidate: SyphonMetalServer? = SyphonMetalServer(name: serverName, device: device, options: nil)
        guard let server = candidate else { return nil }
        self.device = device
        self.commands = commands
        self.server = server
        self.frameRate = max(1, frameRate)
        self.continuous = continuous
        self.previewLayer = previewLayer
        self.onFirstFrame = onFirstFrame
    }

    // The SCStreamOutput wrapper filters statuses; metadata-only samples never
    // replace a real frame, even when called directly by the integration probe.
    func submit(_ sample: CMSampleBuffer, source: UUID? = nil) {
        guard sample.isValid, sample.dataReadiness == .ready,
              let pixels = sample.imageBuffer,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixels) > 0, CVPixelBufferGetHeight(pixels) > 0,
              CVPixelBufferGetIOSurface(pixels) != nil else { return }
        admission.withLock {
            guard accepting, sourceID == source, !followsSources || source != nil else { return }
            pending = sample
            if !drainScheduled {
                drainScheduled = true
                worker.async { [weak self] in self?.drain() }
            }
        }
    }

    private func drain() {
        let sample = admission.withLock {
            let next = pending
            pending = nil
            drainScheduled = false
            return next
        }
        if let sample { capture(sample) }
    }

    func configure(frameRate: Int, continuous: Bool) {
        worker.sync {
            guard admission.withLock({ accepting }) else { return }
            self.frameRate = max(1, frameRate)
            self.continuous = continuous
            updateClock()
        }
    }

    /// Attaches only from the waiting state. Each stream gets its own preview
    /// layer so a late renderer flush cannot remove the next show's first image.
    func beginSource(_ id: UUID, previewLayer: AVSampleBufferDisplayLayer?,
                     onFirstFrame: @escaping @Sendable () -> Void) -> Bool {
        worker.sync {
            let attached = admission.withLock {
                guard accepting, followsSources, sourceID == nil, latest != nil else { return false }
                sourceID = id
                return true
            }
            guard attached else { return false }
            self.previewLayer = previewLayer
            self.onFirstFrame = onFirstFrame
            return true
        }
    }

    func sourceHasFrame(_ id: UUID) -> Bool {
        worker.sync {
            hasSourceFrame && admission.withLock { accepting && sourceID == id }
        }
    }

    /// A temporarily suspended stream may resume on the same window. Drop the
    /// picture, but keep its token and first-frame callback for that next image.
    func pauseSource(_ id: UUID, onPause: @Sendable () -> Void) -> Bool {
        worker.sync {
            let current = admission.withLock {
                guard accepting, sourceID == id else { return false }
                pending = nil
                return true
            }
            guard current, hasSourceFrame else { return true }
            guard publishWaitingFrame() else { return false }
            onPause()
            return true
        }
    }

    /// Publishes opaque black immediately; this slate is never counted as a
    /// captured frame. Passing the ending stream's ID makes late terminal
    /// callbacks harmless. On allocation/submission failure the owner must stop.
    @discardableResult
    func showWaitingFrame(after id: UUID? = nil) -> Bool {
        worker.sync {
            guard !retired else { return id != nil }
            let reset = admission.withLock {
                guard accepting, sourceID == id else { return false }
                followsSources = true
                sourceID = nil
                pending = nil
                return true
            }
            guard reset else { return true } // Already replaced or stopped.
            onFirstFrame = nil
            previewLayer = nil
            previewPool = nil
            if !hasSourceFrame, latest != nil { return true }
            return publishWaitingFrame()
        }
    }

    private func publishWaitingFrame() -> Bool {
        let width = latest?.texture.width ?? 1280
        let height = latest?.texture.height ?? 720
        hasSourceFrame = false
        latest = nil
        timer?.cancel()
        timer = nil
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let image = device.makeTexture(descriptor: descriptor),
              let command = commands.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = image
        color.loadAction = .clear
        color.storeAction = .store
        color.clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.endEncoding()
        let black = Frame(texture: image, pixels: nil)
        publish(black, on: command)
        finish(command)
        guard command.status == .completed else { return false }
        latest = black
        updateClock()
        return true
    }

    // Called from the session owner, never from the worker. Commands complete
    // on the worker before it returns, including Syphon's notification handler.
    func stop() {
        admission.withLock {
            accepting = false
            pending = nil
        }
        worker.sync {
            guard !retired else { return }
            retired = true
            timer?.cancel()
            timer = nil
            latest = nil
            previewPool = nil
            server.stop()
        }
    }

    private func updateClock() {
        timer?.cancel()
        timer = nil
        guard continuous, latest != nil else { return }
        let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / frameRate)
        let clock = DispatchSource.makeTimerSource(queue: worker)
        clock.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        clock.setEventHandler { [weak self] in
            guard let self, self.continuous, let frame = self.latest,
                  let command = self.commands.makeCommandBuffer() else { return }
            self.publish(frame, on: command)
            self.finish(command)
        }
        timer = clock
        clock.resume()
    }

    private func capture(_ sample: CMSampleBuffer) {
        guard let sourcePixels = sample.imageBuffer, let source = texture(for: sourcePixels),
              let frame = destination(width: source.width, height: source.height),
              let command = commands.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: frame.texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let first = !hasSourceFrame
        if first || !continuous { publish(frame, on: command) }
        // Keep the ScreenCaptureKit lease until the GPU actually reads the
        // pixels. Do not use the system buffer as an idle cache or preview.
        withExtendedLifetime(sample) { finish(command) }
        guard command.status == .completed else { return }
        latest = frame
        if let pixels = frame.pixels {
            preview(pixels, copiedFrom: sample)
        }
        if first {
            hasSourceFrame = true
            updateClock()
            onFirstFrame?()
        }
    }

    private func finish(_ command: MTLCommandBuffer) {
        command.commit()
        // Only this dedicated worker waits. This bounds in-flight GPU work to
        // one and serializes Syphon's completion-time surface change on resize.
        command.waitUntilCompleted()
    }

    private func publish(_ frame: Frame, on command: MTLCommandBuffer) {
        let image = frame.texture
        server.publishFrameTexture(image, on: command,
                                   imageRegion: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                                   flipped: true)
    }

    private func texture(for pixels: CVPixelBuffer) -> MTLTexture? {
        guard let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: CVPixelBufferGetWidth(pixels),
            height: CVPixelBufferGetHeight(pixels), mipmapped: false)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }

    private func destination(width: Int, height: Int) -> Frame? {
        if previewLayer != nil, let pixels = previewBuffer(width: width, height: height),
           let texture = texture(for: pixels) {
            return Frame(texture: texture, pixels: pixels)
        }
        // A busy preview must not hold up the Syphon feed. Without a preview
        // the sole private texture can be reused after the preceding GPU fence.
        if hasSourceFrame, let latest, latest.pixels == nil, latest.texture.width == width,
           latest.texture.height == height { return latest }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .shaderRead
        return device.makeTexture(descriptor: descriptor).map { Frame(texture: $0, pixels: nil) }
    }

    private func previewBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if size != poolSize || previewPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            previewPool = nil
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &previewPool) == kCVReturnSuccess
            else { return nil }
            poolSize = size
        }
        guard let previewPool else { return nil }
        var pixels: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, previewPool, limit, &pixels)
        if result == kCVReturnWouldExceedAllocationThreshold {
            // Discard queued preview frames in favor of the most recent sample.
            previewLayer?.sampleBufferRenderer.flush()
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, previewPool, limit, &pixels)
        }
        return pixels
    }

    private func preview(_ pixels: CVPixelBuffer, copiedFrom sample: CMSampleBuffer) {
        guard let renderer = previewLayer?.sampleBufferRenderer, let source = sample.imageBuffer else { return }
        CVBufferRemoveAllAttachments(pixels)
        CVBufferPropagateAttachments(source, pixels)
        // The cache may have a different row stride from ScreenCaptureKit.
        // Describe the copied pixels and their propagated color attachments.
        var outputFormat: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                    formatDescriptionOut: &outputFormat) == noErr, let format = outputFormat else { return }
        var timing = CMSampleTimingInfo(duration: sample.duration,
                                        presentationTimeStamp: sample.presentationTimeStamp,
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
                    formatDescription: format, sampleTiming: &timing, sampleBufferOut: &copy) == noErr,
              let copy else { return }
        copy.sampleAttachments[0][.displayImmediately] = true
        if renderer.status == .failed || !renderer.isReadyForMoreMediaData { renderer.flush() }
        renderer.enqueue(copy)
    }
}
