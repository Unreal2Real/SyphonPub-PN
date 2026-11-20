import AppKit
import Carbon
import ScreenCaptureKit

@MainActor
final class KeynoteShowLocator {
    private let reader = KeynoteEventReader()
    private(set) var binding: KeynoteAudienceBinding?
    private var editorPID: pid_t?
    private var idleEditors: [CGWindowID: String] = [:]
    private var excludedWindowIDs: Set<CGWindowID> = []
    private var standbyCheck: Task<Void, Never>?
    private var lastStandbySample: [CGWindowID: String]?

    // PowerPoint can remain on air while the operator opens the next Keynote
    // deck. Learn its editor IDs without delaying the PowerPoint capture loop.
    func observeEditorsDuringPowerPoint(in windows: [SCWindow]) {
        guard standbyCheck == nil else { return }
        let owned = windows.filter { window in
            guard let owner = window.owningApplication else { return false }
            return ShowApplication.keynote.bundleIdentifiers.contains(owner.bundleIdentifier)
        }
        let pids = Set(owned.compactMap { $0.owningApplication?.processID })
        guard pids.count == 1, let pid = pids.first else {
            lastStandbySample = nil
            return
        }
        useProcess(pid)
        let visible = Self.visibleEditors(owned.map(KeynoteWindowIdentity.init(window:)))
        guard visible != lastStandbySample else { return }
        lastStandbySample = visible
        standbyCheck = Task { [weak self] in
            guard let self else { return }
            defer { standbyCheck = nil }
            guard let playing = try? await reader.isPlaying(pid: pid), !Task.isCancelled, editorPID == pid else { return }
            if !playing {
                idleEditors = visible
                excludedWindowIDs.removeAll()
            }
        }
    }

    func cancelStandby() { standbyCheck?.cancel() }

    private func useProcess(_ pid: pid_t) {
        if editorPID != pid {
            editorPID = pid
            idleEditors = [:]
            excludedWindowIDs.removeAll()
            lastStandbySample = nil
        }
    }

