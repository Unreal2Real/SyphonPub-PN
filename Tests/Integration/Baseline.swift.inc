// Test-only adapter appended to the unmodified v1.2 manager at compile time.
// The constructed stream is never started. Only its original output callback is invoked.
extension CaptureManager {
    fileprivate func prepareFixture(_ name: String) {
        syphonServer = SyphonMetalServer(name: name, device: metalDevice, options: nil)
    }
    fileprivate func endFixture() { syphonServer?.stop() }
}
@MainActor
final class OriginalFixture {
    let manager = CaptureManager()
    let stream: SCStream

    init(name: String) {
        stream = SCStream(filter: SCContentFilter(), configuration: SCStreamConfiguration(), delegate: nil)
        manager.prepareFixture(name)
    }
    func submit(_ sample: CMSampleBuffer) {
        manager.stream(stream, didOutputSampleBuffer: sample, of: .screen)
    }
    func stop() { manager.endFixture() }
}
