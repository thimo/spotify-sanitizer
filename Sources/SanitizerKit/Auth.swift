import Foundation
import CryptoKit
import AppKit
import Network

enum AuthError: Error, LocalizedError {
    case notLoggedIn
    case denied(String)
    case stateMismatch
    case tokenRequestFailed(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:              return "Not logged in. Use Log in to authorize with Spotify."
        case .denied(let e):            return "Authorization denied: \(e)"
        case .stateMismatch:            return "OAuth state mismatch — possible CSRF, aborted."
        case .tokenRequestFailed(let m): return "Token request failed: \(m)"
        case .server(let m):            return "Local callback server error: \(m)"
        }
    }
}

// OAuth 2.0 Authorization Code + PKCE, ported from the Ruby Auth module.
// No client secret: a loopback HTTP listener catches the redirect, we exchange
// the code for tokens and cache them. accessToken() refreshes transparently.
enum Auth {
    static let authorizeURL = "https://accounts.spotify.com/authorize"
    static let tokenURL = "https://accounts.spotify.com/api/token"

    static func loggedIn() -> Bool { Config.loadTokens() != nil }

    static func accessToken() async throws -> String {
        guard var tokens = Config.loadTokens() else { throw AuthError.notLoggedIn }
        if expired(tokens) { tokens = try await refresh(tokens) }
        return tokens.access_token
    }

    static func expired(_ t: Tokens) -> Bool {
        // Refresh a minute early to avoid races on long scans.
        Int(Date().timeIntervalSince1970) >= (t.expires_at ?? 0) - 60
    }

    // MARK: - Interactive login

    static func login() async throws {
        let verifier = randomURLSafe(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(16)
        let redirect = URL(string: Config.redirectURI)!
        let port = UInt16(redirect.port ?? 8888)

        var comps = URLComponents(string: authorizeURL)!
        comps.queryItems = [
            .init(name: "client_id", value: try Config.clientID()),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Config.redirectURI),
            .init(name: "scope", value: Config.scopes.joined(separator: " ")),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            // Force the consent screen so re-authorizing actually re-grants every
            // scope (Spotify otherwise silently reuses a prior, possibly narrower
            // consent — which can leave library-modify ineffective).
            .init(name: "show_dialog", value: "true")
        ]
        NSWorkspace.shared.open(comps.url!)

        let code = try await awaitRedirect(port: port, path: redirect.path, expectedState: state)
        try await exchangeCode(code, verifier: verifier)
    }

    // MARK: - PKCE helpers

    static func randomURLSafe(_ bytes: Int) -> String {
        // Swift's default RNG is a CSPRNG on Apple platforms.
        base64URL(Data((0..<bytes).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Loopback redirect catcher

    static func awaitRedirect(port: UInt16, path: String, expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            } catch {
                cont.resume(throwing: AuthError.server("\(error)")); return
            }

            let lock = NSLock()
            var finished = false
            func finish(_ result: Result<String, Error>) {
                lock.lock(); defer { lock.unlock() }
                if finished { return }
                finished = true
                listener.cancel()
                cont.resume(with: result)
            }

            listener.newConnectionHandler = { conn in
                conn.start(queue: .global())
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    guard let data = data, let text = String(data: data, encoding: .utf8) else {
                        if let error = error { finish(.failure(AuthError.server("\(error)"))) }
                        return
                    }
                    let requestLine = text.components(separatedBy: "\r\n").first ?? ""
                    let fields = requestLine.split(separator: " ")
                    guard fields.count >= 2 else { conn.cancel(); return }
                    let target = String(fields[1])
                    guard target.hasPrefix(path) else {
                        respond(conn, status: "404 Not Found", body: "Not found"); return
                    }

                    let items = URLComponents(string: "http://127.0.0.1\(target)")?.queryItems ?? []
                    func q(_ name: String) -> String? { items.first { $0.name == name }?.value }

                    if let err = q("error") {
                        respond(conn, status: "400 Bad Request",
                                body: "Authorization denied: \(err). You can close this tab.")
                        finish(.failure(AuthError.denied(err))); return
                    }
                    guard q("state") == expectedState else {
                        respond(conn, status: "400 Bad Request",
                                body: "State mismatch — possible CSRF. You can close this tab.")
                        finish(.failure(AuthError.stateMismatch)); return
                    }
                    guard let code = q("code") else { conn.cancel(); return }

                    respond(conn, status: "200 OK",
                            body: "spotify-sanitizer is authorized. You can close this tab and return to the app.")
                    finish(.success(code))
                }
            }
            listener.start(queue: .global())
        }
    }

    static func respond(_ conn: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>spotify-sanitizer</title>"
            + "<body style='font:16px system-ui;margin:3rem'>\(body)</body>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Token exchange / refresh

    static func exchangeCode(_ code: String, verifier: String) async throws {
        _ = try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.redirectURI,
            "client_id": try Config.clientID(),
            "code_verifier": verifier
        ])
    }

    static func refresh(_ tokens: Tokens) async throws -> Tokens {
        guard let refreshToken = tokens.refresh_token else { throw AuthError.notLoggedIn }
        var fresh = try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": try Config.clientID()
        ])
        // Spotify may omit a new refresh_token; keep the old one if so.
        if fresh.refresh_token == nil {
            fresh.refresh_token = refreshToken
            Config.saveTokens(fresh)
        }
        return fresh
    }

    @discardableResult
    static func postToken(_ body: [String: String]) async throws -> Tokens {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(body).data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw AuthError.tokenRequestFailed(message)
        }
        var tokens = try JSONDecoder().decode(Tokens.self, from: data)
        tokens.expires_at = Int(Date().timeIntervalSince1970) + (tokens.expires_in ?? 3600)
        Config.saveTokens(tokens)
        return tokens
    }

    static func formEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlFormValueAllowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }
}

extension CharacterSet {
    // Strict set for application/x-www-form-urlencoded values: only the RFC 3986
    // unreserved characters pass through, everything else is percent-encoded.
    static let urlFormValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
