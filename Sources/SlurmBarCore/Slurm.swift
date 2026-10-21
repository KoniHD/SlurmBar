import Foundation

public enum NodeCategory: String, Sendable, CaseIterable {
    case idle, mixed, allocated, unavailable
}

public struct SlurmNode: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let state: String
    public let allocatedCPUs: Int
    public let totalCPUs: Int
    public let reservation: String
    public let partitionAvailability: String

    public init(name: String, state: String, allocatedCPUs: Int, totalCPUs: Int,
                reservation: String = "", partitionAvailability: String = "up") {
        self.name = name
        self.state = state
        self.allocatedCPUs = allocatedCPUs
        self.totalCPUs = totalCPUs
        self.reservation = reservation
        self.partitionAvailability = partitionAvailability
    }

    public var category: NodeCategory {
        let value = state.lowercased()
        // Flags must take precedence over the underlying IDLE/ALLOCATED state.
        guard partitionAvailability.lowercased() == "up",
              reservation.isEmpty || ["(null)", "none", "n/a"].contains(reservation.lowercased()),
              !value.contains(where: { "*~#!%$@^-".contains($0) }),
              totalCPUs > 0 else { return .unavailable }
        switch value {
        case "idle": return allocatedCPUs == 0 ? .idle : .unavailable
        case "mixed", "mix": return .mixed
        case "allocated", "alloc", "allocated+", "alloc+": return .allocated
        default: return .unavailable
        }
    }
}

public struct PartitionSnapshot: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let nodes: [SlurmNode]
    /// Visible pending queue entries; array tasks remain grouped as in squeue.
    public let pendingJobs: Int?
    public init(name: String, nodes: [SlurmNode], pendingJobs: Int? = nil) {
        self.name = name; self.nodes = nodes; self.pendingJobs = pendingJobs
    }
    public var idle: Int { nodes.filter { $0.category == .idle }.count }
    public var allocated: Int { nodes.filter { $0.category == .allocated }.count }
    public var mixed: Int { nodes.filter { $0.category == .mixed }.count }
    public var unavailable: Int { nodes.filter { $0.category == .unavailable }.count }
}

public struct SlurmJob: Identifiable, Sendable, Equatable {
    public let id: String
    public let partition: String
    public let name: String
    public let state: String
    public let reason: String
    /// Slurm's expected start for pending jobs; empty means no estimate is available.
    public let expectedStart: String
    public init(id: String, partition: String, name: String, state: String, reason: String, expectedStart: String) {
        self.id = id; self.partition = partition; self.name = name
        self.state = state; self.reason = reason; self.expectedStart = expectedStart
    }
}

public struct ClusterSnapshot: Sendable {
    /// Availability is partition-dependent; a node idle in any selected partition counts once.
    public var uniqueIdleNodeCount: Int {
        Set(partitions.flatMap(\.nodes).filter { $0.category == .idle }.map(\.name)).count
    }
    public let partitions: [PartitionSnapshot]
    public let jobs: [SlurmJob]
    public let updatedAt: Date
    public let availablePartitionNames: [String]
    public let jobsWarning: String?
    public let pendingWarning: String?
    public init(partitions: [PartitionSnapshot], jobs: [SlurmJob], updatedAt: Date = Date(),
                availablePartitionNames: [String]? = nil, jobsWarning: String? = nil, pendingWarning: String? = nil) {
        self.partitions = partitions; self.jobs = jobs; self.updatedAt = updatedAt
        self.availablePartitionNames = availablePartitionNames ?? partitions.map(\.name)
        self.jobsWarning = jobsWarning
        self.pendingWarning = pendingWarning
    }
}

public enum SlurmError: LocalizedError, Equatable {
    case commandFailed(Int32, String)
    case invalidOutput(String)
    public var errorDescription: String? {
        switch self {
        case let .commandFailed(code, detail):
            return "Slurm query failed (\(code)). \(detail) Check that sinfo and squeue are on the remote PATH and that your account can view Slurm."
        case let .invalidOutput(detail): return "Cannot read Slurm output: \(detail)"
        }
    }
}

public actor SlurmCollector {
    private let transport: SSHTransport
    public init(transport: SSHTransport) { self.transport = transport }

    public func collect(host: SSHHost) async throws -> ClusterSnapshot {
        let result = try await transport.run(command: SlurmParser.command, for: host)
        guard result.exitCode == 0 else {
            throw SlurmError.commandFailed(result.exitCode, String(result.stderr.prefix(2_048)))
        }
        return try SlurmParser.parse(result.stdout, selectedPartitions: host.selectedPartitions, stderr: result.stderr)
    }
}

/// Fixed read-only queries: no host names, partition names, or other user input enter this script.
enum SlurmParser {
    static let nodeMarker = "__SLURMBAR_NODES_V1__"
    static let jobMarker = "__SLURMBAR_JOBS_V1__"
    static let userPrefix = "__SLURMBAR_USER_V1__:"
    static let endMarker = "__SLURMBAR_END_V1__"
    static let jobStatusPrefix = "__SLURMBAR_JOB_STATUS_V1__:"
    static let command = "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
    private static let script = """
    LC_ALL=C; export LC_ALL
    SLURM_TIME_FORMAT=standard; export SLURM_TIME_FORMAT
    slurmbar_uid=$(/usr/bin/id -u) || exit $?
    printf '%s\\n' '__SLURMBAR_NODES_V1__'
    sinfo --local --hide --Node --exact --noheader --format='%R|%N|%T|%C|%i|%a' || exit $?
    printf '%s\\n' '__SLURMBAR_JOBS_V1__'
    printf '__SLURMBAR_USER_V1__:%s\\n' "$slurmbar_uid"
    squeue --local --start --states=all --noheader --format='%i|%P|%j|%T|%R|%S|%U'
    printf '__SLURMBAR_JOB_STATUS_V1__:%s\\n' "$?"
    printf '%s\\n' '__SLURMBAR_END_V1__'
    """

