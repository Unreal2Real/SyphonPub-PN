import AppKit
import AVFoundation
import Metal
import ScreenCaptureKit

/// A follow run owns one advertised server. Each audience window gets its own
/// stream, input token and preview. Only the polling loop may attach a stream.
@MainActor
final class PresentationFollowSession {
    static let serverName = "SyphonPub Show Follow — Audience"
    private let publisher: FramePublisher
    private let onState: (String, AVSampleBufferDisplayLayer?) -> Void
    private let onFailure: (CaptureIssue) async -> Void
    private let keynoteLocator = KeynoteShowLocator()
    private var activeKeynote: KeynoteAudienceBinding?
    private var fps: Int
    private var watcher: Task<Void, Never>?
    private var preferredApp = ShowApplication.powerPoint
    private var stopped = false
    private var inputID: UUID?
    private var windowID: CGWindowID?
    private var ownerPID: pid_t?
    private var presentationName: String?
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var preview: AVSampleBufferDisplayLayer?
    private var lastStreamError: String?
    private var inputEnded = false
    private var appliedSize = CGSize.zero
    private var appliedFPS = 0

    init?(device: MTLDevice, fps: Int,
          onState: @escaping (String, AVSampleBufferDisplayLayer?) -> Void,
          onFailure: @escaping (CaptureIssue) async -> Void) {
        guard let publisher = FramePublisher(device: device, serverName: Self.serverName,
                                             frameRate: fps, continuous: true, previewLayer: nil,
                                             onFirstFrame: {}) else { return nil }
        self.publisher = publisher
        self.fps = fps
        self.onState = onState
        self.onFailure = onFailure
    }

