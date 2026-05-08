import AppKit
import Combine
import Foundation

enum LaunchModifier: String, Codable, CaseIterable, Identifiable {
    case command, option, control

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option:  return "⌥"
        case .control: return "⌃"
        }
    }

    var displayName: String {
        switch self {
        case .command: return "Command"
        case .option:  return "Option"
        case .control: return "Control"
        }
    }

    /// Pick the dominant modifier from a key event. Prefers ⌃ > ⌥ > ⌘ when several
    /// are held, so power-user combos resolve deterministically. Returns nil when
    /// no relevant modifier is present (= plain Return → open in Finder).
    static func from(eventFlags: NSEvent.ModifierFlags) -> LaunchModifier? {
        let f = eventFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.control) { return .control }
        if f.contains(.option)  { return .option }
        if f.contains(.command) { return .command }
        return nil
    }
}

struct LaunchAction: Codable, Equatable {
    /// Absolute path to a `.app` bundle. `nil` means unconfigured — fall back to Finder.
    var appPath: String?
    /// Cached display name for the Settings UI.
    var appDisplayName: String?
    /// Optional argument template. `{path}` is replaced with the selected folder.
    /// When empty, the folder is opened with the chosen app via LaunchServices.
    var arguments: String

    static let empty = LaunchAction(appPath: nil, appDisplayName: nil, arguments: "")

    var isConfigured: Bool { appPath != nil }
}

@MainActor
final class LaunchActionsStore: ObservableObject {
    @Published var actions: [LaunchModifier: LaunchAction]

    static let shared = LaunchActionsStore()

    private static let defaultsKey = "LaunchActions.v1"

