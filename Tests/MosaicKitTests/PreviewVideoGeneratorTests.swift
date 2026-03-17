import Foundation
import Testing
@testable import MosaicKit

struct PreviewVideoGeneratorTests {
    @Test("Preview extract timestamps are formatted as HH:MM:SS")
    func extractTimestampFormatting() {
        #expect(PreviewGenerationLogic.formatExtractTimestamp(seconds: 0) == "00:00:00")
        #expect(PreviewGenerationLogic.formatExtractTimestamp(seconds: 65.9) == "00:01:05")
        #expect(PreviewGenerationLogic.formatExtractTimestamp(seconds: 3_723.4) == "01:02:03")
    }
}
