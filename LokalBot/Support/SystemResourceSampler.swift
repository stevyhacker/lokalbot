import Darwin
import Foundation

/// Stateless CPU and memory readings for the LokalBot process family from
/// Mach/libproc. Every call answers "what is true right now" and the caller
/// owns the cadence.
enum SystemResourceSampler {
    /// One process reading used to build a whole-app sample. CPU time is
    /// cumulative, so callers compare two snapshots to get Activity Monitor's
    /// multi-core percentage (which may legitimately exceed 100%).
    struct ProcessUsage: Equatable, Sendable {
        let processIdentifier: pid_t
        let startTime: UInt64
        let cpuTimeNanoseconds: UInt64
        let physicalFootprintBytes: UInt64

        var identity: ProcessIdentity {
            ProcessIdentity(processIdentifier: processIdentifier, startTime: startTime)
        }
    }

    struct ProcessIdentity: Hashable, Sendable {
        let processIdentifier: pid_t
        let startTime: UInt64
    }

    struct UsageSnapshot: Equatable, Sendable {
        let capturedAt: TimeInterval
        let processes: [ProcessUsage]

        var totalPhysicalFootprintBytes: UInt64 {
            processes.reduce(0) { $0 + $1.physicalFootprintBytes }
        }

        func usage(for processIdentifier: pid_t) -> ProcessUsage? {
            processes.first { $0.processIdentifier == processIdentifier }
        }
    }

    /// Samples LokalBot plus every descendant process (llama-server, Agent
    /// Mode, transient native helpers). Extra PIDs cover a healthy llama-server
    /// adopted from a prior app process, which is no longer our descendant.
    static func usageSnapshot(additionalProcessIdentities: [ProcessIdentity] = []) -> UsageSnapshot {
        let root = getpid()
        let familyIdentifiers = Set([root] + descendantProcessIdentifiers(of: root))
        var processes = familyIdentifiers.sorted().compactMap(processUsage(for:))

        // Adopted llama servers are no longer descendants. Match both PID and
        // start time before adding one so a stale marker cannot make an
        // unrelated process part of LokalBot's headline CPU/RAM totals.
        let adoptedIdentities = Set(additionalProcessIdentities).filter {
            $0.processIdentifier > 0 && !familyIdentifiers.contains($0.processIdentifier)
        }
        for identity in adoptedIdentities {
            guard let usage = processUsage(for: identity.processIdentifier),
                  usage.startTime == identity.startTime else { continue }
            processes.append(usage)
        }
        return UsageSnapshot(
            capturedAt: ProcessInfo.processInfo.systemUptime,
            processes: processes.sorted { $0.processIdentifier < $1.processIdentifier }
        )
    }

    /// Combined CPU percentage between two whole-app samples. Identity includes
    /// the process start time so a rapidly reused PID never creates a huge,
    /// bogus delta. New and exited helpers begin/leave contributing cleanly.
    static func cpuUsagePercent(from previous: UsageSnapshot,
                                to current: UsageSnapshot) -> Double? {
        let elapsed = current.capturedAt - previous.capturedAt
        guard elapsed > 0 else { return nil }

        let previousByIdentity = Dictionary(uniqueKeysWithValues: previous.processes.map {
            ($0.identity, $0)
        })
        var cpuDelta: UInt64 = 0
        var matchedProcess = false
        for process in current.processes {
            guard let old = previousByIdentity[process.identity],
                  process.cpuTimeNanoseconds >= old.cpuTimeNanoseconds else { continue }
            matchedProcess = true
            cpuDelta += process.cpuTimeNanoseconds - old.cpuTimeNanoseconds
        }
        guard matchedProcess else { return nil }
        return Double(cpuDelta) / (elapsed * 1_000_000_000) * 100
    }

    static func processUsage(for processIdentifier: pid_t) -> ProcessUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processIdentifier, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return ProcessUsage(
            processIdentifier: processIdentifier,
            startTime: info.ri_proc_start_abstime,
            cpuTimeNanoseconds: info.ri_user_time + info.ri_system_time,
            physicalFootprintBytes: info.ri_phys_footprint
        )
    }

    private static func descendantProcessIdentifiers(of root: pid_t) -> [pid_t] {
        var visited = Set<pid_t>([root])
        var queue = [root]
        var descendants: [pid_t] = []

        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in directChildProcessIdentifiers(of: parent)
            where child > 0 && visited.insert(child).inserted {
                descendants.append(child)
                queue.append(child)
            }
        }
        return descendants
    }

    private static func directChildProcessIdentifiers(of parent: pid_t) -> [pid_t] {
        // The nil-buffer call returns a PID-count estimate. Leave slack because
        // the process tree can grow between the sizing and population calls.
        let estimatedCount = max(Int(proc_listchildpids(parent, nil, 0)), 0)
        var identifiers = [pid_t](repeating: 0, count: max(estimatedCount + 16, 32))
        let count = identifiers.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(identifiers.prefix(min(Int(count), identifiers.count)))
    }
}
