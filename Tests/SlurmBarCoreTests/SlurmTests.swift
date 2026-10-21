import Foundation
import XCTest
@testable import SlurmBarCore

final class SlurmTests: XCTestCase {
    private func frame(nodes: String, jobs: String = "", jobStatus: Int = 0, uid: String = "1000") -> String {
        "\(SlurmParser.nodeMarker)\n\(nodes)\n\(SlurmParser.jobMarker)\n\(SlurmParser.userPrefix)\(uid)\n\(jobs)\n\(SlurmParser.jobStatusPrefix)\(jobStatus)\n\(SlurmParser.endMarker)\n"
    }

    func testNodeCategoriesAndSharedPartitionDoNotDoubleCount() throws {
        let snapshot = try SlurmParser.parse(frame(nodes: """
        cpu|n01|idle|0/64/0/64||up
        cpu|n02|mixed|32/32/0/64||up
        cpu|n03|allocated|64/0/0/64||up
        cpu|n04|draining|32/0/32/64||up
        cpu|n01|idle|0/64/0/64||up
        debug|n01|idle|0/64/0/64||up
        """))
        XCTAssertEqual(snapshot.partitions.map(\.name), ["cpu", "debug"])
        let cpu = snapshot.partitions[0]
        XCTAssertEqual(cpu.nodes.count, 4)
        XCTAssertEqual(cpu.idle, 1)
        XCTAssertEqual(cpu.mixed, 1)
        XCTAssertEqual(cpu.allocated, 1)
        XCTAssertEqual(cpu.unavailable, 1)
        XCTAssertEqual(snapshot.partitions[1].nodes.count, 1)
    }

    func testUnavailableFlagsOverrideIdleAndAllocation() {
        for state in ["idle*", "idle~", "idle#", "idle!", "idle%", "idle$", "idle@", "idle^", "idle-",
                      "idle+drain", "allocated+drain", "down", "drained", "draining", "reserved", "maint", "future", "unknown", "completing"] {
            let node = SlurmNode(name: "n", state: state, allocatedCPUs: 0, totalCPUs: 64)
            XCTAssertEqual(node.category, .unavailable, state)
        }
        XCTAssertEqual(SlurmNode(name: "n", state: "idle", allocatedCPUs: 0, totalCPUs: 64, reservation: "exam").category, .unavailable)
        XCTAssertEqual(SlurmNode(name: "n", state: "idle", allocatedCPUs: 0, totalCPUs: 64, partitionAvailability: "down").category, .unavailable)
        XCTAssertEqual(SlurmNode(name: "n", state: "idle", allocatedCPUs: 0, totalCPUs: 0).category, .unavailable)
    }

    func testSelectionIncludesJobsRequestedInSeveralPartitions() throws {
        let snapshot = try SlurmParser.parse(frame(nodes: """
        cpu|n01|idle|0/64/0/64||up
        debug|n01|idle|0/64/0/64||up
        """, jobs: """
        100|cpu,debug|training|PENDING|(Priority)|2026-10-20T18:00:00|1000
        101|debug|other|RUNNING|n01|2026-10-20T14:00:00|1000
        102|cpu|no estimate|PENDING|(Resources)|N/A|1000
        103|cpu|running|RUNNING|n02|2026-10-20T14:00:00|1000
        """), selectedPartitions: ["cpu"])
        XCTAssertEqual(snapshot.partitions.map(\.name), ["cpu"])
        XCTAssertEqual(snapshot.availablePartitionNames, ["cpu", "debug"])
        XCTAssertEqual(snapshot.jobs.map(\.id), ["100", "102", "103"])
        XCTAssertEqual(snapshot.jobs[0].expectedStart, "2026-10-20T18:00:00")
        XCTAssertEqual(snapshot.jobs[1].expectedStart, "")
        XCTAssertEqual(snapshot.jobs[2].expectedStart, "")
    }

