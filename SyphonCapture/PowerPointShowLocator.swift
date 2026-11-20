import AppKit
import Carbon
import ScreenCaptureKit

/// Looks up the audience slideshow in PowerPoint's scripting model before
/// matching it to a capture window. Editor focus is irrelevant to this query.
@MainActor
enum PowerPointShowLocator {
    private static let bundleID = "com.microsoft.Powerpoint"
    private static let reader = PowerPointEventReader()

    static func locate(in windows: [SCWindow]) async -> ShowDetection<SCWindow> {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        guard !applications.isEmpty else { return .idle }
        guard applications.count == 1 else { return .attention("检测到多个 PowerPoint 进程，等待唯一的观众放映") }
        let app = applications[0]
        let pid = app.processIdentifier
        do {
            let show = try await reader.readShow(pid: pid)
            guard !Task.isCancelled, !app.isTerminated, let show else {
                return .idle
            }
            let owned = windows.filter {
                $0.owningApplication?.processID == pid &&
                $0.owningApplication?.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
            }
            let candidates = owned.map { PowerPointWindowIdentity(id: $0.windowID, frame: $0.frame, title: $0.title, isOnScreen: $0.isOnScreen) }
            guard let id = show.resolve(candidates), let window = owned.first(where: { $0.windowID == id }) else {
                return .attention("PowerPoint 已开始放映，等待确认观众窗口。可改用手动选择窗口。")
            }
            return .window(window, presentation: show.presentation)
        } catch {
            let e = error as NSError
            if e.code == Int(errAEEventWouldRequireUserConsent) || e.code == Int(errAEEventNotPermitted) {
                return .needsPermission("请点「授权 PowerPoint」检查自动化权限。")
            }
            if e.code == Int(procNotFound) || e.code == Int(errAENoSuchObject) {
                return .idle
            }
            if let issue = error as? ShowQueryError {
                return .attention(issue == .multiple ? "检测到多场放映，等待唯一的观众窗口" : "无法确认 PowerPoint 放映窗口，正在重试")
            }
            return .attention("正在重试 PowerPoint 放映查询（错误 \(e.code)）")
        }
    }
}

nonisolated struct PowerPointWindowIdentity: Sendable {
    let id: CGWindowID
    let frame: CGRect
    let title: String?
    let isOnScreen: Bool
}

nonisolated struct PowerPointShowInfo: Sendable {
    let id: CGWindowID?
    let frame: CGRect?
    let title: String?
    let presentation: String

    func resolve(_ windows: [PowerPointWindowIdentity]) -> CGWindowID? {
        // Script IDs are not specified to be CGWindowIDs. Corroborate them
        // with position, size, and any titles available from both APIs.
        let candidates = windows.filter { candidate in
            guard let frame else { return true }
            return abs(candidate.frame.minX - frame.minX) <= 2 && abs(candidate.frame.minY - frame.minY) <= 2 &&
                   abs(candidate.frame.maxX - frame.maxX) <= 2 && abs(candidate.frame.maxY - frame.maxY) <= 2
        }
        // Windows on different Spaces can have identical geometry. With a
        // collision require an audience-role title even if an ID also matches.
        if frame != nil, candidates.count == 1, let exact = candidates.first, exact.id == id,
           titlesAgree(exact.title, title), !Self.isPresenterTitle(exact.title) {
            return exact.id
        }

        // Some Office builds expose only an Office-local ID. Require a native
        // audience-role title plus the complete deck name, or a script-confirmed
        // role title *and* bounds. Neither a large window nor "active" is proof.
        let named = candidates.filter { candidate in
            guard candidate.isOnScreen || (frame != nil && candidate.id == id), let native = candidate.title,
                  let document = Self.audienceDocument(in: native) else { return false }
            if frame != nil, title == native { return true }
            let stem = (presentation as NSString).deletingPathExtension
            return !document.isEmpty && [presentation, stem].contains {
                !$0.isEmpty && document.caseInsensitiveCompare($0) == .orderedSame
            }
        }
        return named.count == 1 ? named[0].id : nil
    }

    private func titlesAgree(_ one: String?, _ other: String?) -> Bool {
        guard let one, !one.isEmpty, let other, !other.isEmpty else { return true }
        return one == other
    }

    private static func isPresenterTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return ["presenter view", "演讲者视图", "演示者视图", "簡報者檢視畫面"].contains {
            title.localizedCaseInsensitiveContains($0)
        }
    }

    private static func audienceDocument(in title: String) -> String? {
        let label = title.lowercased().replacingOccurrences(of: "microsoft powerpoint ", with: "powerpoint ",
                                                             options: .anchored)
        let roles = ["powerpoint slide show", "powerpoint 幻灯片放映", "powerpoint 投影片放映"]
        guard let role = roles.first(where: label.hasPrefix) else { return nil }
        var suffix = label.dropFirst(role.count).trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty else { return "" }
        if let separator = suffix.first, "-–—:：".contains(separator) {
            suffix = suffix.dropFirst().trimmingCharacters(in: .whitespaces)
        } else if !suffix.hasPrefix("[") {
            return nil
        }
        if suffix.hasPrefix("["), suffix.hasSuffix("]") { suffix = String(suffix.dropFirst().dropLast()) }
        return suffix
    }
}

