import SwiftUI
import AVKit
import Photos
import UIKit

// MARK: - Exports tab

struct ExportsView: View {
    @Environment(AppModel.self) private var model

    enum SortKey: String, CaseIterable, Identifiable {
        case recordingDate = "Recording date"
        case createdDate = "Export created"
        var id: String { rawValue }
    }

    @State private var exports: [FrigateExport] = []
    @State private var sortKey: SortKey =
        SortKey(rawValue: UserDefaults.standard.string(forKey: "exports.sortKey") ?? "") ?? .recordingDate
    @State private var ascending = UserDefaults.standard.bool(forKey: "exports.ascending")
    /// export id -> file mtime (server render time), filled lazily via HEAD.
    @State private var createdDates: [String: Date] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var downloadingID: String?
    @State private var shareURL: URL?
    @State private var playExport: FrigateExport?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && exports.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if exports.isEmpty {
                    ContentUnavailableView("No exports yet", systemImage: "square.and.arrow.down",
                        description: Text("Create clips from a camera’s History screen. Frigate renders them server-side."))
                } else {
                    List {
                        ForEach(sorted) { item in
                            ExportRow(export: item, isDownloading: downloadingID == item.id)
                                .listRowBackground(Theme.card)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        Task { await deleteExport(item) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                .contextMenu {
                                    Button("Save to Photos") { Task { await save(item) } }
                                    Button("Share…") { prepareShare(item) }
                                    Button("Play") { playExport = item }
                                }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .refreshable { await load() }
                }
            }
            .background(Theme.bg)
            .navigationTitle("Exports")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort by", selection: $sortKey) {
                            ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Button {
                            ascending.toggle()
                        } label: {
                            Label(ascending ? "Ascending" : "Descending",
                                  systemImage: ascending ? "arrow.up" : "arrow.down")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .onChange(of: sortKey) { _, k in UserDefaults.standard.set(k.rawValue, forKey: "exports.sortKey") }
            .onChange(of: ascending) { _, a in UserDefaults.standard.set(a, forKey: "exports.ascending") }
            .task(id: sortKey) { await resolveCreatedDates() }
            .task { await load() }
            // Auto-poll while any export is in progress
            .task(id: inProgressCount) {
                guard inProgressCount > 0 else { return }
                while !Task.isCancelled, inProgressCount > 0 {
                    try? await Task.sleep(for: .seconds(5))
                    await load(silent: true)
                }
            }
            .sheet(item: $playExport) { item in
                if let url = model.api.flatMap({ $0.exportVideoURL(item) }) {
                    ExportPlayerSheet(url: url, model: model)
                }
            }
            .sheet(item: Binding(get: { shareURL.map { FrigateExportURL(url: $0) } },
                                 set: { shareURL = $0?.url })) { wrap in
                ShareSheet(items: [wrap.url])
            }
            .overlay(alignment: .bottom) {
                if let msg = errorMessage {
                    Text(msg).font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 20)
                }
            }
        }
    }

    private var sorted: [FrigateExport] {
        exports.sorted { a, b in
            let lhs = sortDate(a), rhs = sortDate(b)
            return ascending ? lhs < rhs : lhs > rhs
        }
    }

    private func sortDate(_ e: FrigateExport) -> Double {
        switch sortKey {
        case .recordingDate:
            return e.date
        case .createdDate:
            // file mtime when known; fall back to recording date (renders
            // ~same order until mtimes resolve, then re-sorts live)
            return createdDates[e.id]?.timeIntervalSince1970 ?? e.date
        }
    }

    /// Populate createdDates for exports missing an mtime (parallel HEADs).
    private func resolveCreatedDates() async {
        guard sortKey == .createdDate, let api = model.api else { return }
        let missing = exports.filter { createdDates[$0.id] == nil && $0.inProgress != true }
        await withTaskGroup(of: (String, Date?).self) { group in
            for e in missing {
                guard let url = api.exportVideoURL(e) else { continue }
                group.addTask { (e.id, await api.session.headLastModified(url)) }
            }
            for await (id, date) in group {
                if let date { createdDates[id] = date }
            }
        }
    }

    private var inProgressCount: Int {
        exports.filter { $0.inProgress == true || $0.status == "in_progress" }.count
    }