    func testCombinedQueueCountsOtherUsersButOnlyListsOwnJobs() throws {
        let nodes = """
        cpu|n01|idle|0/64/0/64||up
        debug|n01|idle|0/64/0/64||up
        gpu|n02|idle|0/64/0/64||up
        """
        let jobs = """
        100|cpu|mine|PENDING|Priority|2026-10-20T18:00:00|1000
        101|cpu,debug|theirs|PENDING|Resources|Unknown|2000
        102_[1-100]|cpu,cpu|array|PENDING|Priority|Unknown|2000
        103|cpu|running|RUNNING|n01|2026-10-20T14:00:00|2000
        104|debug|my running job|RUNNING|n01|2026-10-20T14:00:00|1000
        """
        let snapshot = try SlurmParser.parse(frame(nodes: nodes, jobs: jobs))
        XCTAssertEqual(snapshot.partitions.map(\.pendingJobs), [3, 1, 0])
        XCTAssertEqual(snapshot.jobs.map(\.id), ["100", "104"])
        XCTAssertEqual(snapshot.jobs.first?.expectedStart, "2026-10-20T18:00:00")
        let filtered = try SlurmParser.parse(frame(nodes: nodes, jobs: jobs), selectedPartitions: ["cpu"])
        XCTAssertEqual(filtered.partitions.map(\.pendingJobs), [3])
        XCTAssertEqual(filtered.jobs.map(\.id), ["100"])
    }

    func testInvalidJobOwnersAndPartitionsAreRejected() {
        for job in ["1|cpu,,debug|name|PENDING|Priority|Unknown|1000",
                    "1|cpu|name|PENDING|Priority|Unknown|not-a-uid",
                    "1|cpu|name|PENDING|Priority|Unknown|",
                    "1|cpu|name|PENDING|Priority|Unknown"] {
            XCTAssertThrowsError(try SlurmParser.parse(frame(nodes: "", jobs: job)))
        }
        XCTAssertThrowsError(try SlurmParser.parse(frame(nodes: "", uid: "")))
    }

    func testMalformedDataCannotShowMisleadingOccupancy() {
        let malformed = [
            "cpu|n01|idle|0/64/0/63||up",
            "cpu|n01|idle|-1/64/0/63||up",
            "cpu|n01|idle|x/64/0/64||up",
            "cpu|n[01-02]|idle|0/128/0/128||up",
            "cpu|n01|idle|0/64/0/64|up",
            "cpu|n01|idle|0/64/0/64||up\u{1b}",
            "cpu|n01|idle|0/64/0/64||up\ncpu|n01|allocated|64/0/0/64||up"
        ]
        for nodes in malformed { XCTAssertThrowsError(try SlurmParser.parse(frame(nodes: nodes)), nodes) }
        XCTAssertThrowsError(try SlurmParser.parse("Welcome\n" + frame(nodes: "")))
        XCTAssertThrowsError(try SlurmParser.parse(String(repeating: "x", count: 8_388_609)))
        XCTAssertThrowsError(try SlurmParser.parse(frame(nodes: "", jobs: "1|cpu|name|with pipe|PENDING|reason|Unknown")))
    }

    func testCPUCountsRequireExactlyFourValidBoundedIntegers() {
        let malformed = [
            "0/bad/64/0/64", "0//64/0/64", "0/64/0/64/", "/0/64/0/64",
            "0/64/0", "0/64/0/64/0", "0/64//64", "0/64/0/invalid",
            "-1/64/0/63", "0/1000000001/0/1000000001",
            "0/9223372036854775807/1/0", "0/18446744073709551616/0/64",
            "1/64/0/64"
        ]
        for counts in malformed {
            XCTAssertThrowsError(try SlurmParser.parse(frame(nodes: "cpu|n01|idle|\(counts)||up")), counts) { error in
                XCTAssertEqual(error as? SlurmError, .invalidOutput("invalid CPU allocation counts"))
            }
        }
    }

    func testValidCPUCountsRetainZeroAndUpperBound() throws {
        for counts in ["0/0/0/0", "0/1000000000/0/1000000000", "1/2/3/6"] {
            let snapshot = try SlurmParser.parse(frame(nodes: "cpu|n01|mixed|\(counts)||up"))
            XCTAssertEqual(snapshot.partitions.first?.nodes.count, 1)
        }
    }

