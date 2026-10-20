import Foundation
import CryptoKit
import Darwin

public struct DiscoveredHost: Identifiable, Equatable, Sendable {
    public var id: String { alias }
    public let alias: String
    public let controlPath: String?
    public let resolutionIssue: String?
    public var suggestedControlPath: String { controlPath ?? "" }

    public init(alias: String, controlPath: String?, resolutionIssue: String? = nil) {
        self.alias = alias
        self.controlPath = controlPath
        self.resolutionIssue = resolutionIssue
    }
}

/// A deliberately static SSH configuration reader. Never invokes ssh, evaluates commands,
/// resolves DNS or changes configuration. Ambiguous settings require a manual socket path.
public enum HostDiscovery {
    public static func discover(home: String = NSHomeDirectory(), systemConfigPath: String? = "/etc/ssh/ssh_config") -> [DiscoveredHost] {
        let context = Context(home: home, localHostname: hostname(), localUser: NSUserName(), uid: getuid(), environment: ProcessInfo.processInfo.environment)
        var loader = Loader(context: context)
        let files = loader.roots(systemConfigPath: systemConfigPath)
        return Set(files.flatMap { $0.aliases }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
            resolved(alias: $0, files: files, context: context)
        }
    }

    /// Resolves wildcard-only hosts too, without needing a literal Host entry.
    public static func resolve(alias: String, home: String = NSHomeDirectory(), systemConfigPath: String? = "/etc/ssh/ssh_config") -> DiscoveredHost {
        let context = Context(home: home, localHostname: hostname(), localUser: NSUserName(), uid: getuid(), environment: ProcessInfo.processInfo.environment)
        var loader = Loader(context: context)
        return resolved(alias: alias, files: loader.roots(systemConfigPath: systemConfigPath), context: context)
    }

    /// Pure resolver for fixtures. Includes deliberately require the filesystem API.
    public static func resolve(alias: String, config: String, home: String, localHostname: String, localUser: String,
                               uid: UInt32 = UInt32(getuid()), environment: [String: String] = [:]) -> DiscoveredHost {
        let context = Context(home: home, localHostname: localHostname, localUser: localUser, uid: uid, environment: environment)
        let file = parse(config) { _ in [.issue("Include requires filesystem resolution; enter the socket path manually.")] }
        return resolved(alias: alias, files: [file], context: context)
    }

    public static func aliases(in text: String) -> [String] {
        parse(text) { _ in [] }.aliases.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func isSafeAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.count <= 200 && alias.first != "-" &&
        alias.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }

    private struct Context {
        var home: String
        var localHostname: String
        var localUser: String
        var uid: UInt32
        var environment: [String: String]
    }
    private indirect enum Entry {
        case directive(String, [String])
        case include([File])
        case issue(String)
    }
    private struct File {
        var entries: [Entry]
        var aliases: [String] {
            entries.flatMap { entry in
                switch entry {
                case .directive(let key, let words) where key == "host": return words.filter { isSafeAlias($0) }
                case .include(let files): return files.flatMap { $0.aliases }
                default: return []
                }
            }
        }
    }