    private static func visibleEditors(_ windows: [KeynoteWindowIdentity]) -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]
        for window in windows where window.visible && window.layer == 0 {
            if let title = window.title, !title.isEmpty { result[window.id] = title }
        }
        return result
    }

    func locate(in windows: [SCWindow], displayFrames: [CGRect],
                continuing previous: KeynoteAudienceBinding? = nil) async -> ShowDetection<SCWindow> {
        binding = nil
        cancelStandby()
        lastStandbySample = nil
        let apps = ShowApplication.keynote.bundleIdentifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { !$0.isTerminated }
        guard !apps.isEmpty else {
            editorPID = nil
            idleEditors = [:]
            excludedWindowIDs.removeAll()
            return .idle
        }

        // An authorized Keynote can be playing with no discoverable fullscreen
        // surface (windowed playback or a hidden show). Query its actual state.
        let candidates = apps.compactMap { app -> (NSRunningApplication, [SCWindow], [KeynoteWindowIdentity])? in
            let owned = windows.filter {
                $0.owningApplication?.processID == app.processIdentifier &&
                $0.owningApplication?.bundleIdentifier == app.bundleIdentifier
            }
            let identities = owned.map(KeynoteWindowIdentity.init(window:))
            guard apps.count == 1 || identities.contains(where: { $0.isFullscreenCandidate(on: displayFrames)
                || ($0.layer == 0 && $0.visible && $0.title?.isEmpty == false) }) else { return nil }
            return (app, owned, identities)
        }
        let fullscreen = candidates.filter { $0.2.contains(where: { $0.isFullscreenCandidate(on: displayFrames) }) }
        let potential = fullscreen.isEmpty ? candidates : fullscreen
        guard !potential.isEmpty else { return .attention("多个 Keynote 进程已打开，无法确认正在放映的进程。") }
        guard potential.count == 1 else { return .attention("多个 Keynote 进程有可见窗口，等待唯一放映进程") }
        let (app, owned, identities) = potential[0]
        let pid = app.processIdentifier
        useProcess(pid)
        excludedWindowIDs.formIntersection(identities.map(\.id))
        do {
            guard let names = try await reader.playingDocuments(pid: pid) else {
                if !Task.isCancelled, !app.isTerminated {
                    idleEditors = Self.visibleEditors(identities)
                    excludedWindowIDs.removeAll()
                }
                return .idle
            }
            guard !Task.isCancelled, !app.isTerminated else { return .idle }
            var match = KeynoteWindowIdentity.match(identities, on: displayFrames, documents: names)
            var documentIDs: [CGWindowID: String] = [:]
            if case .failure(.noFullscreenSurface) = match {
                let groups = KeynoteWindowIdentity.windowedEvidence(identities, documents: names)
                if !groups.related.isEmpty {
                    documentIDs = try await reader.windowDocumentIDs(groups.related + groups.presenters, pid: pid)
                    let presenterIDs = Set(groups.presenters.compactMap { documentIDs[$0] })
                    guard presenterIDs.count <= 1 else { return .attention("多个演讲者窗口对应不同文稿，等待唯一放映") }
                    match = KeynoteWindowIdentity.windowedMatch(identities, documents: names, idleEditors: idleEditors,
                        presenterDocumentID: presenterIDs.first, documentIDs: documentIDs, previous: previous,
                        pid: pid, excludedWindowIDs: excludedWindowIDs)
                }
            }
            switch match {
            case .success(let matched):
                guard let window = owned.first(where: { $0.windowID == matched.id }) else { return .idle }
                let verifiedID: String?
                if window.windowLayer == 0, let id = documentIDs[matched.id] {
                    verifiedID = id
                    // A hidden companion reappearing while the audience window
                    // is minimized must not be mistaken for its replacement.
                    excludedWindowIDs.formUnion(identities.filter {
                        !$0.visible && $0.layer == 0 && documentIDs[$0.id] == id
                    }.map(\.id))
                } else {
                    verifiedID = try await reader.optionalDocumentID(named: matched.document, pid: pid)
                }
                if let documentID = verifiedID,
                   let title = window.title {
                    binding = KeynoteAudienceBinding(pid: pid, id: window.windowID, title: title,
                        frame: window.frame, layer: window.windowLayer, document: matched.document,
                        documentID: documentID)
                }
                guard !Task.isCancelled, !app.isTerminated else { return .idle }
                return .window(window, presentation: matched.document)
            case .failure(let reason):
                if let previous, previous.layer > 0, !app.isHidden, names == [previous.document],
                   let window = owned.first(where: { $0.windowID == previous.id }), !window.isOnScreen,
                   let documentID = try await reader.optionalDocumentID(named: previous.document, pid: pid),
                   previous.canContinue(after: reason, pid: pid, windows: identities, on: displayFrames,
                                        documents: names, documentID: documentID),
                   !Task.isCancelled, !app.isTerminated {
                    binding = previous
                    return .window(window, presentation: previous.document)
                }
                return .attention("Keynote 正在放映。" + reason.guidance)
            }
        } catch {
            let code = (error as NSError).code
            if code == Int(errAEEventWouldRequireUserConsent) || code == Int(errAEEventNotPermitted) {
                return .needsPermission("请点「授权 Keynote」检查自动化权限。")
            }
            if Task.isCancelled || app.isTerminated || code == Int(procNotFound) { return .idle }
            return .attention("正在重试 Keynote 放映查询（错误 \(code)）")
        }
    }
}

/// Evidence from a positively identified on-screen audience window. Valid only
/// for its existing stream; an off-screen window can never start a new stream.
nonisolated struct KeynoteAudienceBinding {
    let pid: pid_t
    let id: CGWindowID
    let title: String
    let frame: CGRect
    let layer: Int
    let document: String
    let documentID: String

    func canContinue(after failure: KeynoteWindowIdentity.MatchFailure, pid: pid_t,
                     windows: [KeynoteWindowIdentity], on displays: [CGRect], documents: [String], documentID: String) -> Bool {
        // 'playing' is app-wide. With several decks open it cannot prove that
        // the one which owns an old hidden window is still being presented.
        guard failure == .noVisibleWindow || failure == .noFullscreenSurface,
              layer > 0, pid == self.pid, documents == [document], documentID == self.documentID, displays.contains(frame),
              let same = windows.first(where: { $0.id == id }),
              !same.visible, same.layer == layer, same.frame == frame, same.title == title else { return false }
        // Keynote may replace a fullscreen show with a new windowed show of the
        // same document. A visible same-document window is competing evidence.
        return !windows.contains { window in
            window.visible && window.title.map { KeynoteWindowIdentity.represents($0, document: document) } == true
        }
    }
}

