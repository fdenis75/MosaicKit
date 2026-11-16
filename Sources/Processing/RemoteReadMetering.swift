import Darwin
import Foundation
import OSLog
import os

private let logger = Logger(subsystem: "com.mosaicKit", category: "remote-io")
private let signposter = OSSignposter(subsystem: "com.mosaicKit", category: "remote-io")

// MARK: - Remote source detection

/// What MosaicKit knows about where a source lives, from Apple APIs only.
///
/// - `http`/`https` URLs are remote by definition.
/// - A file URL is remote when its volume is not local (`URLResourceValues.volumeIsLocal ==
///   false`: SMB, AFP, NFS, WebDAV, a NAS mounted in Finder). `statfs(2)` supplies the file
///   system type (`smbfs`, `nfs`, …), the mount source (`//user@nas/share`) and a second opinion
///   through the `MNT_LOCAL` flag.
public struct RemoteSourceInfo: Sendable, Equatable {
    /// `true` when reading the source moves bytes over a network.
    public let isRemote: Bool
    /// `https`, `http`, or the file-system type of the volume (`smbfs`, `nfs`, `apfs`, …).
    public let transport: String
    /// The host for a URL source, or the volume name for a file source.
    public let location: String
    /// The mount source from `statfs` (`//nas/share`), for a file on a mounted volume.
    public let mountSource: String?
    /// The file size in bytes: `URLResourceValues.fileSize` for a file, `nil` for a URL source.
    public let fileSize: Int64?

    public static func inspect(_ url: URL) -> RemoteSourceInfo {
        if !url.isFileURL {
            let scheme = url.scheme?.lowercased() ?? "unknown"
            return RemoteSourceInfo(isRemote: true, transport: scheme, location: url.host() ?? "?",
                                    mountSource: nil, fileSize: nil)
        }
        let values = try? url.resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeNameKey, .fileSizeKey, .fileAllocatedSizeKey
        ])
        var fs = statfs()
        let haveFS = statfs(url.path, &fs) == 0
        let fsType = haveFS ? string(from: fs.f_fstypename) : "unknown"
        let mountFrom = haveFS ? string(from: fs.f_mntfromname) : nil
        let flaggedLocal = haveFS ? (fs.f_flags & UInt32(MNT_LOCAL)) != 0 : true
        // `volumeIsLocal` is the documented answer; `MNT_LOCAL` only breaks a missing value.
        let isLocal = values?.volumeIsLocal ?? flaggedLocal
        return RemoteSourceInfo(
            isRemote: !isLocal,
            transport: fsType,
            location: values?.volumeName ?? "?",
            mountSource: mountFrom,
            fileSize: values?.fileSize.map(Int64.init)
        )
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

// MARK: - Counters

/// A point-in-time reading of the byte counters MosaicKit can observe.
struct IOCounterSnapshot: Sendable {
    /// Bytes received on every non-loopback network interface (64-bit link-layer counters).
    var networkBytesIn: UInt64
    /// Bytes this process read from physical disks (`ri_diskio_bytesread`).
    var processDiskBytesRead: UInt64

    static func now() -> IOCounterSnapshot {
        IOCounterSnapshot(networkBytesIn: readNetworkBytesIn(), processDiskBytesRead: readProcessDiskBytes())
    }

    static func - (lhs: IOCounterSnapshot, rhs: IOCounterSnapshot) -> IOCounterSnapshot {
        IOCounterSnapshot(networkBytesIn: lhs.networkBytesIn &- rhs.networkBytesIn,
                          processDiskBytesRead: lhs.processDiskBytesRead &- rhs.processDiskBytesRead)
    }

    #if os(macOS)
    /// `sysctl(NET_RT_IFLIST2)` returns `if_data64`, whose byte counters don't wrap at 4 GiB the
    /// way the 32-bit counters of `getifaddrs` do.
    private static func readNetworkBytesIn() -> UInt64 {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return 0 }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return 0 }
        var total: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let size = Int(header.ifm_msglen)
                guard size > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if (UInt32(bitPattern: info.ifm_flags) & UInt32(IFF_LOOPBACK)) == 0 {
                        total &+= info.ifm_data.ifi_ibytes
                    }
                }
                offset += size
            }
        }
        return total
    }

    private static func readProcessDiskBytes() -> UInt64 {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 ? usage.ri_diskio_bytesread : 0
    }
    #else
    /// iOS and Mac Catalyst have neither `NET_RT_IFLIST2` nor `libproc`: sum the 32-bit
    /// `getifaddrs` counters (they wrap at 4 GiB, so a very long operation can under-report)
    /// and report no process disk reads.
    private static func readNetworkBytesIn() -> UInt64 {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return 0 }
        defer { freeifaddrs(list) }
        var total: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let info = entry.pointee
            if let address = info.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               (info.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, let data = info.ifa_data {
                total &+= UInt64(data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes)
            }
            cursor = info.ifa_next
        }
        return total
    }

    private static func readProcessDiskBytes() -> UInt64 { 0 }
    #endif
}

