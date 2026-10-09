import AppKit
import CryptoKit
import Foundation
import Network

/// Spotify sign-in with the Authorization Code + PKCE flow, so no client secret is needed.
/// The redirect lands on a one-shot loopback server; tokens live in the Keychain.
@MainActor final class SpotifyAuth {
    static let port: UInt16 = 47821
    static var redirectURI: String { "http://127.0.0.1:\(port)/callback" }
    static let scopes = [
        "user-read-playback-state",
        "user-read-currently-playing",
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
    ]
    private static let keychainService = "Lipsync Spotify"
    private static let keychainAccount = "tokens"

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    enum AuthError: LocalizedError {
        case noClientID
        case denied(String)
        case stateMismatch
        case badResponse(Int, String)
        case timedOut
        case notConnected

        var errorDescription: String? {
            switch self {
            case .noClientID: return "No Spotify client ID is set."
            case .denied(let reason): return "Spotify sign-in was declined (\(reason))."
            case .stateMismatch: return "Spotify sign-in returned an unexpected response."
            case .badResponse(let status, _): return "Spotify sign-in failed (HTTP \(status))."
            case .timedOut: return "Spotify sign-in timed out."
            case .notConnected: return "Spotify isn't connected."
            }
        }
    }

    private(set) var tokens: Tokens?
    private var refreshTask: Task<Tokens, Error>?
    /// Called when Spotify revokes the sign-in and the user has to connect again.
    var onSignedOut: (() -> Void)?

    var isConnected: Bool { tokens != nil }

    init() {
        if let data = Keychain.load(service: Self.keychainService, account: Self.keychainAccount) {
            tokens = try? JSONDecoder().decode(Tokens.self, from: data)
        }
    }

    func connect() async throws {
        guard let clientID = Settings.spotifyClientID else { throw AuthError.noClientID }
        let verifier = Self.randomURLSafe(byteCount: 48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(byteCount: 16)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]

        let server = LoopbackServer()
        async let callback = server.waitForCallback(port: Self.port, path: "/callback", timeout: 300)
        NSWorkspace.shared.open(components.url!)
        let response = try await callback

        let items = Dictionary((response.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if let error = items["error"] { throw AuthError.denied(error) }
        guard items["state"] == state, let code = items["code"] else { throw AuthError.stateMismatch }
        let fresh = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        store(fresh)
        Log.info("Spotify connected")
    }

    func disconnect() {
        tokens = nil
        Keychain.delete(service: Self.keychainService, account: Self.keychainAccount)
    }

    func accessToken() async throws -> String {
        guard let tokens else { throw AuthError.notConnected }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        return try await refresh().accessToken
    }

    /// Refreshes the access token. Concurrent callers share one request.
    func refresh() async throws -> Tokens {
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens, let clientID = Settings.spotifyClientID else { throw AuthError.notConnected }
        let task = Task { @MainActor in
            try await self.requestTokens([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": clientID,
            ], keepingRefreshToken: current.refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh
        } catch AuthError.badResponse(let status, let body) where status == 400 || status == 401 {
            Log.warn("Spotify refresh rejected (\(status)): \(body)")
            disconnect()
            onSignedOut?()
            throw AuthError.notConnected
        }
    }

    private func store(_ fresh: Tokens) {
        tokens = fresh
        if let data = try? JSONEncoder().encode(fresh) {
            Keychain.save(data, service: Self.keychainService, account: Self.keychainAccount)
        }
    }

    private func requestTokens(_ form: [String: String], keepingRefreshToken previous: String? = nil) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AuthError.badResponse(status, String(data: data, encoding: .utf8) ?? "") }
        struct Body: Decodable {
            let access_token: String
            let expires_in: Double
            let refresh_token: String?
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let refresh = body.refresh_token ?? previous else { throw AuthError.badResponse(status, "no refresh token") }
        return Tokens(accessToken: body.access_token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(body.expires_in))
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Accepts one OAuth redirect on the loopback interface and answers it with a small page.
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lipsync.oauth.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URLComponents, Error>?

    func waitForCallback(port: UInt16, path: String, timeout: TimeInterval) async throws -> URLComponents {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredInterfaceType = .loopback
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
                    self.listener = listener
                    // These closures hold the server until finish() cancels the listener.
                    listener.newConnectionHandler = { connection in self.handle(connection, path: path) }
                    listener.stateUpdateHandler = { state in
                        if case .failed(let error) = state { self.finish(.failure(error)) }
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) {
                        self.finish(.failure(SpotifyAuth.AuthError.timedOut))
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func handle(_ connection: NWConnection, path: String) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if let components = URLComponents(string: "http://127.0.0.1" + target), components.path == path {
                let failed = components.queryItems?.contains { $0.name == "error" } ?? false
                self.respond(connection, status: "200 OK", body: Self.page(success: !failed))
                self.finish(.success(components))
            } else {
                self.respond(connection, status: "404 Not Found", body: "")
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<URLComponents, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener?.cancel()
        listener = nil
        continuation.resume(with: result)
    }

    private static func page(success: Bool) -> String {
        let title = success ? "Spotify is connected" : "Spotify wasn't connected"
        let detail = success ? "You can close this tab. Lipsync takes it from here." : "Close this tab and try again from Lipsync."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Lipsync</title>
        <style>body{font:15px -apple-system,system-ui;background:#111;color:#eee;display:grid;place-items:center;height:100vh;margin:0}
        div{text-align:center}h1{font-size:20px;font-weight:600;margin:0 0 8px}p{color:#999;margin:0}</style></head>
        <body><div><h1>\(title)</h1><p>\(detail)</p></div></body></html>
        """
    }
}