nonisolated struct KeynoteWindowIdentity {
    let id: CGWindowID
    let title: String?
    let frame: CGRect
    let layer: Int
    let visible: Bool

    // Keynote.strings labels for presenter/rehearsal UI. An open deck can itself
    // be named "Presenter Display", so an exact deck-name match is insufficient there.
    private static let presenterTitles: Set<String> = [
        "presenter display", "presenter display window", "演讲者显示器", "演讲者显示器窗口",
        "發表人顯示模式", "發表人顯示器視窗"
    ]
    private static let rehearsalTitles: Set<String> = ["rehearsal mode", "预演模式", "預演模式"]
    private static let reservedTitles = presenterTitles.union(rehearsalTitles)

    func isFullscreenCandidate(on displays: [CGRect]) -> Bool {
        visible && layer > 0 && displays.contains(frame)
    }

    enum MatchFailure: Error {
        case noVisibleWindow, noFullscreenSurface, noAudienceTitle, unverifiedDocument, ambiguous, unverifiedWindowed

        var guidance: String {
            switch self {
            case .noVisibleWindow: return "系统没有列出可见的 Keynote 窗口，请恢复放映窗口。"
            case .noFullscreenSurface: return "尚未找到可核实的观众窗口。请确认已开始放映且观众窗口未最小化。"
            case .noAudienceTitle: return "全屏窗口缺少可用于确认观众画面的标题。请手动选择并核对预览。"
            case .unverifiedDocument: return "全屏窗口无法与正在打开的文稿和编辑窗口对应。请手动选择并核对预览。"
            case .ambiguous: return "多个窗口或文稿可能对应观众画面。请手动选择并核对预览。"
            case .unverifiedWindowed: return "无法确认窗口放映属于哪份文稿。可在 Keynote 中显示一次演讲者显示器，或保持跟随并重新开始窗口放映。"
            }
        }
    }

    // Request document IDs only for plausible pairs and a visible presenter.
    // Other open decks, palettes, and stale fullscreen surfaces need no events.
    static func windowedEvidence(_ windows: [Self], documents: [String])
        -> (related: [CGWindowID], presenters: [CGWindowID]) {
        let normal = windows.filter { $0.layer == 0 }
        var related = Set<CGWindowID>()
        for name in documents where !reservedTitles.contains(stem(name).lowercased()) {
            let same = normal.filter { $0.title.map { represents($0, document: name) } == true }
            if same.contains(where: \.visible), same.contains(where: { !$0.visible }) {
                related.formUnion(same.map(\.id))
            }
        }
        let presenters = normal.filter { window in
            guard window.visible, let title = window.title, presenterTitles.contains(title.lowercased()) else { return false }
            return !documents.contains { represents(title, document: $0) }
        }
        return (Array(related).sorted(), presenters.map(\.id))
    }

    static func windowedMatch(_ windows: [Self], documents: [String], idleEditors: [CGWindowID: String],
                              presenterDocumentID: String?, documentIDs: [CGWindowID: String],
                              previous: KeynoteAudienceBinding?, pid: pid_t, excludedWindowIDs: Set<CGWindowID> = [])
        -> Result<(id: CGWindowID, document: String), MatchFailure> {
        if windows.contains(where: { $0.visible && $0.title.map { rehearsalTitles.contains($0.lowercased()) } == true }) {
            return .failure(.unverifiedWindowed)
        }
        var matches: [(id: CGWindowID, document: String)] = []
        for window in windows where window.visible && window.layer == 0 {
            guard let title = window.title, !title.isEmpty, !reservedTitles.contains(stem(title).lowercased()),
                  let documentID = documentIDs[window.id] else { continue }
            let names = documents.filter { represents(title, document: $0) }
            if names.count > 1 { return .failure(.ambiguous) }
            guard let name = names.first, idleEditors[window.id] == nil, !excludedWindowIDs.contains(window.id) else { continue }
            if let presenterDocumentID, presenterDocumentID != documentID { continue }
            let siblings = windows.filter { other in
                guard other.id != window.id, let otherTitle = other.title else { return false }
                return represents(otherTitle, document: title) && documents.filter { represents(otherTitle, document: $0) } == [name]
            }
            let hidden = siblings.filter { !$0.visible && $0.layer == 0 && documentIDs[$0.id] == documentID }
            guard !hidden.isEmpty else { continue }
            let editorWasVisible = hidden.contains { idleEditors[$0.id] != nil && idleEditors[$0.id] == $0.title }
            let continuing = previous?.pid == pid && previous?.layer == 0 && previous?.id == window.id
                && previous?.title == title && previous?.document == name && previous?.documentID == documentID
            guard editorWasVisible || continuing || presenterDocumentID == documentID else { continue }
            // Multiple same-deck windows on screen can mean a rehearsal or a
            // transition. An unknown role must never expose notes to the audience.
            guard !siblings.contains(where: \.visible) else { return .failure(.ambiguous) }
            matches.append((window.id, name))
        }
        guard matches.count < 2 else { return .failure(.ambiguous) }
        guard let sole = matches.first else { return .failure(.unverifiedWindowed) }
        return .success(sole)
    }

    static func match(_ windows: [Self], on displays: [CGRect], documents: [String])
        -> Result<(id: CGWindowID, document: String), MatchFailure> {
        guard windows.contains(where: \.visible) else { return .failure(.noVisibleWindow) }
        let fullscreen = windows.filter { $0.isFullscreenCandidate(on: displays) }
        guard !fullscreen.isEmpty else { return .failure(.noFullscreenSurface) }
        let titled = fullscreen.filter {
            guard let title = $0.title, !title.isEmpty else { return false }
            return !reservedTitles.contains(stem(title).lowercased())
        }
        guard !titled.isEmpty else { return .failure(.noAudienceTitle) }

        // Resolve both title spellings to a single document. macOS can hide or
        // show a known file extension. Exact matches are still required for names
        // with different explicit extensions, and ambiguous stems are rejected.
        let editorTitles = Set(windows.filter { !$0.visible && $0.layer == 0 }.compactMap(\.title))
        let titles = editorTitles.union(titled.compactMap(\.title))
        let documentsByTitle = Dictionary(uniqueKeysWithValues: titles.map { title in
            (title, documents.filter { represents(title, document: $0) })
        })
        var matches: [(window: Self, document: String)] = []
        for window in titled {
            guard let title = window.title, let names = documentsByTitle[title] else { continue }
            if names.count > 1 { return .failure(.ambiguous) }
            guard let name = names.first, editorTitles.contains(where: { editor in
                represents(editor, document: title) && documentsByTitle[editor] == [name]
            }) else { continue }
            matches.append((window, name))
        }
        guard let first = matches.first else { return .failure(.unverifiedDocument) }
        guard matches.allSatisfy({ $0.document == first.document && $0.window.frame == first.window.frame }),
              let top = matches.map({ $0.window.layer }).max() else { return .failure(.ambiguous) }
        let front = matches.filter { $0.window.layer == top }
        guard front.count == 1 else { return .failure(.ambiguous) }
        return .success((front[0].window.id, front[0].document))
    }

    fileprivate static func represents(_ title: String, document: String) -> Bool {
        title == document || stem(title) == document || stem(document) == title
    }

    private static func stem(_ name: String) -> String {
        let file = name as NSString
        return ["key", "ppt", "pptx"].contains(file.pathExtension.lowercased()) ? file.deletingPathExtension : name
    }
}

