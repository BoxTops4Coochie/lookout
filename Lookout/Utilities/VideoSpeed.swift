import Foundation
import AVFoundation

/// App-side playback speed for exports.
/// Frigate's export API only supports realtime or timelapse_25x, so other
/// speeds = realtime export + lossless timeline compression here (no re-encode).
enum VideoSpeed {
    /// export_id -> requested speed multiplier, persisted so the Exports tab
    /// knows to post-process a realtime download
    private static let key = "Lookout.exportSpeeds"

    static func setSpeed(_ speed: Double, forExport id: String) {
        var m = defaults()
        m[id] = speed
        UserDefaults.standard.set(m, forKey: key)
    }

    static func speed(forExport id: String) -> Double {
        defaults()[id] ?? 1
    }

    static func clearSpeed(forExport id: String) {
        var m = defaults()
        m.removeValue(forKey: id)
        UserDefaults.standard.set(m, forKey: key)
    }

    private static func defaults() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
    }

    static func process(_ input: URL, speed: Double) async throws -> URL {
        guard speed > 1.01 else { return input }
        let asset = AVURLAsset(url: input)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return input }

        let composition = AVMutableComposition()
        guard let track = asset.tracks(withMediaType: .video).first,
              let compTrack = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return input
        }
        let full = CMTimeRange(start: .zero, duration: asset.duration)
        try compTrack.insertTimeRange(full, of: track, at: .zero)
        compTrack.scaleTimeRange(full, toDuration: CMTime(seconds: duration / speed, preferredTimescale: 600))

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetPassthrough) else {
            return input
        }
        let out = input.deletingPathExtension().appendingPathExtension("x\(Int(speed)).mp4")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4

        return try await withCheckedThrowingContinuation { cont in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    if let url = export.outputURL { cont.resume(returning: url) }
                    else { cont.resume(throwing: NSError(domain: "VideoSpeed", code: -2)) }
                default:
                    cont.resume(throwing: export.error ?? NSError(domain: "VideoSpeed", code: -1))
                }
            }
        }
    }
}
