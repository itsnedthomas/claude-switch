import Foundation
import Network

/// "Sign in with ChatGPT" for Codex, done the way the Codex CLI does it (codex-rs/login):
/// PKCE in the browser, a one-shot callback server on 127.0.0.1, then the token endpoint.
enum CodexAuth {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let issuer = "https://auth.openai.com"
    static let tokenURL = URL(string: issuer + "/oauth/token")!
    /// The two ports on OpenAI's redirect allow-list for this client, in the order Codex tries them.
    static let ports: [UInt16] = [1455, 1457]
    static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    /// Opens the browser via `open`, waits up to 10 minutes for the callback, returns the login.
    static func signIn(open: @escaping (URL) -> Void) async throws -> ProviderLogin {
        let verifier = PKCE.random(64)
        let state = PKCE.random()
        let server = try await CallbackServer.start(ports: ports, state: state)
        let redirect = "http://127.0.0.1:\(server.port)/auth/callback"
        open(authorizeURL(redirect: redirect, challenge: PKCE.challenge(verifier), state: state))
        let code = try await server.code(timeout: 600)
        try Task.checkCancellation()
        return try await exchange(code: code, redirect: redirect, verifier: verifier)
    }

    /// New tokens from the refresh token; keeps fields the reply leaves out.
    static func refresh(_ login: ProviderLogin) async throws -> ProviderLogin {
        guard let rt = login.refresh, !rt.isEmpty else { throw APIError.bad("Sign in to Codex again") }
        var req = URLRequest(url: tokenURL, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": rt,
        ])
        return merge(try await post(req, signedOut: "Codex sign-in expired. Sign in again"), into: login)
    }

    static func authorizeURL(redirect: String, challenge: String, state: String) -> URL {
        let q = form([
            ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirect),
            ("code_challenge", challenge), ("code_challenge_method", "S256"), ("state", state),
            ("scope", scope), ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"), ("originator", "codex_cli_rs"),
        ])
        return URL(string: issuer + "/oauth/authorize?" + String(decoding: q, as: UTF8.self))!
    }

    static func exchange(code: String, redirect: String, verifier: String) async throws -> ProviderLogin {
        var req = URLRequest(url: tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code),
            ("redirect_uri", redirect), ("code_verifier", verifier),
        ])
        let j = try await post(req)
        guard let access = j["access_token"] as? String, !access.isEmpty else { throw APIError.bad("ChatGPT sent no access token") }
        return merge(j, into: ProviderLogin(access: access))
    }

    /// `signedOut` replaces errors that mean the refresh token is dead.
    static func post(_ req: URLRequest, signedOut: String? = nil) async throws -> JSON {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON
        guard (200..<300).contains(code) else {
            let err = j?["error"] as? JSON
            let kind = j?["error"] as? String ?? err?["code"] as? String
            let dead = ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"]
            if let signedOut, code == 401 || dead.contains(kind ?? "") { throw APIError.bad(signedOut) }
            let why = j?["error_description"] as? String ?? err?["message"] as? String
            throw why.map(APIError.bad) ?? APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        guard let j else { throw APIError.bad("Unreadable reply") }
        return j
    }

    /// Fills a login from a token reply, keeping what the reply leaves out.
    static func merge(_ j: JSON, into old: ProviderLogin) -> ProviderLogin {
        var l = old
        if let a = j["access_token"] as? String, !a.isEmpty { l.access = a }
        if let r = j["refresh_token"] as? String, !r.isEmpty { l.refresh = r }
        if let i = j["id_token"] as? String, !i.isEmpty { l.idToken = i }
        let id = l.idToken.flatMap(Providers.jwtPayload) ?? [:]
        let at = Providers.jwtPayload(l.access) ?? [:]
        let idAuth = id["https://api.openai.com/auth"] as? JSON ?? [:]
        let atAuth = at["https://api.openai.com/auth"] as? JSON ?? [:]
        l.expires = Providers.num(at["exp"]).map { Date(timeIntervalSince1970: $0) } ?? l.expires
        l.email = id["email"] as? String ?? (at["https://api.openai.com/profile"] as? JSON)?["email"] as? String ?? l.email
        l.name = id["name"] as? String ?? l.name
        l.accountID = idAuth["chatgpt_account_id"] as? String ?? atAuth["chatgpt_account_id"] as? String ?? l.accountID
        l.plan = (idAuth["chatgpt_plan_type"] as? String ?? atAuth["chatgpt_plan_type"] as? String)
            .map(Providers.capitalised) ?? l.plan
        return l
    }

    static func form(_ pairs: [(String, String)]) -> Data {
        var ok = CharacterSet.alphanumerics
        ok.insert(charactersIn: "-._~")
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: ok) ?? s }
        return Data(pairs.map { enc($0.0) + "=" + enc($0.1) }.joined(separator: "&").utf8)
    }
}

