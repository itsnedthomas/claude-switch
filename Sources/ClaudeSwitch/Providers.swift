import Foundation
import SQLite3

/// Other AI tools whose plan limits we show next to Claude's.
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case cursor, codex

    var id: String { rawValue }
    var name: String {
        switch self {
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        }
    }
}

struct ProviderAccount: Codable, Identifiable, Equatable {
    var kind: ProviderKind
    var email: String
    var plan: String
    var id: String { kind.rawValue }
}

/// One limit a provider reports, shown like Claude's weekly bar.
struct ProviderWindow: Codable, Equatable {
    var title: String
    var icon: String
    var window: Window
    /// Window length in seconds, for pace projections.
    var length: TimeInterval
    /// Extra line under the bar, e.g. "$4.20 on-demand".
    var note: String?
}

struct ProviderUsage: Codable, Equatable {
    var windows: [ProviderWindow]
    var plan: String?
    var fetchedAt: Date
}

/// Reads the logins Cursor and Codex already keep on this Mac. Never refreshes
/// or writes them: each app owns its own login.
enum Providers {
    /// The login this Mac's Cursor app / Codex CLI is signed in with, or nil if none.
    static func detect(_ kind: ProviderKind) -> ProviderAccount? {
        switch kind {
        case .cursor:
            guard let a = Cursor.auth() else { return nil }
            return ProviderAccount(kind: .cursor, email: a.email ?? "", plan: a.plan.map(capitalised) ?? "")
        case .codex:
            guard let a = Codex.auth() else { return nil }
            return ProviderAccount(kind: .codex, email: a.email ?? "", plan: a.plan.map(capitalised) ?? "")
        }
    }

    static func usage(_ kind: ProviderKind) async throws -> ProviderUsage {
        switch kind {
        case .cursor: return try await Cursor.usage()
        case .codex: return try await Codex.usage()
        }
    }

    // MARK: Cursor

    enum Cursor {
        static let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        static let url = URL(string: "https://cursor.com/api/usage-summary")!

        struct Auth { var token: String; var userID: String; var email: String?; var plan: String? }

        static func auth() -> Auth? {
            let keys = ["cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType"]
            guard let rows = readItems(keys), let token = rows[keys[0]], !token.isEmpty,
                  let sub = jwtPayload(token)?["sub"] as? String,
                  let userID = sub.split(separator: "|").last.map(String.init), !userID.isEmpty else { return nil }
            return Auth(token: token, userID: userID, email: rows[keys[1]], plan: rows[keys[2]])
        }

        static func usage() async throws -> ProviderUsage {
            guard let a = auth() else { throw APIError.bad("Sign in to Cursor first") }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("WorkosCursorSessionToken=\(a.userID)%3A%3A\(a.token)", forHTTPHeaderField: "Cookie")
            req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let j = try await fetch(req, signedOut: "Open Cursor and sign in again")

            let start = (j["billingCycleStart"] as? String).flatMap(parseISO)
            let end = (j["billingCycleEnd"] as? String).flatMap(parseISO)
            let ind = j["individualUsage"] as? JSON ?? [:]
            let plan = ind["plan"] as? JSON ?? [:]
            var pct = num(plan["totalPercentUsed"])
            if pct == nil, let used = num(plan["used"]), let limit = num(plan["limit"]), limit > 0 {
                pct = used / limit * 100
            }
            var note: String?
            if let od = ind["onDemand"] as? JSON, od["enabled"] as? Bool == true,
               let used = num(od["used"]), used > 0 {
                note = String(format: "$%.2f on-demand", used / 100)
            }
            let length = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 30 * 86400
            let w = ProviderWindow(title: "Monthly", icon: "calendar",
                                   window: Window(percent: min(max(pct ?? 0, 0), 100), resetsAt: end),
                                   length: length, note: note)
            return ProviderUsage(windows: [w], plan: (j["membershipType"] as? String).map(capitalised), fetchedAt: Date())
        }