// MARK: - Records

/// What was read from a remote source during one measured operation (public for host apps).
///
/// **How exact is it?** MosaicKit cannot see inside AVFoundation's reads, so the numbers are
/// derived from system counters, not from the reader itself:
/// - ``networkBytesIn`` is exact for the interface counters, but those count *everything* the
///   Mac received (other apps, protocol headers, SMB/TCP overhead of a few percent), and the
///   share attributed to this file is an equal split between the overlapping operations.
///   It is closest to the truth when ``isolated`` is `true`.
/// - ``networkBytesInWindow`` is the raw counter delta over the operation: an upper bound.
/// - ``fileSize`` is exact metadata, so `networkBytesIn / fileSize` shows how much of the file was
///   really transferred (a mosaic seeks to a few frames, so it is usually a small fraction).
/// - ``processDiskBytesRead`` is *physical disk* I/O of this process (cache, temp files,
///   output). Reads from an SMB/NFS mount do not count there.
public struct RemoteReadRecord: Sendable, Identifiable {
    public let id = UUID()
    public let fileName: String
    public let operation: String
    public let source: RemoteSourceInfo
    /// Equal-share attribution of the network bytes received while this operation ran.
    public let networkBytesIn: UInt64
    /// Raw network bytes received over the whole operation, whoever caused them (upper bound).
    public let networkBytesInWindow: UInt64
    public let processDiskBytesRead: UInt64
    public let duration: TimeInterval
    /// `true` when no other measured operation overlapped this one.
    public let isolated: Bool
    /// The largest number of measured operations that ran at the same time as this one.
    public let peakConcurrency: Int
    public let failed: Bool
}

/// Totals for one source file across every operation measured on it.
public struct RemoteReadFileTotal: Sendable {
    public let fileName: String
    public let source: RemoteSourceInfo
    public let networkBytesIn: UInt64
    public let operations: Int
}

/// Collects ``RemoteReadRecord``s. Thread safe. Read it from a host app to show or export them.
public final class RemoteReadLedger: Sendable {
    public static let shared = RemoteReadLedger()

    private struct Window {
        let token: UUID
        let fileName: String
        let operation: String
        let source: RemoteSourceInfo
        let start: ContinuousClock.Instant
        let startSnapshot: IOCounterSnapshot
        var attributedNetwork: Double = 0
        var attributedDisk: Double = 0
        var peakConcurrency: Int = 1
    }

    private struct State {
        var active: [UUID: Window] = [:]
        var last = IOCounterSnapshot(networkBytesIn: 0, processDiskBytesRead: 0)
        var batchStart: IOCounterSnapshot?
        var batchBegan: ContinuousClock.Instant?
        var batchOperations = 0
        var records: [RemoteReadRecord] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Every record since launch or the last ``reset()``.
    public var records: [RemoteReadRecord] { state.withLock { $0.records } }

    /// Per-file totals (network bytes summed over every operation on the same file).
    public var fileTotals: [RemoteReadFileTotal] {
        let all = records
        var order: [String] = []
        var grouped: [String: [RemoteReadRecord]] = [:]
        for record in all {
            if grouped[record.fileName] == nil { order.append(record.fileName) }
            grouped[record.fileName, default: []].append(record)
        }
        return order.compactMap { name in
            guard let group = grouped[name], let first = group.first else { return nil }
            return RemoteReadFileTotal(fileName: name, source: first.source,
                                       networkBytesIn: group.reduce(0) { $0 + $1.networkBytesIn },
                                       operations: group.count)
        }
    }

    public func reset() { state.withLock { $0.records.removeAll() } }

    // MARK: Window lifecycle

    fileprivate func begin(fileName: String, operation: String, source: RemoteSourceInfo) -> UUID {
        let token = UUID()
        let now = IOCounterSnapshot.now()
        state.withLock { state in
            distribute(until: now, in: &state)
            if state.active.isEmpty {
                state.batchStart = now
                state.batchBegan = .now
                state.batchOperations = 0
            }
            state.batchOperations += 1
            state.active[token] = Window(token: token, fileName: fileName, operation: operation,
                                         source: source, start: .now, startSnapshot: now)
            let count = state.active.count
            for key in Array(state.active.keys) {
                if var w = state.active[key] {
                    w.peakConcurrency = max(w.peakConcurrency, count)
                    state.active[key] = w
                }
            }
        }
        let sizeText = source.fileSize.map { Self.format($0) } ?? "unknown"
        logger.info("""
        ▶︎ remote read START [\(operation, privacy: .public)] \(fileName, privacy: .public) \
        — \(source.transport, privacy: .public) \(source.location, privacy: .public) \
        mount=\(source.mountSource ?? "-", privacy: .public) size=\(sizeText, privacy: .public)
        """)
        return token
    }

