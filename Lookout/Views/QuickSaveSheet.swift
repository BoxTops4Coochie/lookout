import SwiftUI

/// One-tap "save the last N minutes" flow for people who don't want to scrub a
/// timeline: pick a duration, Frigate renders the clip. No modes, no start/end
/// handles, no date pickers.
struct QuickSaveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let camera: FrigateConfig.Camera
    /// Called when the person would rather pick exact times themselves.
    var onChooseTimeline: (() -> Void)? = nil

    @State private var busyMinutes: Int?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var savedOK = false

    private let choices = [1, 5, 10, 30, 60, 180]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text(camera.friendlyName ?? camera.name)
                        .font(.title2.weight(.bold))

                    Text("Choose how much recent footage to save. Frigate makes the clip for you — nothing else to set up.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 6)

                    ForEach(choices, id: \.self) { minutes in
                        Button {
                            Task { await save(minutes) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.title3)
                                Text(label(minutes))
                                    .font(.title3.weight(.semibold))
                                Spacer()
                                if busyMinutes == minutes {
                                    ProgressView().tint(.white)
                                }
                            }
                            .padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(Theme.accent.opacity(busyMinutes == nil ? 1 : 0.45),
                                        in: RoundedRectangle(cornerRadius: 16))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(busyMinutes != nil)
                    }

                    Text("Longer clips take longer to show up in Exports.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    Button {
                        onChooseTimeline?()
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "timeline.selection")
                                .font(.title3)
                            Text("Choose from timeline")
                                .font(.title3.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.bold))
                                .opacity(0.6)
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(busyMinutes != nil)
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Save a clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                if savedOK {
                    Button("Go to Exports") {
                        model.tab = .exports
                        dismiss()
                    }
                    Button("Done", role: .cancel) { dismiss() }
                } else {
                    Button("OK", role: .cancel) { }
                }
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func label(_ minutes: Int) -> String {
        switch minutes {
        case 1: return "Last minute"
        case 60: return "Last hour"
        case 180: return "Last 3 hours"
        default: return "Last \(minutes) minutes"
        }
    }

    private func save(_ minutes: Int) async {
        guard let api = model.api else { return }
        busyMinutes = minutes
        defer { busyMinutes = nil }
        let end = Date.now.timeIntervalSince1970
        let start = end - Double(minutes * 60)
        do {
            _ = try await api.createExport(camera: camera.name, start: start, end: end)
            alertTitle = "Saving your clip"
            alertMessage = "The last \(minutes) minutes are being saved. The clip will appear in the Exports tab in a minute or two."
            savedOK = true
            showAlert = true
        } catch {
            alertTitle = "Couldn’t save the clip"
            alertMessage = error.localizedDescription
            savedOK = false
            showAlert = true
        }
    }
}
