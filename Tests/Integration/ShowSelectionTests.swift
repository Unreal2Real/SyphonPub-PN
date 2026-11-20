@main
enum ShowSelectionTests {
    typealias Detection = ShowDetection<Int>

    @MainActor
    static func main() async {
        // Both apps can remain open throughout. An inactive editor, including one
        // with denied automation, never prevents the confirmed show from winning.
        for first in [ShowApplication.powerPoint, .keynote] {
            let next = first.other
            let active = Detection.window(42, presentation: "B")
            let unavailable: [Detection] = [.idle, .attention("no audience"), .needsPermission("consent")]
            for status in unavailable {
                var calls: [ShowApplication] = []
                let result = await selectAudienceShow(first: first) { app in
                    calls.append(app)
                    return app == first ? status : active
                }
                guard case .window(next, 42, "B") = result else { fatalError("missed new show") }
                precondition(calls == [first, next])
            }
            let retained = await selectAudienceShow(first: first) { app in
                precondition(app == first, "queried an unrelated editor during a verified show")
                return active
            }
            guard case .window(first, 42, "B") = retained else { fatalError("lost current show") }
            let denied = await selectAudienceShow(first: first) { _ in
                Detection.needsPermission("consent")
            }
            guard case .waiting("consent\nconsent") = denied else { fatalError("missing setup guidance") }
        }
        let idle = await selectAudienceShow(first: .powerPoint) { _ in Detection.idle }
        guard case .waiting("等待 PowerPoint 或 Keynote 放映") = idle else { fatalError("bad idle state") }
        print("PASS both handover directions, idle/ambiguous/unauthorized editors, sticky show, and permission guidance")
    }
}
