import SwiftUI

struct PermissionSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authorizer = ShowAutomationAuthorizer.shared
    @State private var results: [ShowApplication: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("允许读取放映状态").font(.title2)
            Text("需要自动跟随时，打开要用的放映软件，在编辑界面点下面对应的按钮。")
            ForEach([ShowApplication.keynote, .powerPoint], id: \.self) { app in
                VStack(alignment: .leading, spacing: 4) {
                    Button("授权 " + app.rawValue) {
                        Task { results[app] = await authorizer.request(app) }
                    }
                    .disabled(authorizer.pending != nil)
                    if authorizer.pending == app {
                        Text("请在 macOS 的授权窗口中选择。")
                    } else if let result = results[app] {
                        Text(result).textSelection(.enabled)
                    }
                }
            }
            HStack {
                Button("打开自动化设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 450, alignment: .leading)
    }
}