    private func load(silent: Bool = false) async {
        guard let api = model.api else { return }
        if !silent { isLoading = true }
        defer { isLoading = false && !silent }
        do {
            exports = try await api.exports()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func localFile(_ export: FrigateExport) -> URL? {
        guard let name = export.playbackPath else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    private func save(_ export: FrigateExport) async {
        guard let api = model.api, let url = api.exportVideoURL(export) else { return }
        downloadingID = export.id
        defer { downloadingID = nil }
        let dest = localFile(export) ?? URL(fileURLWithPath: "/dev/null")
        if !FileManager.default.fileExists(atPath: dest.path) {
            do { _ = try await api.session.download(url, to: dest) }
            catch { errorMessage = "Download failed: \(error.localizedDescription)"; return }
        }
        do {
            let speed = VideoSpeed.speed(forExport: export.id)
            let final = speed > 1.01 ? try await VideoSpeed.process(dest, speed: speed) : dest
            try await PhotosSaver.saveVideo(at: final)
            if speed > 1.01 { errorMessage = "Saved to Photos ✓ (\(Int(speed))× speed)" }
            else { errorMessage = "Saved to Photos ✓" }
            try? await Task.sleep(for: .seconds(2))
            errorMessage = nil
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func prepareShare(_ export: FrigateExport) {
        guard let api = model.api, let url = api.exportVideoURL(export) else { return }
        let dest = localFile(export)
        Task {
            downloadingID = export.id
            defer { downloadingID = nil }
            if let dest, !FileManager.default.fileExists(atPath: dest.path) {
                _ = try? await api.session.download(url, to: dest)
            }
            let speed = VideoSpeed.speed(forExport: export.id)
            if speed > 1.01, let dest,
               FileManager.default.fileExists(atPath: dest.path),
               let final = try? await VideoSpeed.process(dest, speed: speed) {
                shareURL = final
            } else {
                shareURL = dest ?? url
            }
        }
    }

    private func deleteExport(_ export: FrigateExport) async {
        guard let api = model.api else { return }
        try? await api.deleteExport(id: export.id)
        await load(silent: true)
    }
}

private struct ExportRow: View {
    @Environment(AppModel.self) private var model
    let export: FrigateExport
    let isDownloading: Bool

    private var inProgress: Bool { export.inProgress == true || export.status == "in_progress" }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let api = model.api, let thumb = export.thumbPath {
                    FrigateImage(thumbURL(api: api, thumb: thumb), model: model)
                        .frame(width: 84, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.bg)
                        .frame(width: 84, height: 48)
                        .overlay(Image(systemName: "film").foregroundStyle(.secondary))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(export.name ?? export.id).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(export.camera + " · " + timeString(export.date))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if inProgress {
                    Label("Rendering…", systemImage: "hourglass")
                        .font(.caption2).foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            if isDownloading {
                ProgressView()
            } else if !inProgress {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private func thumbURL(api: FrigateAPI, thumb: String) -> URL {
        // /media/frigate/clips/export/x.webp -> served at /clips/export/x.webp (root, verified)
        let trimmed = thumb.replacingOccurrences(of: "/media/frigate", with: "")
        return URL(string: trimmed, relativeTo: api.base)!.absoluteURL
    }
}

private struct FrigateExportURL: Identifiable { let url: URL; var id: URL { url } }

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Export player sheet

struct ExportPlayerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let model: AppModel?
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        guard let player, let item = player.currentItem else { return }
                        Task {
                            // Download via app session (cert-pinned) then save.
                            guard let api = model?.api else { return }
                            let dest = FileManager.default.temporaryDirectory
                                .appendingPathComponent((url.lastPathComponent))
                            if !FileManager.default.fileExists(atPath: dest.path) {
                                _ = try? await api.session.download(url, to: dest)
                            }
                            _ = item
                            try? await PhotosSaver.saveVideo(at: dest)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                let p = AVPlayer(url: url)
                player = p
                p.play()
            }
            .onDisappear { player?.pause() }
        }
    }
}

// MARK: - Photos

enum PhotosSaver {
    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Photos", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Photos access denied"])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                if success { cont.resume() }
                else { cont.resume(throwing: error ?? NSError(domain: "Photos", code: 2)) }
            }
        }
    }
}
