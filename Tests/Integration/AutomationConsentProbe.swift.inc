// File-scoped stand-ins give the production authorizer a delayed human reply.
// The incompatible mock address type prevents any call to the system consent API.
private final class NSRunningApplication {
    let processIdentifier: pid_t = 777
    let isTerminated = false
    static var count = 1
    static func runningApplications(withBundleIdentifier bundle: String) -> [NSRunningApplication] {
        guard bundle != "com.apple.iWork.Keynote" else { return [] }
        return (0..<count).map { _ in NSRunningApplication() }
    }
}

private nonisolated struct NSAppleEventDescriptor {
    let aeDesc: pid_t
    init(processIdentifier: pid_t) { aeDesc = processIdentifier }
}

private nonisolated let humanReply = DispatchSemaphore(value: 0)

private nonisolated func AEDeterminePermissionToAutomateTarget(_ pid: pid_t, _ group: AEEventClass,
                                                            _ event: AEEventID, _ ask: Bool) -> OSStatus {
    precondition(!Thread.isMainThread && pid == 777 && ask && group == kAECoreSuite && event == kAEGetData)
    precondition(humanReply.wait(timeout: .now() + 10) == .success)
    return noErr
}

@main private enum ConsentProbe {
    @MainActor static func main() async {
        let authorization = ShowAutomationAuthorizer.shared
        NSRunningApplication.count = 0
        let missing = await authorization.request(.keynote)
        precondition(missing.contains("先打开 Keynote") && authorization.pending == nil)
        NSRunningApplication.count = 2
        let multiple = await authorization.request(.keynote)
        precondition(multiple.contains("多个 Keynote") && authorization.pending == nil)
        NSRunningApplication.count = 1
        let first = Task { await authorization.request(.keynote) }
        while authorization.pending == nil { await Task.yield() }
        try! await Task.sleep(for: .milliseconds(1100))
        precondition(authorization.pending == .keynote)
        let second = await authorization.request(.powerPoint)
        precondition(second.contains("先完成 Keynote") && authorization.pending == .keynote)
        humanReply.signal()
        let done = await first.value
        precondition(done.contains("已允许读取 Keynote") && authorization.pending == nil)
        print("PASS simulated consent remained pending past the polling timeout, UI stayed responsive, concurrent request was blocked, missing/multiple targets handled")
    }
}
