import Foundation

public struct DiscoveredHost: Identifiable, Equatable, Sendable {
    public var id: String { alias }
    public let alias: String
    public let suggestedControlPath: String
}

/// Reads literal Host/Include entries. Never evaluates Match exec or invokes ssh -G.
public enum HostDiscovery {
    public static func discover(home: String = NSHomeDirectory()) -> [DiscoveredHost] {
        var visited = Set<String>()
        let entries = read(path: home + "/.ssh/config", depth: 0, visited: &visited, home: home)
        return aliases(in: entries).map {
            DiscoveredHost(alias: $0, suggestedControlPath: home + "/.ssh/slurmbar/" + $0)
        }
    }

    public static func aliases(in text: String) -> [String] {
        var names = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: "#", maxSplits: 1).first.map(String.init)?.replacingOccurrences(of: "=", with: " ").split(whereSeparator: \.isWhitespace) ?? []
            guard words.first?.lowercased() == "host" else { continue }
            for name in words.dropFirst() {
                let value = String(name)
                if isSafeAlias(value) { names.insert(value) }
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func isSafeAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.count <= 200 && alias.first != "-" &&
        alias.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }

    private static func read(path: String, depth: Int, visited: inout Set<String>, home: String) -> String {
        guard depth < 8, visited.count < 128, !visited.contains(path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber, size.intValue < 1_048_576,
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        visited.insert(path)
        var output = contents
        for line in contents.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: "#", maxSplits: 1).first.map(String.init)?.split(whereSeparator: \.isWhitespace) ?? []
            guard words.first?.lowercased() == "include" else { continue }
            for word in words.dropFirst() {
                var include = String(word)
                // Literal includes only; glob expansion and conditional configuration are intentionally not evaluated.
                guard !include.contains("*"), !include.contains("?"), !include.contains("%"), !include.contains("$") else { continue }
                if include.hasPrefix("~/") { include = home + include.dropFirst() }
                if !include.hasPrefix("/") { include = home + "/.ssh/" + include }
                output += "\n" + read(path: include, depth: depth + 1, visited: &visited, home: home)
            }
        }
        return output
    }
}
