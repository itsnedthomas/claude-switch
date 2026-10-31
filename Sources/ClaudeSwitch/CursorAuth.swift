import Foundation

/// Cursor's own browser sign-in, the "deep control" flow the editor and cursor-agent use.
/// Cursor's login page also offers Grok and X sign-in, so xAI bundle accounts work too.
enum CursorAuth {
    static let loginURL = URL(string: "https://cursor.com/loginDeepControl")!
    static let pollURL = URL(string: "https://api2.cursor.sh/auth/poll")!
    static let tokenURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    static let meURL = URL(string: "https://cursor.com/api/auth/me")!
    static let stripeURL = URL(string: "https://cursor.com/api/auth/stripe")!
    /// Cursor's public client id for its installed apps.
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    static let signInAgain = "Sign in to Cursor again"

    /// Opens the browser via `open`, polls until signed in (10 min max), then reads the profile.
    static func signIn(open: @escaping (URL) -> Void) async throws -> ProviderLogin {
        let verifier = PKCE.random()
        let uuid = UUID().uuidString.lowercased()
        var c = URLComponents(url: loginURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "challenge", value: PKCE.challenge(verifier)),
                        URLQueryItem(name: "uuid", value: uuid),
                        URLQueryItem(name: "mode", value: "login")]
        open(c.url!)

        let t = try await poll(uuid: uuid, verifier: verifier)
        guard let access = t["accessToken"] as? String, !access.isEmpty else { throw APIError.bad("Cursor sent no token") }
        var login = ProviderLogin(access: access, refresh: (t["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        login.expires = expiry(access)
        login.accountID = userID(t["authId"] as? String) ?? userID(access: access)
        return await withProfile(login)
    }

    /// Swaps the refresh token for a new access token, keeping the profile.
    static func refresh(_ login: ProviderLogin) async throws -> ProviderLogin {
        guard let token = login.refresh, !token.isEmpty else { throw APIError.bad(signInAgain) }
        var req = URLRequest(url: tokenURL, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": token,
        ])
        // Network errors pass through so the caller can retry; anything Cursor says is final.
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              j["shouldLogout"] as? Bool != true,
              let access = j["access_token"] as? String, !access.isEmpty else { throw APIError.bad(signInAgain) }
        var out = login
        out.access = access
        // Cursor usually keeps the refresh token; take a new one if it sends one.
        if let r = j["refresh_token"] as? String, !r.isEmpty { out.refresh = r }
        if let id = j["id_token"] as? String, !id.isEmpty { out.idToken = id }
        out.expires = expiry(access)
        out.accountID = userID(access: access) ?? login.accountID
        return out
    }

    /// The session cookie for cursor.com APIs, as a whole `Cookie` header value.
    static func cookie(_ login: ProviderLogin) -> String {
        let id = login.accountID ?? userID(access: login.access) ?? ""
        return "WorkosCursorSessionToken=\(id)%3A%3A\(login.access)"
    }

    // MARK: Internals

    /// 404 while waiting, 200 with the tokens once the browser says yes. Network
    /// blips and server errors are retried; a refusal (400, 401, 403, 410) ends it.
    static func poll(uuid: String, verifier: String) async throws -> JSON {
        var c = URLComponents(url: pollURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "uuid", value: uuid), URLQueryItem(name: "verifier", value: verifier)]
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try Task.checkCancellation()
            var req = URLRequest(url: c.url!, timeoutInterval: 10)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let (data, resp) = try? await URLSession.shared.data(for: req) {
                switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
                case 200:
                    if let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
                       let a = j["accessToken"] as? String, !a.isEmpty { return j }
                case 400, 401, 403, 410:
                    throw APIError.bad("Cursor refused the sign-in")
                default: break
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw APIError.bad("Cursor sign-in timed out")
    }

    /// Fills email, name and plan. Best effort: a failed read leaves the fields as they were.
    static func withProfile(_ login: ProviderLogin) async -> ProviderLogin {
        var out = login
        async let me = get(meURL, login)
        async let stripe = get(stripeURL, login)
        if let m = await me {
            out.email = (m["email"] as? String) ?? out.email
            out.name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? out.name
        }
        if let s = await stripe {
            out.plan = (s["membershipType"] as? String) ?? (s["individualMembershipType"] as? String) ?? out.plan
        }
        return out
    }

    static func get(_ url: URL, _ login: ProviderLogin) async -> JSON? {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(cookie(login), forHTTPHeaderField: "Cookie")
        req.setValue(Providers.browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try? await Providers.fetch(req, signedOut: signInAgain)
    }

    /// "google-oauth2|user_01…" becomes "user_01…".
    static func userID(_ id: String?) -> String? {
        guard let s = id?.split(separator: "|").last.map(String.init), !s.isEmpty else { return nil }
        return s
    }

    static func userID(access: String) -> String? {
        userID(Providers.jwtPayload(access)?["sub"] as? String)
    }

    static func expiry(_ access: String) -> Date? {
        Providers.num(Providers.jwtPayload(access)?["exp"]).map { Date(timeIntervalSince1970: $0) }
    }
}