    private init() {
        var initial: [LaunchModifier: LaunchAction] = [:]
        if let raw = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: LaunchAction].self, from: raw) {
            for (key, value) in decoded {
                if let mod = LaunchModifier(rawValue: key) { initial[mod] = value }
            }
        }
        for mod in LaunchModifier.allCases where initial[mod] == nil {
            initial[mod] = .empty
        }
        self.actions = initial
    }

    func action(for modifier: LaunchModifier) -> LaunchAction {
        actions[modifier] ?? .empty
    }

    func update(_ action: LaunchAction, for modifier: LaunchModifier) {
        actions[modifier] = action
        save()
    }

    private func save() {
        var dict: [String: LaunchAction] = [:]
        for (mod, action) in actions { dict[mod.rawValue] = action }
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

enum ActionLauncher {
    /// Terminal emulators we know how to drive. For these, the Arguments field is treated
    /// as a shell command to run in a new window/tab at the selected folder, rather than
    /// as launch-time argv handed to `open --args` (which most terminal apps ignore).
    private enum TerminalKind {
        case terminalApp   // com.apple.Terminal — temp .command file via `open`
        case iterm2        // com.googlecode.iterm2 — temp .command file via `open`
        case ghostty       // com.mitchellh.ghostty — exec bundled `ghostty` binary
        case kitty         // net.kovidgoyal.kitty — exec bundled `kitty` binary
        case alacritty     // org.alacritty — exec bundled `alacritty` binary
        case wezterm       // com.github.wez.wezterm — exec bundled `wezterm` binary
    }

    static func openInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func bundleID(forAppAt appPath: String) -> String? {
        Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier
    }

    private static func terminalKind(forAppAt appPath: String) -> TerminalKind? {
        guard let id = bundleID(forAppAt: appPath) else { return nil }
        switch id {
        case "com.apple.Terminal":      return .terminalApp
        case "com.googlecode.iterm2":   return .iterm2
        case "com.mitchellh.ghostty":   return .ghostty
        case "net.kovidgoyal.kitty":    return .kitty
        case "org.alacritty":           return .alacritty
        case "com.github.wez.wezterm":  return .wezterm
        default:                        return nil
        }
    }

    static func isKnownTerminal(appPath: String) -> Bool {
        terminalKind(forAppAt: appPath) != nil
    }

    /// Run `action` against `path`. Falls back to opening in Finder when no app is configured.
    ///
    /// Behavior:
    /// - Known terminal emulator (Terminal.app, iTerm2, Ghostty, kitty, Alacritty, WezTerm) with
    ///   non-empty arguments → opens a new window/tab in that terminal at the selected folder
    ///   and runs the arguments as a shell command (via AppleScript or by invoking the terminal's
    ///   bundled CLI binary, depending on the emulator).
    /// - Empty arguments → open the folder with the chosen app via LaunchServices.
    /// - Arguments contain `{path}` → user has placed the folder explicitly; we shell out to
    ///   `/usr/bin/open -na <app> --args <substituted argv>` so the args go to the app.
    /// - Arguments are non-empty without `{path}` → folder is also opened, args are appended via
    ///   `open -a <app> <path> --args <argv>`.
    static func launch(_ action: LaunchAction, path: String) {
        guard let appPath = action.appPath, FileManager.default.fileExists(atPath: appPath) else {
            openInFinder(path)
            return
        }
        let template = action.arguments

        if !template.isEmpty, let kind = terminalKind(forAppAt: appPath) {
            runInTerminal(kind: kind, appPath: appPath, folder: path, commandTemplate: template)
            return
        }

        if template.isEmpty {
            let folderURL = URL(fileURLWithPath: path)
            let appURL = URL(fileURLWithPath: appPath)
            NSWorkspace.shared.open(
                [folderURL],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
            return
        }

        let substituted = template.replacingOccurrences(of: "{path}", with: path)
        let argv = parseShellArguments(substituted)
        let includesPath = template.contains("{path}")

        var openArgs = ["-a", appPath]
        if !includesPath { openArgs.append(path) }
        if !argv.isEmpty {
            openArgs.append("--args")
            openArgs.append(contentsOf: argv)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = openArgs
        do { try task.run() } catch { openInFinder(path) }
    }

    private static func runInTerminal(kind: TerminalKind, appPath: String, folder: String, commandTemplate: String) {
        let quotedFolder = shellSingleQuote(folder)
        let substitutedCommand = commandTemplate.replacingOccurrences(of: "{path}", with: quotedFolder)
        let shell = loginShellPath()

        switch kind {
        case .terminalApp, .iterm2:
            // We deliberately avoid AppleScript here: `do script` / `write text` require
            // the user to grant Automation→<terminal> permission to Autojump under
            // System Settings, and on modern macOS the prompt sometimes never appears,
            // leaving the call to silently no-op. A temp .command file opened with the
            // chosen terminal works on every machine without any TCC permission.
            runViaCommandFile(appPath: appPath, folder: folder, command: substitutedCommand, shell: shell)

        case .ghostty:
            // `--working-directory` sets cwd; `-e <shell> -lic <cmd>` runs the command in a login
            // + interactive shell so the user's PATH/aliases are loaded.
            execTerminalBinary(
                appPath: appPath,
                binaryName: "ghostty",
                arguments: ["--working-directory=\(folder)", "-e", shell, "-lic", substitutedCommand],
                fallbackFolder: folder
            )

        case .kitty:
            execTerminalBinary(
                appPath: appPath,
                binaryName: "kitty",
                arguments: ["--directory=\(folder)", shell, "-lic", substitutedCommand],
                fallbackFolder: folder
            )

        case .alacritty:
            execTerminalBinary(
                appPath: appPath,
                binaryName: "alacritty",
                arguments: ["--working-directory", folder, "-e", shell, "-lic", substitutedCommand],
                fallbackFolder: folder
            )

        case .wezterm:
            // wezterm's `start` subcommand spawns a new GUI window; `--` separates wezterm
            // flags from the program to run inside it.
            execTerminalBinary(
                appPath: appPath,
                binaryName: "wezterm",
                arguments: ["start", "--cwd", folder, "--", shell, "-lic", substitutedCommand],
                fallbackFolder: folder
            )
        }
    }

    /// Launch the named binary inside the chosen .app bundle. These terminal emulators ship a
    /// CLI binary under `Contents/MacOS/<name>` that, when launched, spawns/reuses the GUI
    /// process — so this both opens the window and runs the command in one step.
    private static func execTerminalBinary(
        appPath: String,
        binaryName: String,
        arguments: [String],
        fallbackFolder: String
    ) {
        let binaryURL = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/MacOS/\(binaryName)")
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            NSLog("ActionLauncher: terminal binary missing at %@; opening folder instead", binaryURL.path)
            openInFinder(fallbackFolder)
            return
        }
        let task = Process()
        task.executableURL = binaryURL
        task.arguments = arguments
        do {
            try task.run()
        } catch {
            NSLog("ActionLauncher: failed to run %@: %@", binaryURL.path, "\(error)")
            openInFinder(fallbackFolder)
        }
    }

    /// Drive Terminal.app / iTerm2 by writing a tiny .command shell script and opening it
    /// with the chosen terminal. The script `cd`s into `folder`, runs the user's command in
    /// a login + interactive user shell so PATH/aliases are loaded, then `exec`s back into
    /// an interactive shell so the window stays open after the command exits (matching what
    /// the user would see if they typed the command into a Terminal prompt themselves).
    private static func runViaCommandFile(appPath: String, folder: String, command: String, shell: String) {
        let pathArg = shellSingleQuote(folder)
        // `cd && cmd` so the command never runs in the wrong directory if cd fails.
        // `; exec $SHELL -i` keeps the window open with a fresh interactive prompt
        // after the user's command exits.
        let innerCommand = "cd \(pathArg) && \(command); exec \(shell) -i"
        let outerArg = shellSingleQuote(innerCommand)
        let scriptBody = """
        #!/bin/sh
        exec '\(shell)' -lic \(outerArg)
        """

        do {
            let dir = launchScriptsDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let scriptURL = dir.appendingPathComponent("launch-\(UUID().uuidString).command")
            try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: scriptURL.path
            )

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", appPath, scriptURL.path]
            try task.run()

            purgeOldLaunchScripts(in: dir)
        } catch {
            NSLog("ActionLauncher: failed to launch via .command file: %@", "\(error)")
            openInFinder(folder)
        }
    }

    private static func launchScriptsDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("autojump-gui-launches", isDirectory: true)
    }

    /// Delete .command scripts older than a day. Terminal opens them quickly, so anything
    /// still sitting around is just leftover from previous launches.
    private static func purgeOldLaunchScripts(in dir: URL) {
        let cutoff = Date(timeIntervalSinceNow: -86_400)
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        for url in urls where url.pathExtension == "command" {
            guard
                let attrs = try? fm.attributesOfItem(atPath: url.path),
                let mtime = attrs[.modificationDate] as? Date,
                mtime < cutoff
            else { continue }
            try? fm.removeItem(at: url)
        }
    }

    private static func loginShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Split a template string into argv with double-quote and backslash-escape support.
    /// Not a full POSIX parser — handles `"foo bar"` and `\"` but not single quotes or `$VAR`.
    private static func parseShellArguments(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\":
                escaped = true
            case "\"":
                inQuotes.toggle()
            case " ", "\t":
                if inQuotes {
                    current.append(ch)
                } else if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            default:
                current.append(ch)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }
}