    func start() {
        onState("等待 PowerPoint 或 Keynote 放映", nil)
        watcher = Task { [weak self] in
            guard let self else { return }
            guard publisher.showWaitingFrame() else { await failOutput(); return }
            while !Task.isCancelled && !stopped {
                await inspectShow()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    func setFrameRate(_ newValue: Int) {
        fps = newValue
        publisher.configure(frameRate: fps, continuous: true)
    }

    func stop() async {
        stopped = true
        watcher?.cancel()
        watcher = nil
        keynoteLocator.cancelStandby()
        publisher.stop()
        await detach()
    }

    private func inspectShow() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard !stopped else { return }
            let result = await selectAudienceShow(first: preferredApp) { app in
                guard !self.stopped else { return ShowDetection<SCWindow>.idle }
                if ShowAutomationAuthorizer.shared.pending == app { return .needsPermission("等待系统授权读取 \(app.rawValue) 放映状态") }
                let detection = await self.locate(app, in: content)
                if case .window = detection { return detection }
                // Retire the old input before a query to the next app can stall.
                if !self.stopped, self.inputID != nil, self.preferredApp == app {
                    await self.waitForShow("正在等待观众窗口…")
                }
                return detection
            }
            guard !stopped else { return }
            switch result {
            case .waiting(let message):
                await waitForShow(message)
            case .window(let app, let window, let document):
                preferredApp = app
                if app == .powerPoint, ShowAutomationAuthorizer.shared.pending != .keynote {
                    keynoteLocator.observeEditorsDuringPowerPoint(in: content.windows)
                }
                let presentation = "\(app.rawValue) · \(document)"
                let binding = app == .keynote ? keynoteLocator.binding : nil
                // Only an active stream may use a previously verified hidden window.
                // It might have ended while Keynote answered the document query.
                let sameStream = windowID == window.windowID && ownerPID == window.owningApplication?.processID
                    && presentationName == presentation && !inputEnded && stream != nil
                if app == .keynote, !window.isOnScreen,
                   !(sameStream && activeKeynote != nil && binding?.documentID == activeKeynote?.documentID) {
                    await waitForShow("等待可确认的 Keynote 观众窗口…")
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let size = CaptureManager.pixelSize(of: filter)
                let changedDocument = binding != nil && activeKeynote != nil
                    && binding?.documentID != activeKeynote?.documentID
                if sameStream, !changedDocument, let stream {
                    activeKeynote = binding
                    guard size != appliedSize || fps != appliedFPS else { return }
                    let rate = fps
                    try await stream.updateConfiguration(CaptureManager.configuration(size: size, fps: rate))
                    appliedSize = size
                    appliedFPS = rate
                    return
                }
                if inputID != nil { await waitForShow("正在切换放映…") }
                guard !stopped, !Task.isCancelled else { return }
                activeKeynote = binding
                try await attach(window, presentation: presentation, filter: filter, size: size)
            }
        } catch {
            guard !stopped else { return }
            let issue = CaptureIssue("跟随捕捉失败", error: error)
            if issue.isScreenAccessDenied {
                await onFailure(issue)
            } else {
                await waitForShow(issue.message)
            }
        }
    }

    private func locate(_ app: ShowApplication, in content: SCShareableContent) async -> ShowDetection<SCWindow> {
        switch app {
        case .powerPoint:
            return await PowerPointShowLocator.locate(in: content.windows)
        case .keynote:
            return await keynoteLocator.locate(in: content.windows, displayFrames: content.displays.map(\.frame),
                                              continuing: inputEnded ? nil : activeKeynote)
        }
    }

    private func attach(_ window: SCWindow, presentation: String, filter: SCContentFilter, size: CGSize) async throws {
        let id = UUID()
        let layer = AVSampleBufferDisplayLayer()
        guard publisher.beginSource(id, previewLayer: layer, onFirstFrame: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped, self.inputID == id, !self.inputEnded,
                      self.publisher.sourceHasFrame(id), let preview = self.preview else { return }
                self.lastStreamError = nil
                self.onState("已就绪 · \(presentation)", preview)
            }
        }) else {
            await failOutput()
            return
        }
        var onPause: (@Sendable () -> Void)?
        if preferredApp == .keynote {
            onPause = { [weak self] in
                Task { @MainActor in
                    guard let self, self.inputID == id, !self.stopped, !self.inputEnded,
                          !self.publisher.sourceHasFrame(id) else { return }
                    self.reportWaiting("Keynote 暂停提供画面，等待放映恢复…")
                }
            }
        }
        let output = CaptureOutput(publisher: publisher, followSource: id,
            onWaitingFrameFailure: { [weak self] in
                Task { @MainActor in
                    guard let self, self.inputID == id, !self.stopped else { return }
                    await self.failOutput()
                }
            }, onTemporaryPause: onPause, onEnd: { [weak self] issue in
                Task { @MainActor in
                    guard let self, self.inputID == id, !self.stopped else { return }
                    self.inputEnded = true
                    if issue.isScreenAccessDenied {
                        await self.onFailure(issue)
                    } else {
                        if issue.isSystemError { self.lastStreamError = issue.message }
                        self.reportWaiting("等待下一场放映")
                    }
                }
            })
        let stream = SCStream(filter: filter, configuration: CaptureManager.configuration(size: size, fps: fps),
                              delegate: output)
        self.stream = stream
        self.output = output
        preview = layer
        inputID = id
        inputEnded = false
        presentationName = presentation
        windowID = window.windowID
        ownerPID = window.owningApplication?.processID
        appliedSize = size
        appliedFPS = fps
        reportWaiting("已找到观众窗口，等待首帧…")
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.sampleQueue)
        try await stream.startCapture()
        if stopped || inputID != id { try? await stream.stopCapture() }
    }

    private func waitForShow(_ message: String) async {
        if let id = inputID, !publisher.showWaitingFrame(after: id) {
            await failOutput()
            return
        }
        reportWaiting(message)
        await detach()
    }

    private func reportWaiting(_ message: String) {
        onState(lastStreamError.map { message + "\n" + $0 } ?? message, nil)
    }

    private func detach() async {
        let oldStream = stream
        let oldOutput = output
        inputID = nil
        windowID = nil
        ownerPID = nil
        activeKeynote = nil
        presentationName = nil
        stream = nil
        output = nil
        preview = nil
        if let oldStream {
            try? await oldStream.stopCapture()
            if let oldOutput { try? oldStream.removeStreamOutput(oldOutput, type: .screen) }
        }
    }

    private func failOutput() async {
        guard !stopped else { return }
        await onFailure(CaptureIssue("无法发布等待画面，跟随已停止。请重新 Start。"))
    }
}
