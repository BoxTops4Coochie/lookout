import Foundation

// MARK: - Server

struct ServerConfig: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var url: URL
    var username: String?
    /// Stored in the iOS Keychain (per server UUID), never in UserDefaults.
    var password: String?
    /// Pinned SHA-256 of the server leaf certificate (for self-signed HTTPS).
    var pinnedCertHash: String?
}

// MARK: - Frigate config

struct FrigateConfig: Codable {
    struct AuthRole: Codable { let cameras: [String]? }
    struct Camera: Codable, Identifiable {
        struct Record: Codable { let enabled: Bool? }
        var id: String { name }
        var name: String
        var cameraName: String?
        var friendlyName: String?
        var record: Record?

        enum CodingKeys: String, CodingKey {
            case name, cameraName, friendlyName, record
        }

        init(from decoder: Decoder) throws {
            // Frigate's config embeds the camera's own name inside its dict entry
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? c.decode(String.self, forKey: .name)) ?? ""
            cameraName = try? c.decode(String.self, forKey: .cameraName)
            friendlyName = try? c.decode(String.self, forKey: .friendlyName)
            record = try? c.decode(Record.self, forKey: .record)
        }
    }

    var cameras: [String: Camera]
    var auth: Auth?

    struct Auth: Codable { let enabled: Bool?; let reset: Bool? }

    var orderedCameras: [Camera] {
        cameras.map { key, cam in
            var mutable = cam
            mutable.name = key
            return mutable
        }
        .sorted { $0.name < $1.name }
    }
}

// MARK: - Events

struct FrigateEvent: Codable, Identifiable, Sendable {
    var id: String
    var camera: String
    var label: String
    var subLabel: String?
    var startTime: Double
    var endTime: Double?
    var hasClip: Bool
    var hasSnapshot: Bool
    var thumbnail: String?
    var zones: [String]
    var zonesCameras: [String]?
    var inProgress: Bool?
    var topScore: Int?
    var box: String?

    enum CodingKeys: String, CodingKey {
        case id, camera, label
        case subLabel = "sub_label"
        case startTime = "start_time"
        case endTime = "end_time"
        case hasClip = "has_clip"
        case hasSnapshot = "has_snapshot"
        case thumbnail
        case zones
        case zonesCameras = "camera_zones"
        case inProgress = "in_progress"
        case topScore = "top_score"
        case box
    }

    var duration: TimeInterval { (endTime ?? Date().timeIntervalSince1970) - startTime }
}

// MARK: - Exports

struct FrigateExport: Codable, Identifiable, Sendable {
    var id: String
    var camera: String
    var name: String?
    var date: Double
    var videoPath: String?
    var thumbPath: String?
    var inProgress: Bool?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id, camera, name, date, status
        case videoPath = "video_path"
        case thumbPath = "thumb_path"
        case inProgress = "in_progress"
    }

    var playbackPath: String? {
        guard let videoPath else { return nil }
        // video_path is /media/frigate/exports/<file>.mp4 -> served at /exports/<file>.mp4
        return (videoPath as NSString).lastPathComponent
    }
}

// MARK: - PTZ

struct PTZInfo: Codable, Sendable {
    var name: String
    var features: [String]
    var presets: [String]?

    var supportsMove: Bool { features.contains("pt") || features.contains("pt-r") }
    var supportsZoom: Bool { features.contains("zoom") || features.contains("zoom-r") || features.contains("zoom-a") }
}

// MARK: - Version

struct VersionResponse: Decodable { let version: String? }
