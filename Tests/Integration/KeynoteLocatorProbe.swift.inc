
// Appended to the locator so the live probe uses the production event reader.
@main
struct KeynoteLocatorProbe {
    // Replay the Keynote 15.4 window identities observed on this Mac. Titles are
    // normalized to the test deck. No production deck names or pixels are used.
    private static func replayTwoDisplayShow() {
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: -752, y: -1080, width: 1920, height: 1080)
        let title = "SyphonPub-Diag-29A"
        func surface(_ id: CGWindowID, _ name: String?, _ frame: CGRect, _ layer: Int) -> KeynoteWindowIdentity {
            KeynoteWindowIdentity(id: id, title: name, frame: frame, layer: layer, visible: layer > 0)
        }
        // Keynote made one titled and one untitled surface per display.
        func snapshot(editorFrame: CGRect, externalFrame: CGRect, externalID: CGWindowID,
                      laptopID: CGWindowID, blankLaptopID: CGWindowID, blankExternalID: CGWindowID) -> [KeynoteWindowIdentity] {
            [surface(15613, title, editorFrame, 0),
             surface(externalID, title, externalFrame, 25), surface(blankExternalID, nil, externalFrame, 25),
             surface(laptopID, title, laptop, 9), surface(blankLaptopID, nil, laptop, 9)]
        }
        func match(_ windows: [KeynoteWindowIdentity], _ screens: [CGRect], _ names: [String]) ->
            Result<(id: CGWindowID, document: String), KeynoteWindowIdentity.MatchFailure> {
            KeynoteWindowIdentity.match(windows, on: screens, documents: names)
        }
        let names = [title + ".key", "Other open test document.key"]
        // At 21:32:52.703 only the laptop surface had reached its full bounds.
        let opening = snapshot(editorFrame: CGRect(x: 18, y: 359, width: 288, height: 182),
                               externalFrame: CGRect(x: -135, y: -511, width: 876, height: 493),
                               externalID: 15651, laptopID: 15654, blankLaptopID: 15655, blankExternalID: 15656)
        precondition((try? match(opening, [laptop, external], names).get().id) == 15654)
        guard case .failure(.noFullscreenSurface) = match(opening, [external], names) else {
            fatalError("External display picked a window during the opening transition")
        }
        let editorFrame = CGRect(x: 0, y: 117, width: 960, height: 606)
        // 21:32:53.468 and a fresh full-screen show at 21:34:04.505.
        let runs: [(external: CGWindowID, laptop: CGWindowID, blankLaptop: CGWindowID, blankExternal: CGWindowID)] =
            [(15651, 15654, 15655, 15656), (15803, 15805, 15806, 15807)]
        for run in runs {
            let stable = snapshot(editorFrame: editorFrame, externalFrame: external, externalID: run.external,
                                  laptopID: run.laptop, blankLaptopID: run.blankLaptop, blankExternalID: run.blankExternal)
            guard case .failure(.ambiguous) = match(stable, [laptop, external], names) else {
                fatalError("Expected two identically titled full-screen windows")
            }
            precondition((try? match(stable, [external], names).get().id) == run.external)
            precondition((try? match(stable, [laptop], names).get().id) == run.laptop)
            precondition((try? match(stable, [external], ["Unrelated.key"]).get()) == nil)
            precondition((try? match(stable.filter { $0.layer > 0 }, [external], names).get()) == nil)
        }
        print("PASS replay of two live Keynote shows: all displays ambiguous, individual display IDs, opening transition, unrelated document and missing editor")
    }

    private static func testWindowedShows() {
        let normal = CGRect(x: 40, y: 110, width: 960, height: 575)
        let moved = CGRect(x: -1270, y: -100, width: 1200, height: 710)
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func window(_ id: CGWindowID, _ title: String?, _ visible: Bool,
                    frame: CGRect? = nil, layer: Int = 0) -> KeynoteWindowIdentity {
            KeynoteWindowIdentity(id: id, title: title, frame: frame ?? normal, layer: layer, visible: visible)
        }
        let editor = window(10, "测试 A", false)
        let audience = window(20, "测试 A", true)
        let pair = [editor, audience]
        let notesTitle = "演讲者显示器窗口"
        let notes = window(30, notesTitle, true)
        let candidates = pair + [notes, window(31, "Presenter Display", false),
                                 window(32, "预演模式", true), window(33, "测试 B", true)]
        let evidence = KeynoteWindowIdentity.windowedEvidence(candidates, documents: ["测试 A.key", "测试 B.key"])
        precondition(Set(evidence.related) == Set([editor.id, audience.id]))
        precondition(evidence.presenters == [notes.id])
        let collision = KeynoteWindowIdentity.windowedEvidence(candidates, documents: ["测试 A.key", notesTitle + ".key"])
        precondition(collision.presenters.isEmpty, "A document named like the presenter display cannot certify an audience")
        func match(_ windows: [KeynoteWindowIdentity], names: [String] = ["测试 A.key"],
                   idle: [CGWindowID: String] = [:], presenter: String? = nil,
                   ids: [CGWindowID: String] = [10: "deck-A", 20: "deck-A"],
                   previous: KeynoteAudienceBinding? = nil, pid: pid_t = 77,
                   excluded: Set<CGWindowID> = [])
            -> (id: CGWindowID, document: String)? {
            try? KeynoteWindowIdentity.windowedMatch(windows, documents: names, idleEditors: idle,
                presenterDocumentID: presenter, documentIDs: ids, previous: previous, pid: pid,
                excludedWindowIDs: excluded).get()
        }
        let binding = KeynoteAudienceBinding(pid: 77, id: audience.id, title: "测试 A", frame: normal,
                                            layer: 0, document: "测试 A.key", documentID: "deck-A")

        precondition(match(pair) == nil, "A title and matching document IDs alone cannot identify the audience")
        precondition(match(pair, presenter: "deck-A")?.id == audience.id, "Presenter confirms a show already running")
        let swapped = [window(editor.id, "测试 A", true), window(audience.id, "测试 A", false)]
        precondition(match(swapped, presenter: "deck-A", previous: binding, excluded: [editor.id]) == nil,
                     "If the editor reappears, the presenter cannot turn it into the audience")
        precondition(match(pair, excluded: [editor.id]) == nil,
                     "A previously hidden companion alone cannot certify the next visible window")
        precondition(match(pair, presenter: "deck-B") == nil)
        precondition(match(pair, idle: [editor.id: "测试 A"])?.id == audience.id)
        precondition(match(pair, idle: [editor.id: "测试 B"]) == nil)
        precondition(match(pair, previous: binding)?.id == audience.id)
        precondition(match(pair, previous: binding, pid: 78) == nil)
        let fullscreen = KeynoteAudienceBinding(pid: 77, id: audience.id, title: "测试 A", frame: display,
                                              layer: 25, document: "测试 A.key", documentID: "deck-A")
        precondition(match(pair, previous: fullscreen) == nil)
        for frame in [moved, display] {
            let resized = window(audience.id, "测试 A", true, frame: frame)
            precondition(match([editor, resized], previous: binding)?.id == audience.id,
                         "Moving or maximizing the verified audience must preserve its identity")
        }

        // The visible window and its hidden editor must both identify the same document.
        precondition(match([audience], presenter: "deck-A") == nil)
        precondition(match([window(10, "测试 B", false), audience], presenter: "deck-A") == nil)
        precondition(match(pair, presenter: "deck-A", ids: [10: "deck-A"]) == nil)
        precondition(match(pair, presenter: "deck-A", ids: [20: "deck-A"]) == nil)
        precondition(match(pair, presenter: "deck-A", ids: [10: "deck-B", 20: "deck-A"]) == nil)
        precondition(match(pair, names: ["测试 A.key", "测试 A"], presenter: "deck-A") == nil)
        precondition(match(pair, names: ["测试 A.key", "测试 A.key"], presenter: "deck-A") == nil)
        precondition(match(pair, ids: [10: "reopened-A", 20: "reopened-A"], previous: binding) == nil,
                     "Reopening a document with the same name cannot reuse the old binding")
        let editorB = window(11, "测试 B", false)
        let audienceB = window(21, "测试 B", true)
        let next = match([editorB, audienceB], names: ["测试 A.key", "测试 B.key"],
                         presenter: "deck-B", ids: [11: "deck-B", 21: "deck-B"], previous: binding)
        precondition(next?.id == audienceB.id && next?.document == "测试 B.key")
        precondition(match(pair + [editorB, audienceB], names: ["测试 A.key", "测试 B.key"],
                           idle: [editor.id: "测试 A", editorB.id: "测试 B"],
                           ids: [10: "deck-A", 20: "deck-A", 11: "deck-B", 21: "deck-B"]) == nil)
        precondition(match([editor, window(21, "测试 A", true)], ids: [10: "deck-A", 21: "deck-A"],
                           previous: binding) == nil, "A replacement window needs fresh evidence")
        precondition(match([window(10, "测试 B", false), window(20, "测试 B", true)],
                           names: ["测试 B.key"], previous: binding) == nil)

        // Deny known editors even if there is a presenter or a previous binding.
        precondition(match(pair, idle: [editor.id: "测试 A", audience.id: "测试 A"],
                           presenter: "deck-A", previous: binding) == nil)
        let second = window(22, "测试 A", true)
        precondition(match(pair + [second], presenter: "deck-A",
                           ids: [10: "deck-A", 20: "deck-A", 22: "deck-A"]) == nil)
        precondition(match([window(10, notesTitle, false), window(20, notesTitle, true)],
                           names: [notesTitle + ".key"], presenter: "deck-A") == nil)
        precondition(match([editor, window(20, nil, true)], presenter: "deck-A") == nil)
        precondition(match([editor, window(20, "测试 A", true, layer: 9)], presenter: "deck-A") == nil)

        let maximized = KeynoteAudienceBinding(pid: 77, id: audience.id, title: "测试 A", frame: display,
                                              layer: 0, document: "测试 A.key", documentID: "deck-A")
        let offscreen = [editor, window(20, "测试 A", false, frame: display)]
        precondition(match(offscreen, previous: maximized) == nil)
        precondition(!maximized.canContinue(after: .noVisibleWindow, pid: 77, windows: offscreen,
                                            on: [display], documents: ["测试 A.key"], documentID: "deck-A"),
                     "An off-screen windowed show cannot use fullscreen retention, even when maximized")
        print("PASS windowed Keynote identification, presenter and editor evidence, moves, replacement, ambiguity, and off-screen rejection")
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            guard CGPreflightScreenCaptureAccess() else {
                print("SKIP screen recording is not preauthorized for this process")
                return
            }
            let all = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            switch await KeynoteShowLocator().locate(in: all.windows, displayFrames: all.displays.map(\.frame)) {
            case .window(let window, _): print("LIVE matched audience window ID", window.windowID)
            case .needsPermission: print("SKIP Keynote automation is not preauthorized")
            case .idle: print("LIVE idle")
            case .attention(let message): print("LIVE waiting", message)
            }
            return
        }

        replayTwoDisplayShow()
        testWindowedShows()
        let internalScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: -1920, y: -250, width: 1920, height: 1080)
        let displays = [internalScreen, external]
        let editorBounds = CGRect(x: 120, y: 95, width: 920, height: 770)
        func window(_ id: CGWindowID, _ title: String?, _ rect: CGRect, _ layer: Int, _ visible: Bool) -> KeynoteWindowIdentity {
            KeynoteWindowIdentity(id: id, title: title, frame: rect, layer: layer, visible: visible)
        }
        let editor = window(1, "演出 A", editorBounds, 0, false)
        let audience = window(2, "演出 A", external, 30, true)
        let notes = window(3, "演讲者显示器窗口", internalScreen, 31, true)
        func resolve(_ candidates: [KeynoteWindowIdentity], _ names: [String] = ["演出 A.key"]) -> CGWindowID? {
            try? KeynoteWindowIdentity.match(candidates, on: displays, documents: names).get().id
        }
        precondition(resolve([editor, audience, notes]) == 2)
        precondition(resolve([editor, notes]) == nil)
        let titleCollision = window(11, "演讲者显示器窗口", editorBounds, 0, false)
        precondition(resolve([titleCollision, notes], ["演讲者显示器窗口.key"]) == nil)
        precondition(resolve([window(4, "演出 A", external, 0, true)]) == nil) // Fullscreen editor.
        precondition(resolve([audience]) == nil)
        precondition(resolve([editor, window(5, nil, external, 30, true)]) == nil)
        precondition(resolve([editor, window(6, "演出 A", external, 30, false)]) == nil)
        precondition(resolve([editor, window(7, "演出 A", editorBounds, 30, true)]) == nil)
        precondition(resolve([editor, audience], ["演出 AB.key"]) == nil)
        precondition(resolve([editor, audience], ["演出 A.key", "演出 A"]) == nil)
        precondition(resolve([editor, audience, window(8, "演出 A", internalScreen, 40, true)]) == nil)
        precondition(resolve([editor, audience, window(9, "演出 A", external, 30, true)]) == nil)
        precondition(resolve([editor, audience, window(10, "演出 A", external, 12, true)]) == 2)
        let editorWithExtension = window(12, "演出 A.key", editorBounds, 0, false)
        precondition(resolve([editorWithExtension, audience]) == 2)
        precondition(resolve([window(13, "演出 A.pptx", editorBounds, 0, false), audience]) == nil)
        precondition(resolve([window(13, "演出 A.pptx", editorBounds, 0, false), window(14, "演出 A.key", external, 30, true)], ["演出 A"]) == nil)
        func failure(_ windows: [KeynoteWindowIdentity]) -> KeynoteWindowIdentity.MatchFailure? {
            if case .failure(let reason) = KeynoteWindowIdentity.match(windows, on: displays, documents: ["演出 A.key"]) { return reason }
            return nil
        }
        precondition(failure([editor]) == .noVisibleWindow)
        precondition(failure([window(14, "演出 A", editorBounds, 0, true)]) == .noFullscreenSurface)
        precondition(failure([notes]) == .noAudienceTitle)
        precondition(failure([audience]) == .unverifiedDocument)
        precondition(failure([editor, audience, window(15, "演出 A", internalScreen, 24, true)]) == .ambiguous)
        print("PASS synthetic Keynote audience, full-screen editor, presenter, duplicate title, ambiguous display, window layer and negative display origin")

        let binding = KeynoteAudienceBinding(pid: 77, id: audience.id, title: "演出 A", frame: external,
                                             layer: audience.layer, document: "演出 A.key", documentID: "deck-A")
        let hidden = window(audience.id, audience.title, external, audience.layer, false)
        func remains(_ windows: [KeynoteWindowIdentity], _ docs: [String] = ["演出 A.key"],
                     pid: pid_t = 77, screens: [CGRect] = displays, documentID: String = "deck-A") -> Bool {
            if case .failure(let reason) = KeynoteWindowIdentity.match(windows, on: screens, documents: docs) {
                return binding.canContinue(after: reason, pid: pid, windows: windows, on: screens, documents: docs, documentID: documentID)
            }
            return false
        }
        precondition(remains([hidden, editor]))
        precondition(!remains([editor])) // Window gone from the enumeration.
        precondition(!remains([hidden, editor], ["演出 A.key", "B.key"]))
        precondition(!remains([hidden, editor], ["B.key"]))
        precondition(!remains([hidden, editor], documentID: "reopened-deck-with-same-name"))
        precondition(!remains([hidden, editor], pid: 78))
        precondition(!remains([hidden, editor], screens: [internalScreen]))
        precondition(!remains([window(audience.id, audience.title, internalScreen, audience.layer, false)]))
        precondition(!remains([window(audience.id, audience.title, external, 0, false)]))
        precondition(!remains([window(audience.id, "B", external, audience.layer, false)]))
        precondition(!remains([window(42, audience.title, external, audience.layer, false)]))
        precondition(!remains([hidden, window(42, "演出 A.key", editorBounds, 0, true)]))
        precondition(!remains([hidden, window(42, "unverified", external, 50, true)]))
        print("PASS only the verified hidden Keynote window can continue, with matching process, geometry, role and unique deck")

        if CommandLine.arguments.contains("--self-events") {
            let service = KeynoteReadService()
            NSAppleEventManager.shared().setEventHandler(service, andSelector: #selector(KeynoteReadService.handle(_:reply:)),
                                                         forEventClass: AEEventClass(kAECoreSuite), andEventID: AEEventID(kAEGetData))
            let reader = KeynoteEventReader()
            var names = try await reader.playingDocuments(pid: getpid())
            precondition(names == nil && service.calls == 1)
            service.playing = true
            names = try await reader.playingDocuments(pid: getpid())
            precondition(names == ["演出 A.key", "演出 B"] && service.calls == 3)
            let documentID = try await reader.documentID(named: "演出 A.key", pid: getpid())
            precondition(documentID == "deck-A" && service.calls == 4)
            let ids = try await reader.windowDocumentIDs([10, 20, 99, 11], pid: getpid())
            precondition(ids == [10: "deck-A", 20: "deck-A", 11: "deck-B"] && service.calls == 8,
                         "A vanished window should not invalidate the remaining window-to-document IDs")
            do {
                _ = try await reader.windowDocumentIDs([98], pid: getpid())
                fatalError("An automation permission denial must reach the locator")
            } catch {
                precondition((error as NSError).code == Int(errAEEventNotPermitted) && service.calls == 9)
            }
            print("PASS in-process read-only Apple events for playback, document names and IDs, window document IDs, stale windows, and permission denial")
        }
    }
}

