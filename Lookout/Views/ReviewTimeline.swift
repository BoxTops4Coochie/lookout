import SwiftUI

struct RecordingSegment: Identifiable, Sendable {
    let startTime: Double
    let endTime: Double
    let motion: Int      // 0-100 motion intensity (web-UI tick height)
    var id: Double { startTime }
}

/// Web-UI-style review timeline: full-day vertical scrubber with recording
/// bars, per-segment motion ticks, detection bars, red playhead + time pill,
/// adaptive time ruler, zoom buttons. Drag = scrub; tap rail = mark export
/// start, then end.
struct ReviewTimeline: View {
    let dayStart: Double
    let dayEnd: Double
    let segments: [RecordingSegment]
    let events: [FrigateEvent]
    let playhead: Double
    let rangeStart: Double?
    let rangeEnd: Double?
    /// When true, rail taps mark export start/end; otherwise taps just seek.
    let selecting: Bool
    let onScrub: (Double) -> Void
    let onScrubEnd: () -> Void
    let onRangeTap: (Double) -> Void

    /// visible span (zoomed window inside the day)
    @State private var span: Double = 24 * 3600

    private let railWidth: CGFloat = 250

    private var center: Double {
        min(max(playhead, dayStart + span / 2), max(dayEnd, dayStart + span / 2))
    }
    private var viewStart: Double { max(dayStart, center - span / 2) }
    private var viewEnd: Double { min(dayEnd, viewStart + span) }
    private var pxPerSecond: CGFloat { 300 / CGFloat(max(1, viewEnd - viewStart)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Timeline").font(.subheadline.weight(.semibold))
                Spacer()
                Text(spanLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button { zoom(1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { zoom(1 / 1.6) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            HStack(alignment: .top, spacing: 6) {
                ruler
                rail
            }
            .frame(height: 300)
            Text(selecting ? "Selection mode: tap start → then end"
                           : "Drag or tap to scrub the video")
                .font(.caption2).foregroundStyle(selecting ? Theme.accent : .secondary)
        }
        .padding(12)
        .onAppear { span = dayEnd - dayStart }
    }

    private var spanLabel: String {
        let m = Int(span / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    // MARK: Left ruler (major labels + minor ticks, adapts to zoom)

    private var ruler: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(ticks, id: \.self) { t in
                let y = yFor(t)
                let major = Int(t) % 3600 == 0
                if y >= -2, y <= 300 + 2 {
                    HStack(spacing: 2) {
                        if major {
                            Text(shortTime(t))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Rectangle().fill(Color.secondary.opacity(major ? 0.7 : 0.35))
                            .frame(width: major ? 8 : 4, height: 1)
                    }
                    .offset(y: y - 5)
                }
            }
        }
        .frame(width: 56, height: 300, alignment: .topTrailing)
    }

    private var ticks: [Double] {
        // pick a tick step that stays readable: ~ >= 4px apart
        let steps: [Double] = [300, 600, 900, 1800, 3600, 7200]
        let step = steps.first(where: { $0 * Double(pxPerSecond) >= 4 }) ?? 7200
        let first = (viewStart / step).rounded(.up) * step
        return stride(from: first, through: viewEnd, by: step).map { $0 }
    }

    // MARK: Rail

    private var visibleSegments: [RecordingSegment] {
        segments.filter { $0.endTime >= viewStart && $0.startTime <= viewEnd }
    }

    /// Canvas-rendered recording coverage bars + motion ticks in one pass,
    /// so a full day of segments stays fast.
    private var segmentCanvas: some View {
        SegmentCanvasView(segments: visibleSegments, viewStart: viewStart,
                          viewEnd: viewEnd, height: 300, width: railWidth)
    }

    private var rail: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.35))
                .frame(width: railWidth, height: 300)

            segmentCanvas

            // detections (few per day — individual views are fine)
            ForEach(events) { ev in
                bar(ev.startTime, ev.endTime ?? playhead, Theme.accent, maxH: 44)
            }

            // selected export range
            if let s = rangeStart {
                let e = rangeEnd ?? playhead
                let y1 = yFor(s), y2 = yFor(e)
                Rectangle()
                    .fill(Theme.accent.opacity(0.20))
                    .frame(width: railWidth, height: max(2, abs(y2 - y1)))
                    .offset(y: min(y1, y2))
                handle(at: s, label: "S")
                if rangeEnd != nil { handle(at: e, label: "E") }
            }

            // red playhead + pill
            let py = yFor(playhead)
            ZStack(alignment: .leading) {
                Rectangle().fill(.red).frame(width: railWidth, height: 2)
                Text(hms(playhead))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: 4, y: -15)
            }
            .frame(width: railWidth)
            .offset(y: py)
            .allowsHitTesting(false)
        }
        .frame(width: railWidth, height: 300, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { v in onScrub(timeFor(y: v.location.y)) }
                .onEnded { _ in onScrubEnd() }
        )
        .simultaneousGesture(
            SpatialTapGesture().onEnded { v in onRangeTap(timeFor(y: v.location.y)) }
        )
    }

