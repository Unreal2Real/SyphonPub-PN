import SwiftUI

@main
struct SyphonCaptureApp: App {
    @StateObject private var captureManager = CaptureManager()

    var body: some Scene {
        Window("SyphonPub PN", id: "capture") {
            ContentView()
                .environmentObject(captureManager)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SyphonPub PN") {
                    showAboutPanel()
                }
            }
        }

        MenuBarExtra {
            MenuBarMenuView()
                .environmentObject(captureManager)
        } label: {
            Image("SyphonPub-MenuBar")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Shows the standard macOS About panel with copyright and GitHub link.
func showAboutPanel() {
    NSApp.activate(ignoringOtherApps: true)

    let centered = NSMutableParagraphStyle()
    centered.alignment = .center

    let credits = NSMutableAttributedString(
        string: "Copyright © 2026 Xylopyrographer\n\n",
        attributes: [.paragraphStyle: centered]
    )
    for (label, url) in [
        ("SyphonPub PN · Unreal2Real\n", "https://github.com/Unreal2Real/SyphonPub-PN"),
        ("Original SyphonPub · Xylopyrographer", "https://github.com/Xylopyrographer/SyphonPub")
    ] {
        credits.append(NSAttributedString(string: label, attributes: [
            .link: URL(string: url)!, .paragraphStyle: centered
        ]))
    }

    NSApplication.shared.orderFrontStandardAboutPanel(options: [
        .credits: credits
    ])
}
