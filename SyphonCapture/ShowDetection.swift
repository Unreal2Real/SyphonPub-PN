// Both locators must confirm an audience window before offering it for capture.
enum ShowDetection<Window> {
    case idle
    case attention(String)
    case needsPermission(String)
    case window(Window, presentation: String)
}

enum ShowApplication: String {
    case powerPoint = "PowerPoint"
    case keynote = "Keynote"

    var bundleIdentifiers: [String] {
        switch self {
        case .powerPoint: return ["com.microsoft.Powerpoint"]
        case .keynote: return ["com.apple.Keynote", "com.apple.iWork.Keynote"]
        }
    }

    var other: Self { self == .powerPoint ? .keynote : .powerPoint }
}

enum ShowSelection<Window> {
    case window(ShowApplication, Window, presentation: String)
    case waiting(String)
}

@MainActor
func selectAudienceShow<Window>(
    first: ShowApplication,
    query: (ShowApplication) async -> ShowDetection<Window>
) async -> ShowSelection<Window> {
    var messages: [String] = []
    for app in [first, first.other] {
        switch await query(app) {
        case .window(let window, let presentation):
            return .window(app, window, presentation: presentation)
        case .idle:
            continue
        case .attention(let message), .needsPermission(let message):
            messages.append(message)
        }
    }
    return .waiting(messages.isEmpty ? "等待 PowerPoint 或 Keynote 放映" : messages.joined(separator: "\n"))
}