    static func parse(_ output: String, selectedPartitions: [String] = [], stderr: String = "") throws -> ClusterSnapshot {
        guard output.utf8.count <= 8_388_608 else { throw SlurmError.invalidOutput("response exceeds 8 MiB") }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 5, lines.count <= 100_005, lines.first == nodeMarker, lines.last == endMarker,
              let jobsIndex = lines.firstIndex(of: jobMarker), jobsIndex < lines.count - 3,
              lines[jobsIndex + 1].hasPrefix(userPrefix),
              let currentUID = UInt32(lines[jobsIndex + 1].dropFirst(userPrefix.count)),
              lines[lines.count - 2].hasPrefix(jobStatusPrefix),
              let jobStatus = Int(lines[lines.count - 2].dropFirst(jobStatusPrefix.count)),
              (0...255).contains(jobStatus),
              lines.filter({ $0 == jobMarker }).count == 1 else {
            throw SlurmError.invalidOutput("missing framing, unexpected login output, or too many records")
        }
        var partitions: [String: [String: SlurmNode]] = [:]
        for line in lines[1..<jobsIndex] {
            let fields = try fields(line, count: 6)
            let partition = fields[0]
            guard !partition.isEmpty, !fields[1].isEmpty,
                  !fields[1].contains(where: { "[],".contains($0) }) else {
                throw SlurmError.invalidOutput("expected one named node per partition record")
            }
            let rawCounts = fields[3].split(separator: "/", omittingEmptySubsequences: false)
            guard rawCounts.count == 4 else {
                throw SlurmError.invalidOutput("invalid CPU allocation counts")
            }
            let counts = try rawCounts.map { field in
                guard let count = Int(field), (0...1_000_000_000).contains(count) else {
                    throw SlurmError.invalidOutput("invalid CPU allocation counts")
                }
                return count
            }
            guard counts[0] + counts[1] + counts[2] == counts[3] else {
                throw SlurmError.invalidOutput("invalid CPU allocation counts")
            }
            let node = SlurmNode(name: fields[1], state: fields[2], allocatedCPUs: counts[0],
                                 totalCPUs: counts[3], reservation: fields[4], partitionAvailability: fields[5])
            if let previous = partitions[partition]?[node.name], previous != node {
                throw SlurmError.invalidOutput("conflicting duplicate node record")
            }
            partitions[partition, default: [:]][node.name] = node
        }
        let selection = Set(selectedPartitions)
        var pendingCounts: [String: Int] = [:]
        var jobs: [SlurmJob] = []
        for line in (jobStatus == 0 ? Array(lines[(jobsIndex + 2)..<(lines.count - 2)]) : []) {
            let fields = try fields(line, count: 7)
            let names = fields[1].split(separator: ",", omittingEmptySubsequences: false)
            guard !fields[0].isEmpty, !names.isEmpty, names.allSatisfy({ !$0.isEmpty }),
                  let ownerUID = UInt32(fields[6]) else {
                throw SlurmError.invalidOutput("job identifier, partition, or owner missing or invalid")
            }
            let requestedPartitions = Set(names.map(String.init))
            let isPending = fields[3].uppercased() == "PENDING"
            if isPending {
                for name in requestedPartitions { pendingCounts[name, default: 0] += 1 }
            }
            // Queue counts cover all visible owners; the personal list contains only this remote account.
            guard ownerUID == currentUID,
                  selection.isEmpty || !requestedPartitions.isDisjoint(with: selection) else { continue }
            let start = fields[5]
            let expected = isPending &&
                !["unknown", "n/a", "none", "(null)"].contains(start.lowercased()) ? start : ""
            jobs.append(SlurmJob(id: fields[0], partition: fields[1], name: fields[2], state: fields[3],
                                 reason: fields[4], expectedStart: expected))
        }
        let snapshots = partitions.keys.sorted().filter { selection.isEmpty || selection.contains($0) }.map { name in
            PartitionSnapshot(name: name, nodes: partitions[name]!.values.sorted { $0.name < $1.name },
                              pendingJobs: jobStatus == 0 ? pendingCounts[name, default: 0] : nil)
        }
        let warning = jobStatus == 0 ? nil : "Your jobs and start estimates are unavailable (squeue exited \(jobStatus)). \(String(stderr.prefix(2_048)))"
        let pendingWarning = jobStatus == 0 ? nil : "Pending counts are unavailable (squeue exited \(jobStatus))."
        return ClusterSnapshot(partitions: snapshots, jobs: jobs, availablePartitionNames: partitions.keys.sorted(),
                               jobsWarning: warning, pendingWarning: pendingWarning)
    }

    private static func fields(_ line: String, count: Int) throws -> [String] {
        guard line.utf8.count <= 16_384,
              !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SlurmError.invalidOutput("oversized record or control character")
        }
        let result = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard result.count == count else { throw SlurmError.invalidOutput("unexpected field count (names containing | are unsupported)") }
        return result
    }
}
