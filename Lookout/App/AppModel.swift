import SwiftUI
import Observation

@Observable
@MainActor
final class AppModel {
    enum Tab: Hashable { case live, detections, exports, settings }

    // Persistence keys
    private let serversKey = "lookout.servers"

    var servers: [ServerConfig] = [] { didSet { persistServers() } }
    var activeServerID: UUID? { didSet { persistActiveServer() } }
    var tab: Tab = .live

    // Session state
    var needsLogin: Bool = false
    var bootError: String?
    var config: FrigateConfig?
    var frigateVersion: String?

    // Cert pinning flow
    var certChallenge: CertChallenge?
    var pendingCertRetry: (() -> Void)?

    private(set) var session: FrigateSession?
    private var loginAttempted = false

    var activeServer: ServerConfig? {
        servers.first { $0.id == activeServerID } ?? servers.first
    }

    var api: FrigateAPI? { session.map { FrigateAPI(session: $0) } }

    var cameras: [FrigateConfig.Camera] { config?.orderedCameras ?? [] }

    init() {
        load()
        if let server = activeServer {
            activate(server)
        }
    }

    // MARK: Bootstrap

    func bootstrap() async {
        guard let server = activeServer else { return }
        do {
            config = try await requireAPI().config()
            frigateVersion = try? await requireAPI().version()
            needsLogin = false
            bootError = nil
        } catch FrigateError.unauthorized {
            // Try stored credentials once automatically.
            if let u = server.username, let p = server.password, !loginAttempted {
                loginAttempted = true
                if (try? await session?.login(username: u, password: p)) == true {
                    loginAttempted = false
                    return await bootstrap()
                }
            }
            loginAttempted = false
            needsLogin = true
        } catch {
            bootError = error.localizedDescription
        }
    }

    func activate(_ server: ServerConfig) {
        let s = FrigateSession(baseURL: server.url, pinnedHash: server.pinnedCertHash)
        s.onCertChallenge = { [weak self] challenge in
            guard let self else { return }
            self.certChallenge = challenge
            self.pendingCertRetry = { [weak self] in Task { await self?.bootstrap() } }
        }
        session = s
        activeServerID = server.id
        config = nil
        bootError = nil
    }

    func login(username: String, password: String) async -> Bool {
        guard let session else { return false }
        let ok = ((try? await session.login(username: username, password: password)) ?? false)
        if ok {
            needsLogin = false
            await bootstrap()
        }
        return ok
    }

    func acceptCertChallenge() {
        guard let challenge = certChallenge, let idx = servers.firstIndex(where: { $0.id == activeServerID }) else { return }
        servers[idx].pinnedCertHash = challenge.sha256
        session?.pinnedHash = challenge.sha256
        certChallenge = nil
        let retry = pendingCertRetry
        pendingCertRetry = nil
        retry?()
    }

    func rejectCertChallenge() {
        certChallenge = nil
        pendingCertRetry = nil
        bootError = "Certificate not trusted. Add a valid certificate or connect over HTTP on your LAN."
    }

    func requireAPI() throws -> FrigateAPI {
        guard let session else { throw FrigateError.notConfigured }
        return FrigateAPI(session: session)
    }

    // MARK: Persistence

    private func load() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            // passwords live in the Keychain, not in the encoded blob
            servers = decoded.map { var s = $0
                s.password = Keychain.get(s.id.uuidString)
                return s }
        }
        if let idData = d.data(forKey: "lookout.activeServer"),
           let id = try? JSONDecoder().decode(UUID.self, from: idData) {
            activeServerID = id
        }
    }

    private func persistServers() {
        var stripped = servers
        for i in stripped.indices {
            if let pw = stripped[i].password, !pw.isEmpty {
                _ = Keychain.set(pw, for: stripped[i].id.uuidString)
            }
            stripped[i].password = nil
        }
        if let data = try? JSONEncoder().encode(stripped) {
            UserDefaults.standard.set(data, forKey: serversKey)
        }
    }

    func removeServer(_ server: ServerConfig) {
        Keychain.delete(server.id.uuidString)
        servers.removeAll { $0.id == server.id }
        if activeServerID == server.id { activeServerID = servers.first?.id }
    }

    private func persistActiveServer() {
        if let id = activeServerID, let data = try? JSONEncoder().encode(id) {
            UserDefaults.standard.set(data, forKey: "lookout.activeServer")
        }
    }
}
