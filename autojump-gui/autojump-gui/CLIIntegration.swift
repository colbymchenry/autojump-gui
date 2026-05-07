import Foundation

enum Shell: String, CaseIterable {
    case zsh, bash, fish, tcsh

    static func detect() -> Shell? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let name = (shellPath as NSString).lastPathComponent
        return Shell(rawValue: name)
    }

    var hookFileName: String { "autojump.\(rawValue)" }

    var rcFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .zsh:  return home.appendingPathComponent(".zshrc")
        case .bash: return home.appendingPathComponent(".bash_profile")
        case .fish: return home.appendingPathComponent(".config/fish/config.fish")
        case .tcsh: return home.appendingPathComponent(".tcshrc")
        }
    }

    func sourceBlock(installDir: String) -> String {
        let dir = installDir.replacingOccurrences(of: "\"", with: "\\\"")
        let hook = "\(dir)/\(hookFileName)"
        switch self {
        case .zsh, .bash:
            return """
            \(CLIIntegration.blockStart)
            if [ -s "\(hook)" ]; then
                export PATH="\(dir):$PATH"
                . "\(hook)"
            fi
            \(CLIIntegration.blockEnd)
            """
        case .fish:
            return """
            \(CLIIntegration.blockStart)
            if test -s "\(hook)"
                set -gx PATH "\(dir)" $PATH
                source "\(hook)"
            end
            \(CLIIntegration.blockEnd)
            """
        case .tcsh:
            return """
            \(CLIIntegration.blockStart)
            if ( -e "\(hook)" ) then
                setenv PATH "\(dir):${PATH}"
                source "\(hook)"
            endif
            \(CLIIntegration.blockEnd)
            """
        }
    }
}

enum CLIIntegrationError: LocalizedError {
    case bundleResourceMissing(String)
    case rcFileWriteFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .bundleResourceMissing(let f):
            return "Bundled CLI file is missing: \(f)."
        case .rcFileWriteFailed(let url, let err):
            return "Could not write \(url.path): \(err.localizedDescription)"
        }
    }
}

enum CLIIntegration {
    static let blockStart = "# >>> autojump-gui >>>"
    static let blockEnd = "# <<< autojump-gui <<<"

    private static let bundleFiles = [
        "autojump",
        "autojump_argparse.py",
        "autojump_data.py",
        "autojump_match.py",
        "autojump_utils.py",
        "autojump.bash",
        "autojump.fish",
        "autojump.sh",
        "autojump.tcsh",
        "autojump.zsh",
    ]

    static var installDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/autojump-gui/cli")
    }

    static func isInstalled(in shell: Shell) -> Bool {
        guard let contents = try? String(contentsOf: shell.rcFileURL, encoding: .utf8) else { return false }
        return contents.contains(blockStart)
    }

    static func install(shell: Shell) throws {
        try copyBundleFiles()
        try patchRcFile(shell: shell)
    }

    static func uninstall(shell: Shell) throws {
        try unpatchRcFile(shell: shell)
        // Files in installDirectory are intentionally kept so reinstalls are cheap.
    }

    private static func copyBundleFiles() throws {
        let fm = FileManager.default
        let dest = installDirectory
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let resources = Bundle.main.resourceURL else {
            throw CLIIntegrationError.bundleResourceMissing("(no resourceURL)")
        }
        for filename in bundleFiles {
            let src = resources.appendingPathComponent(filename)
            guard fm.fileExists(atPath: src.path) else {
                throw CLIIntegrationError.bundleResourceMissing(filename)
            }
            let destURL = dest.appendingPathComponent(filename)
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: src, to: destURL)
        }
        let autojumpPath = dest.appendingPathComponent("autojump").path
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: autojumpPath)
    }

    private static func patchRcFile(shell: Shell) throws {
        let url = shell.rcFileURL
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if existing.contains(blockStart) {
            existing = stripBlock(from: existing)
        }
        let block = shell.sourceBlock(installDir: installDirectory.path)
        let separator = (existing.isEmpty || existing.hasSuffix("\n")) ? "" : "\n"
        let newContents = existing + separator + "\n" + block + "\n"
        do {
            try newContents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw CLIIntegrationError.rcFileWriteFailed(url, underlying: error)
        }
    }

    private static func unpatchRcFile(shell: Shell) throws {
        let url = shell.rcFileURL
        guard let existing = try? String(contentsOf: url, encoding: .utf8),
              existing.contains(blockStart) else { return }
        let stripped = stripBlock(from: existing)
        do {
            try stripped.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw CLIIntegrationError.rcFileWriteFailed(url, underlying: error)
        }
    }

    private static func stripBlock(from text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result: [String] = []
        var inBlock = false
        for line in lines {
            if line.contains(blockStart) { inBlock = true; continue }
            if line.contains(blockEnd) { inBlock = false; continue }
            if !inBlock { result.append(line) }
        }
        while result.last == "" { result.removeLast() }
        return result.joined(separator: "\n") + "\n"
    }
}
