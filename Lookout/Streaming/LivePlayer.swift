import SwiftUI
import AVKit
import WebRTC

// MARK: - Live player
// Latency ladder: RTSP direct via go2rtc :8554 (sub-second, what the lag fix needs)
// -> HLS via Frigate proxy (~2-4s) -> JPEG poster polling. Verified against live 0.17.

enum StreamMode: String, CaseIterable, Identifiable {
    case auto, webrtc, rtsp, hls, stills
    var id: String { rawValue }
}

@Observable
@MainActor
final class LivePlayer {
    var mode: StreamMode = .auto
    var activeKind: ActiveKind = .idle
    var errorMessage: String?
    var player: AVPlayer?
    var webrtc: WebRTCClient?
    var latestStill: UIImage?
    /// true once video is actually rendering (prevents black flashes)
    var videoReady = false

    enum ActiveKind: Equatable { case idle, webrtc, rtsp, hls, stills }

    private var poller: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private let stream: String
    private let camera: String
    private var generation = 0

    init(stream: String, camera: String) {
        self.stream = stream
        self.camera = camera
        // instant paint while the transport comes up
        self.latestStill = PosterCache.get(camera)
    }

    func start(api: FrigateAPI?) async {
        stop()
        guard let api else { return }
        switch mode {
        case .auto:
            // The web UI's transport first: WebRTC -> RTSP -> HLS -> stills
            startWebRTC(api)
        case .webrtc:
            startWebRTC(api)
        case .rtsp:
            startPlayer(api.rtspLiveURL(stream: stream), kind: .rtsp, api: api, nextFallback: nil)
        case .hls:
            startPlayer(api.hlsLiveURL(stream: stream), kind: .hls, api: api, nextFallback: nil)
        case .stills:
            startStills(api)
        }
    }

    private func startWebRTC(_ api: FrigateAPI) {
        let client = WebRTCClient(session: api.session.socketSession)
        webrtc = client
        activeKind = .webrtc
        videoReady = false
        startPosterPoller(api)
        let gen = generation
        client.onStateChange = { [weak self] st in
            guard let self, self.generation == gen else { return }
            switch st {
            case .connected:
                // ICE up but maybe no media yet (back-yard observed). Only cut
                // the poster when the video track actually starts; if ICE is up
                // but silent for 4s, the track watchdog below drops us to RTSP.
                self.watchdog?.cancel()
                watchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, self.generation == gen, !Task.isCancelled, !self.videoReady else { return }
                    self.webrtc?.stop(); self.webrtc = nil
                    self.startPlayer(api.rtspLiveURL(stream: self.stream), kind: .rtsp, api: api, nextFallback: nil)
                }
            case .failed:
                // ladder: webrtc -> rtsp -> stills
                self.errorMessage = client.errorMessage
                self.webrtc?.stop(); self.webrtc = nil
                self.startPlayer(api.rtspLiveURL(stream: self.stream), kind: .rtsp, api: api, nextFallback: nil)
            default:
                break
            }
        }
        client.onVideoTrack = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.videoReady = true
            self.poller?.cancel()
            self.watchdog?.cancel()
        }
        client.connect(url: api.webrtcSignalingURL(stream: stream))

        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.generation == gen, !Task.isCancelled, !self.videoReady else { return }
            self.webrtc?.stop(); self.webrtc = nil
            self.startPlayer(api.rtspLiveURL(stream: self.stream), kind: .rtsp, api: api, nextFallback: nil)
        }
    }

    func stop() {
        generation += 1
        poller?.cancel(); poller = nil
        watchdog?.cancel(); watchdog = nil
        webrtc?.stop(); webrtc = nil
        player?.pause(); player = nil
        activeKind = .idle
        videoReady = false
    }

    /// Poster poller: keeps latestStill fresh until video renders.
    private func startPosterPoller(_ api: FrigateAPI) {
        poller?.cancel()
        let gen = generation
        poller = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.videoReady, self.generation == gen {
                let url = api.liveStillURL(camera: self.camera, height: 480)
                if let data = try? await api.session.imageData(url), let img = UIImage(data: data) {
                    self.latestStill = img
                    PosterCache.set(img, for: self.camera)
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    private struct FallbackStep {
        let url: URL
        let kind: ActiveKind
    }

    private func startPlayer(_ url: URL, kind: ActiveKind, api: FrigateAPI,
                             nextFallback: FallbackStep?) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        // RTSP/Live: don't buffer aggressively — trim latency to ~1.5s of video
        p.automaticallyWaitsToMinimizeStalling = (kind != .rtsp)
        if kind == .rtsp {
            item.preferredForwardBufferDuration = 1.5
            item.preferredPeakBitRate = 8_000_000
        }
        player = p
        activeKind = kind
        videoReady = false
        startPosterPoller(api)

        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            for await status in item.values(\.status) {
                guard self.generation == gen else { return }
                switch status {
                case .readyToPlay:
                    self.videoReady = true
                    self.poller?.cancel()
                    self.watchdog?.cancel()
                    p.play()
                case .failed:
                    self.errorMessage = item.error?.localizedDescription
                    if let fb = nextFallback {
                        self.startPlayer(fb.url, kind: fb.kind, api: api, nextFallback: nil)
                    } else {
                        self.startStills(api)
                    }
                default:
                    break
                }
            }
        }

        // Watchdog: RTSP/HLS that never reaches readyToPlay in 6s -> next rung.
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, self.generation == gen, !Task.isCancelled else { return }
            if !self.videoReady {
                if let fb = nextFallback {
                    self.startPlayer(fb.url, kind: fb.kind, api: api, nextFallback: nil)
                } else {
                    self.startStills(api)
                }
            }
        }
    }

    private func startStills(_ api: FrigateAPI) {
        activeKind = .stills
        videoReady = false
        watchdog?.cancel(); watchdog = nil
        player?.pause()
        player = nil
        startPosterPoller(api)
        // Stills mode never flips videoReady, so the poller keeps running.
    }
}