@MainActor private final class KeynoteReadService: NSObject {
    var playing = false
    private(set) var calls = 0

    @objc func handle(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        calls += 1
        let object = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))!
        precondition(object.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == OSType(cProperty))
        guard let field = object.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue else { fatalError("missing field") }
        let parent = object.forKeyword(AEKeyword(keyAEContainer))!
        let value: NSAppleEventDescriptor
        switch field {
        case 0x506c6e67: // Keynote application.playing
            precondition(parent.descriptorType == typeNull)
            value = .init(boolean: playing)
        case OSType(pName):
            precondition(playing && parent.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == OSType(cDocument))
            let ordinal = parent.forKeyword(AEKeyword(keyAEKeyData))!
            precondition(ordinal.descriptorType == typeAbsoluteOrdinal && ordinal.data.withUnsafeBytes {
                $0.loadUnaligned(as: OSType.self) == OSType(kAEAll)
            })
            value = .list()
            value.insert(.init(string: "演出 A.key"), at: 1)
            value.insert(.init(string: "演出 B"), at: 2)
        case OSType(pID):
            if parent.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == OSType(cDocument) {
                precondition(parent.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formName))
                precondition(parent.forKeyword(AEKeyword(keyAEKeyData))?.stringValue == "演出 A.key")
                value = .init(string: "deck-A")
            } else {
                // get id of (document of (window id N)), as defined by the installed Keynote dictionary.
                precondition(parent.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == OSType(cProperty))
                precondition(parent.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formPropertyID))
                precondition(parent.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == OSType(cDocument))
                let window = parent.forKeyword(AEKeyword(keyAEContainer))!
                precondition(window.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == OSType(cWindow))
                precondition(window.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == OSType(formUniqueID))
                precondition(window.forKeyword(AEKeyword(keyAEContainer))?.descriptorType == typeNull)
                let windowID = window.forKeyword(AEKeyword(keyAEKeyData))!.int32Value
                switch windowID {
                case 10, 20: value = .init(string: "deck-A")
                case 11: value = .init(string: "deck-B")
                case 98, 99:
                    let code = windowID == 98 ? errAEEventNotPermitted : errAENoSuchObject
                    reply.setParam(.init(int32: Int32(code)), forKeyword: AEKeyword(keyErrorNumber))
                    return
                default: fatalError("Unexpected window ID in read-only event")
                }
            }
        default: fatalError("unexpected query")
        }
        reply.setParam(value, forKeyword: AEKeyword(keyDirectObject))
    }
}
