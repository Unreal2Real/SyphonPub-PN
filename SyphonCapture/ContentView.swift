import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @EnvironmentObject private var captureManager: CaptureManager

    @State private var showsPermissions = false

    var body: some View {
        VSplitView {
            previewPane
            controlPane
        }
        .frame(minWidth: 720, minHeight: 500)
        .sheet(isPresented: $showsPermissions) { PermissionSetupView() }
        .task(id: captureManager.automaticallyFollowsShows) {
            if !captureManager.automaticallyFollowsShows { await captureManager.refreshSources() }
        }
    }

    // MARK: - Preview pane

    private var previewPane: some View {
        ZStack {
            Color.black

            if captureManager.isCapturing || captureManager.isTransitioning {
                if captureManager.hasFrame {
                    PreviewView(layer: captureManager.previewLayer)
                        .id(ObjectIdentifier(captureManager.previewLayer))
                } else {
                    Text(captureManager.automaticallyFollowsShows ? captureManager.followStatus : "等待画面…")
                        .multilineTextAlignment(.center).foregroundStyle(.white).padding()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(captureManager.automaticallyFollowsShows ? "点 Start 开始跟随放映" : "选择窗口或显示器，然后点 Start")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 240)
    }

    // MARK: - Control pane (source list + toolbar)

    private var controlPane: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Picker("捕捉模式", selection: $captureManager.automaticallyFollowsShows) {
                    Text("自动跟随放映").tag(true)
                    Text("手动选择").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                .disabled(captureManager.isCapturing || captureManager.isTransitioning)
                Spacer()
                if captureManager.automaticallyFollowsShows {
                    Button("放映软件授权…") { showsPermissions = true }
                }
                if !captureManager.automaticallyFollowsShows {
                    Button {
                        Task { await captureManager.refreshSources() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(captureManager.isLoading || captureManager.isCapturing || captureManager.isTransitioning)
                }

                HStack(spacing: 6) {
                    Text("FPS")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Picker("", selection: $captureManager.frameRate) {
                        ForEach([15, 24, 30, 60], id: \.self) { fps in
                            Text("\(fps)").tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
                .padding(.leading, 12)
                .padding(.trailing, 12)
                if !captureManager.automaticallyFollowsShows {
                    Toggle("连续输出", isOn: $captureManager.continuousOutput)
                        .disabled(captureManager.isCapturing || captureManager.isTransitioning)
                }

                captureButton
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if let message = captureManager.lastError, !captureManager.permissionDenied {
                Text(message).foregroundStyle(.red).padding(.horizontal)
            }

            if let name = captureManager.manualServerName {
                Text("QLab 手动来源 · " + name)
                    .textSelection(.enabled)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Source list
            if captureManager.isLoading {
                ProgressView("Loading sources…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if captureManager.permissionDenied {
                permissionDeniedView
            } else if captureManager.automaticallyFollowsShows {
                VStack(alignment: .leading, spacing: 8) {
                    Text(captureManager.hasFrame ? captureManager.followStatus : "自动跟随 PowerPoint 或 Keynote 放映")
                        .font(.headline)
                    Text("QLab 来源  ·  " + PresentationFollowSession.serverName)
                        .textSelection(.enabled)
                    Text("Start 一次即可换稿。两场放映之间输出黑场，看到新稿预览后即可在 QLab 切回。")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if captureManager.availableWindows.isEmpty && captureManager.availableDisplays.isEmpty {
                ContentUnavailableView(
                    "No Sources Found",
                    systemImage: "macwindow",
                    description: Text("Click Refresh to scan for displays and windows.")
                )
            } else {
                sourceList
            }
        }
        .frame(minHeight: 180)
    }

    // MARK: - Subviews

    private var captureButton: some View {
        Button {
            Task {
                if captureManager.isCapturing {
                    await captureManager.stopCapture()
                } else {
                    await captureManager.startCapture()
                }
            }
        } label: {
            Label(
                captureManager.isCapturing ? "Stop" : "Start",
                systemImage: captureManager.isCapturing ? "stop.fill" : "play.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(captureManager.isCapturing ? .red : .accentColor)
        .disabled(captureManager.isTransitioning || captureManager.isLoading || (!captureManager.canStart && !captureManager.isCapturing))
    }

    private var sourceList: some View {
        List(selection: $captureManager.selectedSource) {
            if !captureManager.availableDisplays.isEmpty {
                Section("Displays") {
                    ForEach(captureManager.availableDisplays, id: \.displayID) { display in
                        DisplayRow(
                            name: captureManager.displayName(for: display),
                            width: display.width,
                            height: display.height
                        )
                        .tag(CaptureSource.display(display.displayID))
                    }
                }
            }
            if !captureManager.availableWindows.isEmpty {
                Section("Windows") {
                    ForEach(captureManager.availableWindows, id: \.windowID) { window in
                        WindowRow(window: window)
                            .tag(CaptureSource.window(window.windowID))
                    }
                }
            }
        }
        .disabled(captureManager.isCapturing || captureManager.isTransitioning)
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("macOS 拒绝了这次屏幕捕捉")
                .font(.headline)
            Text("在「隐私与安全性 → 录屏与系统录音」中选择 SyphonPub PN。若系统提示重新打开，请重开后再点 Start。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let error = captureManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Button("打开录屏设置") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    )
                }
                Button("重试") {
                    Task { await captureManager.retryCaptureAccess() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Display Row

struct DisplayRow: View {
    let name: String
    let width: Int
    let height: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.subheadline)
                .fontWeight(.medium)
            Text("\(width) × \(height)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Window Row

struct WindowRow: View {
    let window: SCWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(window.owningApplication?.applicationName ?? "Unknown App")
                .font(.subheadline)
                .fontWeight(.medium)
            Text(CaptureManager.windowDetail(window))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
