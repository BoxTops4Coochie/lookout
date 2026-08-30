import Foundation

/// All routes verified against live Frigate 0.17.2 (openapi dump / probing).
/// Auth: cookie session via /api/login (JSON body).
struct FrigateAPI: Sendable {
    let session: FrigateSession

    var base: URL { session.baseURL }

    // MARK: Core

    func version() async throws -> String {
        // /api/version returns plain text (verified).
        let data = try await session.get("api/version")
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    func config() async throws -> FrigateConfig {
        try await session.getJSON(FrigateConfig.self, "api/config")
    }

    // MARK: Events / detections

    func events(camera: String? = nil, label: String? = nil, after: Double? = nil,
                before: Double? = nil, limit: Int = 100, hasClip: Bool? = nil) async throws -> [FrigateEvent] {
        var q: [String: String] = ["limit": String(limit), "include_thumbnails": "0"]
        if let camera { q["cameras"] = camera }
        if let label { q["labels"] = label }
        if let after { q["after"] = String(Int(after)) }
        if let before { q["before"] = String(Int(before)) }
        if let hasClip { q["has_clip"] = hasClip ? "true" : "false" }
        return try await session.getJSON([FrigateEvent].self, "api/events", query: q)
    }

    func eventDetail(id: String) async throws -> FrigateEvent {
        try await session.getJSON(FrigateEvent.self, "api/events/\(id)")
    }

    func eventThumbnailURL(id: String) -> URL { session.urlFor("api/events/\(id)/thumbnail.jpg") }
    func eventSnapshotURL(id: String) -> URL { session.urlFor("api/events/\(id)/snapshot.jpg") }
    /// VOD playlist for a detection event's segment window.
    func eventVODURL(id: String) -> URL { session.urlFor("api/vod/event/\(id)") }

    // MARK: Recordings / timeline

    /// Per-day availability map {"2026-08-28": true, ...}
    func recordingsSummary(camera: String, after: Double) async throws -> [String: Bool] {
        try await session.getJSON([String: Bool].self, "api/recordings/summary",
                                  query: ["camera": camera, "after": String(Int(after))])
    }

    struct VODResponse: Codable {
        struct Sequence: Codable {
            struct Clip: Codable { let type: String; let path: String }
            let clips: [Clip]
        }
        let cache: Bool?
        let discontinuity: Bool?
        let durations: [Int]?
        let segmentDuration: Int?
        let sequences: [Sequence]?
        enum CodingKeys: String, CodingKey {
            case cache, discontinuity, durations, sequences
            case segmentDuration = "segment_duration"
        }
    }

    func vod(camera: String, start: Double, end: Double) async throws -> VODResponse {
        try await session.getJSON(VODResponse.self, "api/vod/\(camera)/start/\(Int(start))/end/\(Int(end))")
    }

    /// Seekable HLS for a time range via nginx-vod (root path, NOT /api).
    /// Verified live: /vod/{cam}/start/{s}/end/{e}/master.m3u8 -> 200 mpegurl.
    /// Keep windows <= ~6h or nginx returns 503.
    func vodHLSURL(camera: String, start: Double, end: Double) -> URL {
        URL(string: "vod/\(camera)/start/\(Int(start))/end/\(Int(end))/master.m3u8", relativeTo: base)!.absoluteURL
    }

    /// Review-player rendition (what the Frigate web UI review player uses):
    /// /vod/clip/... — verified live, ~0.5 Mbps H.264 + AAC, far lighter than
    /// the master recording stream => smooth scrubbing on phones.
    func vodClipHLSURL(camera: String, start: Double, end: Double) -> URL {
        URL(string: "vod/clip/\(camera)/start/\(Int(start))/end/\(Int(end))/master.m3u8", relativeTo: base)!.absoluteURL
    }

    /// Pre-flight a VOD window: nginx-vod 503s on some dense multi-hour
    /// stitch windows (e.g. certain 3h ranges on busy days) even though the
    /// same time splits into playable 1h windows. HEAD the playlist to learn
    /// whether AVPlayer will actually get media.
    func vodPlayable(camera: String, start: Double, end: Double) async -> Bool {
        var req = URLRequest(url: vodClipHLSURL(camera: camera, start: start, end: end))
        req.httpMethod = "HEAD"
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Timeline scrub frames (webp thumbnails) for a window.
    func previewFrames(camera: String, start: Double, end: Double) async throws -> [String] {
        try await session.getJSON([String].self,
            "api/preview/\(camera)/start/\(Int(start))/end/\(Int(end))/frames")
    }

    /// Recording segments for the timeline (verified live: plain JSON array,
    /// each item has start_time/end_time/motion 0-100).
    func recordingSegments(camera: String, after: Double, before: Double) async throws -> [RecordingSegment] {
        struct Item: Codable { let start_time: Double; let end_time: Double; let motion: Int? }
        let items = try await session.getJSON([Item].self, "api/\(camera)/recordings",
                                              query: ["after": String(Int(after)),
                                                      "before": String(Int(before))])
        return items.map { RecordingSegment(startTime: $0.start_time, endTime: $0.end_time,
                                            motion: $0.motion ?? 0) }
    }

    func previewThumbnailURL(fileName: String) -> URL {
        session.urlFor("api/preview/\(fileName)/thumbnail.webp")
    }

    /// Direct MP4 for a time range (verified: serves video/mp4, 206 range-capable).
    func timeRangeClipURL(camera: String, start: Double, end: Double) -> URL {
        session.urlFor("api/\(camera)/start/\(Int(start))/end/\(Int(end))/preview.mp4")
    }

    func recordingSnapshotURL(camera: String, frameTime: Double) -> URL {
        session.urlFor("api/\(camera)/recordings/\(Int(frameTime))/snapshot.jpg")
    }

    // MARK: Exports

    func exports() async throws -> [FrigateExport] {
        try await session.getJSON([FrigateExport].self, "api/exports")
    }

    /// Create a server-side export for a time range. Timestamps in epoch seconds.
    /// Frigate supports realtime or timelapse_25x only; other speeds are applied
    /// app-side after download (VideoSpeed) keyed by the returned export id.
    @discardableResult
    func createExport(camera: String, start: Double, end: Double,
                      name: String? = nil, speed: Double = 1) async throws -> String {
        var body: [String: Any] = [
            "playback": speed >= 25 ? "timelapse_25x" : "realtime",
            "source": "recordings",
        ]
        if let name, !name.isEmpty { body["name"] = name }
        let data = try JSONSerialization.data(withJSONObject: body)
        let resp = try await session.post("api/export/\(camera)/start/\(Int(start))/end/\(Int(end))", body: data)
        let id = (try? JSONSerialization.jsonObject(with: resp) as? [String: Any])?["export_id"] as? String ?? ""
        // app-side extra factor on top of what the server rendered
        let extra = speed >= 25 ? speed / 25 : speed
        if extra > 1.01 && !id.isEmpty {
            VideoSpeed.setSpeed(extra, forExport: id)
        }
        return id
    }

    func deleteExport(id: String) async throws {
        _ = try await session.delete("api/export/\(id)")
    }

    func exportVideoURL(_ export: FrigateExport) -> URL? {
        guard let file = export.playbackPath else { return nil }
        // video_path /media/frigate/exports/x.mp4 served at /exports/x.mp4 (root, not under /api)
        return URL(string: base.absoluteString, relativeTo: nil)!
            .appendingPathComponent("exports").appendingPathComponent(file)
    }

    // MARK: Live streaming

    /// go2rtc WebRTC signaling via Frigate proxy.
    func webrtcOfferURL(stream: String) -> URL { session.urlFor("api/go2rtc/webrtc", query: ["src": stream]) }

    /// go2rtc HLS master playlist (AVPlayer-compatible; nested relative URLs verified).
    func hlsLiveURL(stream: String) -> URL { session.urlFor("api/go2rtc/api/stream.m3u8", query: ["src": stream]) }

    /// WebRTC signaling socket (root path, NOT /api): the web UI's transport. Verified live.
    func webrtcSignalingURL(stream: String) -> URL {
        session.wssRootURL(path: "live/webrtc/api/ws", query: ["src": stream])
    }

    /// Direct RTSP from go2rtc's publisher (host = Frigate host, port 8554 published in compose).
    func rtspLiveURL(stream: String) -> URL {
        var c = URLComponents()
        c.scheme = "rtsp"
        c.host = base.host
        c.port = 8554
        c.path = "/" + stream
        return c.url!
    }

    func go2rtcStreamInfo(stream: String) async throws -> Data {
        try await session.get("api/go2rtc/streams/\(stream)")
    }

    /// Live still for posters/fallback: /api/{cam}/latest.jpg
    /// (verified: instant 200 JPEG. The /api/{cam}?h= MJPEG route HANGS on 0.17 — do not use.)
    func liveStillURL(camera: String, height: Int = 480) -> URL {
        session.urlFor("api/\(camera)/latest.jpg", query: ["h": String(height)])
    }

    // MARK: PTZ (via Frigate WS -> MQTT command; verified payload in dispatcher.py)

    func ptzInfo(camera: String) async throws -> PTZInfo {
        try await session.getJSON(PTZInfo.self, "api/\(camera)/ptz/info")
    }
}