nonisolated private enum ShowQueryError: Error { case multiple, malformed }

/// A single serial reader keeps synchronous Apple event replies off the UI
/// and limits automation traffic to the one poll in progress. Addressing by
/// PID never launches PowerPoint when it quits between discovery and send.
private actor PowerPointEventReader {
    typealias Descriptor = NSAppleEventDescriptor

    func readShow(pid: pid_t) throws -> PowerPointShowInfo? {
        try Task.checkCancellation()
        let target = Descriptor(processIdentifier: pid)
        let showClass = code("pSSw") // PowerPoint.sdef: slide show window
        func read(_ object: Descriptor) throws -> Descriptor {
            let event = Descriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                   targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                   transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(object, forKeyword: AEKeyword(keyDirectObject))
            return try reply(to: event)
        }

        let count = Descriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAECountElements),
                               targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                               transactionID: AETransactionID(kAnyTransactionID))
        count.setParam(.null(), forKeyword: AEKeyword(keyDirectObject))
        count.setParam(Descriptor(typeCode: showClass), forKeyword: AEKeyword(keyAEObjectClass))
        guard let number = try reply(to: count).coerce(toDescriptorType: DescType(typeSInt32)) else {
            throw ShowQueryError.malformed
        }
        guard number.int32Value != 0 else { return nil }
        guard number.int32Value == 1 else { throw ShowQueryError.multiple }

        let show = try objectSpecifier(want: showClass, form: OSType(formAbsolutePosition),
                                       selector: Descriptor(int32: 1), container: .null())
        func property(_ name: String, of container: Descriptor) throws -> Descriptor {
            try objectSpecifier(want: OSType(cProperty), form: OSType(formPropertyID),
                                selector: Descriptor(typeCode: code(name)), container: container)
        }

        let fullScreen = try read(property("SWfs", of: show))
        guard let bool = fullScreen.coerce(toDescriptorType: DescType(typeBoolean)) else { throw ShowQueryError.malformed }
        guard bool.booleanValue else { return nil }
        let bounds = try? Self.bounds(read(property("pbnd", of: show)))
        let id = try? read(property("ID  ", of: show)).coerce(toDescriptorType: DescType(typeSInt32))?.int32Value
        let title = try? read(property("pnam", of: show)).stringValue
        let presentation = try property("pptP", of: show)
        guard let name = try read(property("pnam", of: presentation)).stringValue, !name.isEmpty else {
            throw ShowQueryError.malformed
        }
        return PowerPointShowInfo(id: id.flatMap { $0 > 0 ? CGWindowID($0) : nil },
                                  frame: bounds, title: title, presentation: name)
    }

    private func code(_ fourCharacters: String) -> OSType {
        precondition(fourCharacters.utf8.count == 4)
        return fourCharacters.utf8.reduce(0) { $0 << 8 | OSType($1) }
    }

    private func objectSpecifier(want: OSType, form: OSType, selector: Descriptor, container: Descriptor) throws -> Descriptor {
        let record = Descriptor.record()
        record.setDescriptor(Descriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(Descriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(selector, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let result = record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else { throw ShowQueryError.malformed }
        return result
    }

    private func reply(to event: Descriptor) throws -> Descriptor {
        try Task.checkCancellation()
        let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract,
            .init(rawValue: UInt(kAEDoNotPromptForUserConsent))]
        let reply = try event.sendEvent(options: options, timeout: 1)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        guard let value = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { throw ShowQueryError.malformed }
        return value
    }

    static func bounds(_ descriptor: Descriptor) -> CGRect? {
        let left, top, right, bottom: Int
        if descriptor.descriptorType == typeQDRectangle, descriptor.data.count == 8 {
            // The QuickDraw record contains four native signed 16-bit values.
            let edges = descriptor.data.withUnsafeBytes { buffer in
                (0..<4).map { Int(buffer.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
            }
            (left, top, right, bottom) = (edges[1], edges[0], edges[3], edges[2])
        } else if descriptor.descriptorType == typeAEList, descriptor.numberOfItems == 4 {
            let values = (1...4).compactMap { descriptor.atIndex($0)?.coerce(toDescriptorType: DescType(typeSInt32))?.int32Value }
            guard values.count == 4 else { return nil }
            (left, top, right, bottom) = (Int(values[0]), Int(values[1]), Int(values[2]), Int(values[3]))
        } else {
            return nil
        }
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
