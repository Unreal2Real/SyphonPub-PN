import Foundation
import Combine
import AppKit
import ScreenCaptureKit
import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo
import Metal

/// Window titles that belong to system chrome rather than real app content.
private let systemWindowTitles: Set<String> = [
    "Menubar", "Menu Bar", "Dock", "Display Backstop",
    "Control Center", "Notification Center", "Desktop", "Backstop Menubar",
]

enum CaptureSource: Hashable {
    case window(CGWindowID)
    case display(CGDirectDisplayID)
}

/// Retain the error domain and code across the stream delegate queue.
nonisolated struct CaptureIssue: Sendable {
    let message: String
    let isScreenAccessDenied: Bool
    let isSystemError: Bool

    init(_ message: String) {
        self.message = message
        isScreenAccessDenied = false
        isSystemError = false
    }

    init(_ operation: String, error: Error) {
        let ns = error as NSError
        isScreenAccessDenied = ns.domain == SCStreamError.errorDomain &&
                               ns.code == SCStreamError.Code.userDeclined.rawValue
        isSystemError = true
        message = "\(operation) · \(ns.localizedDescription)（\(ns.domain) \(ns.code)）"
    }
}

@MainActor
class CaptureManager: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var availableWindows: [SCWindow] = []
    @Published var availableDisplays: [SCDisplay] = []
    @Published var selectedSource: CaptureSource? = nil
    @Published var automaticallyFollowsShows = true
    @Published private(set) var manualServerName: String?
    @Published private(set) var followStatus = "等待 PowerPoint 或 Keynote 放映"
    @Published var isLoading = false
    @Published var isCapturing = false
    @Published var permissionDenied = false
    @Published var lastError: String? = nil
    @Published var frameRate = 30 {
        didSet {
            guard frameRate != oldValue else { return }
            followSession?.setFrameRate(frameRate)
            output?.publisher.configure(frameRate: frameRate, continuous: continuousOutput)
            requestConfigurationUpdate()
        }
    }
    @Published var continuousOutput = true
    @Published private(set) var hasFrame = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var previewLayer = AVSampleBufferDisplayLayer()

    private var followSession: PresentationFollowSession?
    private let device = MTLCreateSystemDefaultDevice()
    private var sessionID: UUID?
    private var stream: SCStream?
    private var output: CaptureOutput?
    private var retryManualSelection: (source: CaptureSource, ownerPID: pid_t?)?
    private var monitor: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var desiredSize = CGSize.zero
    private var appliedSize = CGSize.zero
    private var appliedFPS = 0

    // MARK: - Source enumeration

    func refreshSources() async {
        guard !isLoading, stream == nil, followSession == nil, !isTransitioning else { return }
        isLoading = true
        retryManualSelection = nil
        permissionDenied = false
        lastError = nil
        defer { isLoading = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays.sorted { $0.displayID < $1.displayID }
            availableWindows = content.windows
                .filter { isUserWindow($0) }
                .sorted {
                    let a = $0.owningApplication?.applicationName ?? ""
                    let b = $1.owningApplication?.applicationName ?? ""
                    return a.localizedCompare(b) == .orderedAscending
                }
            switch selectedSource {
            case .window(let id) where !availableWindows.contains(where: { $0.windowID == id }),
                 .display(let id) where !availableDisplays.contains(where: { $0.displayID == id }):
                selectedSource = nil
            default: break
            }
        } catch {
            let issue = CaptureIssue("获取可捕捉窗口失败", error: error)
            permissionDenied = issue.isScreenAccessDenied
            lastError = issue.message
            selectedSource = nil
            availableDisplays = []
            availableWindows = []
        }
    }

    func retryCaptureAccess() async {
        guard !isLoading, !isTransitioning, !isCapturing else { return }
        if automaticallyFollowsShows {
            await startCapture()
            return
        }
        let selection = retryManualSelection
        await refreshSources()
        guard !automaticallyFollowsShows, let selection else { return }
        if permissionDenied {
            // Another refusal must not lose which operation the user is retrying.
            retryManualSelection = selection
            return
        }
        guard lastError == nil, selectedSource == nil || selectedSource == selection.source else { return }
        let stillAvailable: Bool
        switch selection.source {
        case .window(let id):
            stillAvailable = availableWindows.contains {
                $0.windowID == id && selection.ownerPID != nil && $0.owningApplication?.processID == selection.ownerPID
            }
        case .display(let id):
            stillAvailable = availableDisplays.contains { $0.displayID == id }
        }
        guard stillAvailable else {
            selectedSource = nil
            lastError = "上一次的来源已关闭或更换，请从列表重新选择。"
            return
        }
        selectedSource = selection.source
        await startCapture()
    }

    /// Returns the human-readable name for a display, matched via NSScreen.localizedName.
    func displayName(for display: SCDisplay) -> String {
        let screen = NSScreen.screens.first { screen in
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return num.map { CGDirectDisplayID($0.uint32Value) == display.displayID } ?? false
        }
        return screen?.localizedName ?? "Display \(display.displayID)"
    }

    // MARK: - Capture

    var canStart: Bool {
        !isLoading && !isTransitioning && !isCapturing && (automaticallyFollowsShows || selectedSource != nil)
    }

    func startCapture() async {
        guard canStart else { return }
        if automaticallyFollowsShows {
            startFollowing()
            return
        }
        guard let source = selectedSource, stream == nil, !isLoading, !isTransitioning else { return }
        let filter: SCContentFilter
        let label: String
        switch source {
        case .window(let id):
            guard let window = availableWindows.first(where: { $0.windowID == id }) else { return }
            filter = SCContentFilter(desktopIndependentWindow: window)
            label = window.owningApplication?.applicationName ?? "Window"
        case .display(let id):
            guard let display = availableDisplays.first(where: { $0.displayID == id }) else { return }
            filter = SCContentFilter(display: display, excludingWindows: [])
            label = displayName(for: display)
        }

        let id = UUID()
        let layer = AVSampleBufferDisplayLayer()
        let name = "SyphonPub PN — \(label)"
        guard let device,
              let publisher = FramePublisher(device: device, serverName: name, frameRate: frameRate,
                                             continuous: continuousOutput, previewLayer: layer,
                                             onFirstFrame: { [weak self] in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    self.hasFrame = true
                }
              }) else {
            lastError = "Could not create the Metal output."
            return
        }
        let output = CaptureOutput(publisher: publisher) { [weak self] issue in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                await self.stopCapture(issue: issue)
            }
        }
        desiredSize = Self.pixelSize(of: filter)
        appliedSize = desiredSize
        appliedFPS = frameRate
        let stream = SCStream(filter: filter, configuration: Self.configuration(size: desiredSize, fps: frameRate),
                              delegate: output)
        self.stream = stream
        self.output = output
        sessionID = id
        previewLayer = layer
        lastError = nil
        permissionDenied = false
        hasFrame = false
        isTransitioning = true

        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.sampleQueue)
            try await stream.startCapture()
            guard sessionID == id else { return }
            isTransitioning = false
            isCapturing = true
            manualServerName = name
            requestConfigurationUpdate()
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.sessionID == id else { return }
                    await self.checkSource(source, session: id)
                }
            }
        } catch {
            guard sessionID == id else { return }
            await stopCapture(issue: CaptureIssue("启动窗口捕捉失败", error: error))
        }
    }

    private func startFollowing() {
        lastError = nil
        permissionDenied = false
        let id = UUID()
        guard let device, let follow = PresentationFollowSession(device: device, fps: frameRate,
            onState: { [weak self] message, layer in
                guard let self, self.sessionID == id else { return }
                if self.followStatus != message { self.followStatus = message }
                if let layer, self.previewLayer !== layer { self.previewLayer = layer }
                if layer == nil && self.hasFrame { self.previewLayer = AVSampleBufferDisplayLayer() }
                if self.hasFrame != (layer != nil) { self.hasFrame = layer != nil }
            }, onFailure: { [weak self] reason in
                guard let self, self.sessionID == id else { return }
                self.lastError = reason.message
                self.permissionDenied = reason.isScreenAccessDenied
                await self.stopCapture()
            }) else {
            lastError = "无法创建 Metal 输出。"
            return
        }
        sessionID = id
        followSession = follow
        isCapturing = true
        hasFrame = false
        follow.start()
    }

    func stopCapture() async {
        if let follow = followSession {
            followSession = nil
            sessionID = nil
            isTransitioning = true
            hasFrame = false
            isCapturing = false
            await follow.stop()
            previewLayer = AVSampleBufferDisplayLayer()
            isTransitioning = false
            return
        }
        await stopCapture(issue: nil)
    }

    private func stopCapture(issue: CaptureIssue?) async {
        guard sessionID != nil, let stream else { return }
        sessionID = nil
        isTransitioning = true
        monitor?.cancel()
        monitor = nil
        configurationTask?.cancel()
        configurationTask = nil
        output?.publisher.stop()
        manualServerName = nil
        hasFrame = false
        isCapturing = false
        lastError = issue?.message
        permissionDenied = issue?.isScreenAccessDenied == true
        if permissionDenied, let source = selectedSource {
            var pid: pid_t?
            if case .window(let id) = source {
                pid = availableWindows.first { $0.windowID == id }?.owningApplication?.processID
            }
            retryManualSelection = (source, pid)
        } else {
            retryManualSelection = nil
        }
        do { try await stream.stopCapture() } catch {
            if lastError == nil { lastError = CaptureIssue("停止捕捉失败", error: error).message }
        }
        await previewLayer.sampleBufferRenderer.flush(removingDisplayedImage: true)
        self.stream = nil
        output = nil
        isTransitioning = false
    }

    // Ask for source metadata only. A still window can go away or change display
    // scale without producing another usable image. Never refresh pixels here.
    private func checkSource(_ source: CaptureSource, session id: UUID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard sessionID == id else { return }
            let filter: SCContentFilter
            switch source {
            case .window(let windowID):
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    await stopCapture(issue: CaptureIssue("来源窗口已关闭，请刷新后选择新窗口。"))
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
            case .display(let displayID):
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    await stopCapture(issue: CaptureIssue("来源显示器已断开。"))
                    return
                }
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            desiredSize = Self.pixelSize(of: filter)
            requestConfigurationUpdate()
        } catch {
            guard sessionID == id else { return }
            await stopCapture(issue: CaptureIssue("检查捕捉来源失败", error: error))
        }
    }

    private func requestConfigurationUpdate() {
        guard isCapturing, let stream, let id = sessionID, configurationTask == nil,
              desiredSize != appliedSize || frameRate != appliedFPS else { return }
        configurationTask = Task {
            defer { if sessionID == id { configurationTask = nil } }
            while sessionID == id && (desiredSize != appliedSize || frameRate != appliedFPS) {
                let size = desiredSize
                let fps = frameRate
                do {
                    try await stream.updateConfiguration(Self.configuration(size: size, fps: fps))
                    guard sessionID == id else { return }
                    appliedSize = size
                    appliedFPS = fps
                } catch {
                    guard sessionID == id else { return }
                    await stopCapture(issue: CaptureIssue("更新捕捉配置失败", error: error))
                }
            }
        }
    }

    static func pixelSize(of filter: SCContentFilter) -> CGSize {
        let scale = CGFloat(filter.pointPixelScale)
        return CGSize(width: max(1, (filter.contentRect.width * scale).rounded()),
                      height: max(1, (filter.contentRect.height * scale).rounded()))
    }

    static func configuration(size: CGSize, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 3
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    static func windowDetail(_ window: SCWindow) -> String {
        let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? "无标题窗口"
        guard let owner = window.owningApplication?.bundleIdentifier,
              ShowApplication.keynote.bundleIdentifiers.contains(owner) else { return title }
        return "\(title) · \(Int(window.frame.width)) × \(Int(window.frame.height)) pt · 窗口 \(window.windowID)"
    }

    private func isUserWindow(_ window: SCWindow) -> Bool {
        guard let app = window.owningApplication else { return false }
        let title = window.title ?? ""
        guard !title.isEmpty || ShowApplication.keynote.bundleIdentifiers.contains(app.bundleIdentifier) else { return false }

        // Only show windows whose owning process is — or is a helper of — a regular
        // .app bundle (one that appears in the Dock / App Switcher).
        // Electron apps (VS Code, Slack, etc.) render in a helper subprocess whose
        // bundle ID is a child of the main app, e.g. com.microsoft.VSCode.helper.renderer.
        let ownerID = app.bundleIdentifier
        let isRegularApp = NSWorkspace.shared.runningApplications.contains {
            guard $0.activationPolicy == .regular,
                  let bid = $0.bundleIdentifier else { return false }
            return ownerID == bid || ownerID.hasPrefix(bid + ".")
        }
        guard isRegularApp else { return false }

        if systemWindowTitles.contains(title) { return false }
        if title.hasSuffix("Backdrop") || title.hasSuffix("Backstop") { return false }
        if window.frame.width < 100 || window.frame.height < 100 { return false }

        return true
    }
}

