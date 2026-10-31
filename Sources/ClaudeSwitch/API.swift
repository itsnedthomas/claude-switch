import Foundation

struct Window: Equatable, Codable {
    var percent: Double
    var resetsAt: Date?
}

/// Claude plans have one limit now: the weekly one. (The 5-hour window was dropped.)
struct Usage: Equatable, Codable {
    var weekly: Window?
    var fetchedAt: Date

    /// How close the account is to being blocked.
    var pressure: Double { weekly?.percent ?? 0 }
}

enum APIError: LocalizedError {
    case http(Int, String)
    case expired
    case bad(String)

    var errorDescription: String? {
        switch self {
        case .http(401, _): return "Signed out. Add this account again."
        case .http(429, _): return "Rate limited, will retry."
        case .http(let c, _): return "The server returned \(c)."
        case .expired: return "Waiting for Claude Code to refresh its login."
        case .bad(let s): return s
        }
    }
}

/// Undocumented endpoints behind Claude Code's /usage and login refresh.
enum API {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let base = URL(string: "https://api.anthropic.com/api/oauth/")!

    static func get(_ path: String, token: String) async throws -> JSON {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ClaudeSwitch/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { throw APIError.bad("Unreadable reply") }
        return j
    }

    static func usage(_ token: String) async throws -> Usage {
        let j = try await get("usage", token: token)
        return Usage(weekly: window(j["seven_day"]), fetchedAt: Date())
    }

    static func profile(_ token: String) async throws -> JSON { try await get("profile", token: token) }

    /// Builds the `oauthAccount` block Claude Code keeps in ~/.claude.json.
    static func oauthAccount(fromProfile p: JSON) -> JSON {
        let a = p["account"] as? JSON ?? [:], o = p["organization"] as? JSON ?? [:]
        var out: JSON = [
            "accountUuid": a["uuid"] ?? "",
            "emailAddress": a["email"] ?? "",
            "organizationUuid": o["uuid"] ?? "",
        ]
        out["displayName"] = a["display_name"]
        out["fullName"] = a["full_name"]
        out["organizationName"] = o["name"]
        out["organizationType"] = o["organization_type"]
        out["billingType"] = o["billing_type"]
        return out
    }

    /// Swaps a refresh token for a new pair. Only ever used on accounts that are
    /// not live, so Claude Code never holds a token we've just rotated away.
    static func refresh(_ oauth: JSON) async throws -> JSON {
        guard let rt = oauth["refreshToken"] as? String else { throw APIError.bad("No refresh token") }
        let scopes = (oauth["scopes"] as? [String]) ?? ["user:inference", "user:profile"]
        var req = URLRequest(url: tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": rt,
            "client_id": clientID, "scope": scopes.joined(separator: " "),
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
              let at = j["access_token"] as? String else {
            throw APIError.http(code == 400 ? 401 : code, String(decoding: data, as: UTF8.self))
        }
        var out = oauth
        out["accessToken"] = at
        if let newRT = j["refresh_token"] as? String { out["refreshToken"] = newRT }
        if let exp = j["expires_in"] as? Double { out["expiresAt"] = Int64((Date().timeIntervalSince1970 + exp) * 1000) }
        if let s = j["scope"] as? String { out["scopes"] = s.split(separator: " ").map(String.init) }
        return out
    }

    /// Limits read off a one-token reply's rate-limit headers, for when the usage
    /// endpoint is throttled. Only for the live account, which is in use anyway.
    static func probe(_ token: String) async throws -> Usage {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001", "max_tokens": 1,
            "system": [["type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."]],
            "messages": [["role": "user", "content": "hi"]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }
        func window(_ key: String) -> Window? {
            guard let u = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(key)-utilization").flatMap(Double.init) else { return nil }
            let reset = http.value(forHTTPHeaderField: "anthropic-ratelimit-unified-\(key)-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            return Window(percent: (u * 100).rounded(), resetsAt: reset)
        }
        return Usage(weekly: window("7d"), fetchedAt: Date())
    }

    static func expiresSoon(_ oauth: JSON, within: TimeInterval = 300) -> Bool {
        guard let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue else { return true }
        return ms / 1000 - Date().timeIntervalSince1970 < within
    }

    private static func window(_ any: Any?) -> Window? {
        guard let w = any as? JSON, let pct = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return Window(percent: pct, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Anthropic sends microseconds; drop the fraction if the formatter balks.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }
}