    private func bar(_ start: Double, _ endRaw: Double, _ color: Color, maxH: CGFloat) -> some View {
        let end = min(max(endRaw, start), dayEnd)
        let y1 = yFor(max(start, viewStart))
        let y2 = yFor(min(end, viewEnd))
        let h = min(maxH, max(2, y2 - y1))
        let visible = end >= viewStart && start <= viewEnd
        return RoundedRectangle(cornerRadius: 2)
            .fill(color.opacity(visible ? 1 : 0))
            .frame(width: 12, height: h)
            .offset(y: y1)
    }

    private func handle(at t: Double, label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Theme.accent, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
            .offset(x: railWidth - 24, y: yFor(t) - 9)
    }

    // MARK: Geometry

    private func yFor(_ t: Double) -> CGFloat { CGFloat(t - viewStart) * pxPerSecond }
    private func timeFor(y: CGFloat) -> Double {
        min(viewEnd, max(viewStart, viewStart + Double(y / pxPerSecond)))
    }

    private func zoom(_ factor: Double) {
        let maxSpan = max(300, dayEnd - dayStart)
        span = min(maxSpan, max(60, span * factor))
    }

    private func shortTime(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private func hms(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm:ss a"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

/// Canvas-rendered recording coverage bars + motion ticks in one pass so a
/// full day of segments draws fast.
private struct SegmentCanvasView: View {
    let segments: [RecordingSegment]
    let viewStart: Double
    let viewEnd: Double
    let height: CGFloat
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let span = max(1, viewEnd - viewStart)
            let pxs = size.height / CGFloat(span)
            let mid = size.width / 2
            // pass 1: bucket motion per pixel row, strongest wins (web-UI style
            // dense mirrored waveform, one row per pixel => continuous envelope)
            var rowMax = [Int: Int](minimumCapacity: Int(size.height) + 1)
            for seg in segments where seg.motion > 0 {
                let y = (seg.startTime - viewStart) * pxs
                if y >= 0, y <= size.height {
                    let row = Int(y)
                    if (rowMax[row] ?? 0) < seg.motion { rowMax[row] = seg.motion }
                }
            }
            for (row, motion) in rowMax {
                let half = 2 + CGFloat(motion) * 0.28
                let rect = CGRect(x: mid - half, y: CGFloat(row), width: half * 2, height: 1.4)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.7),
                         with: .color(.yellow.opacity(0.55 + Double(motion) / 240)))
            }
            // pass 2: recording coverage bars on the center axis
            for seg in segments {
                let y1 = CGFloat(seg.startTime - viewStart) * pxs
                let y2 = CGFloat(min(seg.endTime, viewEnd) - viewStart) * pxs
                guard y2 >= 0, y1 <= size.height else { continue }
                let h = min(26, max(2, y2 - y1))
                ctx.fill(Path(roundedRect: CGRect(x: mid - 6, y: y1, width: 12, height: h),
                              cornerRadius: 2),
                         with: .color(.yellow.opacity(0.85)))
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
