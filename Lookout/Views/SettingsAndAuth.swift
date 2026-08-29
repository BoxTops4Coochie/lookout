import SwiftUI

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("Servers") {
                    ForEach(model.servers) { server in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(server.name).font(.body)
                                Text(server.url.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary)
                                if server.pinnedCertHash != nil {
                                    Label("Certificate pinned", systemImage: "checkmark.seal.fill")
                                        .font(.caption2).foregroundStyle(.green)
                                }
                            }
                            Spacer()
                            if server.id == model.activeServerID {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.activate(server) }
                        .swipeActions {
                            Button(role: .destructive) {
                                model.removeServer(server)
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    Button { showAdd = true } label: { Label("Add server", systemImage: "plus") }
                }

                Section("Status") {
                    LabeledContent("App version", value: appVersion)
                    LabeledContent("Frigate", value: model.frigateVersion ?? "—")
                    LabeledContent("Cameras", value: String(model.cameras.count))
                    LabeledContent("Session", value: model.needsLogin ? "Signed out" : "Active")
                }

                if let err = model.bootError {
                    Section("Last error") {
                        Text(err).font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .sheet(isPresented: $showAdd) { ServerEditView() }
        }
    }
}

// MARK: - Add server

struct ServerEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Home"
    @State private var urlString = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("https://host:port", text: $urlString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Frigate login (leave blank to sign in later)") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Section {
                    Button { Task { await test() } } label: {
                        if testing { ProgressView() }
                        else { Text("Test connection") }
                    }
                    if let r = testResult {
                        Text(r).font(.callout).foregroundStyle(r.hasPrefix("✓") ? .green : .orange)
                    }
                }
            }
            .navigationTitle("Add server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isPlausibleURL)
                }
            }
        }
    }

    private var isPlausibleURL: Bool {
        let t = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: t), t.count >= 8,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        return true
    }

    private func test() async {
        guard let url = URL(string: urlString) else { testResult = "Invalid URL"; return }
        testing = true; defer { testing = false }
        let s = FrigateSession(baseURL: url, pinnedHash: nil)
        s.onCertChallenge = { [weak s] c in
            // Auto-pin for the *test* only so self-signed servers are measurable.
            s?.pinnedHash = c.sha256
        }
        do {
            let api = FrigateAPI(session: s)
            let v = try await api.version()
            _ = try await s.login(username: username, password: password)
            testResult = "✓ Frigate \(v) reachable"
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func save() {
        guard let url = URL(string: urlString) else { return }
        var server = ServerConfig(name: name, url: url,
                                  username: username.isEmpty ? nil : username,
                                  password: password.isEmpty ? nil : password,
                                  pinnedCertHash: nil)
        // Reuse a previously pinned hash for same host:port.
        if let prior = model.servers.first(where: { $0.url.host == url.host && $0.url.port == url.port }),
           prior.pinnedCertHash != nil {
            server.pinnedCertHash = prior.pinnedCertHash
        }
        model.servers.append(server)
        model.activate(server)
        dismiss()
    }
}

// MARK: - First-run setup

struct ServerSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false

    var body: some View {
        ContentUnavailableView {
            Label("Welcome to Lookout", systemImage: "video.fill.badge.plus")
        } description: {
            Text("Add your Frigate server to get started.")
        } actions: {
            Button {
                showAdd = true
            } label: {
                Text("Add Frigate server")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .background(Theme.bg)
        .sheet(isPresented: $showAdd) { ServerEditView() }
    }
}

// MARK: - Login overlay

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text(model.activeServer?.url.host ?? "Frigate")
                .font(.headline)
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Password", text: $password)
            if failed { Text("Login failed").font(.caption).foregroundStyle(.red) }
            Button {
                busy = true
                Task {
                    let ok = await model.login(username: username, password: password)
                    failed = !ok
                    busy = false
                }
            } label: {
                if busy { ProgressView() } else { Text("Sign in").fontWeight(.semibold) }
            }
            .padding(.horizontal, 40).padding(.vertical, 12)
            .background(Theme.accent.opacity(0.9), in: Capsule())
            .foregroundStyle(.black)
            .disabled(username.isEmpty || password.isEmpty || busy)
        }
        .textFieldStyle(.roundedBorder)
        .padding(28)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay {
            // Cert trust sheet sits above login when needed
            if let challenge = model.certChallenge {
                CertTrustView(challenge: challenge)
            }
        }
    }
}

// MARK: - Cert trust prompt (fixes the self-signed HTTPS problem)

struct CertTrustView: View {
    @Environment(AppModel.self) private var model
    let challenge: CertChallenge

    var shortHash: String {
        String(challenge.sha256.prefix(16)).uppercased().chunked(into: 4).joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 40)).foregroundStyle(.yellow)
            Text("Untrusted certificate").font(.headline)
            Text("\(challenge.host):\(challenge.port)\n\(challenge.subjectSummary)")
                .font(.caption.monospaced()).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("SHA-256: \(shortHash)…")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            Text("This is expected for self-signed HTTPS on your LAN. Trust it for this server?")
                .font(.callout).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Don’t trust") { model.rejectCertChallenge() }
                    .buttonStyle(.bordered)
                Button("Trust") { model.acceptCertChallenge() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(24)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20))
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.6))
    }
}

extension String {
    fileprivate func chunked(into size: Int) -> [String] {
        var out: [String] = []
        var idx = startIndex
        while idx < endIndex {
            let end = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(String(self[idx..<end]))
            idx = end
        }
        return out
    }
}
