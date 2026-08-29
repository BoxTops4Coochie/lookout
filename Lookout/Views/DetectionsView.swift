import SwiftUI
import AVKit

// MARK: - Detections tab

struct DetectionsView: View {
    @Environment(AppModel.self) private var model

    @State private var events: [FrigateEvent] = []
    @State private var isLoading = false
    @State private var cameraFilter: String?
    @State private var labelFilter: String? = "all"
    @State private var errorMessage: String?
    @State private var selected: FrigateEvent?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && events.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if events.isEmpty {
                    ContentUnavailableView("No detections", systemImage: "magnifyingglass",
                                           description: Text(errorMessage ?? "Nothing found for this filter."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(events) { event in
                                Button { selected = event } label: {
                                    EventCard(event: event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                    .refreshable { await load() }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Detections")
            .searchable(text: .constant(""), prompt: labelFilter ?? "person")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("All cameras") { cameraFilter = nil; Task { await load() } }
                        ForEach(model.cameras) { cam in
                            Button(cam.friendlyName ?? cam.name) { cameraFilter = cam.name; Task { await load() } }
                        }
                    } label: {
                        Image(systemName: cameraFilter == nil ? "video" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .task { await load() }
            .sheet(item: $selected) { event in
                EventDetailView(event: event)
            }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        isLoading = true; defer { isLoading = false }
        do {
            events = try await api.events(camera: cameraFilter,
                                          label: (labelFilter == "all" ? nil : labelFilter),
                                          after: Date.now.timeIntervalSince1970 - 14 * 86400,
                                          limit: 200)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EventCard: View {
    @Environment(AppModel.self) private var model
    let event: FrigateEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                FrigateImage(model.api?.eventThumbnailURL(id: event.id) ?? URL(string: "about:blank")!, model: model)
                    .frame(height: 110)
                    .clipped()
                if event.hasSnapshot {
                    Image(systemName: "camera.fill")
                        .font(.caption2).foregroundStyle(.white)
                        .padding(5).background(.black.opacity(0.5), in: Circle()).padding(5)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.label.capitalized + (event.subLabel.map { " · \($0)" } ?? ""))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(model.cameras.first { $0.name == event.camera }.map { $0.friendlyName ?? $0.name } ?? event.camera) · \(relativeTime(event.startTime))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
        }
        .cardStyle()
    }
}

// MARK: - Event detail: clip + snapshot + jump

struct EventDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let event: FrigateEvent

    @State private var player: AVPlayer?
    @State private var showSnapshot = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Group {
                        if let player {
                            VideoPlayer(player: player)
                                .frame(height: 240)
                        } else {
                            FrigateImage(model.api?.eventSnapshotURL(id: event.id) ?? URL(string: "about:blank")!, model: model)
                                .frame(height: 240)
                        }
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 6) {
                        row("Label", event.label + (event.subLabel.map { " / \($0)" } ?? ""))
                        row("Camera", event.camera)
                        row("Start", timeString(event.startTime))
                        row("Duration", String(format: "%.0fs", event.duration))
                        if !event.zones.isEmpty { row("Zones", event.zones.joined(separator: ", ")) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner))

                    HStack(spacing: 10) {
                        if event.hasClip {
                            Button {
                                loadClip()
                            } label: {
                                Label("Play clip", systemImage: "play.circle")
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.borderedProminent)
                        }
                        if event.hasSnapshot {
                            Button { showSnapshot = true } label: {
                                Label("Snapshot", systemImage: "photo")
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }.buttonStyle(.bordered)
                        }
                    }
                    .tint(Theme.accent)
                }
                .padding()
            }
            .background(Theme.bg)
            .navigationTitle(relativeTime(event.startTime))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .fullScreenCover(isPresented: $showSnapshot) {
                FullImageView(url: model.api?.eventSnapshotURL(id: event.id))
            }
            .onDisappear { player?.pause() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).fontWeight(.medium) }
            .font(.callout)
    }

    private func loadClip() {
        guard let api = model.api else { return }
        let p = AVPlayer(url: api.eventVODURL(id: event.id))
        player = p
        p.play()
    }
}

struct FullImageView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let url: URL?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                FrigateImage(url, model: appModel)
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white)
                    }.padding()
                }
                Spacer()
            }
        }
    }
}
