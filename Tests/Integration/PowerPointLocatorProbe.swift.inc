// Appended to the production source so the test can exercise its exact Apple
// event reader without making that implementation part of the module API.
import Foundation

@main
struct LocatorProbe {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--preflight") || CommandLine.arguments.contains("--metadata-only") {
            try await preflight(metadataOnly: CommandLine.arguments.contains("--metadata-only"))
            return
        }
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: -1920, y: -220, width: 1920, height: 1080)
        let editor = PowerPointWindowIdentity(id: 10, frame: external, title: "Deck.pptx", isOnScreen: true)
        let audience = PowerPointWindowIdentity(id: 20, frame: external, title: "PowerPoint 幻灯片放映 - [Deck]", isOnScreen: true)
        let hidden = PowerPointWindowIdentity(id: 20, frame: external, title: nil, isOnScreen: false)
        let notes = PowerPointWindowIdentity(id: 30, frame: main, title: "PowerPoint Presenter View", isOnScreen: true)
        let other = PowerPointWindowIdentity(id: 40, frame: external, title: "PowerPoint 幻灯片放映 - [Deck 2]", isOnScreen: true)
        let clone = PowerPointWindowIdentity(id: 50, frame: external, title: audience.title, isOnScreen: true)
        func show(_ id: CGWindowID?, _ rect: CGRect?, _ title: String?) -> PowerPointShowInfo {
            PowerPointShowInfo(id: id, frame: rect, title: title, presentation: "Deck.pptx")
        }
        precondition(show(20, external, nil).resolve([notes, hidden]) == 20)
        precondition(show(20, external, nil).resolve([notes, editor, hidden]) == nil)
        precondition(show(20, external, audience.title).resolve([notes, editor, audience]) == 20)
        precondition(show(999, external, nil).resolve([notes, editor]) == nil)
        precondition(show(999, external, audience.title).resolve([notes, editor, audience]) == 20)
        precondition(show(nil, nil, nil).resolve([editor, other, audience]) == 20)
        precondition(show(nil, nil, nil).resolve([editor, other]) == nil)
        precondition(show(nil, main, nil).resolve([notes, audience]) == nil)
        precondition(show(20, external, audience.title).resolve([editor]) == nil)
        precondition(show(30, main, nil).resolve([notes]) == nil)
        precondition(show(999, external, audience.title).resolve([audience, clone]) == nil)
        precondition(show(30, external, nil).resolve([other, audience]) == 20)
        let badID = PowerPointWindowIdentity(id: 20, frame: external, title: "Deck.pptx", isOnScreen: true)
        precondition(show(20, external, audience.title).resolve([badID]) == nil)
        let list = NSAppleEventDescriptor.list()
        for edge: Int32 in [-1920, -220, 0, 860] { list.insert(.init(int32: edge), at: 0) }
        precondition(PowerPointEventReader.bounds(list) == external)
        let qd = [-220, -1920, 860, 0] as [Int16] // top, left, bottom, right
        let bytes = qd.withUnsafeBytes { Data($0) }
        let rect = NSAppleEventDescriptor(descriptorType: DescType(typeQDRectangle), data: bytes)!
        precondition(PowerPointEventReader.bounds(rect) == external)
        print("PASS audience, presenter, editor, duplicate, stale ID, negative display coordinates and rectangle decoding")

        if CommandLine.arguments.contains("--self-events") {
            let service = ShowService()
            let manager = NSAppleEventManager.shared()
            for event in [kAECountElements, kAEGetData] {
                manager.setEventHandler(service, andSelector: #selector(ShowService.handle(_:reply:)),
                                        forEventClass: AEEventClass(kAECoreSuite), andEventID: AEEventID(event))
            }
            let info = try await PowerPointEventReader().readShow(pid: getpid())
            precondition(info?.id == 20 && info?.frame == external && info?.presentation == "Deck.pptx")
            precondition(service.calls == 6)
            print("PASS 6 real read-only Apple events to a mock responder in the probe process")
        }
    }

    @MainActor private static func preflight(metadataOnly: Bool) async throws {
        // Neither mode requests TCC permission. Do not print any user titles.
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.Powerpoint")
        guard apps.count == 1 else { print("SKIP running PowerPoint process count:", apps.count); return }
        let target = NSAppleEventDescriptor(processIdentifier: apps[0].processIdentifier)
        let checks = [kAECountElements, kAEGetData].map {
            AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite), AEEventID($0), false)
        }
        print("Apple event preflight OSStatus:", checks)
        guard checks.allSatisfy({ $0 == noErr }) else { print("SKIP Apple events without preauthorization"); return }
        if metadataOnly {
            do {
                let show = try await PowerPointEventReader().readShow(pid: apps[0].processIdentifier)
                print(show == nil ? "LIVE full-screen audience shows: 0" : "LIVE full-screen audience metadata read successfully")
            } catch {
                // Never include a scripting error's full message or descriptor.
                print("LIVE show query failed, code:", (error as NSError).code)
                exit(1)
            }
            return
        }
        let screen = CGPreflightScreenCaptureAccess()
        print("Screen recording preflight:", screen ? "authorized" : "unavailable")
        guard screen else { print("SKIP live matching without screen-recording preauthorization"); return }
        let metadata = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        switch await PowerPointShowLocator.locate(in: metadata.windows) {
        case .window: print("LIVE audience window matched; no capture started")
        case .idle: print("LIVE idle")
        case .needsPermission(let message), .attention(let message): print("LIVE waiting:", message)
        }
    }
}

@MainActor private final class ShowService: NSObject {
    private(set) var calls = 0
    private func code(_ name: String) -> OSType { name.utf8.reduce(0) { $0 << 8 | OSType($1) } }
    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        calls += 1
        let result: NSAppleEventDescriptor
        if event.eventID == kAECountElements {
            precondition(event.paramDescriptor(forKeyword: AEKeyword(keyAEObjectClass))?.typeCodeValue == code("pSSw"))
            result = .init(int32: 1)
        } else {
            let prop = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
            precondition(prop.descriptorType == typeObjectSpecifier)
            let field = prop.forKeyword(AEKeyword(keyAEKeyData))!.typeCodeValue
            let container = prop.forKeyword(AEKeyword(keyAEContainer))!
            switch field {
            case code("SWfs"): result = .init(boolean: true)
            case code("pbnd"):
                result = .list()
                for edge: Int32 in [-1920, -220, 0, 860] { result.insert(.init(int32: edge), at: 0) }
            case code("ID  "): result = .init(int32: 20)
            case code("pnam"):
                let isDeck = container.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == code("pptP")
                result = .init(string: isDeck ? "Deck.pptx" : "PowerPoint 幻灯片放映 - [Deck]")
            default: fatalError("unexpected query field")
            }
        }
        reply.setParam(result, forKeyword: AEKeyword(keyDirectObject))
    }
}
