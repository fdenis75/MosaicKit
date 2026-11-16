import Foundation
import Testing
@testable import MosaicKit

@Suite("Remote read metering")
struct RemoteReadMeteringTests {
    @Test func httpsSourceIsRemote() {
        let info = RemoteSourceInfo.inspect(URL(string: "https://nas.example/video.mp4")!)
        #expect(info.isRemote)
        #expect(info.transport == "https")
        #expect(info.location == "nas.example")
    }

    @Test func temporaryFileIsLocalWithSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meter-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 1234).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let info = RemoteSourceInfo.inspect(url)
        #expect(!info.isRemote)
        #expect(info.fileSize == 1234)
    }

    @Test func localOperationsAreNotRecorded() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("local-\(UUID().uuidString).mp4")
        let value = try await RemoteReadMeter.measure(url: url, operation: "test") { 42 }
        #expect(value == 42)
        #expect(!RemoteReadLedger.shared.records.contains { $0.fileName == url.lastPathComponent })
    }

    @Test func counterDeltaIsMonotonic() {
        let a = IOCounterSnapshot.now()
        let b = IOCounterSnapshot.now()
        #expect(b.networkBytesIn >= a.networkBytesIn)
        #expect(a.networkBytesIn > 0)
    }

    @Test func remoteOperationIsRecorded() async throws {
        let url = URL(string: "https://nas.example/clip-\(UUID().uuidString).mp4")!
        let name = "nas.example" + url.path
        _ = try await RemoteReadMeter.measure(url: url, operation: "test") { 1 }
        let record = try #require(RemoteReadLedger.shared.records.last { $0.fileName == name })
        #expect(record.operation == "test")
        #expect(!record.failed)
        #expect(record.peakConcurrency >= 1)
    }
}