/// Manual streams own their server. Follow streams share the server but all
/// submissions and terminal events are scoped to the stream's generation.
nonisolated final class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let sampleQueue = DispatchQueue(label: "local.syphonpub.samples", qos: .userInteractive)
    let publisher: FramePublisher
    private let followSource: UUID?
    private let onWaitingFrameFailure: @Sendable () -> Void
    private let onTemporaryPause: (@Sendable () -> Void)?
    private let onEnd: @Sendable (CaptureIssue) -> Void
    private let endLock = NSLock()
    private var ended = false

    init(publisher: FramePublisher, followSource: UUID? = nil,
         onWaitingFrameFailure: @escaping @Sendable () -> Void = {},
         onTemporaryPause: (@Sendable () -> Void)? = nil,
         onEnd: @escaping @Sendable (CaptureIssue) -> Void) {
        self.followSource = followSource
        self.onWaitingFrameFailure = onWaitingFrameFailure
        self.onTemporaryPause = onTemporaryPause
        self.publisher = publisher
        self.onEnd = onEnd
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                          as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete, .started:
            if CMSampleBufferDataIsReady(sample), CMSampleBufferGetImageBuffer(sample) != nil {
                publisher.submit(sample, source: followSource)
            }
        case .idle:
            break
        case .blank, .suspended:
            if let followSource, let onTemporaryPause {
                if !publisher.pauseSource(followSource, onPause: onTemporaryPause) {
                    onWaitingFrameFailure()
                }
            } else {
                end(CaptureIssue("来源已暂停或结束，请重新选择窗口。"))
            }
        case .stopped:
            end(CaptureIssue("来源已暂停或结束，请重新选择窗口。"))
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        end(CaptureIssue("捕捉流已中断", error: error))
    }

    func streamDidBecomeInactive(_ stream: SCStream) {
        end(CaptureIssue("来源已关闭，请刷新并选择新窗口。"))
    }

    private func end(_ reason: CaptureIssue) {
        endLock.lock()
        let first = !ended
        ended = true
        endLock.unlock()
        guard first else { return }
        if let followSource {
            guard publisher.showWaitingFrame(after: followSource) else {
                onWaitingFrameFailure()
                return
            }
        } else {
            publisher.stop()
        }
        onEnd(reason)
    }
}