private extension KeynoteWindowIdentity {
    init(window: SCWindow) {
        self.init(id: window.windowID, title: window.title, frame: window.frame,
                  layer: window.windowLayer, visible: window.isOnScreen)
    }
}

/// Read-only core/getd events. Sending directly to a
/// live PID avoids launching Keynote if it quits between discovery and delivery.
private actor KeynoteEventReader {
    private typealias Descriptor = NSAppleEventDescriptor

    private func property(_ field: OSType, of container: Descriptor, pid: pid_t) throws -> Descriptor {
        let target = Descriptor(processIdentifier: pid)
        let object = try specifier(class: OSType(cProperty), form: OSType(formPropertyID),
                                   key: Descriptor(typeCode: field), of: container)
        try Task.checkCancellation()
        let event = Descriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                               targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(object, forKeyword: AEKeyword(keyDirectObject))
        let options: Descriptor.SendOptions = [.waitForReply, .neverInteract,
            .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
        let reply = try event.sendEvent(options: options, timeout: 1)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { throw Self.malformed }
        return value
    }

    func optionalDocumentID(named name: String, pid: pid_t) throws -> String? {
        do {
            return try documentID(named: name, pid: pid)
        } catch {
            let code = (error as NSError).code
            if code == Int(errAEEventWouldRequireUserConsent) || code == Int(errAEEventNotPermitted)
                || code == Int(procNotFound) || Task.isCancelled { throw error }
            return nil
        }
    }

    func documentID(named name: String, pid: pid_t) throws -> String {
        let document = try specifier(class: OSType(cDocument), form: OSType(formName),
                                     key: Descriptor(string: name), of: .null())
        let value = try property(OSType(pID), of: document, pid: pid)
        guard let id = value.stringValue, !id.isEmpty else { throw Self.malformed }
        return id
    }

    func windowDocumentIDs(_ ids: [CGWindowID], pid: pid_t) throws -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]
        for id in ids {
            let window = try specifier(class: OSType(cWindow), form: OSType(formUniqueID),
                                       key: Descriptor(int32: Int32(bitPattern: id)), of: .null())
            let document = try specifier(class: OSType(cProperty), form: OSType(formPropertyID),
                                        key: Descriptor(typeCode: OSType(cDocument)), of: window)
            do {
                let value = try property(OSType(pID), of: document, pid: pid)
                if let docID = value.stringValue, !docID.isEmpty { result[id] = docID }
            } catch let error as NSError where error.domain == NSOSStatusErrorDomain &&
                (error.code == Int(errAENoSuchObject) || error.code == Int(errAECoercionFail)) {
                continue // A window can close or lose its document between reads.
            }
        }
        return result
    }

    func isPlaying(pid: pid_t) throws -> Bool {
        // Keynote.sdef: Compatibility Suite, application.playing ('Plng').
        let playing = try property(0x506c6e67, of: .null(), pid: pid)
        guard let flag = playing.coerce(toDescriptorType: DescType(typeBoolean)) else { throw Self.malformed }
        return flag.booleanValue
    }

    func playingDocuments(pid: pid_t) throws -> [String]? {
        guard try isPlaying(pid: pid) else { return nil }
        var all = OSType(kAEAll)
        guard let ordinal = Descriptor(descriptorType: DescType(typeAbsoluteOrdinal), bytes: &all,
                                       length: MemoryLayout<OSType>.size) else { throw Self.malformed }
        let documents = try specifier(class: OSType(cDocument), form: OSType(formAbsolutePosition),
                                      key: ordinal, of: .null())
        let names = try property(OSType(pName), of: documents, pid: pid)
        guard names.descriptorType == typeAEList else { throw Self.malformed }
        return try (0..<names.numberOfItems).map {
            guard let name = names.atIndex($0 + 1)?.stringValue, !name.isEmpty else { throw Self.malformed }
            return name
        }
    }

    private static var malformed: NSError { NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail)) }

    private func specifier(class type: OSType, form: OSType, key: Descriptor, of container: Descriptor) throws -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: type), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(Descriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let result = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw Self.malformed }
        return result
    }
}