/// Last-known frame per camera, cached on disk so opening a camera (or cold
/// launching the app) paints instantly while WebRTC/RTSP connects.
enum PosterCache {
    private static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("posters")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let mem = NSCache<NSString, UIImage>()

    static func set(_ image: UIImage, for camera: String) {
        mem.setObject(image, forKey: camera as NSString)
        if let data = image.jpegData(compressionQuality: 0.7) {
            try? data.write(to: dir.appendingPathComponent(camera + ".jpg"), options: .atomic)
        }
    }

    static func get(_ camera: String) -> UIImage? {
        if let hit = mem.object(forKey: camera as NSString) { return hit }
        let url = dir.appendingPathComponent(camera + ".jpg")
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data),
              Date().timeIntervalSince1970 - ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0) < 300
        else { return nil }
        mem.setObject(img, forKey: camera as NSString)
        return img
    }
}

// Async values for AVPlayerItem KVO (small shim, iOS 17+).
extension AVPlayerItem {
    func values(_ keyPath: KeyPath<AVPlayerItem, AVPlayerItem.Status>) -> AsyncStream<AVPlayerItem.Status> {
        AsyncStream { continuation in
            let obs = observe(keyPath, options: [.initial, .new]) { _, change in
                if let v = change.newValue { continuation.yield(v) }
            }
            continuation.onTermination = { _ in obs.invalidate() }
        }
    }
}

// MARK: - Player surface
// AVPlayerLayer-backed: no native VideoPlayer chrome, taps pass through to SwiftUI.

struct PlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer?
    var fill: Bool = true

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// WebRTC video surface (Metal renderer view from the WebRTC framework).
struct WebRTCSurfaceView: UIViewRepresentable {
    let client: WebRTCClient?
    var fill: Bool = true

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let v = RTCMTLVideoView(frame: .zero)
        v.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        return v
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        uiView.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        if let client { client.attach(view: uiView) }
    }
}

struct LivePlayerSurface: View {
    @Bindable var livePlayer: LivePlayer
    /// true = zoom-to-fill (crops), false = fit entire frame (letterbox)
    var fill: Bool = true

    var body: some View {
        ZStack {
            Color.black
            // Poster still underneath until video actually renders (no black flash)
            if !livePlayer.videoReady, let img = livePlayer.latestStill {
                Image(uiImage: img)
                    .resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            }
            if livePlayer.activeKind == .webrtc {
                WebRTCSurfaceView(client: livePlayer.webrtc, fill: fill)
                    .opacity(livePlayer.videoReady ? 1 : 0)
            } else if livePlayer.activeKind == .rtsp || livePlayer.activeKind == .hls {
                PlayerSurfaceView(player: livePlayer.player, fill: fill)
                    .opacity(livePlayer.videoReady ? 1 : 0)
            }
        }
        .clipped()
    }
}
