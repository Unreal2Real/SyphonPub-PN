import AppKit
import Carbon
import Combine

/// The setup buttons own consent. Background detection sends noninteractive events only.
@MainActor
final class ShowAutomationAuthorizer: ObservableObject {
    static let shared = ShowAutomationAuthorizer()
    @Published private(set) var pending: ShowApplication?

    func request(_ app: ShowApplication) async -> String {
        if let pending { return "请先完成 \(pending.rawValue) 的授权。" }
        let targets = app.bundleIdentifiers.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }.filter { !$0.isTerminated }
        guard let target = targets.first else { return "请先打开 \(app.rawValue)，停留在编辑界面，然后再点授权。" }
        guard targets.count == 1 else { return "发现多个 \(app.rawValue) 进程。请只保留演出使用的版本，再点授权。" }

        pending = app
        defer { pending = nil }
        let pid = target.processIdentifier
        let events = app == .powerPoint ? [kAECountElements, kAEGetData] : [kAEGetData]
        // Apple's consent API can wait indefinitely for the user. Keep this
        // synchronous call off the main actor and out of the one-second query loop.
        let status: OSStatus = await withCheckedContinuation { resume in
            DispatchQueue.global(qos: .userInitiated).async {
                let address = NSAppleEventDescriptor(processIdentifier: pid)
                for event in events {
                    let code = AEDeterminePermissionToAutomateTarget(address.aeDesc, AEEventClass(kAECoreSuite),
                                                                      AEEventID(event), true)
                    if code != noErr {
                        resume.resume(returning: code)
                        return
                    }
                }
                resume.resume(returning: noErr)
            }
        }
        switch Int(status) {
        case Int(noErr):
            return "已允许读取 \(app.rawValue) 的放映状态。"
        case Int(errAEEventNotPermitted):
            return "请在「系统设置 → 隐私与安全性 → 自动化」中展开 SyphonPub PN，允许访问 \(app.rawValue)，然后再点授权检查。"
        case Int(procNotFound):
            return "\(app.rawValue) 已退出。请重新打开后再点授权。"
        default:
            return "\(app.rawValue) 授权未完成（系统返回 \(status)）。请在编辑界面重试。"
        }
    }
}
