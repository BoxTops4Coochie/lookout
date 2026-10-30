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
    /// Called while either selection line is dragged: (start, end).
    let onRangeChange: (Double, Double) -> Void

    /// visible span (zoomed window inside the day)
    @State private var span: Double = 24 * 3600

    /// Left edge of the visible window. This must be ANCHORED state, not a
    /// value derived from `playhead`: deriving it re-centred the rail on every
    /// tap, so the same pixel returned a different (earlier) time on the next
    /// tap and the export range collapsed to "(0s)".
    @State private var anchor: Double = 0
    /// True while a touch is in flight — stops auto-pan fighting the finger.
    @State private var gestureActive = false
    @State private var dragging = false
    /// nil = axis not decided yet, true = sideways pan, false = scrub.
    @State private var panning: Bool?
    @State private var panBase: Double = 0
    /// Which selection line the current touch grabbed, if any.
    private enum Edge { case start, end }
    @State private var draggingEdge: Edge?
    @State private var edgeBaseStart: Double = 0
    @State private var edgeBaseEnd: Double = 0

    private let railWidth: CGFloat = 216
    private let railHeight: CGFloat = 300
    private let panBarWidth: CGFloat = 28

    private var maxAnchor: Double { max(dayStart, dayEnd - span) }
    private var viewStart: Double { min(max(anchor, dayStart), maxAnchor) }
    private var viewEnd: Double { min(dayEnd, viewStart + span) }
    private var pxPerSecond: CGFloat { railHeight / CGFloat(max(1, viewEnd - viewStart)) }

    private var dayLength: Double { max(1, dayEnd - dayStart) }
    private var isZoomed: Bool { span < dayLength - 1 }
    private var thumbHeight: CGFloat { max(40, railHeight * CGFloat(span / dayLength)) }
    private var thumbY: CGFloat {
        let frac = min(max((viewStart - dayStart) / dayLength, 0), 1)
        return min(CGFloat(frac) * railHeight, railHeight - thumbHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Timeline").font(.subheadline.weight(.semibold))
                Spacer()
                Text(spanLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Button { zoom(1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button { zoom(1 / 1.6) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            HStack(alignment: .top, spacing: 6) {
                ruler
                rail
                // Outside the rail on purpose: a bar sitting on top of the
                // timeline had its drags captured by the scrub gesture, so it
                // only ever moved the playhead.
                if isZoomed {
                    panBar
                } else {
                    Color.clear.frame(width: panBarWidth, height: railHeight)
                }
            }
            .frame(height: railHeight)
            Text(selecting ? "Drag the two lines to set start & end"
                           : (isZoomed ? "Drag to scrub · slide the bar to move the day"
                                       : "Drag or tap to scrub the video"))
                .font(.caption).foregroundStyle(selecting ? Theme.accent : .secondary)
        }
        .padding(12)
        .onAppear { fitDay() }
        .onChange(of: dayStart) { _, _ in fitDay() }
        .onChange(of: playhead) { _, p in
            // Follow the playhead only when it leaves the window, and never
            // while a finger is down (that was the moving-target scroll).
            guard !gestureActive else { return }
            if p < viewStart || p > viewEnd { anchor = p - span / 2 }
        }
        .onChange(of: rangeStart) { _, s in
            // A freshly seeded (or externally set) range may be off-screen,
            // and at day zoom a 5-minute range is a sliver — zoom in on it so
            // both drag lines are far enough apart to grab.
            guard let s, let e = rangeEnd, !gestureActive else { return }
            let want = max(60, min(dayLength, (e - s) * 8))
            if span > want { span = want }
            if s < viewStart || e > viewEnd { anchor = (s + e) / 2 - span / 2 }
        }
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
                                .font(.system(size: 10))
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

            // selected export range: band + two draggable time lines
            if let s = rangeStart {
                let e = rangeEnd ?? playhead
                let y1 = yFor(s), y2 = yFor(e)
                Rectangle()
                    .fill(Theme.accent.opacity(0.22))
                    .frame(width: railWidth, height: max(2, abs(y2 - y1)))
                    .offset(y: min(y1, y2))
                rangeEdge(at: s, label: hms(s))
                if rangeEnd != nil { rangeEdge(at: e, label: hms(e)) }
            }

            // red playhead + pill
            let py = yFor(playhead)
            ZStack(alignment: .leading) {
                Rectangle().fill(.red).frame(width: railWidth, height: 2)
                Text(hms(playhead))
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
                    .offset(x: 4, y: -15)
            }
            .frame(width: railWidth)
            .offset(y: py)
            .allowsHitTesting(false)
        }
        .frame(width: railWidth, height: railHeight, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        // One gesture for taps AND drags. With two gestures (drag min 1pt +
        // SpatialTapGesture) a tap that wobbles 1px became a drag and the two
        // handlers could land at different times — start/end then collapsed
        // to 0s. Tap = travel < 6pt, drag = anything further.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !gestureActive {
                        gestureActive = true
                        dragging = false
                        panning = nil
                        panBase = anchor
                        draggingEdge = nil
                        edgeBaseStart = rangeStart ?? 0
                        edgeBaseEnd = rangeEnd ?? 0
                        // A touch that lands on a selection line grabs it.
                        if let s = rangeStart, let e = rangeEnd {
                            let ds = abs(v.startLocation.y - yFor(s))
                            let de = abs(v.startLocation.y - yFor(e))
                            if min(ds, de) <= 26 {
                                draggingEdge = ds <= de ? .start : .end
                            }
                        }
                    }

                    if let edge = draggingEdge {
                        let t = timeFor(y: v.location.y)
                        if edge == .start {
                            onRangeChange(min(t, edgeBaseEnd - 1), edgeBaseEnd)
                        } else {
                            onRangeChange(edgeBaseStart, max(t, edgeBaseStart + 1))
                        }
                        return
                    }

                    let dx = v.translation.width
                    let dy = v.translation.height
                    // Decide once, after a few points of travel: mostly
                    // sideways = slide the day, mostly vertical = scrub.
                    if panning == nil, (dx * dx + dy * dy).squareRoot() > 10 {
                        panning = abs(dx) > abs(dy) * 1.2
                    }
                    if panning == true {
                        anchor = panBase - Double(dx / railWidth) * span
                    } else if abs(dy) >= 3 {
                        dragging = true
                        onScrub(timeFor(y: v.location.y))
                    }
                }
                .onEnded { v in
                    if draggingEdge != nil {
                        draggingEdge = nil
                        gestureActive = false
                        panning = nil
                        dragging = false
                        return
                    }
                    let wasPan = panning == true
                    gestureActive = false
                    panning = nil
                    dragging = false
                    let tap = !wasPan && abs(v.translation.height) < 6 && abs(v.translation.width) < 6
                    if wasPan { return }
                    onScrub(timeFor(y: v.location.y))
                    if tap { onRangeTap(timeFor(y: v.location.y)) } else { onScrubEnd() }
                }
        )
    }

    /// Slim scrollbar for the day. The thumb shows how much of the day is on
    /// screen; drag anywhere on it to move the window without zooming out.
    private var panBar: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 11)
                .fill(.white.opacity(0.08))
                .frame(width: panBarWidth, height: railHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
            RoundedRectangle(cornerRadius: 9)
                .fill(.white.opacity(0.5))
                .frame(width: panBarWidth - 4, height: thumbHeight)
                .overlay(
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55))
                )
                .offset(y: thumbY)
        }
        .frame(width: panBarWidth, height: railHeight)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    gestureActive = true
                    let frac = min(max(Double(v.location.y / railHeight), 0), 1)
                    anchor = dayStart + frac * dayLength - span / 2
                }
                .onEnded { _ in gestureActive = false }
        )
        .accessibilityLabel("Move through the day")
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

    /// Frigate-style selection edge: a full-width line with the time on a pill.
    /// The drag itself is handled by the rail gesture (touch-down near the
    /// line grabs it) so the pill can never swallow the touch.
    private func rangeEdge(at t: Double, label: String) -> some View {
        let y = min(max(yFor(t) - 12, 0), railHeight - 24)
        return ZStack {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: railWidth, height: 2.5)
            Text(label)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(.black)
                .overlay(Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
        }
        .frame(width: railWidth, height: 24)
        .offset(y: y)
        .allowsHitTesting(false)
    }

    // MARK: Geometry

    private func yFor(_ t: Double) -> CGFloat { CGFloat(t - viewStart) * pxPerSecond }
    private func timeFor(y: CGFloat) -> Double {
        min(viewEnd, max(viewStart, viewStart + Double(y / pxPerSecond)))
    }

    private func fitDay() {
        span = max(60, dayEnd - dayStart)
        anchor = dayStart
    }

    private func zoom(_ factor: Double) {
        let maxSpan = max(60, dayEnd - dayStart)
        let newSpan = min(maxSpan, max(60, span * factor))
        // Keep the playhead (or the window centre if it's off-screen) pinned
        // at the same relative height while zooming.
        let focus = min(max(playhead, viewStart), viewEnd)
        let rel = (focus - viewStart) / max(1, viewEnd - viewStart)
        span = newSpan
        anchor = focus - rel * newSpan
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
