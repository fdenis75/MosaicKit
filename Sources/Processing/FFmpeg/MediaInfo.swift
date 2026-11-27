import Foundation

/// What `ffprobe` says about a source AVFoundation can't describe.
struct MediaInfo: Sendable, Equatable {
    let duration: TimeInterval
    /// Display size: sample aspect ratio and rotation applied.
    let width: Int
    let height: Int
    let frameRate: Double?
    /// ffmpeg codec names, for example `wmv2`.
    let videoCodec: String
    let audioCodec: String?
    let isInterlaced: Bool
    let formatNames: [String]

    var hasAudio: Bool { audioCodec != nil }

    /// The codec name shown in headers, matching the native path's spelling where there is one.
    static func displayName(ofCodec codec: String) -> String {
        switch codec {
        case "h264": "H.264"
        case "hevc": "HEVC (H.265)"
        case "vp9": "VP9"
        case "av1": "AV1"
        case "prores": "ProRes 422"
        case "aac": "AAC"
        case "ac3": "AC3"
        default: codec.uppercased()
        }
    }

    private struct Report: Decodable {
        struct Stream: Decodable {
            struct SideData: Decodable { let rotation: Double? }
            let codec_type: String?
            let codec_name: String?
            let width: Int?
            let height: Int?
            let sample_aspect_ratio: String?
            let avg_frame_rate: String?
            let r_frame_rate: String?
            let field_order: String?
            let duration: String?
            let disposition: [String: Int]?
            let tags: [String: String]?
            let side_data_list: [SideData]?
        }
        struct Format: Decodable {
            let format_name: String?
            let duration: String?
        }
        let streams: [Stream]?
        let format: Format?
    }

    /// Parses `ffprobe -print_format json -show_format -show_streams`.
    init(ffprobeJSON data: Data) throws {
        let report = try JSONDecoder().decode(Report.self, from: data)
        // Cover art is a "video" stream too: skip it (ffmpeg's `V` specifier does the same).
        guard let video = report.streams?.first(where: { $0.codec_type == "video" && ($0.disposition?["attached_pic"] ?? 0) == 0 }),
              let codec = video.codec_name, let storedWidth = video.width, let storedHeight = video.height,
              storedWidth > 0, storedHeight > 0, storedWidth <= 32_768, storedHeight <= 32_768 else {
            throw MosaicError.invalidVideo("Source contains no video track")
        }
        guard let duration = (report.format?.duration ?? video.duration).flatMap(Double.init),
              duration.isFinite, duration > 0 else {
            throw MosaicError.invalidVideo("Video duration must be finite and positive")
        }
        func ratio(_ text: String?, _ separator: Character) -> Double? {
            guard let parts = text?.split(separator: separator), parts.count == 2,
                  let top = Double(parts[0]), let bottom = Double(parts[1]), top > 0, bottom > 0 else { return nil }
            return top / bottom
        }
        let sar = ratio(video.sample_aspect_ratio, ":") ?? 1
        var width = Int((Double(storedWidth) * min(max(sar, 0.1), 10)).rounded())
        var height = storedHeight
        let rotation = video.side_data_list?.compactMap(\.rotation).first
            ?? video.tags?["rotate"].flatMap(Double.init) ?? 0
        if Int(abs(rotation).rounded()) % 180 == 90 { swap(&width, &height) }
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = (ratio(video.avg_frame_rate, "/") ?? ratio(video.r_frame_rate, "/")).flatMap { $0 <= 1000 ? $0 : nil }
        self.videoCodec = codec
        self.audioCodec = report.streams?.first(where: { $0.codec_type == "audio" })?.codec_name
        self.isInterlaced = ["tt", "bb", "tb", "bt"].contains(video.field_order ?? "")
        self.formatNames = report.format?.format_name?.split(separator: ",").map(String.init) ?? []
    }

    #if os(macOS)
    static func probe(_ url: URL, ffprobe: String) async throws -> MediaInfo {
        var arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams"]
        arguments += FFmpegRunner.inputArguments(for: url)
        let output = try await FFmpegRunner.run(ffprobe, arguments, timeout: 60)
        guard output.status == 0 else {
            throw MosaicError.invalidVideo("ffprobe can't read this file: \(output.stderr.suffix(300))")
        }
        return try MediaInfo(ffprobeJSON: output.stdout)
    }
    #endif
}
