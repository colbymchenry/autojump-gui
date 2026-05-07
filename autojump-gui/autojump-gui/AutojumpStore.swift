import Foundation

struct AutojumpEntry: Hashable, Identifiable {
    let path: String
    let weight: Double
    var id: String { path }
}

final class AutojumpStore {
    private(set) var entries: [AutojumpEntry] = []

    private var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/autojump/autojump.txt")
    }

    func reload() {
        guard let raw = try? String(contentsOf: dbURL, encoding: .utf8) else {
            entries = []
            return
        }
        var parsed: [AutojumpEntry] = []
        parsed.reserveCapacity(512)
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let weight = Double(parts[0]),
                  !parts[1].isEmpty else { continue }
            parsed.append(AutojumpEntry(path: String(parts[1]), weight: weight))
        }
        parsed.sort { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.path > rhs.path
        }
        entries = parsed
    }

    func search(query: String, limit: Int = 8) -> [AutojumpEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let needles = trimmed.split(separator: " ").map(String.init)
        let caseInsensitive = !needles.contains { $0.contains(where: { $0.isUppercase }) }

        let consecutive = compileConsecutive(needles, caseInsensitive: caseInsensitive)
        let anywhere = compileAnywhere(needles, caseInsensitive: caseInsensitive)

        var results: [AutojumpEntry] = []
        var seen = Set<String>()
        let fm = FileManager.default

        func collect(using regex: NSRegularExpression?) {
            guard let regex else { return }
            for entry in entries {
                if results.count >= limit { return }
                if seen.contains(entry.path) { continue }
                let range = NSRange(entry.path.startIndex..., in: entry.path)
                guard regex.firstMatch(in: entry.path, range: range) != nil else { continue }
                guard fm.fileExists(atPath: entry.path) else { continue }
                results.append(entry)
                seen.insert(entry.path)
            }
        }

        collect(using: consecutive)
        if results.count < limit { collect(using: anywhere) }
        return results
    }

    private func compileConsecutive(_ needles: [String], caseInsensitive: Bool) -> NSRegularExpression? {
        let escaped = needles.map { NSRegularExpression.escapedPattern(for: $0) }
        let noSep = "[^/]*"
        let between = "\(noSep)/\(noSep)"
        let pattern = escaped.joined(separator: between) + "\(noSep)$"
        return try? NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )
    }

    private func compileAnywhere(_ needles: [String], caseInsensitive: Bool) -> NSRegularExpression? {
        let escaped = needles.map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = ".*" + escaped.joined(separator: ".*") + ".*"
        return try? NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        )
    }
}