    fileprivate func end(_ token: UUID, failed: Bool) {
        let now = IOCounterSnapshot.now()
        let (record, batchSummary): (RemoteReadRecord?, String?) = state.withLock { state in
            var record: RemoteReadRecord?
            var batchSummary: String?
            distribute(until: now, in: &state)
            guard let window = state.active.removeValue(forKey: token) else { return (nil, nil) }
            let raw = now - window.startSnapshot
            let duration = window.start.duration(to: .now)
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            let made = RemoteReadRecord(
                fileName: window.fileName, operation: window.operation, source: window.source,
                networkBytesIn: UInt64(window.attributedNetwork.rounded()),
                networkBytesInWindow: raw.networkBytesIn,
                processDiskBytesRead: UInt64(window.attributedDisk.rounded()),
                duration: seconds, isolated: window.peakConcurrency == 1,
                peakConcurrency: window.peakConcurrency, failed: failed
            )
            state.records.append(made)
            record = made
            if state.active.isEmpty, let start = state.batchStart, let began = state.batchBegan {
                let total = now - start
                let span = began.duration(to: .now)
                let spanSeconds = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
                batchSummary = "network_in=\(Self.format(total.networkBytesIn)) disk_read=\(Self.format(total.processDiskBytesRead)) "
                    + "operations=\(state.batchOperations) elapsed=\(String(format: "%.1f", spanSeconds))s"
            }
            return (record, batchSummary)
        }
        if let record { log(record) }
        if let batchSummary {
            logger.info("Σ remote read BATCH TOTAL (exact interface delta, no double counting) \(batchSummary, privacy: .public)")
        }
    }

    /// Splits the counter growth since the previous event equally between the operations that
    /// were running during it, so overlapping files don't each claim the whole delta.
    private func distribute(until now: IOCounterSnapshot, in state: inout State) {
        defer { state.last = now }
        guard !state.active.isEmpty else { return }
        let delta = now - state.last
        let share = 1.0 / Double(state.active.count)
        for key in Array(state.active.keys) {
            state.active[key]?.attributedNetwork += Double(delta.networkBytesIn) * share
            state.active[key]?.attributedDisk += Double(delta.processDiskBytesRead) * share
        }
    }

    private func log(_ record: RemoteReadRecord) {
        let ratio: String
        if let size = record.source.fileSize, size > 0 {
            ratio = String(format: "%.2f%% of file", Double(record.networkBytesIn) / Double(size) * 100)
        } else {
            ratio = "ratio n/a"
        }
        let mbps = record.duration > 0 ? Double(record.networkBytesIn) / record.duration / 1_000_000 : 0
        let quality = record.isolated ? "isolated (single operation)"
            : "shared (equal split across \(record.peakConcurrency) concurrent operations)"
        let state = record.failed ? "FAILED" : "done"
        logger.info("""
        ◼︎ remote read END [\(record.operation, privacy: .public)] \(record.fileName, privacy: .public) \(state, privacy: .public) \
        — network_in=\(Self.format(record.networkBytesIn), privacy: .public) (\(record.networkBytesIn) B, \(ratio, privacy: .public)) \
        window_upper_bound=\(Self.format(record.networkBytesInWindow), privacy: .public) \
        process_disk_read=\(Self.format(record.processDiskBytesRead), privacy: .public) \
        duration=\(String(format: "%.2f", record.duration), privacy: .public)s \
        rate=\(String(format: "%.1f", mbps), privacy: .public) MB/s attribution=\(quality, privacy: .public)
        """)
        signposter.emitEvent("remote read",
                             "\(record.fileName, privacy: .public) \(record.operation, privacy: .public) bytes=\(record.networkBytesIn)")
    }

    static func format(_ bytes: UInt64) -> String { format(Int64(clamping: bytes)) }
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

// MARK: - Entry point

enum RemoteReadMeter {
    /// Runs `body`, and when `url` is remote records the bytes received while it ran.
    ///
    /// Costs one `statfs`/resource lookup for a local file and nothing else; set
    /// `MOSAICKIT_REMOTE_IO=0` in the environment to switch the whole feature off.
    static func measure<T>(
        url: URL,
        operation: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard ProcessInfo.processInfo.environment["MOSAICKIT_REMOTE_IO"] != "0" else { return try await body() }
        let source = RemoteSourceInfo.inspect(url)
        guard source.isRemote else { return try await body() }
        let ledger = RemoteReadLedger.shared
        let name = url.isFileURL ? url.lastPathComponent : (url.host() ?? "?") + url.path
        let token = ledger.begin(fileName: name, operation: operation, source: source)
        do {
            let value = try await body()
            ledger.end(token, failed: false)
            return value
        } catch {
            ledger.end(token, failed: true)
            throw error
        }
    }
}
