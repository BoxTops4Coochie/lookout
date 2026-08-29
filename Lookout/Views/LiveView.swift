import SwiftUI

// MARK: - Live grid (home tab)

struct LiveView: View {
    @Environment(AppModel.self) private var model
    @State private var reloadID = UUID()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.cameras.isEmpty {
                    ContentUnavailableView(
                        model.bootError != nil ? "Can’t reach Frigate" : "No cameras",
                        systemImage: "video.slash",
                        description: Text(model.bootError ?? "Check Settings → Servers."))
                        .symbolEffect(.variableColor)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                            GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(model.cameras) { cam in
                                NavigationLink(value: cam.name) {
                                    LiveGridCell(camera: cam)
                                        .id(reloadID)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                    .refreshable { reloadID = UUID(); await model.bootstrap() }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Live")
            .navigationDestination(for: String.self) { name in
                if let cam = model.cameras.first(where: { $0.name == name }) {
                    CameraDetailView(camera: cam)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { reloadID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

private struct LiveGridCell: View {
    @Environment(AppModel.self) private var model
    let camera: FrigateConfig.Camera
    @State private var live: LivePlayer

    init(camera: FrigateConfig.Camera) {
        self.camera = camera
        _live = State(initialValue: LivePlayer(stream: camera.name, camera: camera.name))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LivePlayerSurface(livePlayer: live)
                .aspectRatio(16.0/9.0, contentMode: .fit)
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Text(camera.friendlyName ?? camera.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(8)
            .background(.black.opacity(0.35), in: Capsule())
            .padding(6)
        }
        .cardStyle()
        .task { await live.start(api: model.api) }
        .onDisappear { live.stop() }
    }
}

// MARK: - Camera detail: full-page live view with overlay controls

struct CameraDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: FrigateConfig.Camera

    @State private var live: LivePlayer
    @State private var ptz: PTZInfo?
    @State private var showPTZ = false
    @State private var showHistory = false
    @State private var chromeVisible = true

    // digital pan/zoom (fixed cameras); ONVIF wired in parallel for real PTZ cams
    @State private var zoomScale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    init(camera: FrigateConfig.Camera) {
        self.camera = camera
        _live = State(initialValue: LivePlayer(stream: camera.name, camera: camera.name))
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                // Full-page player: portrait shows entire frame (letterbox),
                // landscape fills since aspect ratios match closely.
                LivePlayerSurface(livePlayer: live, fill: landscape)
                    .scaleEffect(zoomScale)
                    .offset(panOffset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoomScale = min(max(lastScale * value, 1), 5)
                            }
                            .onEnded { _ in
                                lastScale = zoomScale
                                if zoomScale <= 1.02 {
                                    withAnimation(.snappy) { zoomScale = 1; lastScale = 1; panOffset = .zero; lastPan = .zero }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard zoomScale > 1 else { return }
                                let limit: CGFloat = 80 * zoomScale
                                panOffset = CGSize(
                                    width: min(max(lastPan.width + value.translation.width, -limit), limit),
                                    height: min(max(lastPan.height + value.translation.height, -limit), limit))
                            }
                            .onEnded { _ in lastPan = panOffset }
                    )
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) { zoomScale = 1; lastScale = 1; panOffset = .zero; lastPan = .zero }
                    }
                    .onTapGesture { withAnimation(.snappy) { chromeVisible.toggle() } }

                // Overlay chrome (respects safe area — not under notch/status bar)
                VStack {
                    topBar
                    Spacer()
                    if showPTZ {
                        padForCurrentCamera
                            .padding(.trailing, 20)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    bottomBar
                }
                .opacity(chromeVisible ? 1 : 0)
                .animation(.snappy, value: chromeVisible)
                .allowsHitTesting(chromeVisible)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(true)
        .task {
            await live.start(api: model.api)
            ptz = try? await model.api?.ptzInfo(camera: camera.name)
            showPTZ = true
        }
        .onDisappear { live.stop() }
        .sheet(isPresented: $showHistory) {
            CameraHistoryView(camera: camera)
        }
    }

    // MARK: Pad selection

    /// ONE pad per camera: ONVIF pad (move+zoom+stop) for PTZ cams,
    /// digital pan/zoom pad for fixed cams.
    @ViewBuilder private var padForCurrentCamera: some View {
        if ptz?.supportsMove == true {
            PTZPad(camera: camera.name)
        } else {
            ZoomButtons(zoomScale: $zoomScale, lastScale: $lastScale,
                        panOffset: $panOffset, lastPan: $lastPan)
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack {
            Button {
                dismissBack()
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(camera.friendlyName ?? camera.name)
                    .font(.headline).foregroundStyle(.white)
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text({ switch live.activeKind {
                        case .webrtc: "LIVE · WebRTC"
                        case .rtsp: "LIVE · RTSP"
                        case .hls: "LIVE · HLS"
                        case .stills: "STILLS"
                        case .idle: "…"
                    } }())
                        .font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                }
            }
            Spacer()
            Menu {
                Picker("Stream", selection: Bindable(live).mode) {
                    ForEach(StreamMode.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            // Controls toggle (ONVIF pad on PTZ cams, digital pad on fixed cams)
            controlButton(
                icon: showPTZ ? "dpad.fill" : "dpad",
                label: "Controls",
                active: showPTZ,
                enabled: true
            ) {
                withAnimation(.snappy) { showPTZ.toggle() }
            }

            // History
            controlButton(icon: "clock.arrow.circlepath", label: "History", active: false, enabled: true) {
                showHistory = true
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func controlButton(icon: String, label: String, active: Bool,
                               enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium))
                Text(label).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(enabled ? (active ? .black : .white) : .white.opacity(0.35))
            .frame(width: 64, height: 56)
            .background(active && enabled ? Theme.accent : .black.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
    }

    private func dismissBack() { dismiss() }
}

// MARK: - Digital pan/zoom pad (fixed cameras)

struct ZoomButtons: View {
    @Binding var zoomScale: CGFloat
    @Binding var lastScale: CGFloat
    @Binding var panOffset: CGSize
    @Binding var lastPan: CGSize

    var body: some View {
        VStack(spacing: 6) {
            gridButton("plus.magnifyingglass") { nudge(zoom: 1.35) }
            gridButton("arrow.up") { nudge(dx: 0, dy: -1) }
            HStack(spacing: 6) {
                gridButton("arrow.left") { nudge(dx: 1, dy: 0) }
                gridButton("arrow.right") { nudge(dx: -1, dy: 0) }
            }
            gridButton("arrow.down") { nudge(dx: 0, dy: 1) }
            gridButton("minus.magnifyingglass") { nudge(zoom: 1/1.35) }
            gridButton("arrow.counterclockwise") { reset() }
        }
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private func gridButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 38)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var maxOffset: CGFloat { 140 * zoomScale }

    private func nudge(dx: CGFloat = 0, dy: CGFloat = 0, zoom: CGFloat = 1) {
        withAnimation(.spring(duration: 0.25)) {
            if zoom != 1 {
                zoomScale = min(max(zoomScale * zoom, 1), 6)
                lastScale = zoomScale
                if zoomScale <= 1.01 { panOffset = .zero; lastPan = .zero }
            }
            if dx != 0 || dy != 0 {
                // If not zoomed, zoom in first so panning shows something
                if zoomScale <= 1.01 { zoomScale = 1.8; lastScale = 1.8 }
                panOffset = CGSize(
                    width: min(max(panOffset.width + dx * 50, -maxOffset), maxOffset),
                    height: min(max(panOffset.height + dy * 50, -maxOffset), maxOffset))
                lastPan = panOffset
            }
        }
    }

    private func reset() {
        withAnimation(.snappy) {
            zoomScale = 1; lastScale = 1
            panOffset = .zero; lastPan = .zero
        }
    }
}

// MARK: - PTZ pad (WS -> MQTT commands; payload format verified in dispatcher.py)

struct PTZPad: View {
    @Environment(AppModel.self) private var model
    let camera: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                padButton("plus.magnifyingglass", "ZOOM_IN")
                padButton("arrow.up", "MOVE_UP")
            }
            HStack(spacing: 6) {
                padButton("arrow.left", "MOVE_LEFT")
                padButton("stop.circle.fill", "STOP")
                padButton("arrow.right", "MOVE_RIGHT")
            }
            HStack(spacing: 6) {
                padButton("minus.magnifyingglass", "ZOOM_OUT")
                padButton("arrow.down", "MOVE_DOWN")
            }
        }
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
    }

    private func padButton(_ symbol: String, _ payload: String) -> some View {
        Button {
            Task { await send(payload) }
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 46, height: 42)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func send(_ payload: String) async {
        guard let session = model.session else { return }
        let task = session.webSocket()
        task.resume()
        task.send(FrigateSession.commandMessage(topic: "\(camera)/ptz", payload: payload)) { _ in
            // MOVE_* commands self-stop on the camera side after a short nudge; then STOP for safety.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                task.send(FrigateSession.commandMessage(topic: "\(camera)/ptz", payload: "STOP")) { _ in
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
        }
    }
}
