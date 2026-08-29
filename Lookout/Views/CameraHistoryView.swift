import SwiftUI
import AVKit

// MARK: - Camera history: webui-style full-day review timeline + range export.
// Timeline spans the whole selected day (zoom like the web UI). Playback uses
// nginx-vod HLS loaded in hidden 3h blocks around the playhead (nginx-vod 503s
// on full-day windows) — swapping blocks is invisible to the user.

struct CameraHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: FrigateConfig.Camera

    @State private var selectedDay: Date = .now.addingTimeInterval(-3600)
    @State private var availableDays: [Date] = []
    @State private var segments: [RecordingSegment] = []
    @State private var events: [FrigateEvent] = []
    @State private var playhead: Double = Date.now.timeIntervalSince1970
    @State private var isPlaying = false
    @State private var rangeStart: Double?
    @State private var rangeEnd: Double?
    @State private var exportMessage: String?
    @State private var isLoading = false
    // custom timeframe (web UI style exact start/end + name)
    @State private var showCustom = false
    @State private var customStart = Date.now.addingTimeInterval(-600)
    @State private var customEnd = Date.now
    @State private var exportName = ""
    @State private var exportSpeed: Double = 1
    /// Rail taps only mark export start/end while this is ON (button below).
    @State private var selectingRange = false

    // VOD player (block = <=3h window containing the playhead)
    @State private var player: AVPlayer?
    @State private var blockStart: Double = 0
    @State private var blockEnd: Double = 0
    @State private var blockClips: [(s: Double, e: Double)] = []
    @State private var clockLabel = "--:--:--"
    @State private var timeObs: Any?

    private var dayStart: Double { Calendar.current.startOfDay(for: selectedDay).timeIntervalSince1970 }
    private var dayEnd: Double {
        min(dayStart + 86400, max(Date.now.timeIntervalSince1970, dayStart + 60))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    dayStrip
                    playerCard
                    ReviewTimeline(dayStart: dayStart,
                                   dayEnd: dayEnd,
                                   segments: segments,
                                   events: events,
                                   playhead: playhead,
                                   rangeStart: rangeStart,
                                   rangeEnd: rangeEnd,
                                   selecting: selectingRange,
                                   onScrub: { scrub(to: $0) },
                                   onScrubEnd: { scrubSettled() },
                                   onRangeTap: { markRange($0) })
                        .cardStyle()
                    selectionBar
                    exportButton
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle("History — \(camera.friendlyName ?? camera.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { stopPlayer(); dismiss() }
                }
            }
            .task { await loadDays(); await loadDayData(); startBlock(at: playhead) }
            .onDisappear { stopPlayer() }
            .overlay {
                if let msg = exportMessage {
                    VStack { Spacer()
                        Text(msg).font(.callout.weight(.medium))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: Day strip (calendar kept)

    private var dayStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(availableDays, id: \.self) { day in
                        let sel = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                        Button {
                            select(day)
                        } label: {
                            VStack(spacing: 2) {
                                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                    .font(.caption2).foregroundStyle(sel ? .black : .secondary)
                                Text(day.formatted(.dateTime.day()))
                                    .font(.headline).foregroundStyle(sel ? .black : .primary)
                            }
                            .frame(width: 48, height: 56)
                            .background(sel ? Theme.accent : Theme.card, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .id(day)
                    }
                }
            }
            .onAppear { withAnimation { proxy.scrollTo(selectedDay, anchor: .center) } }
        }
    }

    private func select(_ day: Date) {
        selectedDay = day
        stopPlayer()
        playhead = min(Date.now.timeIntervalSince1970, dayEnd - 30)
        // Must load the new day's segments BEFORE building the block: the
        // clip-run table drives player-time -> wall-time mapping, and a stale
        // (or empty) table makes the playhead jump hours after each drag.
        Task {
            await loadDayData()
            startBlock(at: playhead)
        }
    }

    // MARK: Player card

    private var playerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let player {
                    VideoPlayer(player: player)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .overlay(ProgressView().tint(.white))
                }
                Text(clockLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(6).background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
                if !isPlaying {
                    Button { togglePlay() } label: {
                        Image(systemName: "play.fill")
                            .font(.title2).foregroundStyle(.white)
                            .padding(14).background(.black.opacity(0.5), in: Circle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Text(isPlaying ? "Playing" : "Paused").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .cardStyle()
    }

    // MARK: Block loading (hidden VOD window around playhead)

    @State private var blockGeneration = 0
    @State private var blockRetried = false

    /// Dense days (thousands of tiny segments) make nginx-vod's multi-hour
    /// stitch fragile (503 "durations array" errors on 3h windows) — hour-
    /// aligned 1h windows have never failed AND hit the warm stitch cache
    /// when revisited. Pick block size from the day's segment count so we
    /// don't waste seconds probing known-bad windows.
    private var blockSize: Double { segments.count > 4000 ? 3600 : 3 * 3600 }

    private func blockContaining(_ t: Double) -> (Double, Double) {
        let size = blockSize
        let lower = max(dayStart, (t / size).rounded(.down) * size)
        let upper = min(dayEnd, lower + size)
        // keep blocks at least ~10m where the day is short
        return (lower, max(upper, min(lower + 600, dayEnd)))
    }

    private func startBlock(at t: Double) {
        guard let api = model.api else { return }
        blockGeneration += 1
        let gen = blockGeneration
        blockRetried = false
        Task { @MainActor in
            var (bs, be) = blockContaining(t)
            // Only large blocks get the pre-flight (cheap 0.3s on sparse days);
            // on failure jump straight to an hour-aligned 1h window — never a
            // slow shrink ladder (each cold probe could burn 10-15s stitching).
            if be - bs > 3700 {
                let ok = await api.vodPlayable(camera: camera.name, start: bs, end: be)
                if !ok {
                    let l = max(dayStart, min((t / 3600).rounded(.down) * 3600, max(dayStart, dayEnd - 600)))
                    bs = l; be = min(l + 3600, dayEnd)
                }
            }
            guard gen == blockGeneration else { return }  // superseded by newer scrub
            attachPlayer(api: api, start: bs, end: be, at: t)
        }
    }

    private func attachPlayer(api: FrigateAPI, start bs: Double, end be: Double, at t: Double) {
        blockStart = bs
        blockEnd = be
        blockClips = clipRuns(bs, be)
        stopPlayer()
        // Aggressive HLS startup: don't wait for a big safety buffer before
        // first frame (default behavior caused the 10-15s "spinner" on seeks).
        let asset = AVURLAsset(url: api.vodClipHLSURL(camera: camera.name, start: bs, end: be),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.0
        let p = AVPlayer()
        p.automaticallyWaitsToMinimizeStalling = false
        p.replaceCurrentItem(with: item)
        player = p
        clockLabel = timeString(t)
        // nginx-vod concatenates only recorded clips -> player time is compacted
        // across gaps; map both directions via the clip-run table.
        let obs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                            queue: .main) { tm in
            let wall = wallTime(forLocal: tm.seconds)
            playhead = wall
            clockLabel = timeString(wall)
        }
        timeObs = obs
        // seek to requested position inside the fresh block
        let local = min(localTime(forWall: t), max(0, be - bs))
        p.seek(to: CMTime(seconds: local, preferredTimescale: 600),
               toleranceBefore: .zero, toleranceAfter: .zero)
        // watchdog: if playback never readies, retry once with a small window
        let gen = blockGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard gen == blockGeneration, !blockRetried else { return }
            if item.status != .readyToPlay {
                blockRetried = true
                let l = max(dayStart, min((t / 3600).rounded(.down) * 3600, max(dayStart, dayEnd - 600)))
                attachPlayer(api: api, start: l, end: min(l + 3600, dayEnd), at: t)
            }
        }
    }

    /// This block's recorded segments as ordered clip runs — nginx-vod plays
    /// them back-to-back (gaps excluded), so the table must mirror that exactly.
    private func clipRuns(_ bs: Double, _ be: Double) -> [(s: Double, e: Double)] {
        segments.filter { $0.startTime < be && $0.endTime > bs }
            .sorted { $0.startTime < $1.startTime }
            .map { (max($0.startTime, bs), min($0.endTime, be)) }
    }

    private func localTime(forWall t: Double) -> Double {
        guard !blockClips.isEmpty else { return max(0, t - blockStart) }
        var acc = 0.0
        for run in blockClips {
            if t <= run.e { return acc + max(0, t - run.s) }
            acc += run.e - run.s
        }
        return acc
    }

    private func wallTime(forLocal lt: Double) -> Double {
        guard !blockClips.isEmpty else { return blockStart + lt }
        var acc = 0.0
        for run in blockClips {
            let d = run.e - run.s
            if lt <= acc + d { return run.s + max(0, lt - acc) }
            acc += d
        }
        return blockEnd
    }

    private func stopPlayer() {
        if let obs = timeObs { player?.removeTimeObserver(obs) }
        timeObs = nil
        player?.pause()
        player = nil
    }

    // MARK: Scrub + range

    @State private var wasPlayingBeforeScrub = false

    private func scrub(to t: Double) {
        if isPlaying { wasPlayingBeforeScrub = true; player?.pause(); isPlaying = false }
        playhead = t
        if t < blockStart || t > blockEnd {
            // cross into another hidden block — seamless to the user
            startBlock(at: t)
        } else if let player {
            let local = min(localTime(forWall: t), max(0, blockEnd - blockStart))
            player.seek(to: CMTime(seconds: local, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func scrubSettled() {
        if wasPlayingBeforeScrub {
            wasPlayingBeforeScrub = false
            player?.play()
            isPlaying = true
        }
    }

    private func markRange(_ t: Double) {
        guard selectingRange else {
            scrub(to: t)   // plain tap = seek, not range marking
            return
        }
        if rangeStart == nil || (rangeStart != nil && rangeEnd != nil) {
            rangeStart = t; rangeEnd = nil
        } else if let s = rangeStart {
            rangeEnd = max(s, t)
            selectingRange = false   // both ends picked — leave selection mode
        }
        scrub(to: t)
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
    }

    // MARK: Selection + export UI

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if selectingRange {
                    // pressing again cancels an in-progress start point
                    selectingRange = false
                    if rangeEnd == nil { rangeStart = nil }
                } else {
                    rangeStart = nil; rangeEnd = nil
                    selectingRange = true
                }
            } label: {
                Label(selectingRange ? "Cancel — now tap start, then end" : "Set start/end from timeline",
                      systemImage: selectingRange ? "xmark.circle" : "rectangle.and.pencil.and.ellipsis")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(selectingRange ? Theme.accent.opacity(0.25) : Theme.card,
                                in: RoundedRectangle(cornerRadius: 12))
            }
            if let s = rangeStart, let e = rangeEnd {
                HStack {
                    Label("\(timeString(s)) → \(timeString(e))  (\(Int(e - s))s)",
                          systemImage: "checkmark.circle.fill")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Button("Clear") {
                        rangeStart = nil; rangeEnd = nil; selectingRange = false
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
            } else if let s = rangeStart {
                Label("Start set: \(timeString(s)) — now tap the end point", systemImage: "hand.tap")
                    .font(.callout).foregroundStyle(Theme.accent)
            } else {
                Label("Drag the timeline to scrub and preview.", systemImage: "hand.tap")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { showCustom.toggle() }
            } label: {
                Label(showCustom ? "Custom timeframe" : "Custom timeframe (set exact start/end)",
                      systemImage: "calendar.badge.clock")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            }

            if showCustom {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("Start", selection: $customStart,
                               displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $customEnd,
                               displayedComponents: [.date, .hourAndMinute])
                    TextField("Export name (optional)", text: $exportName)
                        .textFieldStyle(.roundedBorder)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Playback speed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Speed", selection: $exportSpeed) {
                            Text("1×").tag(1.0)
                            Text("2×").tag(2.0)
                            Text("5×").tag(5.0)
                            Text("10×").tag(10.0)
                            Text("25×").tag(25.0)
                            Text("50×").tag(50.0)
                            Text("100×").tag(100.0)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .tint(Theme.accent)
                .padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            }

            Button {
                Task { await createExport() }
            } label: {
                Label("Export clip", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canExport ? Theme.accent : Theme.card,
                                in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .disabled(!canExport)
        }
    }

    private var canExport: Bool {
        showCustom ? customEnd > customStart
                   : (rangeStart != nil && rangeEnd != nil)
    }

    // MARK: Data

    private func timeString(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm:ss a"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func loadDays() async {
        guard let api = model.api else { return }
        let after = Date.now.addingTimeInterval(-35 * 86400).timeIntervalSince1970
        guard let summary = try? await api.recordingsSummary(camera: camera.name, after: after) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        availableDays = summary.keys.compactMap { f.date(from: $0) }.sorted()
        if !availableDays.contains(where: { Calendar.current.isDate($0, inSameDayAs: selectedDay) }),
           let last = availableDays.last {
            selectedDay = last
        }
    }

    private func loadDayData() async {
        guard let api = model.api else { return }
        isLoading = true; defer { isLoading = false }
        segments = (try? await api.recordingSegments(camera: camera.name, after: dayStart, before: dayEnd)) ?? []
        events = (try? await api.events(camera: camera.name, after: dayStart, before: dayEnd, limit: 1000)) ?? []
    }

    private func createExport() async {
        guard let api = model.api else { return }
        let s: Double, e: Double, name: String?
        if showCustom {
            s = customStart.timeIntervalSince1970
            e = customEnd.timeIntervalSince1970
            name = exportName
        } else {
            guard let rs = rangeStart, let re = rangeEnd else { return }
            s = rs; e = re; name = nil
        }
        guard e > s else {
            withAnimation { exportMessage = "End must be after start" }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { exportMessage = nil }
            return
        }
        do {
            try await api.createExport(camera: camera.name, start: s, end: e,
                                       name: name, speed: exportSpeed)
            let label = exportSpeed > 1 ? " at \(Int(exportSpeed))×" : ""
            withAnimation { exportMessage = "Export started\(label) — check Exports tab" }
            rangeStart = nil; rangeEnd = nil
            try? await Task.sleep(for: .seconds(2))
            withAnimation { exportMessage = nil }
        } catch {
            withAnimation { exportMessage = "Export failed: \(error.localizedDescription)" }
        }
    }
}