/// One-shot HTTP server for the OAuth redirect. Wrong-state requests get a 400 and it keeps
/// listening; the first valid callback (or an error from ChatGPT) ends it.
final class CallbackServer: @unchecked Sendable {
    let port: UInt16
    private let state: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ClaudeSwitch.CodexCallback")
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var starting: CheckedContinuation<Bool, Error>?

    private init(port: UInt16, state: String, listener: NWListener) {
        self.port = port
        self.state = state
        self.listener = listener
    }

    /// Listens on the first free port in `ports`.
    static func start(ports: [UInt16], state: String) async throws -> CallbackServer {
        for p in ports {
            try Task.checkCancellation()
            if let s = try await bind(p, state: state) { return s }
        }
        throw APIError.bad("Port 1455 is busy. Close Codex's own sign-in and try again")
    }

    /// Nil when the port is taken.
    private static func bind(_ port: UInt16, state: String) async throws -> CallbackServer? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = false
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        let server = CallbackServer(port: port, state: state, listener: listener)
        listener.newConnectionHandler = { [weak server] c in server?.accept(c) }
        let ready: Bool = try await withCheckedThrowingContinuation { cont in
            server.starting = cont
            listener.stateUpdateHandler = { [weak server] s in server?.changed(s) }
            listener.start(queue: server.queue)
        }
        return ready ? server : nil
    }

    /// Runs on `queue`. Settles `bind` once: ready, port taken, or a real failure.
    private func changed(_ s: NWListener.State) {
        guard let cont = starting else { return }
        switch s {
        case .ready: cont.resume(returning: true)
        case .failed(let e), .waiting(let e):
            listener.cancel()
            if case .posix(.EADDRINUSE) = e { cont.resume(returning: false) }
            else { cont.resume(throwing: APIError.bad("Couldn't start sign-in: \(e.localizedDescription)")) }
        case .cancelled: cont.resume(returning: false)
        default: return
        }
        starting = nil
    }

    /// The authorisation code, once the browser comes back.
    func code(timeout: TimeInterval) async throws -> String {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(APIError.bad("Sign-in timed out. Try again")))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    if let r = self.result { cont.resume(with: r) } else { self.waiter = cont }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    /// Runs on `queue`. The first result wins.
    private func finish(_ r: Result<String, Error>) {
        guard result == nil else { return }
        result = r
        listener.newConnectionHandler = nil
        listener.cancel()
        waiter?.resume(with: r)
        waiter = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, end, err in
            guard let self else { return c.cancel() }
            var buf = buf
            if let data { buf.append(data) }
            if let head = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(c, String(decoding: buf[..<head.lowerBound], as: UTF8.self))
            } else if end || err != nil || buf.count > 65_536 {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private func handle(_ c: NWConnection, _ head: String) {
        let line = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let url = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            return reply(c, 400, page("Bad request."))
        }
        guard url.path == "/auth/callback" else { return reply(c, 404, page("Not found.")) }
        let q = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["state"] == state else { return reply(c, 400, page("State mismatch.")) }
        if let e = q["error"] {
            let why = q["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? e
            reply(c, 200, page("Sign-in failed: \(why). You can close this tab."))
            return finish(.failure(APIError.bad("ChatGPT sign-in failed: \(why)")))
        }
        guard let code = q["code"], !code.isEmpty else {
            reply(c, 400, page("Missing authorisation code. You can close this tab."))
            return finish(.failure(APIError.bad("ChatGPT sent no authorisation code")))
        }
        reply(c, 200, page("Signed in to Claude Switch. You can close this tab."))
        finish(.success(code))
    }

    private func reply(_ c: NWConnection, _ status: Int, _ html: String) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "OK"
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func page(_ text: String) -> String {
        let safe = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><meta charset="utf-8"><title>Claude Switch</title>
        <body style="font:15px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:90vh;margin:0">
        <p>\(safe)</p></body>
        """
    }
}
