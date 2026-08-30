import Foundation
import WebRTC

/// go2rtc WebRTC via Frigate proxy — the same transport the Frigate web UI uses.
/// Signaling verified live against 0.17: wss://{host}/live/webrtc/api/ws?src={stream}
///   send  {"type":"webrtc/offer","value": <local sdp>}
///   send  {"type":"webrtc/candidate","value": <candidate string>}
///   recv  webrtc/answer | webrtc/candidate | error   (answer/candidate = raw sdp strings)
/// WebRTCClient is a plain NSObject (its delegate callbacks arrive on WebRTC's own
/// queues); all state mutation hops to main.
final class WebRTCClient: NSObject, RTCPeerConnectionDelegate {
    enum State { case idle, connecting, connected, failed }
    var state: State = .idle {
        didSet { if oldValue != state { DispatchQueue.main.async { self.onStateChange?(self.state) } } }
    }
    var onStateChange: ((State) -> Void)?
    /// Fires when the remote VIDEO track actually starts delivering — ICE can
    /// reach .connected with zero media flowing (observed with 102_back_yard),
    /// which showed a black surface instead of the poster.
    var onVideoTrack: (() -> Void)?
    private(set) var hasVideoTrack = false
    private(set) var errorMessage: String?

    private let factory: RTCPeerConnectionFactory
    private let wsSession: URLSession
    private var pc: RTCPeerConnection?
    private var ws: URLSessionWebSocketTask?
    private var pendingCandidates: [String] = []
    private weak var videoView: RTCMTLVideoView?
    private var videoTrack: RTCVideoTrack?

    init(session: URLSession) {
        self.wsSession = session
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
    }

    /// Called by the SwiftUI surface; attach immediately if a track already exists.
    func attach(view: RTCMTLVideoView) {
        videoView = view
        if let track = videoTrack { track.add(view) }
        else if let t = pc?.transceivers.first(where: { $0.receiver.track?.kind == "video" })?.receiver.track as? RTCVideoTrack {
            videoTrack = t
            t.add(view)
        }
    }

    func connect(url: URL) {
        state = .connecting
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []   // LAN/VPN: host candidates only, no STUN

        let factoryPcConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config,
                                              constraints: factoryPcConstraints,
                                              delegate: self) else {
            state = .failed
            return
        }
        self.pc = pc
        let initCfg = RTCRtpTransceiverInit()
        initCfg.direction = .recvOnly
        _ = pc.addTransceiver(of: .video, init: initCfg)

        let ws = wsSession.webSocketTask(with: url)
        self.ws = ws
        ws.resume()
        receiveNext()

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] desc, err in
            guard let self else { return }
            DispatchQueue.main.async {
                if let err { self.fail("offer: \(err.localizedDescription)"); return }
                guard let desc else { self.fail("offer: nil"); return }
                pc.setLocalDescription(desc) { err in
                    if let err {
                        DispatchQueue.main.async { self.fail("setLocal: \(err.localizedDescription)") }
                    }
                }
                self.send(type: "webrtc/offer", value: desc.sdp)
            }
        }
    }

    func stop() {
        if let view = videoView { videoTrack?.remove(view) }
        videoTrack = nil
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        pc?.close()
        pc = nil
        pendingCandidates.removeAll()
        if state != .idle { state = .idle }
    }

    private func flushCandidates() {
        guard let pc, pc.remoteDescription != nil else { return }
        for c in pendingCandidates {
            pc.add(RTCIceCandidate(sdp: c, sdpMLineIndex: 0, sdpMid: "0"), completionHandler: { _ in })
        }
        pendingCandidates.removeAll()
    }

    // MARK: Signaling

    private func send(type: String, value: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": type, "value": value]) else { return }
        ws?.send(.data(data)) { [weak self] err in
            if let err, let self {
                DispatchQueue.main.async { self.fail("ws send: \(err.localizedDescription)") }
            }
        }
    }

    private func receiveNext() {
        ws?.receive { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    if self.pc != nil { self.fail("ws: \(err.localizedDescription)") }
                case .success(let msg):
                    let text: String?
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text, let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        self.handle(obj)
                    }
                    self.receiveNext()
                }
            }
        }
    }

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        let value = msg["value"] as? String
        switch type {
        case "webrtc/answer":
            guard let value, let pc else { return }
            let sdp = RTCSessionDescription(type: .answer, sdp: value)
            pc.setRemoteDescription(sdp) { [weak self] err in
                guard let self else { return }
                DispatchQueue.main.async {
                    if let err { self.fail("setRemote: \(err.localizedDescription)"); return }
                    self.flushCandidates()
                }
            }
        case "webrtc/candidate":
            guard let value else { return }
            if let pc, pc.remoteDescription != nil {
                // web UI hardcodes mid "0" (video) — mirror it exactly
                pc.add(RTCIceCandidate(sdp: value, sdpMLineIndex: 0, sdpMid: "0"), completionHandler: { _ in })
            } else {
                pendingCandidates.append(value)
            }
        case "error":
            fail(value ?? "server error")
        default:
            break
        }
    }

    private func fail(_ reason: String) {
        errorMessage = reason
        guard state != .failed, state != .connected else { return }
        state = .failed
    }

    // MARK: RTCPeerConnectionDelegate (ObjC names imported by Swift importer)

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                self.state = .connected
            case .failed:
                self.fail("ice failed")
            default:
                break
            }
        }
    }

    /// Unified-plan media attach point — exactly when the remote video track starts.
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        DispatchQueue.main.async {
            guard let mediaTrack = transceiver.receiver.track, mediaTrack.kind == "video",
                  let track = mediaTrack as? RTCVideoTrack else { return }
            self.videoTrack = track
            self.hasVideoTrack = true
            if let view = self.videoView { track.add(view) }
            self.onVideoTrack?()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        send(type: "webrtc/candidate", value: candidate.sdp)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
