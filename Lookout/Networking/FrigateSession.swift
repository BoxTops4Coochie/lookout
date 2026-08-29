import Foundation
import CryptoKit
import Security

// MARK: - Errors

enum FrigateError: LocalizedError {
    case notConfigured
    case unauthorized
    case certUntrusted(host: String, port: Int, hash: String, subjectSummary: String)
    case http(status: Int, body: String?)
    case decoding(Error)
    case invalidResponse
    case generic(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No server configured"
        case .unauthorized: return "Not signed in"
        case .certUntrusted(let host, let port, _, let subject):
            return "Untrusted certificate for \(host):\(port) (\(subject))"
        case .http(let status, let body):
            if let body, !body.isEmpty {
                // Frigate/FastAPI returns {"detail": ...}; surface a readable snippet.
                let snippet = body.count > 160 ? String(body.prefix(160)) + "…" : body
                return "HTTP \(status): \(snippet)"
            }
            return "HTTP \(status)"
        case .decoding: return "Unexpected server response"
        case .invalidResponse: return "Invalid server response"
        case .generic(let m): return m
        }
    }
}

/// Raised when HTTPS fails; carries the cert info so the UI can offer to pin it.
struct CertChallenge: Error {
    let host: String
    let port: Int
    let sha256: String
    let subjectSummary: String
}

// MARK: - Session manager (auth + cert pinning)

final class FrigateSession: NSObject, URLSessionDelegate, @unchecked Sendable {
    let baseURL: URL
    var pinnedHash: String?
    var onCertChallenge: ((CertChallenge) -> Void)?

    private lazy var config: URLSessionConfiguration = {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.httpCookieStorage = cookieStore
        c.httpAdditionalHeaders = ["User-Agent": "Lookout-iOS/1.0"]
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        return c
    }()

    private let cookieStore = HTTPCookieStorage.shared
    private let cookieJarID = "frigate-session"
    private lazy var session: URLSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

    init(baseURL: URL, pinnedHash: String?) {
        self.baseURL = baseURL
        self.pinnedHash = pinnedHash
        super.init()
    }

    func urlFor(_ path: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    // MARK: Requests

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FrigateError.invalidResponse }
        return (data, http)
    }

    @discardableResult
    func get(_ path: String, query: [String: String] = [:]) async throws -> Data {
        let (data, http) = try await data(for: URLRequest(url: urlFor(path, query: query)))
        if http.statusCode == 401 { throw FrigateError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw FrigateError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }

    func getJSON<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await get(path, query: query)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw FrigateError.decoding(error) }
    }

    /// Live image / media endpoints use a plain data task (no JSON decode).
    func imageData(_ url: URL) async throws -> Data {
        let (data, http) = try await data(for: URLRequest(url: url))
        guard (200..<300).contains(http.statusCode) else {
            throw FrigateError.http(status: http.statusCode, body: nil)
        }
        return data
    }

    @discardableResult
    func post(_ path: String, query: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: urlFor(path, query: query))
        req.httpMethod = "POST"
        if body != nil {
            // FastAPI rejects JSON bodies without an explicit content type (422
            // "Input should be a valid dictionary") — verified against live 0.17.
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        req.httpBody = body
        let (data, http) = try await data(for: req)
        if http.statusCode == 401 { throw FrigateError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw FrigateError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }

    @discardableResult
    func delete(_ path: String, query: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: urlFor(path, query: query))
        req.httpMethod = "DELETE"
        let (data, http) = try await data(for: req)
        guard (200..<300).contains(http.statusCode) else {
            throw FrigateError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }

    func download(_ url: URL, to dest: URL) async throws -> URL {
        let (data, http) = try await data(for: URLRequest(url: url))
        guard (200..<300).contains(http.statusCode) else {
            throw FrigateError.http(status: http.statusCode, body: nil)
        }
        try data.write(to: dest, options: .atomic)
        return dest
    }

    /// Server-side mtime of an export file (when it was rendered/created).
    func headLastModified(_ url: URL) async -> Date? {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        guard let (_, http) = try? await data(for: req),
              let s = http.value(forHTTPHeaderField: "Last-Modified") else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "GMT")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return fmt.date(from: s)
    }

    // MARK: Auth

    var isLoggedIn: Bool {
        cookieStore.cookies(for: baseURL)?.isEmpty == false
    }

    @discardableResult
    func login(username: String, password: String) async throws -> Bool {
        // Frigate /api/login expects JSON body (verified against 0.17).
        var req = URLRequest(url: urlFor("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user": username, "password": password])
        let (data, http) = try await data(for: req)
        if http.statusCode == 200 || http.statusCode == 302 { return true }
        if http.statusCode == 401 { return false }
        throw FrigateError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
    }

    func logout() async {
        _ = try? await get("api/logout")
        for c in cookieStore.cookies ?? [] where c.domain.contains(baseURL.host ?? "") {
            cookieStore.deleteCookie(c)
        }
    }

    // MARK: WebSocket

    /// Shared URLSession (cookie + cert-pin delegate) — reused by WebRTC signaling.
    var socketSession: URLSession { session }

    /// wss:// URL for a ROOT-level path with query (go2rtc live WS lives at /live/..., not /api/).
    func wssRootURL(path: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/" + path
        comps.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url!
    }

    /// Frigate's command/event socket is /ws — /api/ws returns 403 (verified live).
    func webSocket(path: String = "ws") -> URLSessionWebSocketTask {
        let url = wssURL(for: path)
        return session.webSocketTask(with: url)
    }

    private func wssURL(for path: String) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        return comps.url!
    }

    /// Send a command over WS ({"topic": ..., "payload": ...}) after connect.
    static func commandMessage(topic: String, payload: String) -> URLSessionWebSocketTask.Message {
        .data(try! JSONSerialization.data(withJSONObject: ["topic": topic, "payload": payload]))
    }

    // MARK: TLS challenge / pinning

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let hash = Self.certSHA256(cert)
        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        // Pinned match → trust explicitly.
        if let pinned = pinnedHash, pinned == hash {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // Default evaluation (real CAs) → use if valid.
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Self-signed / unknown CA → surface a pin prompt instead of failing silently.
        let subject = Self.subjectSummary(cert)
        DispatchQueue.main.async { [weak self] in
            self?.onCertChallenge?(CertChallenge(host: host, port: port, sha256: hash, subjectSummary: subject))
        }
        // Hold the connection: cancel while the UI decides (next attempt will pin).
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    static func certSHA256(_ cert: SecCertificate) -> String {
        let data = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func subjectSummary(_ cert: SecCertificate) -> String {
        (SecCertificateCopySubjectSummary(cert) as String?) ?? "unknown"
    }
}