    private static func parse(_ text: String, include: ([String]) -> [Entry]) -> File {
        var entries = [Entry]()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let words = tokenize(String(line)) else {
                entries.append(.issue("Unsupported or malformed SSH quoting; enter the socket path manually.")); continue
            }
            guard let first = words.first else { continue }
            let key = first.lowercased()
            let values = Array(words.dropFirst())
            if key == "include" { entries += include(values) }
            else { entries.append(.directive(key, values)) }
        }
        return File(entries: entries)
    }

    // Handles keyword=value, quotes, escaped whitespace and comments without evaluating anything.
    private static func tokenize(_ line: String) -> [String]? {
        var words = [String](), current = "", quote: Character?, escaped = false, started = false
        for char in line {
            if escaped {
                // Do not silently remove a backslash from an unfamiliar SSH escape.
                // Such values require manual resolution rather than a guessed socket path.
                guard char == "\\" || char == "\"" || char == "'" || (quote == nil && char.isWhitespace) else { return nil }
                current.append(char); escaped = false; started = true; continue
            }
            if char == "\\" { escaped = true; started = true; continue }
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
                continue
            }
            if char == "\"" || char == "'" { quote = char; started = true; continue }
            if char == "#" && !started { break }
            if char.isWhitespace || (char == "=" && words.isEmpty) {
                if started { words.append(current); current = ""; started = false }
                continue
            }
            // An optional = may follow spaces after the keyword.
            if char == "=" && words.count == 1 && !started { continue }
            current.append(char); started = true
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(current) }
        return words
    }

    private static func matches(_ host: String, patterns: [String]) -> Bool {
        var positive = false
        for pattern in patterns {
            let negated = pattern.hasPrefix("!")
            let value = negated ? String(pattern.dropFirst()) : pattern
            let match = wildcardMatch(host, pattern: value)
            if match && negated { return false }
            positive = positive || match
        }
        return positive
    }

    // OpenSSH patterns support only * and ?, unlike fnmatch's additional bracket syntax.
    private static func wildcardMatch(_ value: String, pattern: String) -> Bool {
        let text = Array(value), pattern = Array(pattern)
        var t = 0, p = 0, star: Int?, retry = 0
        while t < text.count {
            if p < pattern.count && (pattern[p] == "?" || pattern[p] == text[t]) { t += 1; p += 1 }
            else if p < pattern.count && pattern[p] == "*" { star = p; p += 1; retry = t }
            else if let previous = star { retry += 1; t = retry; p = previous + 1 }
            else { return false }
        }
        while p < pattern.count && pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    private static func resolved(alias: String, files: [File], context: Context) -> DiscoveredHost {
        func failure(_ reason: String) -> DiscoveredHost { DiscoveredHost(alias: alias, controlPath: nil, resolutionIssue: reason) }
        guard isSafeAlias(alias) else { return failure("Enter a literal SSH Host alias.") }
        var options = [String: String](), issue: String?
        func evaluate(_ file: File) {
            var active = true
            for entry in file.entries {
                switch entry {
                case .issue(let reason):
                    if active { issue = issue ?? reason }
                case .include(let included):
                    // OpenSSH restores the outer Host/Match state after each included file.
                    if active { included.forEach(evaluate) }
                case .directive(let key, let values):
                    if key == "host" { active = matches(alias, patterns: values); continue }
                    if key == "match" {
                        // Match can reactivate regardless of the previous Host block, and may
                        // request final/canonical passes. Never execute or guess its condition.
                        issue = issue ?? "Conditional Match configuration needs a manually resolved socket path."
                        active = false
                        continue
                    }
                    guard active else { continue }
                    if ["hostname", "user", "port", "controlpath", "canonicalizehostname", "canonicalizepermittedcnames", "proxyjump", "proxycommand"].contains(key) {
                        guard let value = values.first, !value.isEmpty else { issue = "SSH configuration has a missing value."; continue }
                        if key != "proxycommand" && values.count != 1 { issue = "SSH configuration has an unsupported value."; continue }
                        // ProxyJump and ProxyCommand compete: the first one obtained wins.
                        if key == "proxyjump" && options["proxycommand"] != nil { continue }
                        if key == "proxycommand" && options["proxyjump"] != nil { continue }
                        if options[key] == nil { options[key] = value }
                    }
                }
            }
        }
        files.forEach(evaluate)
        if let issue { return failure(issue) }
        if let canonical = options["canonicalizehostname"], canonical.lowercased() != "no" {
            return failure("Hostname canonicalization requires a manually resolved socket path.")
        }
        if let cnames = options["canonicalizepermittedcnames"], cnames.lowercased() != "none" {
            return failure("Hostname CNAME rules require a manually resolved socket path.")
        }
        guard var path = options["controlpath"], path.lowercased() != "none" else {
            return failure("No ControlPath is configured for this host. Enter the path of its existing master socket.")
        }
        do {
            let host = try expand(options["hostname"] ?? alias, tokens: ["h": alias], environment: [:], allowEnvironment: false).lowercased()
            // OpenSSH may normalize numeric IPv6 addresses through its resolver. Avoid guessing.
            if host.contains(":") { return failure("Numeric IPv6 HostName needs a manually resolved socket path.") }
            if host.allSatisfy({ $0.isNumber || $0 == "." }) {
                let octets = host.split(separator: ".", omittingEmptySubsequences: false)
                guard octets.count == 4, octets.allSatisfy({ part in
                    guard let value = Int(part), (0...255).contains(value) else { return false }
                    return String(value) == part
                }) else { return failure("Nonstandard numeric HostName needs a manually resolved socket path.") }
            }
            guard let port = Int(options["port"] ?? "22"), (1...65535).contains(port) else { return failure("SSH Port must be a numeric port.") }
            let jump = try jumpHostname(options["proxyjump"])
            var tokens: [Character: String] = ["n": alias, "h": host, "p": String(port), "u": context.localUser, "i": String(context.uid), "d": context.home, "l": context.localHostname, "L": context.localHostname.components(separatedBy: ".").first ?? context.localHostname, "j": jump]
            let remoteUser = try expand(options["user"] ?? context.localUser, tokens: tokens, environment: context.environment)
            tokens["r"] = remoteUser
            // OpenSSH hashes the final ProxyJump HOST only, excluding its user/port and preceding hops.
            tokens["C"] = Insecure.SHA1.hash(data: Data((context.localHostname + host + String(port) + remoteUser + jump).utf8)).map { String(format: "%02x", $0) }.joined()
            if path == "~" { path = context.home }
            else if path.hasPrefix("~/") { path = context.home + path.dropFirst() }
            else if path.hasPrefix("~") { return failure("Other users' home paths require manual resolution.") }
            path = try expand(path, tokens: tokens, environment: context.environment)
            guard path.hasPrefix("/"), !path.contains("\0") else { return failure("A relative ControlPath depends on the SSH launch directory; enter an absolute socket path.") }
            return DiscoveredHost(alias: alias, controlPath: path)
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private struct ResolutionError: LocalizedError {
        var errorDescription: String? { "Unsupported SSH token, environment variable or ProxyJump value; enter the resolved socket path manually." }
    }
    private static func expand(_ text: String, tokens: [Character: String], environment: [String: String], allowEnvironment: Bool = true) throws -> String {
        var result = "", index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "%" {
                index = text.index(after: index)
                guard index < text.endIndex else { throw ResolutionError() }
                if text[index] == "%" { result += "%" }
                else if let value = tokens[text[index]] { result += value }
                else { throw ResolutionError() }
            } else if char == "$" && allowEnvironment {
                let next = text.index(after: index)
                guard next < text.endIndex, text[next] == "{", let close = text[next...].firstIndex(of: "}") else { throw ResolutionError() }
                let name = String(text[text.index(after: next)..<close])
                guard let value = environment[name] else { throw ResolutionError() }
                result += value
                index = close
            } else { result.append(char) }
            index = text.index(after: index)
        }
        return result
    }

    private static func jumpHostname(_ value: String?) throws -> String {
        guard let value, value.lowercased() != "none" else { return "" }
        // Preserve hostname case exactly as parse_jump does; validate every hop.
        var final = ""
        for hop in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard !hop.isEmpty, !hop.contains("%"), !hop.contains("$") else { throw ResolutionError() }
            if hop.hasPrefix("ssh://") {
                guard let components = URLComponents(string: String(hop)), components.scheme == "ssh", let host = components.host,
                      !host.isEmpty, components.path.isEmpty, components.query == nil, components.fragment == nil else { throw ResolutionError() }
                final = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
                continue
            }
            let userParts = hop.split(separator: "@", omittingEmptySubsequences: false)
            guard userParts.count <= 2, userParts.allSatisfy({ !$0.isEmpty }) else { throw ResolutionError() }
            let target = String(userParts.last!)
            if target.hasPrefix("[") {
                guard let end = target.firstIndex(of: "]") else { throw ResolutionError() }
                final = String(target[target.index(after: target.startIndex)..<end])
                let suffix = String(target[target.index(after: end)...])
                guard suffix.isEmpty || (suffix.hasPrefix(":") && validPort(String(suffix.dropFirst()))) else { throw ResolutionError() }
            } else {
                let parts = target.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count <= 2, !parts[0].isEmpty else { throw ResolutionError() }
                if parts.count == 2 && !validPort(String(parts[1])) { throw ResolutionError() }
                final = String(parts[0])
            }
            guard !final.contains(where: \.isWhitespace) else { throw ResolutionError() }
        }
        return final
    }
    private static func validPort(_ value: String) -> Bool { Int(value).map { (1...65535).contains($0) } ?? false }
    private static func hostname() -> String {
        var bytes = [CChar](repeating: 0, count: 256)
        guard gethostname(&bytes, bytes.count) == 0 else { return "" }
        bytes[bytes.count - 1] = 0
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private struct Loader {
        var context: Context
        var stack = Set<String>()
        var count = 0
        var bytes = 0
        mutating func roots(systemConfigPath: String?) -> [File] {
            var result = [load(context.home + "/.ssh/config", user: true, depth: 0, optional: true)]
            if let systemConfigPath { result.append(load(systemConfigPath, user: false, depth: 0, optional: true)) }
            return result
        }
        mutating func load(_ path: String, user: Bool, depth: Int, optional: Bool = false) -> File {
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            guard depth < 8, count < 128, !stack.contains(canonical), bytes < 8_388_608 else {
                return File(entries: [.issue("SSH Includes exceed the safe discovery limit or contain a cycle; enter the socket path manually.")])
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: canonical), let size = attrs[.size] as? NSNumber else {
                return File(entries: optional ? [] : [.issue("An SSH Include could not be read; enter the socket path manually.")])
            }
            guard size.intValue <= 1_048_576, let text = try? String(contentsOfFile: canonical, encoding: .utf8) else {
                return File(entries: [.issue("An SSH config is too large or unreadable; enter the socket path manually.")])
            }
            stack.insert(canonical); count += 1; bytes += size.intValue
            defer { stack.remove(canonical) }
            return parse(text) { patterns in
                var entries = [Entry]()
                for raw in patterns {
                    do {
                        var pattern = try expand(raw, tokens: ["d": context.home, "u": context.localUser, "i": String(context.uid), "l": context.localHostname, "L": context.localHostname.components(separatedBy: ".").first ?? context.localHostname], environment: context.environment)
                        if pattern.hasPrefix("~/") && user { pattern = context.home + pattern.dropFirst() }
                        else if pattern.hasPrefix("~") { throw ResolutionError() }
                        if !pattern.hasPrefix("/") { pattern = (user ? context.home + "/.ssh/" : "/etc/ssh/") + pattern }
                        var matches = glob_t()
                        defer { globfree(&matches) }
                        let status = pattern.withCString { Darwin.glob($0, 0, nil, &matches) }
                        if status == GLOB_NOMATCH { continue }
                        guard status == 0, matches.gl_pathc <= 128 else { throw ResolutionError() }
                        var included = [File]()
                        for index in 0..<Int(matches.gl_pathc) {
                            guard let match = matches.gl_pathv[index] else { continue }
                            included.append(load(String(cString: match), user: user, depth: depth + 1))
                        }
                        entries.append(.include(included))
                    } catch { entries.append(.issue("Unsupported SSH Include expansion; enter the socket path manually.")) }
                }
                return entries
            }
        }
    }
}