        /// Opens the WAL database read-only. With Cursor closed there is no -shm file and
        /// a plain read-only open fails, so fall back to `immutable` (nothing is writing).
        static func open() -> OpaquePointer? {
            for uri in [db.absoluteString + "?mode=ro", db.absoluteString + "?immutable=1"] {
                var h: OpaquePointer?
                if sqlite3_open_v2(uri, &h, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
                   sqlite3_exec(h, "SELECT 1 FROM ItemTable LIMIT 1", nil, nil, nil) == SQLITE_OK { return h }
                sqlite3_close(h)
            }
            return nil
        }

        /// Values for `keys` from Cursor's VS Code state database.
        static func readItems(_ keys: [String]) -> [String: String]? {
            guard FileManager.default.fileExists(atPath: db.path), let h = open() else { return nil }
            defer { sqlite3_close(h) }
            sqlite3_busy_timeout(h, 1000)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            var out: [String: String] = [:]
            for k in keys {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, k, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_ROW, let p = sqlite3_column_blob(stmt, 0) else { continue }
                let data = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, 0)))
                out[k] = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return out
        }
    }

    // MARK: Codex

    enum Codex {
        static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        static let stale = "Open Codex once to refresh its login"

        static var authFile: URL {
            if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
                return URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("auth.json")
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        }

        struct Auth { var access: String; var accountID: String?; var email: String?; var plan: String? }

        /// Re-read on every call so a refresh by Codex is picked up. API-key logins
        /// have no plan limits, so they count as no login.
        static func auth() -> Auth? {
            guard let d = try? Data(contentsOf: authFile),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? JSON,
                  (j["auth_mode"] as? String)?.lowercased() == "chatgpt",
                  let t = j["tokens"] as? JSON, let access = t["access_token"] as? String, !access.isEmpty else { return nil }
            let id = (t["id_token"] as? String).flatMap(jwtPayload) ?? [:]
            let at = jwtPayload(access) ?? [:]
            let idAuth = id["https://api.openai.com/auth"] as? JSON ?? [:]
            let atAuth = at["https://api.openai.com/auth"] as? JSON ?? [:]
            let email = id["email"] as? String ?? (at["https://api.openai.com/profile"] as? JSON)?["email"] as? String
            let plan = idAuth["chatgpt_plan_type"] as? String ?? atAuth["chatgpt_plan_type"] as? String
            let account = t["account_id"] as? String ?? idAuth["chatgpt_account_id"] as? String
            return Auth(access: access, accountID: account, email: email, plan: plan)
        }

        static func usage() async throws -> ProviderUsage {
            guard let a = auth() else { throw APIError.bad("Sign in to Codex with ChatGPT first") }
            if let exp = num(jwtPayload(a.access)?["exp"]), exp < Date().timeIntervalSince1970 {
                throw APIError.bad(stale)
            }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("Bearer \(a.access)", forHTTPHeaderField: "Authorization")
            if let id = a.accountID { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
            req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let j = try await fetch(req, signedOut: stale)

            let rl = j["rate_limit"] as? JSON ?? [:]
            let windows = ["primary_window", "secondary_window"].compactMap { window(rl[$0]) }
            let plan = (j["plan_type"] as? String).map(capitalised) ?? a.plan.map(capitalised)
            return ProviderUsage(windows: windows, plan: plan, fetchedAt: Date())
        }

        static func window(_ any: Any?) -> ProviderWindow? {
            guard let w = any as? JSON, let pct = num(w["used_percent"]) else { return nil }
            let secs = num(w["limit_window_seconds"]) ?? 0
            var reset: Date?
            if let at = num(w["reset_at"]) { reset = Date(timeIntervalSince1970: at) }
            else if let after = num(w["reset_after_seconds"]) { reset = Date().addingTimeInterval(after) }
            let (title, icon) = label(secs)
            return ProviderWindow(title: title, icon: icon, window: Window(percent: min(max(pct, 0), 100), resetsAt: reset),
                                  length: secs, note: nil)
        }

        /// 18000 s is "5-hour", 604800 s is "Weekly", anything else by hours or days.
        static func label(_ secs: Double) -> (String, String) {
            switch Int(secs) {
            case 18000: return ("5-hour", "clock")
            case 604800: return ("Weekly", "calendar")
            case let s where s > 0 && s % 86400 == 0: return ("\(s / 86400)-day", "calendar")
            case let s where s > 0: return ("\(max(1, Int((Double(s) / 3600).rounded())))-hour", "clock")
            default: return ("Limit", "gauge")
            }
        }
    }

    // MARK: Shared

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    static func fetch(_ req: URLRequest, signedOut: String) async throws -> JSON {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.bad(signedOut) }
        guard code == 200 else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { throw APIError.bad("Unreadable reply") }
        return j
    }

    /// The claims in a JWT, unverified.
    static func jwtPayload(_ token: String) -> JSON? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let d = Data(base64Encoded: s) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? JSON
    }

    static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func capitalised(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "_" || $0 == " " }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