    func testIdleTotalUsesAnyAvailableSelectedPartition() {
        let snapshot = ClusterSnapshot(partitions: [
            PartitionSnapshot(name: "a-down", nodes: [SlurmNode(name: "n01", state: "idle", allocatedCPUs: 0, totalCPUs: 64, partitionAvailability: "down")]),
            PartitionSnapshot(name: "b-up", nodes: [SlurmNode(name: "n01", state: "idle", allocatedCPUs: 0, totalCPUs: 64)]),
            PartitionSnapshot(name: "c-up", nodes: [SlurmNode(name: "n01", state: "idle", allocatedCPUs: 0, totalCPUs: 64)])
        ], jobs: [])
        XCTAssertEqual(snapshot.uniqueIdleNodeCount, 1)
    }

    func testEmptyVisibleClusterIsValid() throws {
        let snapshot = try SlurmParser.parse(frame(nodes: ""))
        XCTAssertTrue(snapshot.partitions.isEmpty)
        XCTAssertTrue(snapshot.jobs.isEmpty)
    }

    func testJobQueryFailurePreservesNodesAndRejectsPartialJobs() throws {
        let snapshot = try SlurmParser.parse(frame(nodes: "cpu|n01|idle|0/64/0/64||up", jobs: "partial output", jobStatus: 1), stderr: "Access denied")
        XCTAssertEqual(snapshot.partitions.first?.idle, 1)
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertTrue(snapshot.jobsWarning?.contains("Access denied") == true)
        XCTAssertNil(snapshot.partitions.first?.pendingJobs)
        XCTAssertNotNil(snapshot.pendingWarning)
    }

    func testRefreshUsesExactlyOneSinfoAndOneSqueueForAllPartitions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sinfo = directory.appendingPathComponent("sinfo")
        let squeue = directory.appendingPathComponent("squeue")
        let calls = directory.appendingPathComponent("calls")
        try """
        #!/bin/sh
        printf 'sinfo %s\\n' "$*" >> "$CALLS"
        printf '%s\\n' 'cpu|n01|idle|0/64/0/64||up'
        """.write(to: sinfo, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf 'squeue %s\\n' "$*" >> "$CALLS"
        printf '%s\\n' '100|cpu|mine|PENDING|Priority|Unknown|\(getuid())' '101|cpu,debug|theirs|PENDING|Resources|Unknown|\(getuid() + 1)'
        """.write(to: squeue, atomically: true, encoding: .utf8)
        for file in [sinfo, squeue] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SlurmParser.command]
        process.environment = ["PATH": directory.path, "CALLS": calls.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let snapshot = try SlurmParser.parse(String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        XCTAssertEqual(snapshot.partitions.first?.pendingJobs, 2)
        XCTAssertEqual(snapshot.jobs.map(\.id), ["100"])
        let queries = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(queries.count, 2)
        XCTAssertTrue(queries[0].hasPrefix("sinfo "))
        XCTAssertEqual(queries[1], "squeue --local --start --states=all --noheader --format=%i|%P|%j|%T|%R|%S|%U")
    }

    func testRemoteScriptFramingAndFailureWithRealShell() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sinfo = directory.appendingPathComponent("sinfo")
        let squeue = directory.appendingPathComponent("squeue")
        try "#!/bin/sh\nprintf '%s\\n' 'cpu|n01|idle|0/64/0/64||up'\n".write(to: sinfo, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho 'Unsupported start prediction' >&2\nexit 1\n".write(to: squeue, atomically: true, encoding: .utf8)
        for file in [sinfo, squeue] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SlurmParser.command]
        process.environment = ["PATH": directory.path]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let snapshot = try SlurmParser.parse(output, stderr: errors)
        XCTAssertEqual(snapshot.partitions.first?.idle, 1)
        XCTAssertTrue(snapshot.jobsWarning?.contains("Unsupported start prediction") == true)
        XCTAssertNil(snapshot.partitions.first?.pendingJobs)
        XCTAssertNotNil(snapshot.pendingWarning)
    }
}
