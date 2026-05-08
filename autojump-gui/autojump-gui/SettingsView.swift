import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func pickApplication() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Choose"
    return panel.runModal() == .OK ? panel.url : nil
}

struct SettingsView: View {
    @ObservedObject var store: LaunchActionsStore = .shared

    var body: some View {
        TabView {
            ShortcutsTab(store: store)
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
    }
}

private struct ShortcutsTab: View {
    @ObservedObject var store: LaunchActionsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose what happens when you press Return with a modifier on a result. Plain Return always opens the folder in Finder.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(LaunchModifier.allCases) { modifier in
                    ActionRow(
                        modifier: modifier,
                        action: Binding(
                            get: { store.action(for: modifier) },
                            set: { store.update($0, for: modifier) }
                        )
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ActionRow: View {
    let modifier: LaunchModifier
    @Binding var action: LaunchAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(modifier.symbol) + Return")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if action.isConfigured {
                    Button("Clear") {
                        action = .empty
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                if let appPath = action.appPath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                        .resizable()
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                }
                Button(action.appDisplayName ?? "Choose application…") {
                    guard let url = pickApplication() else { return }
                    let appName = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                        ?? url.deletingPathExtension().lastPathComponent
                    action = LaunchAction(
                        appPath: url.path,
                        appDisplayName: appName,
                        arguments: action.arguments
                    )
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Arguments")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                TextField("{path}", text: Binding(
                    get: { action.arguments },
                    set: { action.arguments = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .disabled(!action.isConfigured)
            }

            Text(helpText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var helpText: String {
        if action.arguments.isEmpty {
            return "Opens the folder with the chosen app. Use {path} in Arguments to control where the folder is inserted."
        }
        if let appPath = action.appPath, ActionLauncher.isKnownTerminal(appPath: appPath) {
            return "Opens a new window in the chosen terminal and runs: cd <folder> && \(action.arguments)"
        }
        if action.arguments.contains("{path}") {
            return "Runs: open -na <app> --args \(action.arguments)"
        }
        return "Runs: open -a <app> <folder> --args \(action.arguments)"
    }
}
